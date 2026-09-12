#!/bin/sh

set -eu

DOMAIN="heymail.test"
SELECTOR="lab"

PROVISIONER_UID="1000"
RSPAMD_UID="100"
RSPAMD_GID="101"

PRIVATE_DIR="/private"
PUBLIC_DIR="/public"

PRIVATE_KEY="${PRIVATE_DIR}/${DOMAIN}.${SELECTOR}.key"
PUBLIC_RECORD="${PUBLIC_DIR}/${DOMAIN}.${SELECTOR}.dns.txt"

PRIVATE_TMP="/tmp/${DOMAIN}.${SELECTOR}.key"
PUBLIC_TMP="/tmp/${DOMAIN}.${SELECTOR}.dns.txt"

PRIVATE_STAGE="${PRIVATE_KEY}.tmp.$$"
PUBLIC_STAGE="${PUBLIC_RECORD}.tmp.$$"

PRIVATE_DIR_PREPARED="0"

fail() {
    printf 'DKIM bootstrap failure: %s\n' "$1" >&2
    exit 1
}

cleanup() {
    set +e

    # Ephemeral files are always accessible.
    rm -f         "$PRIVATE_TMP"         "$PUBLIC_TMP"         "$PUBLIC_STAGE"

    # PRIVATE_STAGE is accessible only while the bootstrap still owns
    # PRIVATE_DIR. Once ownership has been restored to the provisioner,
    # deliberately do not traverse /private again.
    if [ "$PRIVATE_DIR_PREPARED" = "1" ]; then
        rm -f "$PRIVATE_STAGE"

        chmod 0770 "$PRIVATE_DIR"
        chown "${PROVISIONER_UID}:${RSPAMD_GID}" "$PRIVATE_DIR"
    fi

}

restore_private_root() {
    # We still own PRIVATE_DIR here, so no CAP_FOWNER is needed.
    chmod 0770 "$PRIVATE_DIR"
    chown "${PROVISIONER_UID}:${RSPAMD_GID}" "$PRIVATE_DIR"

    PRIVATE_DIR_PREPARED="0"

    [ "$(stat -c '%u:%g:%a' "$PRIVATE_DIR")" = "1000:101:770" ] \
        || fail "dynamic DKIM root permissions are invalid"
}

trap cleanup EXIT HUP INT TERM

umask 077

# ---------------------------------------------------------------------------
# Bootstrap temporary ownership.
#
# The persistent private root normally belongs to the non-root DKIM
# provisioner (1000:101). The bootstrap has CAP_CHOWN only.
#
# Take ownership before inspecting/staging the fixed laboratory fixture,
# then restore ownership to the provisioner before exiting.
# ---------------------------------------------------------------------------

chown "0:${RSPAMD_GID}" "$PRIVATE_DIR"
chmod 0770 "$PRIVATE_DIR"

PRIVATE_DIR_PREPARED="1"

# ---------------------------------------------------------------------------
# Existing fixed laboratory keypair: validate it and remain idempotent.
# ---------------------------------------------------------------------------

if [ -e "$PRIVATE_KEY" ] || [ -e "$PUBLIC_RECORD" ]; then
    [ -f "$PRIVATE_KEY" ] \
        || fail "public record exists without private key"

    [ -f "$PUBLIC_RECORD" ] \
        || fail "private key exists without public record"

    PRIVATE_METADATA="$(
        stat -c '%u:%g:%a' "$PRIVATE_KEY"
    )"

    [ "$PRIVATE_METADATA" = "${RSPAMD_UID}:${RSPAMD_GID}:400" ] \
        || fail "private key permissions or ownership are invalid"

    PUBLIC_MODE="$(
        stat -c '%a' "$PUBLIC_RECORD"
    )"

    [ "$PUBLIC_MODE" = "444" ] \
        || fail "public DKIM record permissions are invalid"

    grep -Eq \
        "^${SELECTOR}[.]_domainkey IN TXT" \
        "$PUBLIC_RECORD" \
        || fail "public DKIM record has unexpected owner name"

    grep -F \
        '"v=DKIM1; k=rsa; "' \
        "$PUBLIC_RECORD" \
        >/dev/null \
        || fail "public DKIM record is not RSA DKIM"

    restore_private_root

    printf 'DKIM keypair already provisioned and valid\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Generate the fixed laboratory keypair in ephemeral /tmp first.
# ---------------------------------------------------------------------------

rspamadm dkim_keygen \
    --domain "$DOMAIN" \
    --selector "$SELECTOR" \
    --type rsa \
    --bits 2048 \
    --privkey "$PRIVATE_TMP" \
    --output dns \
    > "$PUBLIC_TMP"

[ -s "$PRIVATE_TMP" ] \
    || fail "generated private key is empty"

[ -s "$PUBLIC_TMP" ] \
    || fail "generated public record is empty"

grep -E \
    '^-----BEGIN (RSA )?PRIVATE KEY-----$' \
    "$PRIVATE_TMP" \
    >/dev/null \
    || fail "generated private key is not a supported PEM key"

grep -Eq \
    "^${SELECTOR}[.]_domainkey IN TXT" \
    "$PUBLIC_TMP" \
    || fail "generated public DKIM record has unexpected owner name"

grep -F \
    '"v=DKIM1; k=rsa; "' \
    "$PUBLIC_TMP" \
    >/dev/null \
    || fail "generated public DKIM record is not RSA DKIM"

# ---------------------------------------------------------------------------
# Stage atomically into persistent storage.
# ---------------------------------------------------------------------------

cp "$PRIVATE_TMP" "$PRIVATE_STAGE"
chmod 0400 "$PRIVATE_STAGE"
chown "${RSPAMD_UID}:${RSPAMD_GID}" "$PRIVATE_STAGE"

cp "$PUBLIC_TMP" "$PUBLIC_STAGE"
chmod 0444 "$PUBLIC_STAGE"

mv "$PRIVATE_STAGE" "$PRIVATE_KEY"
mv "$PUBLIC_STAGE" "$PUBLIC_RECORD"

PRIVATE_METADATA="$(
    stat -c '%u:%g:%a' "$PRIVATE_KEY"
)"

[ "$PRIVATE_METADATA" = "${RSPAMD_UID}:${RSPAMD_GID}:400" ] \
    || fail "final private key permissions are invalid"

[ "$(stat -c '%a' "$PUBLIC_RECORD")" = "444" ] \
    || fail "final public record permissions are invalid"

restore_private_root

printf 'DKIM keypair provisioned successfully\n'
