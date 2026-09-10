#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

echo "=== HeyMail HTTPS gateway security tests ==="

docker compose config --quiet \
    || fail "Compose configuration invalid"

docker compose up \
    -d \
    --wait \
    --build \
    gateway \
    >/dev/null

GATEWAY="$(
    docker compose ps -q gateway
)"

[ -n "$GATEWAY" ] \
    || fail "gateway container unavailable"

UID_VALUE="$(
    docker compose exec -T gateway \
        id -u
)"

[ "$UID_VALUE" = "1000" ] \
    || fail "gateway does not run as UID 1000"

pass "gateway runs non-root"

READ_ONLY="$(
    docker inspect "$GATEWAY" \
        --format '{{.HostConfig.ReadonlyRootfs}}'
)"

[ "$READ_ONLY" = "true" ] \
    || fail "gateway root filesystem is writable"

pass "gateway root filesystem is read-only"

CAP_DROP="$(
    docker inspect "$GATEWAY" \
        --format '{{json .HostConfig.CapDrop}}'
)"

grep -Fq '"ALL"' <<<"$CAP_DROP" \
    || fail "gateway capabilities are not fully dropped"

pass "gateway has no Linux capabilities"

SECURITY_OPT="$(
    docker inspect "$GATEWAY" \
        --format '{{json .HostConfig.SecurityOpt}}'
)"

grep -Fq 'no-new-privileges:true' \
    <<<"$SECURITY_OPT" \
    || fail "gateway lacks no-new-privileges"

pass "gateway has no-new-privileges"

NETWORKS="$(
    docker inspect "$GATEWAY" \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        | sed '/^[[:space:]]*$/d' \
        | sort
)"

[ "$NETWORKS" = "heymail_gateway" ] \
    || fail "unexpected gateway networks: $NETWORKS"

INTERNAL="$(
    docker network inspect heymail_gateway \
        --format '{{.Internal}}'
)"

[ "$INTERNAL" = "false" ] \
    || fail "gateway ingress network unexpectedly blocks host connectivity"

pass "gateway uses a dedicated host-reachable bridge"

PORT_BINDING="$(
    docker inspect "$GATEWAY" \
        --format '{{with index .HostConfig.PortBindings "8443/tcp"}}{{range .}}{{println .HostIp ":" .HostPort}}{{end}}{{end}}' \
        | tr -d " "
)"

[ "$PORT_BINDING" = "127.0.0.1:8443" ] \
    || fail "unexpected gateway host binding: ${PORT_BINDING:-none}"

pass "HTTPS is published only on host loopback"

docker compose exec -T gateway sh -ec '
test -S /run/heymail-fpm/heymail.sock

test -r /run/secrets/gateway_tls_cert
test -r /run/secrets/gateway_tls_key

test ! -e /run/secrets/app_secret
test ! -e /run/secrets/postgres_app_password
test ! -e /run/secrets/payload_kek_v1
test ! -e /run/secrets/api_key
test ! -e /run/secrets/api_secret
' || fail "gateway trust boundary is invalid"

pass "gateway sees only TLS material and FPM socket"

docker compose exec -T gateway \
    nginx -t \
    >/dev/null 2>&1 \
    || fail "Nginx configuration invalid"

pass "Nginx configuration is valid"

curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --fail \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    https://api.heymail.test:8443/gateway-health \
    --output /dev/null \
    || fail "trusted TLS gateway health request failed"

pass "TLS certificate and hostname validate"

HTTP_STATUS="$(
    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --output /dev/null \
        --write-out '%{http_code}' \
        --header 'Content-Type: application/json' \
        --request POST \
        --data '{}' \
        https://api.heymail.test:8443/api/v1/send
)"

[ "$HTTP_STATUS" = "401" ] \
    || fail "unauthenticated HTTPS API returned $HTTP_STATUS instead of 401"

pass "real HTTPS request reaches Symfony authentication"

echo

if grep -Fq \
    '$remote_user' \
    docker/gateway/nginx.conf
then
    fail "Nginx access log configuration exposes authenticated usernames"
fi

if grep -Eq \
    '^[[:space:]]*access\.format.*%u' \
    docker/php/heymail-fpm.conf
then
    fail "PHP-FPM access log configuration exposes authenticated usernames"
fi

pass "HTTP access log formats exclude authenticated usernames"


ACCESS_LOG_LINES="$(
    grep -E \
        '^[[:space:]]*access_log[[:space:]]+' \
        docker/gateway/nginx.conf \
        || true
)"

