#!/bin/sh

set -eu

LOG_FILE="/var/log/postfix/heymail.log"

mkdir -p     "$(dirname "$LOG_FILE")"

if [ ! -e "$LOG_FILE" ]; then
    : > "$LOG_FILE"
fi

chmod 0644     "$LOG_FILE"

echo "[HeyMail] validating Postfix configuration"

postfix check

echo "[HeyMail] mirroring Postfix delivery log to container stdout"

tail     -n 0     -F "$LOG_FILE" &

echo "[HeyMail] starting Postfix SMTP laboratory"

exec "$@"
