#!/usr/bin/env bash

set -euo pipefail

echo "=== HeyMail Symfony API container security tests ==="

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

# ---------------------------------------------------------------------------
# Compose / startup
# ---------------------------------------------------------------------------

docker compose config --quiet \
    || fail "Compose configuration is invalid"

docker compose up -d api >/dev/null

API_CONTAINER="$(docker compose ps -q api)"

[ -n "$API_CONTAINER" ] \
    || fail "API container does not exist"

# Wait explicitly for Docker health instead of assuming startup == ready.
HEALTH=""

for _ in $(seq 1 30); do
    HEALTH="$(
        docker inspect "$API_CONTAINER" \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
    )"

    case "$HEALTH" in
        healthy)
            break
            ;;
        unhealthy)
            docker compose logs --tail=100 api >&2 || true
            fail "API container became unhealthy"
            ;;
    esac

    sleep 2
done

[ "$HEALTH" = "healthy" ] \
    || fail "API container did not become healthy"

pass "API container is healthy"

# ---------------------------------------------------------------------------
# Non-root execution
# ---------------------------------------------------------------------------

IMAGE_USER="$(
    docker image inspect heymail-api:local \
        --format '{{.Config.User}}'
)"

case "$IMAGE_USER" in
    ""|root|0|0:0)
        fail "API image defaults to a privileged user: ${IMAGE_USER:-<empty>}"
        ;;
esac

pass "API image defaults to non-root user ($IMAGE_USER)"

CONTAINER_USER="$(
    docker inspect "$API_CONTAINER" \
        --format '{{.Config.User}}'
)"

case "$CONTAINER_USER" in
    ""|root|0|0:0)
        fail "API container runs as a privileged user: ${CONTAINER_USER:-<empty>}"
        ;;
esac

pass "API container is configured as non-root ($CONTAINER_USER)"

PID1_UID="$(
    docker compose exec -T api sh -lc \
        "awk '/^Uid:/ {print \$2}' /proc/1/status"
)"

[ "$PID1_UID" != "0" ] \
    || fail "PID 1 effectively runs as root"

pass "API PID 1 effectively runs as UID $PID1_UID"

# ---------------------------------------------------------------------------
# Filesystem confinement
# ---------------------------------------------------------------------------

READ_ONLY="$(
    docker inspect "$API_CONTAINER" \
        --format '{{.HostConfig.ReadonlyRootfs}}'
)"

[ "$READ_ONLY" = "true" ] \
    || fail "API root filesystem is not read-only"

pass "API root filesystem is read-only"

docker compose exec -T api sh -lc '
if touch /etc/heymail-security-write-test 2>/dev/null
then
    rm -f /etc/heymail-security-write-test
    exit 1
fi
' || fail "API can write to its root filesystem"

pass "write to API root filesystem is effectively blocked"

docker compose exec -T api sh -lc '
set -eu

touch /app/var/heymail-security-write-test
rm /app/var/heymail-security-write-test
' || fail "Symfony writable tmpfs is unavailable"

pass "Symfony var tmpfs is writable"

# ---------------------------------------------------------------------------
# Linux privilege confinement
# ---------------------------------------------------------------------------

SECURITY_OPT="$(
    docker inspect "$API_CONTAINER" \
        --format '{{json .HostConfig.SecurityOpt}}'
)"

grep -Fq 'no-new-privileges:true' <<<"$SECURITY_OPT" \
    || fail "no-new-privileges is missing"

pass "no-new-privileges is enabled"

CAP_DROP="$(
    docker inspect "$API_CONTAINER" \
        --format '{{json .HostConfig.CapDrop}}'
)"

grep -Fq '"ALL"' <<<"$CAP_DROP" \
    || fail "not all Linux capabilities are dropped"

pass "all Linux capabilities are dropped"

# ---------------------------------------------------------------------------
# Docker daemon isolation
# ---------------------------------------------------------------------------

if docker inspect "$API_CONTAINER" \
    --format '{{range .Mounts}}{{println .Destination}}{{end}}' \
    | grep -Fxq '/var/run/docker.sock'
