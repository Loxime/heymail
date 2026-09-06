#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
        && pwd
)"

cd "$ROOT_DIR"

ALPINE_IMAGE="alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"

PRIVATE_VOLUME="heymail_rspamd_dkim_private"
PUBLIC_VOLUME="heymail_rspamd_dkim_public"

PRIVATE_KEY="/private/heymail.test.lab.key"
RSPAMD_PRIVATE_KEY="/run/heymail-dkim/heymail.test.lab.key"
PUBLIC_RECORD="/public/heymail.test.lab.dns.txt"

pass() {
    printf 'PASS: %s\n' "$1"
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

echo "=== HeyMail DKIM key boundary security tests ==="

docker compose config --quiet \
    || fail "Compose configuration is invalid"

sh -n docker/rspamd/dkim-bootstrap.sh \
    || fail "DKIM bootstrap script has invalid syntax"

pass "Compose and DKIM bootstrap syntax are valid"


# ---------------------------------------------------------------------------
# Static Compose trust boundary
# ---------------------------------------------------------------------------

COMPOSE_JSON="$(
    docker compose config --format json
)"

COMPOSE_DKIM_BOUNDARY="$(
    python3 -c '
import json
import sys

config = json.load(sys.stdin)
services = config["services"]

private_sources = {
    "rspamd_dkim_private",
    "heymail_rspamd_dkim_private",
}

consumers = []

for name, service in sorted(services.items()):
    volumes = service.get("volumes") or []

    for volume in volumes:
        if (
            volume.get("type") == "volume"
            and volume.get("source") in private_sources
        ):
            consumers.append(name)
            break

print("\n".join(consumers))
' <<<"$COMPOSE_JSON"
)"

EXPECTED_DKIM_CONSUMERS="$(
    printf '%s\n' \
        rspamd \
        rspamd-dkim-bootstrap
)"

[ "$COMPOSE_DKIM_BOUNDARY" = "$EXPECTED_DKIM_CONSUMERS" ] || {
    printf 'Expected DKIM private-volume consumers:\n%s\n' \
        "$EXPECTED_DKIM_CONSUMERS" >&2
    printf 'Actual DKIM private-volume consumers:\n%s\n' \
        "$COMPOSE_DKIM_BOUNDARY" >&2
    fail "unexpected service can access the private DKIM volume"
}

pass "only Rspamd and its bootstrap reference the private DKIM volume"


if python3 -c '
import json
import sys

config = json.load(sys.stdin)
services = config["services"]

bootstrap = services["rspamd-dkim-bootstrap"]
rspamd = services["rspamd"]

assert bootstrap["network_mode"] == "none"
assert str(bootstrap["user"]) == "0:0"
assert bootstrap["read_only"] is True
assert set(bootstrap.get("cap_drop") or []) == {"ALL"}
assert set(bootstrap.get("cap_add") or []) == {"CHOWN"}

bootstrap_private = [
    volume
    for volume in (bootstrap.get("volumes") or [])
    if volume.get("target") == "/private"
]

assert len(bootstrap_private) == 1

rspamd_private = [
    volume
    for volume in (rspamd.get("volumes") or [])
    if volume.get("target") == "/run/heymail-dkim"
]

assert len(rspamd_private) == 1
assert rspamd_private[0].get("read_only") is True
' <<<"$COMPOSE_JSON"
then
    pass "Compose enforces the DKIM bootstrap and signer trust boundary"
else
    fail "Compose DKIM trust boundary is not enforced"
fi


# ---------------------------------------------------------------------------
# Persistent key provisioning
# ---------------------------------------------------------------------------

docker compose up \
    -d \
    --build \
    --force-recreate \
    rspamd \
    >/dev/null

RSPAMD_CONTAINER="$(
    docker compose ps -q rspamd
)"

[ -n "$RSPAMD_CONTAINER" ] \
    || fail "Rspamd container does not exist"

for _ in $(seq 1 90)
do
    HEALTH="$(
        docker inspect "$RSPAMD_CONTAINER" \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
    )"

    case "$HEALTH" in
        healthy)
            break
            ;;

        unhealthy)
            docker compose logs \
                --tail=100 \
                rspamd \
                >&2 \
                || true

            fail "Rspamd became unhealthy"
            ;;

        *)
            sleep 2
            ;;
    esac
done

