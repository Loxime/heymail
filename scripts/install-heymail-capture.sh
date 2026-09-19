#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.." \
        && pwd
)"

PREFIX="${HEYMAIL_CAPTURE_PREFIX:-$HOME/.local}"
SHARE_DIR="$PREFIX/share/heymail-capture"
CAPTURE_OPS_DIR="$SHARE_DIR/ops/capture"
BIN_DIR="$PREFIX/bin"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

for path in \
    "$ROOT_DIR/scripts/heymail-capture" \
    "$ROOT_DIR/compose.capture.yaml" \
    "$ROOT_DIR/ops/capture/haproxy.cfg"
do
    [ -f "$path" ] \
        || fail "missing source file: $path"
done

install -d \
    -m 0755 \
    "$SHARE_DIR" \
    "$CAPTURE_OPS_DIR" \
    "$BIN_DIR"

install \
    -m 0644 \
    "$ROOT_DIR/compose.capture.yaml" \
    "$SHARE_DIR/compose.capture.yaml"

install \
    -m 0644 \
    "$ROOT_DIR/ops/capture/haproxy.cfg" \
    "$CAPTURE_OPS_DIR/haproxy.cfg"

install \
    -m 0755 \
    "$ROOT_DIR/scripts/heymail-capture" \
    "$BIN_DIR/heymail-capture"

printf 'Installed: %s\n' "$BIN_DIR/heymail-capture"
printf 'Bundle: %s\n' "$SHARE_DIR"
printf '\n'
printf 'If %s is not in PATH, add:\n' "$BIN_DIR"
printf '  export PATH="%s:$PATH"\n' "$BIN_DIR"
