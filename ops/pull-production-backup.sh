#!/usr/bin/env bash

set -euo pipefail

umask 077

REMOTE="${HEYMAIL_BACKUP_REMOTE:-ubuntu@51.91.126.247}"
KEY_FILE="${HEYMAIL_BACKUP_PULL_KEY_FILE:-$HOME/.config/heymail/backup-pull-ed25519}"
BACKUP_ROOT="${HEYMAIL_OFFSITE_BACKUP_DIR:-$HOME/backups/heymail-offsite}"
RETENTION_DAYS="${HEYMAIL_OFFSITE_RETENTION_DAYS:-30}"

if [ ! -r "$KEY_FILE" ]; then
    echo "ERROR: restricted backup SSH key unavailable" >&2
    exit 1
fi

mkdir -p "$BACKUP_ROOT"
chmod 0700 "$BACKUP_ROOT"

TMP_DIR="$(
    mktemp \
        --directory \
        "${BACKUP_ROOT}/.pull.XXXXXXXX"
)"

cleanup() {
    rm -rf -- "$TMP_DIR"
}

trap cleanup EXIT

ssh \
    -F /dev/null \
    -T \
    -i "$KEY_FILE" \
    -o "UserKnownHostsFile=$HOME/.ssh/known_hosts" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=10 \
    -o ServerAliveCountMax=2 \
    "$REMOTE" \
| tar \
    --extract \
    --directory="$TMP_DIR" \
    --no-same-owner \
    --no-same-permissions

shopt -s nullglob

bundles=(
    "$TMP_DIR"/heymail-20??????T??????Z.tar.age
)

if [ "${#bundles[@]}" -ne 1 ]; then
    echo "ERROR: remote export did not contain exactly one bundle" >&2
    exit 1
fi

bundle="${bundles[0]}"
bundle_name="$(basename "$bundle")"
checksum_name="${bundle_name}.sha256"
checksum="${TMP_DIR}/${checksum_name}"

if [ ! -f "$checksum" ]; then
    echo "ERROR: remote export checksum missing" >&2
    exit 1
fi

if [[ ! "$bundle_name" =~ ^heymail-(20[0-9]{6}T[0-9]{6}Z)\.tar\.age$ ]]; then
    echo "ERROR: invalid remote backup filename" >&2
    exit 1
fi

TIMESTAMP="${BASH_REMATCH[1]}"

(
    cd "$TMP_DIR"

    sha256sum \
        --check \
        "$checksum_name"
)

DESTINATION="${BACKUP_ROOT}/${TIMESTAMP}"

if [ -d "$DESTINATION" ]; then
    (
        cd "$DESTINATION"

        sha256sum \
            --check \
            "$checksum_name"
    )

    echo "PASS: off-site backup already present and valid"
    echo "OFFSITE_BACKUP=${DESTINATION}"

    exit 0
fi

chmod 0600 \
    "$bundle" \
    "$checksum"

mv \
    "$TMP_DIR" \
    "$DESTINATION"

trap - EXIT

echo "PASS: encrypted backup pulled off-site"
echo "OFFSITE_BACKUP=${DESTINATION}"

find "$BACKUP_ROOT" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name '20??????T??????Z' \
    -mtime "+${RETENTION_DAYS}" \
    -print \
    -exec rm -rf -- {} +

echo "PASS: off-site retention applied"