HEALTH="$(
    docker inspect "$RSPAMD_CONTAINER" \
        --format '{{.State.Health.Status}}'
)"

[ "$HEALTH" = "healthy" ] \
    || fail "Rspamd did not become healthy"

pass "Rspamd becomes healthy with its persistent DKIM key"


PUBLIC_BEFORE="$(
    docker run \
        --rm \
        --network none \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        -v "${PUBLIC_VOLUME}:/public:ro" \
        "$ALPINE_IMAGE" \
        cat "$PUBLIC_RECORD"
)"

BOOTSTRAP_OUTPUT=""

if BOOTSTRAP_OUTPUT="$(
    docker compose run \
        --rm \
        --no-deps \
        rspamd-dkim-bootstrap \
        2>&1
)"
then
    :
else
    printf '%s\n' "$BOOTSTRAP_OUTPUT" >&2
    fail "DKIM bootstrap idempotence run failed"
fi

grep -F \
    'DKIM keypair already provisioned and valid' \
    <<<"$BOOTSTRAP_OUTPUT" \
    >/dev/null \
    || fail "existing DKIM keypair was not recognized"

PUBLIC_AFTER="$(
    docker run \
        --rm \
        --network none \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        -v "${PUBLIC_VOLUME}:/public:ro" \
        "$ALPINE_IMAGE" \
        cat "$PUBLIC_RECORD"
)"

[ "$PUBLIC_BEFORE" = "$PUBLIC_AFTER" ] \
    || fail "DKIM public key changed during an idempotent bootstrap"

pass "DKIM bootstrap is idempotent and does not rotate the key"


# ---------------------------------------------------------------------------
# Private volume contents and metadata
# ---------------------------------------------------------------------------

PRIVATE_METADATA="$(
    docker run \
        --rm \
        --network none \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        -v "${PRIVATE_VOLUME}:/private:ro" \
        "$ALPINE_IMAGE" \
        stat \
            -c '%u:%g:%a' \
            "$PRIVATE_KEY"
)"

[ "$PRIVATE_METADATA" = "100:101:400" ] \
    || fail "private DKIM key metadata is not 100:101:0400"

PRIVATE_FILES="$(
    docker run \
        --rm \
        --network none \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        -v "${PRIVATE_VOLUME}:/private:ro" \
        "$ALPINE_IMAGE" \
        sh -lc '
            find /private \
              -mindepth 1 \
              -maxdepth 1 \
              -type f \
              -print \
              | sort
        '
)"

[ "$PRIVATE_FILES" = "$PRIVATE_KEY" ] \
    || fail "private DKIM volume contains unexpected files"

pass "private DKIM volume contains exactly one 100:101/0400 key"


PUBLIC_MODE="$(
    docker run \
        --rm \
        --network none \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        -v "${PUBLIC_VOLUME}:/public:ro" \
        "$ALPINE_IMAGE" \
        stat \
            -c '%a' \
            "$PUBLIC_RECORD"
)"

[ "$PUBLIC_MODE" = "444" ] \
    || fail "public DKIM record is not mode 0444"

grep -E \
    '^lab[.]_domainkey IN TXT' \
    <<<"$PUBLIC_AFTER" \
    >/dev/null \
    || fail "DKIM public record has unexpected owner name"

grep -F \
    '"v=DKIM1; k=rsa; "' \
    <<<"$PUBLIC_AFTER" \
    >/dev/null \
    || fail "DKIM public record is not RSA DKIM"

pass "public DKIM record is present and read-only"


# ---------------------------------------------------------------------------
# Image/worktree secret absence
# ---------------------------------------------------------------------------

docker run \
    --rm \
    --network none \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --entrypoint sh \
    heymail-rspamd:lab \
    -lc '
        [ ! -e /run/heymail-dkim/heymail.test.lab.key ]
    ' \
    || fail "private DKIM key was baked into the Rspamd image"

pass "private DKIM key is not baked into the Rspamd image"


WORKTREE_PRIVATE_MATERIAL="$(
    find . \
        -path './.git' -prune -o \
        -type f \
        \( \
          -name '*.key' \
          -o -name '*.pem' \
          -o -name '*.p12' \
          -o -name '*.pfx' \
        \) \
        -print
)"

[ -z "$WORKTREE_PRIVATE_MATERIAL" ] || {
    printf '%s\n' "$WORKTREE_PRIVATE_MATERIAL" >&2
    fail "private-key material exists in the Git worktree"
}

