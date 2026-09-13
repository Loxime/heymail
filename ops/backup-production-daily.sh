#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.." \
        && pwd
)"

cd "$ROOT_DIR"

umask 077

BACKUP_ROOT="${HEYMAIL_BACKUP_DIR:-$HOME/backups/heymail}"
RECIPIENT_FILE="${HEYMAIL_BACKUP_RECIPIENT_FILE:-$HOME/.config/heymail/backup-age.recipient}"
RETENTION_DAYS="${HEYMAIL_BACKUP_RETENTION_DAYS:-14}"

mkdir -p "$BACKUP_ROOT"
chmod 0700 "$BACKUP_ROOT"

LOCK_DIR="${XDG_RUNTIME_DIR:-/tmp}"
LOCK_FILE="${LOCK_DIR}/heymail-production-backup.lock"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    echo "ERROR: another HeyMail backup is already running" >&2
    exit 1
fi

if [ ! -r "$RECIPIENT_FILE" ]; then
    echo "ERROR: backup age recipient is unavailable" >&2
    exit 1
fi

echo "=== HeyMail production daily backup ==="

OUTPUT="$(
    ./ops/backup-production.sh
)"

printf '%s\n' "$OUTPUT"

BACKUP_DIR="$(
    printf '%s\n' "$OUTPUT" \
        | awk -F= '/^BACKUP=/{print substr($0,8)}' \
        | tail -n1
)"

if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: backup directory could not be determined" >&2
    exit 1
fi

TIMESTAMP="$(
    basename "$BACKUP_DIR"
)"

BUNDLE="$BACKUP_ROOT/heymail-${TIMESTAMP}.tar.age"
CHECKSUM="${BUNDLE}.sha256"

TMP_BUNDLE="${BUNDLE}.tmp"

rm -f "$TMP_BUNDLE"

tar \
    --create \
    --directory="$BACKUP_ROOT" \
    "$TIMESTAMP" \
    | age \
        --recipients-file "$RECIPIENT_FILE" \
        --output "$TMP_BUNDLE"

test -s "$TMP_BUNDLE"

chmod 0600 "$TMP_BUNDLE"

mv \
    "$TMP_BUNDLE" \
    "$BUNDLE"

(
    cd "$BACKUP_ROOT"

    sha256sum \
        "$(basename "$BUNDLE")" \
        > "$(basename "$CHECKSUM")"

    sha256sum \
        --check \
        "$(basename "$CHECKSUM")"
)

chmod 0600 "$CHECKSUM"

echo "PASS: encrypted off-site bundle created"

echo
echo "=== Retention (${RETENTION_DAYS} days) ==="

find "$BACKUP_ROOT" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name '20??????T??????Z' \
    -mtime "+${RETENTION_DAYS}" \
    -print \
    -exec rm -rf -- {} +

find "$BACKUP_ROOT" \
    -mindepth 1 \
    -maxdepth 1 \
    -type f \
    \( \
        -name 'heymail-20??????T??????Z.tar.age' \
        -o \
        -name 'heymail-20??????T??????Z.tar.age.sha256' \
    \) \
    -mtime "+${RETENTION_DAYS}" \
    -print \
    -delete

echo
echo "PASS: daily production backup completed"
echo "BACKUP_DIR=$BACKUP_DIR"
echo "BUNDLE=$BUNDLE"
