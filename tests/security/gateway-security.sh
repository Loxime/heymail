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
echo "ALL HTTPS GATEWAY SECURITY TESTS PASSED"