pass "private-key material is absent from the Git worktree"


# ---------------------------------------------------------------------------
# Runtime signer mount
# ---------------------------------------------------------------------------

RSPAMD_MOUNTS="$(
    docker inspect "$RSPAMD_CONTAINER" \
        --format '{{range .Mounts}}{{println .Name "|" .Destination "|rw=" .RW}}{{end}}'
)"

EXPECTED_RSPAMD_DKIM_MOUNT="${PRIVATE_VOLUME} | /run/heymail-dkim |rw= false"

grep -F \
    "$EXPECTED_RSPAMD_DKIM_MOUNT" \
    <<<"$RSPAMD_MOUNTS" \
    >/dev/null \
    || fail "Rspamd private DKIM volume is not mounted read-only"

if grep -F \
    "$PUBLIC_VOLUME" \
    <<<"$RSPAMD_MOUNTS" \
    >/dev/null
then
    fail "Rspamd unnecessarily mounts the DKIM public volume"
fi

pass "Rspamd mounts only the private DKIM volume and mounts it read-only"


docker exec "$RSPAMD_CONTAINER" \
    sh -lc '
        set -eu

        KEY=/run/heymail-dkim/heymail.test.lab.key

        [ -r "$KEY" ]
        [ ! -w "$KEY" ]

        METADATA="$(
            stat -c "%u:%g:%a" "$KEY"
        )"

        [ "$METADATA" = "100:101:400" ]

        if touch /run/heymail-dkim/heymail-write-test 2>/dev/null
        then
            rm -f /run/heymail-dkim/heymail-write-test
            exit 1
        fi
    ' \
    || fail "Rspamd DKIM key mount is not effectively read-only"

pass "Rspamd can read but cannot modify the private DKIM key"


# ---------------------------------------------------------------------------
# Effective Rspamd DKIM policy
# ---------------------------------------------------------------------------

OPTIONS="$(
    docker exec "$RSPAMD_CONTAINER" \
        rspamadm configdump options \
        2>/dev/null
)"

grep -F \
    'filters = "dkim";' \
    <<<"$OPTIONS" \
    >/dev/null \
    || fail "DKIM is not the sole enabled C filter"

DKIM_SIGNING="$(
    docker exec "$RSPAMD_CONTAINER" \
        rspamadm configdump dkim_signing \
        2>/dev/null
)"

for EXPECTED_LINE in \
    'allow_envfrom_empty = false;' \
    'allow_hdrfrom_mismatch = false;' \
    'allow_hdrfrom_multiple = false;' \
    'allow_username_mismatch = false;' \
    'sign_authenticated = false;' \
    'sign_local = true;' \
    'try_fallback = false;' \
    'use_domain = "header";' \
    'use_esld = false;' \
    'use_redis = false;' \
    'enabled = true;' \
    'path = "/run/heymail-dkim/heymail.test.lab.key";' \
    'selector = "lab";'
do
    grep -F \
        "$EXPECTED_LINE" \
        <<<"$DKIM_SIGNING" \
        >/dev/null \
        || fail "missing DKIM policy: ${EXPECTED_LINE}"
done

grep -F \
    'heymail.test {' \
    <<<"$DKIM_SIGNING" \
    >/dev/null \
    || fail "heymail.test DKIM domain is missing"

pass "Rspamd effective DKIM signing policy is constrained as expected"


# ---------------------------------------------------------------------------
# Runtime logging / initialization
# ---------------------------------------------------------------------------

RSPAMD_LOGS="$(
    docker logs "$RSPAMD_CONTAINER" \
        2>&1
)"

if grep -Ei \
    'dkim_signing.*failed|cannot enable.*dkim|dkim.*nil value|key.*permission|key.*cannot' \
    <<<"$RSPAMD_LOGS" \
    >/dev/null
then
    fail "Rspamd reported a DKIM initialization error"
fi

if grep -E \
    'BEGIN (RSA )?PRIVATE KEY|END (RSA )?PRIVATE KEY' \
    <<<"$RSPAMD_LOGS" \
    >/dev/null
then
    fail "private DKIM key material appeared in Rspamd logs"
fi

pass "Rspamd initializes DKIM without logging private key material"


echo
echo "ALL DKIM KEY BOUNDARY SECURITY TESTS PASSED"