if [ -z "$ACCESS_LOG_LINES" ]; then
    unset ACCESS_LOG_LINES

    fail "Nginx has no explicit access_log directive"
fi

UNSAFE_ACCESS_LOG_LINES="$(
    printf '%s\n' \
        "$ACCESS_LOG_LINES" \
        | grep -Ev \
            '^[[:space:]]*access_log[[:space:]]+/dev/stdout[[:space:]]+heymail;[[:space:]]*$' \
        || true
)"

unset ACCESS_LOG_LINES

if [ -n "$UNSAFE_ACCESS_LOG_LINES" ]; then
    unset UNSAFE_ACCESS_LOG_LINES

    fail "an Nginx access log can fall back to the built-in combined format"
fi

unset UNSAFE_ACCESS_LOG_LINES

pass "all Nginx access logs explicitly use the safe HeyMail format"


FPM_RUNTIME_CONFIG="$(
    docker compose exec \
        -T \
        api \
        sh -c '
            timeout 10 \
                php-fpm -tt \
                2>&1
        '
)"

if ! grep -Eq \
    'access\.log[[:space:]]*=[[:space:]]*/dev/null' \
    <<<"$FPM_RUNTIME_CONFIG"
then
    unset FPM_RUNTIME_CONFIG

    fail \
        "running PHP-FPM does not disable HTTP access logging"
fi

if grep -Eq \
    'access\.format.*%u' \
    <<<"$FPM_RUNTIME_CONFIG"
then
    unset FPM_RUNTIME_CONFIG

    fail \
        "running PHP-FPM access format still contains authenticated username"
fi

unset FPM_RUNTIME_CONFIG

pass "running PHP-FPM access logging is disabled"

LOG_TEST_DIR="$(
    mktemp -d \
        /tmp/heymail-log-security.XXXXXX
)"

chmod 0700 \
    "$LOG_TEST_DIR"

LOG_WINDOW_START="$(
    date -u '+%Y-%m-%dT%H:%M:%SZ'
)"

API_KEY="$(
    cat secrets/api_key
)"

API_SECRET="$(
    cat secrets/api_secret
)"

AUTH_B64="$(
    printf '%s:%s' \
        "$API_KEY" \
        "$API_SECRET" \
        | base64 -w 0
)"

printf \
    'header = "Authorization: Basic %s"\n' \
    "$AUTH_B64" \
    > "$LOG_TEST_DIR/auth.conf"

chmod 0600 \
    "$LOG_TEST_DIR/auth.conf"

sleep 1

LOG_TEST_HTTP="$(
    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --config "$LOG_TEST_DIR/auth.conf" \
        --output /dev/null \
        --write-out '%{http_code}' \
        'https://api.heymail.test:8443/api/v1/messages/2147483647'
)"

case "$LOG_TEST_HTTP" in
    200|404)
        ;;
    *)
        rm -rf "$LOG_TEST_DIR"

        unset \
            API_KEY \
            API_SECRET \
            AUTH_B64 \
            LOG_WINDOW_START \
            LOG_TEST_HTTP

        fail \
            "credential log probe returned unexpected HTTP $LOG_TEST_HTTP"
        ;;
esac

sleep 1

RUNTIME_LOGS="$(
    docker compose logs \
        --no-color \
        --since "$LOG_WINDOW_START" \
        gateway \
        api \
        2>&1
)"

LEAK_DETECTED="false"

case "$RUNTIME_LOGS" in
    *"$API_KEY"*)
        LEAK_DETECTED="true"
        ;;
esac

case "$RUNTIME_LOGS" in
    *"$API_SECRET"*)
        LEAK_DETECTED="true"
        ;;
esac

case "$RUNTIME_LOGS" in
    *"$AUTH_B64"*)
        LEAK_DETECTED="true"
        ;;
esac

rm -rf \
    "$LOG_TEST_DIR"

unset \
    API_KEY \
    API_SECRET \
    AUTH_B64 \
    LOG_WINDOW_START \
    LOG_TEST_HTTP \
    RUNTIME_LOGS

if [ "$LEAK_DETECTED" = "true" ]; then
    unset LEAK_DETECTED

    fail \
        "API credentials leaked into fresh authenticated-request logs"
fi

unset LEAK_DETECTED

pass "authenticated API credentials are absent from fresh runtime logs"

echo "ALL HTTPS GATEWAY SECURITY TESTS PASSED"
