#!/bin/sh

set -eu

echo "[HeyMail] validating Postfix configuration"

postfix check

echo "[HeyMail] starting Postfix SMTP laboratory"

exec "$@"
