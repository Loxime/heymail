#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
        && pwd
)"
cd "$ROOT_DIR"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

TMP_DIR="$(
    mktemp \
        -d \
        /tmp/heymail-capture-cli.XXXXXX
)"

INSTALL_PREFIX="$TMP_DIR/install"
PROJECT_DIR="$TMP_DIR/project"

cleanup() {
    result=$?

    trap - EXIT
    set +e

    HEYMAIL_CAPTURE_HOME="$INSTALL_PREFIX/share/heymail-capture" \
        "$INSTALL_PREFIX/bin/heymail-capture" \
        down \
        >/dev/null 2>&1

    rm -rf "$TMP_DIR"

    exit "$result"
}

trap cleanup EXIT

echo "=== HeyMail universal capture CLI E2E ==="

HEYMAIL_CAPTURE_PREFIX="$INSTALL_PREFIX" \
    ./scripts/install-heymail-capture.sh \
    >/dev/null

CLI="$INSTALL_PREFIX/bin/heymail-capture"

[ -x "$CLI" ] \
    || fail "installed CLI is not executable"

[ -f "$INSTALL_PREFIX/share/heymail-capture/compose.capture.yaml" ] \
    || fail "installed Compose bundle missing"

[ -f "$INSTALL_PREFIX/share/heymail-capture/ops/capture/haproxy.cfg" ] \
    || fail "installed HAProxy config missing"

echo "PASS: CLI bundle installs into isolated prefix"

HEYMAIL_CAPTURE_HOME="$INSTALL_PREFIX/share/heymail-capture" \
    "$CLI" \
    up \
    >/dev/null

curl \
    -fsS \
    http://127.0.0.1:8025/ \
    >/dev/null \
    || fail "capture UI not reachable after CLI up"

echo "PASS: CLI up starts shared capture service"

mkdir -p "$PROJECT_DIR"

cat > "$PROJECT_DIR/compose.yaml" <<'YAML'
services:
  app:
    image: alpine:3.23.5@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40
    command:
      - sh
      - -ec
      - sleep 600
YAML

(
    cd "$PROJECT_DIR"

    HEYMAIL_CAPTURE_HOME="$INSTALL_PREFIX/share/heymail-capture" \
        "$CLI" \
        inject \
        app \
        >/dev/null
)

OVERRIDE="$PROJECT_DIR/compose.heymail-capture.yaml"

[ -f "$OVERRIDE" ] \
    || fail "inject did not create override"

grep -Fq \
    '# generated-by: heymail-capture' \
    "$OVERRIDE" \
    || fail "generated override lacks ownership marker"

grep -Fq \
    'MAILER_DSN: "smtp://capture:1025"' \
    "$OVERRIDE" \
    || fail "generated override lacks Docker SMTP DSN"

grep -Fq \
    'external: true' \
    "$OVERRIDE" \
    || fail "generated override does not use external capture network"

echo "PASS: inject creates explicit reversible Compose override"

docker compose \
    -p heymail-capture-cli-probe \
    -f "$PROJECT_DIR/compose.yaml" \
    -f "$OVERRIDE" \
    up \
    -d \
    >/dev/null

PROBE_CID="$(
    docker compose \
        -p heymail-capture-cli-probe \
        -f "$PROJECT_DIR/compose.yaml" \
        -f "$OVERRIDE" \
        ps \
        -q \
        app
)"

[ -n "$PROBE_CID" ] \
    || fail "probe application container missing"

docker inspect \
    --format '{{json .NetworkSettings.Networks}}' \
    "$PROBE_CID" \
    | grep -Fq '"heymail_capture_net"' \
    || fail "injected project did not join capture network"

docker inspect \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
    "$PROBE_CID" \
    | grep -Fxq 'MAILER_DSN=smtp://capture:1025' \
    || fail "injected project did not receive capture DSN"

echo "PASS: disposable Docker project joins shared capture network"

docker compose \
    -p heymail-capture-cli-probe \
    -f "$PROJECT_DIR/compose.yaml" \
    -f "$OVERRIDE" \
    down \
    >/dev/null

(
    cd "$PROJECT_DIR"

    HEYMAIL_CAPTURE_HOME="$INSTALL_PREFIX/share/heymail-capture" \
        "$CLI" \
        eject \
        >/dev/null
)

[ ! -e "$OVERRIDE" ] \
    || fail "eject did not remove managed override"

echo "PASS: eject reverses injection without touching project Compose file"

HEYMAIL_CAPTURE_HOME="$INSTALL_PREFIX/share/heymail-capture" \
    "$CLI" \
    status \
    >/dev/null

HEYMAIL_CAPTURE_HOME="$INSTALL_PREFIX/share/heymail-capture" \
    "$CLI" \
    down \
    >/dev/null

echo "PASS: status/down work from installed bundle"
echo "ALL UNIVERSAL CAPTURE CLI TESTS PASSED"
