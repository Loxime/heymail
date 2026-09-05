#!/usr/bin/env bash

set -euo pipefail

readonly ALPINE_IMAGE="alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40"
readonly UNTRUSTED_NETWORK="heymail_untrusted_test_$$"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

cleanup() {
    docker network rm "$UNTRUSTED_NETWORK" >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "=== HeyMail PostgreSQL container security tests ==="

DB_CONTAINER="$(docker compose ps -q database)"

if [[ -z "$DB_CONTAINER" ]]; then
    fail "database container is not running"
fi

# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

HEALTH="$(
    docker inspect "$DB_CONTAINER" \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
)"

[[ "$HEALTH" == "healthy" ]] \
    || fail "database health status is '$HEALTH'"

pass "database container is healthy"

# ---------------------------------------------------------------------------
# Root filesystem
# ---------------------------------------------------------------------------

READ_ONLY="$(
    docker inspect "$DB_CONTAINER" \
        --format '{{.HostConfig.ReadonlyRootfs}}'
)"

[[ "$READ_ONLY" == "true" ]] \
    || fail "root filesystem is not read-only"

pass "root filesystem is read-only"

if docker compose exec -T database \
    sh -c 'touch /etc/heymail-security-test' \
    >/dev/null 2>&1; then
    fail "write to /etc unexpectedly succeeded"
fi

pass "write to root filesystem is effectively blocked"

# ---------------------------------------------------------------------------
# Privilege escalation
# ---------------------------------------------------------------------------

SECURITY_OPT="$(
    docker inspect "$DB_CONTAINER" \
        --format '{{json .HostConfig.SecurityOpt}}'
)"

grep -q 'no-new-privileges:true' <<<"$SECURITY_OPT" \
    || fail "no-new-privileges is not enabled"

pass "no-new-privileges is enabled"

# ---------------------------------------------------------------------------
# Docker socket
# ---------------------------------------------------------------------------

if docker inspect "$DB_CONTAINER" \
    --format '{{range .Mounts}}{{println .Destination}}{{end}}' \
    | grep -qx '/var/run/docker.sock'; then
    fail "Docker socket is mounted inside the database container"
fi

pass "Docker socket is not exposed"

# ---------------------------------------------------------------------------
# Port exposure
# ---------------------------------------------------------------------------

if [[ -n "$(docker port "$DB_CONTAINER" 5432/tcp 2>/dev/null || true)" ]]; then
    fail "PostgreSQL port 5432 is published on the host"
fi

pass "PostgreSQL port is not published on the host"

# ---------------------------------------------------------------------------
# Network membership
# ---------------------------------------------------------------------------

NETWORKS="$(
    docker inspect "$DB_CONTAINER" \
        --format '{{range $name, $conf := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        | sed '/^[[:space:]]*$/d'
)"

[[ "$NETWORKS" == "heymail_data" ]] \
    || fail "database is attached to unexpected network(s): $NETWORKS"

pass "database belongs only to heymail_data"

DATA_INTERNAL="$(
    docker network inspect heymail_data \
        --format '{{.Internal}}'
)"

[[ "$DATA_INTERNAL" == "true" ]] \
    || fail "heymail_data is not an internal Docker network"

pass "heymail_data is internal"

# ---------------------------------------------------------------------------
# Secret handling
# ---------------------------------------------------------------------------

ENVIRONMENT="$(
    docker inspect "$DB_CONTAINER" \
        --format '{{range .Config.Env}}{{println .}}{{end}}'
)"

grep -q '^POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password$' \
    <<<"$ENVIRONMENT" \
    || fail "POSTGRES_PASSWORD_FILE is not configured correctly"

if grep -q '^POSTGRES_PASSWORD=' <<<"$ENVIRONMENT"; then
    fail "PostgreSQL password is exposed as an environment variable"
fi

pass "database password is referenced through a secret file"

docker compose exec -T database \
    sh -c 'test -r /run/secrets/postgres_password' \
    || fail "database cannot read its assigned secret"

pass "database can read its assigned secret"

# ---------------------------------------------------------------------------
# Unauthorized Docker network
# ---------------------------------------------------------------------------

docker network create \
    --driver bridge \
    "$UNTRUSTED_NETWORK" \
    >/dev/null

DB_IP="$(
    docker inspect "$DB_CONTAINER" \
        --format '{{(index .NetworkSettings.Networks "heymail_data").IPAddress}}'
)"

if docker run --rm \
    --network "$UNTRUSTED_NETWORK" \
    -e DB_IP="$DB_IP" \
    "$ALPINE_IMAGE" \
    sh -c 'nc -zw3 "$DB_IP" 5432' \
    >/dev/null 2>&1; then

    fail "database is reachable from an unauthorized Docker network"
fi

pass "database is unreachable from an unauthorized Docker network"

# ---------------------------------------------------------------------------
# Authorized Docker network
# ---------------------------------------------------------------------------

docker run --rm \
    --network heymail_data \
    "$ALPINE_IMAGE" \
    sh -c 'nc -zw3 database 5432' \
    >/dev/null 2>&1 \
    || fail "database is unreachable from authorized data network"

pass "database is reachable from authorized data network"

# ---------------------------------------------------------------------------
# Secret isolation
# ---------------------------------------------------------------------------

if docker run --rm \
    --network heymail_data \
    "$ALPINE_IMAGE" \
    sh -c 'test -e /run/secrets/postgres_password'; then

    fail "PostgreSQL secret leaked to unrelated container"
fi

pass "PostgreSQL secret is not propagated to unrelated containers"

echo
echo "ALL POSTGRESQL CONTAINER SECURITY TESTS PASSED"
