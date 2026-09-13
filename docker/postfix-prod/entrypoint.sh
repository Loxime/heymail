#!/bin/sh

set -eu

: "${HEYMAIL_SMTP_HOSTNAME:?HEYMAIL_SMTP_HOSTNAME is required}"

CONFIGURED_HOSTNAME="$(
    postconf -h myhostname
)"

CONFIGURED_HELO="$(
    postconf -h smtp_helo_name
)"

if [ "$CONFIGURED_HOSTNAME" != "$HEYMAIL_SMTP_HOSTNAME" ]; then
    echo "Postfix myhostname mismatch" >&2
    exit 1
fi

if [ "$CONFIGURED_HELO" != "$HEYMAIL_SMTP_HOSTNAME" ]; then
    echo "Postfix smtp_helo_name mismatch" >&2
    exit 1
fi

LOG_FILE="/var/log/postfix/heymail.log"

mkdir -p \
    "$(dirname "$LOG_FILE")"

touch "$LOG_FILE"

chmod 0644 \
    "$LOG_FILE"

postfix check

tail \
    -n 0 \
    -F "$LOG_FILE" &

echo "[HeyMail] starting production Postfix"
echo "[HeyMail] SMTP HELO: ${HEYMAIL_SMTP_HOSTNAME}"

exec "$@"
