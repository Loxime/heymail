#!/usr/bin/env bash

set -euo pipefail

umask 077

BACKUP_ROOT="${HEYMAIL_OFFSITE_BACKUP_DIR:-$HOME/backups/heymail-offsite}"
AGE_KEY="${HEYMAIL_BACKUP_AGE_KEY_FILE:-$HOME/.config/heymail/backup-age.key}"

POSTGRES_IMAGE="postgres:18.4-alpine3.23"

if [ ! -r "$AGE_KEY" ]; then
    echo "ERROR: backup age private key unavailable" >&2
    exit 1
fi

LATEST="$(
    find \
        "$BACKUP_ROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name '20??????T??????Z' \
    | sort \
    | tail -n1
)"

if [ -z "$LATEST" ]; then
    echo "ERROR: no off-site backup available" >&2
    exit 1
fi

shopt -s nullglob

bundles=(
    "$LATEST"/heymail-20??????T??????Z.tar.age
)

if [ "${#bundles[@]}" -ne 1 ]; then
    echo "ERROR: expected exactly one encrypted bundle" >&2
    exit 1
fi

BUNDLE="${bundles[0]}"
CHECKSUM="${BUNDLE}.sha256"

if [ ! -f "$CHECKSUM" ]; then
    echo "ERROR: bundle checksum missing" >&2
    exit 1
fi

echo "=== Outer checksum ==="

(
    cd "$LATEST"

    sha256sum \
        --check \
        "$(basename "$CHECKSUM")"
)

TMP_DIR="$(
    mktemp \
        --directory \
        "${BACKUP_ROOT}/.restore.XXXXXXXX"
)"

CONTAINER="heymail-restore-${UID}-$$"

cleanup() {
    docker rm \
        -f \
        "$CONTAINER" \
        >/dev/null 2>&1 \
        || true

    rm -rf -- "$TMP_DIR"
}

trap cleanup EXIT

echo "=== Decrypt bundle ==="

age \
    --decrypt \
    --identity "$AGE_KEY" \
    "$BUNDLE" \
| tar \
    --extract \
    --directory="$TMP_DIR" \
    --no-same-owner \
    --no-same-permissions

restore_dirs=(
    "$TMP_DIR"/20??????T??????Z
)

if [ "${#restore_dirs[@]}" -ne 1 ]; then
    echo "ERROR: invalid decrypted backup structure" >&2
    exit 1
fi

RESTORE_DIR="${restore_dirs[0]}"

for required in \
    postgres.dump \
    secrets.tar.age \
    metadata.txt \
    SHA256SUMS
do
    if [ ! -f "$RESTORE_DIR/$required" ]; then
        echo "ERROR: missing $required" >&2
        exit 1
    fi
done

echo "=== Inner checksums ==="

(
    cd "$RESTORE_DIR"

    sha256sum \
        --check \
        SHA256SUMS
)

echo "=== Isolated PostgreSQL ==="

docker run \
    --detach \
    --rm \
    --name "$CONTAINER" \
    --network none \
    --tmpfs /var/lib/postgresql:rw,size=512m \
    --env POSTGRES_PASSWORD=restore-test-only \
    --env POSTGRES_DB=restore_target \
    --volume "$RESTORE_DIR:/backup:ro" \
    "$POSTGRES_IMAGE" \
    >/dev/null

READY=0

for _ in $(seq 1 30)
do
    if docker exec \
        -e PGPASSWORD=restore-test-only \
        "$CONTAINER" \
        psql \
            --username=postgres \
            --dbname=restore_target \
            --no-align \
            --tuples-only \
            --quiet \
            --command='SELECT 1;' \
        2>/dev/null \
        | grep -qx '1'
    then
        READY=1
        break
    fi

    sleep 1
done

if [ "$READY" -ne 1 ]; then
    docker logs "$CONTAINER" >&2 || true

    echo "ERROR: restore PostgreSQL database did not become ready" >&2
    exit 1
fi

docker exec \
    -e PGPASSWORD=restore-test-only \
    "$CONTAINER" \
    pg_restore \
        --username=postgres \
        --dbname=restore_target \
        --no-owner \
        --no-acl \
        --exit-on-error \
        /backup/postgres.dump

echo "PASS: PostgreSQL dump restored"

echo "=== Structural verification ==="

RESULT="$(
docker exec \
    -e PGPASSWORD=restore-test-only \
    "$CONTAINER" \
    psql \
        --username=postgres \
        --dbname=restore_target \
        --no-align \
        --tuples-only \
        --quiet \
        --command="
SELECT
    (
        SELECT count(*)
        FROM information_schema.tables
        WHERE table_schema = 'public'
    )
    || ':'
    ||
    CASE
        WHEN to_regclass('public.outbound_message') IS NOT NULL
         AND to_regclass('public.outbound_message_event') IS NOT NULL
         AND to_regclass('public.outbound_message_payload') IS NOT NULL
         AND to_regclass('public.sending_domain') IS NOT NULL
        THEN 'core-ok'
        ELSE 'core-missing'
    END;
"
)"

echo "restore_check=$RESULT"

TABLE_COUNT="${RESULT%%:*}"
CORE_STATUS="${RESULT#*:}"

if ! [[ "$TABLE_COUNT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid restored table count" >&2
    exit 1
fi

if [ "$TABLE_COUNT" -lt 4 ]; then
    echo "ERROR: restored database contains too few tables" >&2
    exit 1
fi

if [ "$CORE_STATUS" != "core-ok" ]; then
    echo "ERROR: critical restored tables are missing" >&2
    exit 1
fi

echo
echo "PASS: OFFSITE BACKUP RESTORE VERIFIED"
echo "BACKUP=$(basename "$BUNDLE")"
echo "PUBLIC_TABLES=$TABLE_COUNT"
