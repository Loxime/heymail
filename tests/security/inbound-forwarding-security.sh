#!/usr/bin/env bash

set -euo pipefail

echo "=== HeyMail inbound forwarding security tests ==="

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

grep -Fq     '      - "0.0.0.0:25:25"'     compose.mail.vps.yaml     || fail "inbound-ingress does not own public port 25"

if grep -A20 '^  dsn-loopback-proxy:' compose.mail.vps.yaml     | grep -Fq '0.0.0.0:25'
then
    fail "legacy DSN proxy still owns public port 25"
fi

pass "exactly the inbound ingress owns public SMTP"

grep -Fq     'smtpd_relay_restrictions = reject_unauth_destination'     docker/inbound-ingress/Dockerfile     || fail "relay protection is missing"

grep -Fq     'smtpd_reject_unlisted_recipient = yes'     docker/inbound-ingress/Dockerfile     || fail "unlisted inbound recipient rejection is missing"

grep -Fq     'sender_canonical_maps = socketmap:inet:127.0.0.1:10003:forward'     docker/inbound-ingress/Dockerfile     || fail "SRS sender rewriting is missing"

grep -Fq     'recipient_canonical_maps = socketmap:inet:127.0.0.1:10003:reverse'     docker/inbound-ingress/Dockerfile     || fail "SRS reverse rewriting is missing"

grep -Fq     'HEYMAIL_SRS_DOMAIN'     compose.mail.vps.yaml     || fail "dedicated SRS domain is not wired into production"

grep -Fq     "syncTxtRecord"     apps/api/src/Dns/OvhDnsPublisher.php     || fail "SRS SPF publication is missing"

pass "relay, dedicated SRS and SPF protections are configured"

grep -Fq \
    'docker/inbound-ingress/recipient-policy.py' \
    docker/inbound-ingress/Dockerfile \
    || fail "Docker image does not embed inbound recipient policy"

grep -Fq \
    '/usr/local/bin/heymail-inbound-recipient-policy' \
    docker/inbound-ingress/entrypoint.sh \
    || fail "entrypoint does not start inbound recipient policy"

pass "inbound recipient policy is wired into the image"

grep -Fq \
    'postfix start' \
    docker/inbound-ingress/entrypoint.sh \
    || fail "inbound entrypoint does not start Postfix daemon"

grep -Fq \
    'postfix status' \
    docker/inbound-ingress/entrypoint.sh \
    || fail "inbound entrypoint does not supervise Postfix"

if grep -Fq \
    'postfix start-fg &' \
    docker/inbound-ingress/entrypoint.sh
then
    fail "inbound entrypoint backgrounds postfix start-fg"
fi

pass "inbound Postfix lifecycle is explicitly supervised"



TMP="$(
    mktemp -d
)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/aliases" <<'ALIASES'
reply@heymail.test destination@example.net
contact@heymail.test destination@example.net
ALIASES

python3     docker/inbound-ingress/render-aliases.py     "$TMP/aliases"     heymail.test     > "$TMP/rendered"

grep -Fq     '/^reply@heymail\.test$/ destination@example.net'     "$TMP/rendered"     || fail "explicit alias did not render"

cat > "$TMP/catchall" <<'ALIASES'
*@heymail.test destination@example.net
ALIASES

if python3     docker/inbound-ingress/render-aliases.py     "$TMP/catchall"     heymail.test     >/dev/null 2>&1
then
    fail "catch-all alias was accepted"
fi

cat > "$TMP/loop" <<'ALIASES'
reply@heymail.test other@heymail.test
ALIASES

if python3     docker/inbound-ingress/render-aliases.py     "$TMP/loop"     heymail.test     >/dev/null 2>&1
then
    fail "forwarding loop was accepted"
fi

pass "alias parser accepts explicit external forwards only"

echo
echo "ALL INBOUND FORWARDING SECURITY TESTS PASSED"
