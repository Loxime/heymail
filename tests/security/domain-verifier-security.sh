#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

echo "=== HeyMail domain-verifier security tests ==="

docker compose up \
    -d \
    --wait \
    --build \
    fake-dns \
    domain-verifier \
    >/dev/null

VERIFIER="$(
    docker compose ps \
        -q \
        domain-verifier
)"

DNS="$(
    docker compose ps \
        -q \
        fake-dns
)"

[ -n "$VERIFIER" ] \
    || fail "domain-verifier container unavailable"

[ -n "$DNS" ] \
    || fail "fake-dns container unavailable"

UID_VALUE="$(
    docker compose exec \
        -T \
        domain-verifier \
        id -u
)"

[ "$UID_VALUE" = "1000" ] \
    || fail "domain-verifier does not run as UID 1000"

pass "domain-verifier runs non-root"

READ_ONLY="$(
    docker inspect \
        "$VERIFIER" \
        --format '{{.HostConfig.ReadonlyRootfs}}'
)"

[ "$READ_ONLY" = "true" ] \
    || fail "domain-verifier root filesystem is writable"

pass "domain-verifier root filesystem is read-only"

CAP_DROP="$(
    docker inspect \
        "$VERIFIER" \
        --format '{{json .HostConfig.CapDrop}}'
)"

grep -Fq '"ALL"' \
    <<<"$CAP_DROP" \
    || fail "domain-verifier capabilities are not fully dropped"

pass "domain-verifier has no Linux capabilities"

SECURITY_OPT="$(
    docker inspect \
        "$VERIFIER" \
        --format '{{json .HostConfig.SecurityOpt}}'
)"

grep -Fq \
    'no-new-privileges:true' \
    <<<"$SECURITY_OPT" \
    || fail "domain-verifier lacks no-new-privileges"

pass "domain-verifier has no-new-privileges"

NETWORKS="$(
    docker inspect \
        "$VERIFIER" \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        | sed '/^[[:space:]]*$/d' \
        | sort
)"

EXPECTED_NETWORKS="$(
    printf '%s\n' \
        heymail_data \
        heymail_dns_lab \
        | sort
)"

[ "$NETWORKS" = "$EXPECTED_NETWORKS" ] \
    || fail "unexpected domain-verifier networks: $NETWORKS"

pass "domain-verifier belongs only to data and DNS networks"

for NETWORK in \
    heymail_data \
    heymail_dns_lab
do
    INTERNAL="$(
        docker network inspect \
            "$NETWORK" \
            --format '{{.Internal}}'
    )"

    [ "$INTERNAL" = "true" ] \
        || fail "$NETWORK is not internal"
done

pass "domain-verifier networks have no direct Internet egress"

if [ -n "$(docker port "$VERIFIER")" ]
then
    fail "domain-verifier publishes host ports"
fi

pass "domain-verifier publishes no host ports"

docker compose exec \
    -T \
    domain-verifier \
    sh -ec '
        test ! -e /var/run/docker.sock
        test ! -e /run/docker.sock

        test -r /run/secrets/app_secret
        test -r /run/secrets/postgres_app_password

        test ! -e /run/secrets/api_key
        test ! -e /run/secrets/api_secret
        test ! -e /run/secrets/payload_kek_v1

        test ! -e /run/heymail-dkim
    ' \
    || fail "domain-verifier secret boundary is invalid"

pass "domain-verifier receives only the secrets required for DNS verification"

DNS_UID="$(
    docker compose exec \
        -T \
        fake-dns \
        id -u
)"

[ "$DNS_UID" = "10003" ] \
    || fail "fake DNS does not run as UID 10003"

DNS_READ_ONLY="$(
    docker inspect \
        "$DNS" \
        --format '{{.HostConfig.ReadonlyRootfs}}'
)"

[ "$DNS_READ_ONLY" = "true" ] \
    || fail "fake DNS root filesystem is writable"

DNS_CAP_DROP="$(
    docker inspect \
        "$DNS" \
        --format '{{json .HostConfig.CapDrop}}'
)"

grep -Fq '"ALL"' \
    <<<"$DNS_CAP_DROP" \
    || fail "fake DNS capabilities are not fully dropped"

DNS_NETWORKS="$(
    docker inspect \
        "$DNS" \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        | sed '/^[[:space:]]*$/d'
)"

[ "$DNS_NETWORKS" = "heymail_dns_lab" ] \
    || fail "fake DNS has unexpected networks: $DNS_NETWORKS"

if [ -n "$(docker port "$DNS")" ]
then
    fail "fake DNS publishes host ports"
fi

pass "fake DNS is non-root, read-only, capability-free and internal-only"

echo
echo "ALL DOMAIN VERIFIER SECURITY TESTS PASSED"
