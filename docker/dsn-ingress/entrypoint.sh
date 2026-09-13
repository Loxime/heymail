#!/bin/sh

set -eu

: "${HEYMAIL_BOUNCE_DOMAIN:?required}"
: "${HEYMAIL_BOUNCE_HMAC_KEY_FILE:?required}"

test -s "$HEYMAIL_BOUNCE_HMAC_KEY_FILE"

touch /var/log/postfix/heymail-dsn.log
chmod 0640 /var/log/postfix/heymail-dsn.log

python3 \
    /usr/local/bin/heymail-dsn-policy &

POLICY_PID="$!"

postfix check

postfix start-fg &
POSTFIX_PID="$!"

terminate() {
    kill \
        "$POSTFIX_PID" \
        "$POLICY_PID" \
        2>/dev/null \
        || true

    wait \
        "$POSTFIX_PID" \
        "$POLICY_PID" \
        2>/dev/null \
        || true

    exit 0
}

trap terminate INT TERM

while
    kill -0 "$POLICY_PID" 2>/dev/null \
    && kill -0 "$POSTFIX_PID" 2>/dev/null
do
    sleep 1
done

echo "DSN ingress child process exited" >&2

kill \
    "$POSTFIX_PID" \
    "$POLICY_PID" \
    2>/dev/null \
    || true

wait \
    "$POSTFIX_PID" \
    "$POLICY_PID" \
    2>/dev/null \
    || true

exit 1