then
    fail "Docker socket is exposed to API"
fi

pass "Docker socket is absent"

# ---------------------------------------------------------------------------
# Network confinement
# ---------------------------------------------------------------------------

PORT_BINDINGS="$(
    docker inspect "$API_CONTAINER" \
        --format '{{json .HostConfig.PortBindings}}'
)"

case "$PORT_BINDINGS" in
    null|"{}")
        ;;
    *)
        fail "API publishes host ports: $PORT_BINDINGS"
        ;;
esac

pass "API publishes no host ports"

NETWORKS="$(
    docker inspect "$API_CONTAINER" \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        | sed '/^[[:space:]]*$/d' \
        | sort
)"

[ "$NETWORKS" = "heymail_data" ] \
    || fail "unexpected API networks: $NETWORKS"

pass "API belongs only to heymail_data"

DATA_INTERNAL="$(
    docker network inspect heymail_data \
        --format '{{.Internal}}'
)"

[ "$DATA_INTERNAL" = "true" ] \
    || fail "heymail_data is not internal"

pass "heymail_data is internal"

# ---------------------------------------------------------------------------
# FPM exposure
# ---------------------------------------------------------------------------

docker compose exec -T api sh -lc '
grep -Eq "^[[:space:]]*listen[[:space:]]*=[[:space:]]*127\.0\.0\.1:9000[[:space:]]*$" \
    /usr/local/etc/php-fpm.d/zz-heymail.conf
' || fail "PHP-FPM is not restricted to loopback"

pass "PHP-FPM listens only on container loopback"

docker compose exec -T api \
    php-fpm -tt >/dev/null 2>&1 \
    || fail "PHP-FPM configuration is invalid"

pass "PHP-FPM configuration is valid"

docker compose exec -T api sh -lc '
grep -Eq "^[[:space:]]*clear_env[[:space:]]*=[[:space:]]*yes[[:space:]]*$" \
    /usr/local/etc/php-fpm.d/zz-heymail.conf
' || fail "PHP-FPM does not clear inherited environment"

pass "PHP-FPM environment inheritance is disabled"

# ---------------------------------------------------------------------------
# Secret boundary
# ---------------------------------------------------------------------------

docker compose exec -T api sh -lc '
set -eu

test -r /run/secrets/app_secret
test -r /run/secrets/postgres_app_password

test ! -e /run/secrets/postgres_password
test ! -e /run/secrets/postgres_migrator_password
' || fail "API secret boundary is incorrect"

pass "API receives only runtime secrets"

ENV_DUMP="$(
    docker inspect "$API_CONTAINER" \
        --format '{{range .Config.Env}}{{println .}}{{end}}'
)"

grep -Fxq \
    'APP_SECRET_FILE=/run/secrets/app_secret' \
    <<<"$ENV_DUMP" \
    || fail "APP_SECRET_FILE path is missing"

grep -Fxq \
    'DB_PASSWORD_FILE=/run/secrets/postgres_app_password' \
    <<<"$ENV_DUMP" \
    || fail "DB_PASSWORD_FILE path is missing"

pass "environment contains secret paths rather than secret values"

# Ensure known secret values themselves did not leak to the runtime
# environment or Docker image history.
IMAGE_HISTORY="$(
    docker history \
        --no-trunc \
        --format '{{.CreatedBy}}' \
        heymail-api:local
)"

for SECRET_FILE in \
    secrets/app_secret \
    secrets/postgres_app_password \
    secrets/postgres_password \
    secrets/postgres_migrator_password
do
    [ -r "$SECRET_FILE" ] \
        || fail "expected local secret file is missing: $SECRET_FILE"

    SECRET_VALUE="$(cat "$SECRET_FILE")"

    [ -n "$SECRET_VALUE" ] \
        || fail "secret file is empty: $SECRET_FILE"

    if grep -Fq -- "$SECRET_VALUE" <<<"$ENV_DUMP"; then
        fail "secret value from $SECRET_FILE leaked into container environment"
    fi

    if grep -Fq -- "$SECRET_VALUE" <<<"$IMAGE_HISTORY"; then
        fail "secret value from $SECRET_FILE leaked into Docker image history"
    fi
