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
        dkim-provisioner \
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

pass "only DKIM provisioner, Rspamd and bootstrap reference the private DKIM volume"


if python3 -c '
import json
import sys

config = json.load(sys.stdin)
services = config["services"]

bootstrap = services["rspamd-dkim-bootstrap"]
provisioner = services["dkim-provisioner"]
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

assert str(provisioner["user"]) == "1000:101"
assert provisioner["read_only"] is True
assert provisioner.get("privileged", False) is False
assert set(provisioner.get("cap_drop") or []) == {"ALL"}
assert not (provisioner.get("cap_add") or [])

assert "no-new-privileges:true" in (
    provisioner.get("security_opt") or []
)

assert set(provisioner.get("networks") or []) == {
    "data_net",
}

provisioner_private = [
    volume
    for volume in (provisioner.get("volumes") or [])
    if volume.get("target") == "/run/heymail-dkim"
]

assert len(provisioner_private) == 1
assert provisioner_private[0].get("read_only", False) is False

rspamd_private = [
    volume
    for volume in (rspamd.get("volumes") or [])
    if volume.get("target") == "/run/heymail-dkim"
]

assert len(rspamd_private) == 1
assert rspamd_private[0].get("read_only") is True
' <<<"$COMPOSE_JSON"
then
    pass "Compose enforces the DKIM provisioner, bootstrap and signer trust boundary"
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
#
# The fixed heymail.test/lab fixture remains owner-readable by Rspamd.
# Dynamic per-domain keys live one directory below the root and are shared
# read-only with Rspamd through GID 101.
# ---------------------------------------------------------------------------

PRIVATE_METADATA="$(
    docker compose exec -T dkim-provisioner \
        stat \
            -c '%u:%g:%a' \
            /run/heymail-dkim/heymail.test.lab.key
)"

[ "$PRIVATE_METADATA" = "100:101:400" ] \
    || fail "legacy private DKIM key metadata is not 100:101:0400"

pass "legacy private DKIM key remains restricted to Rspamd"


TOP_LEVEL_PRIVATE_FILES="$(
    docker compose exec -T dkim-provisioner \
        sh -c '
            find /run/heymail-dkim \
                -mindepth 1 \
                -maxdepth 1 \
                -type f \
                -print \
                | sort
        '
)"

EXPECTED_TOP_LEVEL_PRIVATE_FILE="/run/heymail-dkim/heymail.test.lab.key"

[ "$TOP_LEVEL_PRIVATE_FILES" = "$EXPECTED_TOP_LEVEL_PRIVATE_FILE" ] || {
    printf 'Unexpected top-level DKIM private files:\n%s\n' \
        "$TOP_LEVEL_PRIVATE_FILES" >&2

    fail "private DKIM root contains unexpected files"
}

pass "private DKIM root contains only the fixed laboratory key"


DYNAMIC_PRIVATE_METADATA="$(
    docker compose exec -T dkim-provisioner \
        sh -c '
            find /run/heymail-dkim \
                -mindepth 2 \
                -maxdepth 2 \
                -type f \
                -name "*.key" \
                -exec stat -c "%u:%g:%a %n" {} \; \
                | sort
        '
)"

BAD_DYNAMIC_PRIVATE_METADATA="$(
    printf '%s\n' "$DYNAMIC_PRIVATE_METADATA" \
        | awk '
            NF > 0 && $1 != "1000:101:440" {
                print
            }
        '
)"

[ -z "$BAD_DYNAMIC_PRIVATE_METADATA" ] || {
    printf 'Unsafe dynamic DKIM private-key metadata:\n%s\n' \
        "$BAD_DYNAMIC_PRIVATE_METADATA" >&2

    fail "dynamic DKIM private key permissions are unsafe"
}

pass "all present dynamic DKIM keys are restricted to 1000:101/0440"


PRIVATE_TEMP_FILES="$(
    docker compose exec -T dkim-provisioner \
        sh -c '
            find /run/heymail-dkim \
                -type f \
                \( \
                    -name "*.tmp" \
                    -o -name "*.tmp.*" \
                    -o -name ".*.tmp" \
                    -o -name ".*.tmp.*" \
                \) \
                -print \
                | sort
        '
)"

[ -z "$PRIVATE_TEMP_FILES" ] || {
    printf 'Unexpected staged DKIM files:\n%s\n' \
        "$PRIVATE_TEMP_FILES" >&2

    fail "staged DKIM private-key material remains in persistent storage"
}

pass "no staged DKIM private-key files remain"


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


TRACKED_PRIVATE_MATERIAL="$(
    git ls-files -z \
        | while IFS= read -r -d '' FILE
          do
              case "$FILE" in
                  *.key|*.p12|*.pfx)
                      printf '%s\n' "$FILE"
                      continue
                      ;;
              esac

              [ -f "$FILE" ] \
                  || continue

              if grep -Eq \
                  -- '^-----BEGIN ((RSA|EC|OPENSSH|DSA) )?PRIVATE KEY-----$|^-----BEGIN ENCRYPTED PRIVATE KEY-----$' \
                  "$FILE" \
                  2>/dev/null
              then
                  printf '%s\n' "$FILE"
              fi
          done
)"

[ -z "$TRACKED_PRIVATE_MATERIAL" ] || {
    printf '%s\n' "$TRACKED_PRIVATE_MATERIAL" >&2
    fail "private-key material is tracked by Git"
}

pass "private-key material is absent from tracked Git files"


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
#
# Global policy signs dynamically provisioned domains using:
#
#   /run/heymail-dkim/$domain/hm1.key
#
# The explicit heymail.test/lab entry remains only as the fixed historical
# laboratory fixture.
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
    'allow_envfrom_empty = true;' \
    'allow_hdrfrom_mismatch = false;' \
    'allow_hdrfrom_mismatch_local = false;' \
    'allow_hdrfrom_mismatch_sign_networks = false;' \
    'allow_hdrfrom_multiple = false;' \
    'allow_username_mismatch = false;' \
    'sign_authenticated = false;' \
    'sign_local = true;' \
    'try_fallback = true;' \
    'use_domain = "header";' \
    'use_esld = false;' \
    'use_redis = false;' \
    'enabled = true;' \
    'selector = "hm1";' \
    'path = "/run/heymail-dkim/$domain/$selector.key";'
do
    grep -F \
        "$EXPECTED_LINE" \
        <<<"$DKIM_SIGNING" \
        >/dev/null \
        || fail "missing DKIM policy: ${EXPECTED_LINE}"
done

pass "Rspamd global DKIM policy uses dynamic per-domain key paths"


grep -F \
    'heymail.test {' \
    <<<"$DKIM_SIGNING" \
    >/dev/null \
    || fail "legacy heymail.test DKIM fixture is missing"

grep -F \
    'path = "/run/heymail-dkim/heymail.test.lab.key";' \
    <<<"$DKIM_SIGNING" \
    >/dev/null \
    || fail "legacy heymail.test private-key path is missing"

grep -F \
    'selector = "lab";' \
    <<<"$DKIM_SIGNING" \
    >/dev/null \
    || fail "legacy heymail.test selector is missing"

pass "legacy heymail.test/lab fixture remains explicitly isolated"


if grep -F \
    'path = "/run/heymail-dkim/heymail.test.lab.key";' \
    <<<"$DKIM_SIGNING" \
    | grep -Fq '$domain'
then
    fail "legacy DKIM fixture leaked into dynamic key template"
fi

pass "dynamic and legacy DKIM key-selection policies remain distinct"


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
