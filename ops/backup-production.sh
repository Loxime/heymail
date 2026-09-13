#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.." \
        && pwd
)"

cd "$ROOT_DIR"

umask 077

BACKUP_ROOT="${HEYMAIL_BACKUP_DIR:-$HOME/backups/heymail}"

TIMESTAMP="$(
    date -u '+%Y%m%dT%H%M%SZ'
)"

DESTINATION="${BACKUP_ROOT}/${TIMESTAMP}"

mkdir -p "$DESTINATION"
chmod 0700 "$BACKUP_ROOT" "$DESTINATION"

DB_DUMP="${DESTINATION}/postgres.dump"
SECRETS_ARCHIVE="${DESTINATION}/secrets.tar.age"
RECIPIENT_FILE="${HEYMAIL_BACKUP_RECIPIENT_FILE:-$HOME/.config/heymail/backup-age.recipient}"
METADATA="${DESTINATION}/metadata.txt"
CHECKSUMS="${DESTINATION}/SHA256SUMS"

if ! command -v age >/dev/null 2>&1; then
    echo "ERROR: age is not installed" >&2
    exit 1
fi

if [ ! -r "$RECIPIENT_FILE" ]; then
    echo "ERROR: backup age recipient is unavailable" >&2
    exit 1
fi

echo "=== PostgreSQL backup ==="

docker compose \
    --env-file .env.prod \
    -f compose.vps.yaml \
    -f compose.mail.vps.yaml \
    exec -T database \
    sh -ec '
        export PGPASSWORD="$(
            cat /run/secrets/postgres_password
        )"

        exec pg_dump \
            --username="$POSTGRES_USER" \
            --dbname="$POSTGRES_DB" \
            --format=custom \
            --no-owner \
            --no-acl
    ' \
    > "$DB_DUMP"

test -s "$DB_DUMP"

echo "PASS: PostgreSQL dump created"

echo "=== Secret backup ==="

test -d secrets/prod

tar \
    --create \
    --directory="$ROOT_DIR" \
    secrets/prod \
    | age \
        --recipients-file "$RECIPIENT_FILE" \
        --output "$SECRETS_ARCHIVE"

test -s "$SECRETS_ARCHIVE"

echo "PASS: secrets encrypted with SSH recipient"

{
    echo "timestamp=${TIMESTAMP}"
    echo "git_commit=$(git rev-parse HEAD)"
    echo "hostname=$(hostname -f)"
    echo "database_image=postgres:18.4-alpine3.23"
} > "$METADATA"

chmod 0600 \
    "$DB_DUMP" \
    "$SECRETS_ARCHIVE" \
    "$METADATA"

(
    cd "$DESTINATION"

    sha256sum \
        postgres.dump \
        secrets.tar.age \
        metadata.txt \
        > SHA256SUMS
)

chmod 0600 "$CHECKSUMS"

echo
echo "PASS: production backup completed"
echo "BACKUP=${DESTINATION}"
echo
echo "Files:"
ls -lh \
    "$DB_DUMP" \
    "$SECRETS_ARCHIVE" \
    "$METADATA" \
    "$CHECKSUMS"