done

unset SECRET_VALUE

pass "known secret values are absent from environment and image history"

# ---------------------------------------------------------------------------
# Production configuration policy
# ---------------------------------------------------------------------------

docker compose exec -T api sh -lc '
set -eu

test ! -e /app/.env
test -r /app/vendor/autoload.php
test -r /app/vendor/autoload_runtime.php
' || fail "production runtime files are inconsistent"

pass "API image does not depend on a .env file"
pass "Composer and Symfony runtime autoloaders are present"

docker compose exec -T api php -r '
$options = json_decode(
    getenv("APP_RUNTIME_OPTIONS") ?: "",
    true,
);

if (($options["disable_dotenv"] ?? null) !== true) {
    exit(1);
}
' || fail "Symfony dotenv loading is not disabled"

pass "Symfony dotenv loading is disabled"

# ---------------------------------------------------------------------------
# No development tooling in runtime image
# ---------------------------------------------------------------------------

docker compose exec -T api sh -lc '
set -eu

test ! -d /app/vendor/phpunit
test ! -d /app/vendor/phpstan
test ! -d /app/vendor/symfony/browser-kit
' || fail "development dependencies are present in runtime image"

pass "development dependencies are absent from runtime image"

# ---------------------------------------------------------------------------
# PHP hardening
# ---------------------------------------------------------------------------

docker compose exec -T api php -r '
$failures = [];

$disabled = static function (string $name) use (&$failures): void {
    $value = ini_get($name);

    if (!in_array($value, ["", "0"], true)) {
        $failures[] = sprintf(
            "%s expected disabled, got %s",
            $name,
            var_export($value, true),
        );
    }
};

$enabled = static function (string $name) use (&$failures): void {
    $value = ini_get($name);

    if ($value !== "1") {
        $failures[] = sprintf(
            "%s expected enabled, got %s",
            $name,
            var_export($value, true),
        );
    }
};

$disabled("expose_php");
$disabled("display_errors");
$enabled("zend.exception_ignore_args");
$enabled("opcache.enable");

if ($failures !== []) {
    foreach ($failures as $failure) {
        fwrite(STDERR, "PHP hardening mismatch: {$failure}\n");
    }

    exit(1);
}
' || fail "PHP hardening settings are not applied"

pass "PHP general hardening settings are applied"

FPM_INFO="$(
    docker compose exec -T api php-fpm -i
)" || fail "unable to inspect PHP-FPM configuration"

grep -Eq "^cgi\.fix_pathinfo => (Off|0) => (Off|0)$" \
    <<<"$FPM_INFO" \
    || fail "PHP-FPM cgi.fix_pathinfo is not disabled"

pass "PHP-FPM cgi.fix_pathinfo is disabled"

# ---------------------------------------------------------------------------
# Actual Symfony boot
# ---------------------------------------------------------------------------

docker compose exec -T api \
    php bin/console about \
    --no-interaction \
    >/dev/null \
    || fail "Symfony Kernel cannot boot"

pass "Symfony Kernel boots successfully"

# ---------------------------------------------------------------------------
# Doctrine least-privilege identity
# ---------------------------------------------------------------------------

DBAL_RESULT="$(
    docker compose exec -T api \
        php bin/console dbal:run-sql \
        "SELECT current_user" \
        --no-interaction
)"

grep -Eq '(^|[[:space:]])heymail_app([[:space:]]|$)' \
    <<<"$DBAL_RESULT" \
    || fail "Doctrine does not connect as heymail_app"

if grep -Eq 'heymail_admin|heymail_migrator' <<<"$DBAL_RESULT"; then
    fail "Doctrine is using a privileged PostgreSQL role"
fi

pass "Doctrine connects exclusively as heymail_app"

echo
echo "ALL SYMFONY API CONTAINER SECURITY TESTS PASSED"
