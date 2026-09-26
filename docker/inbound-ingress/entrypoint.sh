#!/bin/sh

set -eu

: "${HEYMAIL_INBOUND_DOMAIN:?required}"
: "${HEYMAIL_BOUNCE_DOMAIN:?required}"
: "${HEYMAIL_SRS_DOMAIN:?required}"
: "${HEYMAIL_INBOUND_ALIASES_FILE:?required}"
: "${HEYMAIL_INBOUND_SRS_SECRET_FILE:?required}"
: "${HEYMAIL_BOUNCE_HMAC_KEY_FILE:?required}"

test -r "$HEYMAIL_INBOUND_ALIASES_FILE"
test -r "$HEYMAIL_INBOUND_SRS_SECRET_FILE"
test -r "$HEYMAIL_BOUNCE_HMAC_KEY_FILE"

SRS_SECRET="$(
    tr -d '\r\n' \
        < "$HEYMAIL_INBOUND_SRS_SECRET_FILE"
)"

case "$SRS_SECRET" in
    *[!0-9a-f]*|'')
        echo "Invalid inbound SRS secret" >&2
        exit 1
        ;;
esac

[ "${#SRS_SECRET}" -eq 64 ] \
    || {
        echo "Inbound SRS secret must be 64 lowercase hex characters" >&2
        exit 1
    }

unset SRS_SECRET

mkdir -p /run/heymail

/usr/local/bin/heymail-render-inbound-aliases \
    "$HEYMAIL_INBOUND_ALIASES_FILE" \
    "$HEYMAIL_INBOUND_DOMAIN" \
    > /run/heymail/inbound-aliases.regexp

chmod 0644 \
    /run/heymail/inbound-aliases.regexp

cat > /run/heymail/postsrsd.conf <<EOF_SRS
domains = { "${HEYMAIL_INBOUND_DOMAIN}", "${HEYMAIL_BOUNCE_DOMAIN}", "${HEYMAIL_SRS_DOMAIN}" }
srs-domain = "${HEYMAIL_SRS_DOMAIN}"
secrets-file = "${HEYMAIL_INBOUND_SRS_SECRET_FILE}"
socketmap = inet:127.0.0.1:10003
unprivileged-user = "nobody"
chroot-dir = ""
syslog = off
debug = off
EOF_SRS

chmod 0600 \
    /run/heymail/postsrsd.conf

touch /var/log/postfix/heymail-inbound.log
chmod 0644 /var/log/postfix/heymail-inbound.log

python3 \
    /usr/local/bin/heymail-inbound-recipient-policy &
POLICY_PID="$!"

postsrsd \
    -C/run/heymail/postsrsd.conf &
SRS_PID="$!"

READY=0
ATTEMPT=0

while [ "$ATTEMPT" -lt 15 ]
do
    ATTEMPT=$((ATTEMPT + 1))

    if ! kill -0 "$POLICY_PID" 2>/dev/null; then
        echo "Inbound recipient policy exited during startup" >&2
        break
    fi

    if [ ! -r "/proc/$SRS_PID/stat" ]; then
        echo "PostSRSd exited during startup" >&2
        break
    fi

    if python3 - <<'PY_READY' >/dev/null 2>&1
import socket

for port in (10003, 10031):
    with socket.create_connection(
        ("127.0.0.1", port),
        timeout=1,
    ):
        pass
PY_READY
    then
        READY=1
        break
    fi

    sleep 1
done

if [ "$READY" -ne 1 ]; then
    echo "Inbound dependencies did not become ready" >&2

    kill         "$SRS_PID"         "$POLICY_PID"         2>/dev/null         || true

    wait         "$SRS_PID"         "$POLICY_PID"         2>/dev/null         || true

    exit 1
fi

echo "Inbound dependencies ready"

postfix check
postfix start

terminate() {
    postfix stop \
        >/dev/null 2>&1 \
        || true

    kill \
        "$POLICY_PID" \
        2>/dev/null \
        || true

    wait \
        "$POLICY_PID" \
        2>/dev/null \
        || true

    exit 0
}

trap terminate INT TERM

while true
do
    if [ ! -r "/proc/$SRS_PID/stat" ]; then
        echo "PostSRSd exited" >&2
        break
    fi

    if ! kill -0 "$POLICY_PID" 2>/dev/null; then
        echo "Inbound recipient policy exited" >&2
        break
    fi

    if ! postfix status >/dev/null 2>&1; then
        echo "Inbound Postfix exited" >&2
        break
    fi

    sleep 1
done

postfix stop \
    >/dev/null 2>&1 \
    || true

kill \
    "$POLICY_PID" \
    2>/dev/null \
    || true

wait \
    "$POLICY_PID" \
    2>/dev/null \
    || true

exit 1
