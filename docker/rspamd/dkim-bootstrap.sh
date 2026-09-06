#!/bin/sh

set -eu

DOMAIN="heymail.test"
SELECTOR="lab"

PRIVATE_DIR="/private"
PUBLIC_DIR="/public"

PRIVATE_KEY="${PRIVATE_DIR}/${DOMAIN}.${SELECTOR}.key"
PUBLIC_RECORD="${PUBLIC_DIR}/${DOMAIN}.${SELECTOR}.dns.txt"

PRIVATE_TMP="/tmp/${DOMAIN}.${SELECTOR}.key"
PUBLIC_TMP="/tmp/${DOMAIN}.${SELECTOR}.dns.txt"

PRIVATE_STAGE="${PRIVATE_KEY}.tmp.$$"
PUBLIC_STAGE="${PUBLIC_RECORD}.tmp.$$"

fail() {
    printf 'DKIM bootstrap failure: %s\n' "$1" >&2
    exit 1
}

cleanup() {
    rm -f \
        "$PRIVATE_TMP" \
        "$PUBLIC_TMP" \
        "$PRIVATE_STAGE" \
        "$PUBLIC_STAGE"
}

trap cleanup EXIT HUP INT TERM

umask 077

# ---------------------------------------------------------------------------
# Existing keypair: validate it and remain idempotent.
# ---------------------------------------------------------------------------

if [ -e "$PRIVATE_KEY" ] || [ -e "$PUBLIC_RECORD" ]; then
    [ -f "$PRIVATE_KEY" ] \
        || fail "public record exists without private key"

    [ -f "$PUBLIC_RECORD" ] \
        || fail "private key exists without public record"

    PRIVATE_METADATA="$(
        stat -c '%u:%g:%a' "$PRIVATE_KEY"
    )"

    [ "$PRIVATE_METADATA" = "100:101:400" ] \
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

    printf 'DKIM keypair already provisioned and valid\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Generate the keypair only in ephemeral /tmp first.
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
# Stage into persistent volumes, then atomically publish final names.
# ---------------------------------------------------------------------------

cp "$PRIVATE_TMP" "$PRIVATE_STAGE"
chmod 0400 "$PRIVATE_STAGE"
chown 100:101 "$PRIVATE_STAGE"

cp "$PUBLIC_TMP" "$PUBLIC_STAGE"
chmod 0444 "$PUBLIC_STAGE"

mv "$PRIVATE_STAGE" "$PRIVATE_KEY"
mv "$PUBLIC_STAGE" "$PUBLIC_RECORD"

PRIVATE_METADATA="$(
    stat -c '%u:%g:%a' "$PRIVATE_KEY"
)"

[ "$PRIVATE_METADATA" = "100:101:400" ] \
    || fail "final private key permissions are invalid"

[ "$(stat -c '%a' "$PUBLIC_RECORD")" = "444" ] \
    || fail "final public record permissions are invalid"

printf 'DKIM keypair provisioned successfully\n'
