#!/usr/bin/env bash

set -euo pipefail

umask 077

BACKUP_ROOT="${HEYMAIL_BACKUP_DIR:-$HOME/backups/heymail}"

if [ ! -d "$BACKUP_ROOT" ]; then
    echo "ERROR: backup directory unavailable" >&2
    exit 1
fi

shopt -s nullglob

bundles=(
    "$BACKUP_ROOT"/heymail-20??????T??????Z.tar.age
)

if [ "${#bundles[@]}" -eq 0 ]; then
    echo "ERROR: no encrypted backup bundle available" >&2
    exit 1
fi

bundle=""

for ((i=${#bundles[@]} - 1; i >= 0; --i)); do
    candidate="${bundles[$i]}"
    checksum="${candidate}.sha256"

    if [ ! -f "$checksum" ]; then
        continue
    fi

    if (
        cd "$BACKUP_ROOT"
        sha256sum \
            --check \
            "$(basename "$checksum")" \
            >/dev/null 2>&1
    ); then
        bundle="$candidate"
        break
    fi
done

if [ -z "$bundle" ]; then
    echo "ERROR: no complete verified backup bundle available" >&2
    exit 1
fi

checksum="${bundle}.sha256"

bundle_name="$(basename "$bundle")"
checksum_name="$(basename "$checksum")"

exec tar \
    --create \
    --directory="$BACKUP_ROOT" \
    -- \
    "$bundle_name" \
    "$checksum_name"
