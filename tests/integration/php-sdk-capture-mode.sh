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

pass() {
    printf 'PASS: %s\n' "$1"
}

COMPOSE=(
    docker compose
    -p heymail-capture
    -f compose.capture.yaml
)

CAPTURE_WAS_RUNNING=false

if [ -n "$(
    "${COMPOSE[@]}" ps \
        --status running \
        -q \
        capture \
        2>/dev/null \
        || true
)" ]; then
    CAPTURE_WAS_RUNNING=true
fi

cleanup() {
    result=$?
    trap - EXIT
    set +e

    if [ "$CAPTURE_WAS_RUNNING" = false ]; then
        "${COMPOSE[@]}" down \
            --remove-orphans \
            >/dev/null 2>&1 \
            || true
    fi

    exit "$result"
}
trap cleanup EXIT

echo "=== HeyMail PHP SDK capture-mode E2E ==="

"${COMPOSE[@]}" up \
    -d \
    --wait \
    capture \
    ingress \
    >/dev/null

TOKEN="$(
    python3 - <<'PY'
import secrets
print(secrets.token_hex(12))
PY
)"

SUBJECT="HeyMail SDK Capture $TOKEN"
TEXT_TOKEN="capture-text-$TOKEN"
HTML_TOKEN="capture-html-$TOKEN"

RESULT="$(
    docker run \
        --rm \
        -i \
        --network heymail_capture_net \
        -e HEYMAIL_MODE=capture \
        -e HEYMAIL_CAPTURE_DSN=smtp://capture:1025 \
        -e HEYMAIL_DEFAULT_FROM=dev@heymail.test \
        -e "SUBJECT=$SUBJECT" \
        -e "TEXT_TOKEN=$TEXT_TOKEN" \
        -e "HTML_TOKEN=$HTML_TOKEN" \
        -v "$ROOT_DIR/packages/heymail-php:/sdk:ro" \
        php:8.4.25-cli-alpine3.23 \
        php <<'PHP'
<?php

declare(strict_types=1);

require '/sdk/src/Exception/ApiException.php';
require '/sdk/src/Exception/TransportException.php';
require '/sdk/src/HeyMailHub.php';
require '/sdk/src/MessageBuilder.php';

use HeyMail\HeyMailHub;

$hub = HeyMailHub::fromEnvironment();

$result = $hub
    ->message()
    ->to(
        'recipient@example.test',
        'Capture User',
    )
    ->replyTo(
        'reply@example.test',
    )
    ->subject(
        (string) getenv('SUBJECT'),
    )
    ->text(
        'Local text '
        . (string) getenv('TEXT_TOKEN'),
    )
    ->html(
        '<h1>Local HTML '
        . (string) getenv('HTML_TOKEN')
        . '</h1>',
    )
    ->idempotencyKey(
        'capture-local-only',
    )
    ->send();

if (($result['status'] ?? null) !== 'captured') {
    exit(1);
}

if (($result['replayed'] ?? null) !== false) {
    exit(1);
}

if (
    !array_key_exists(
        'messageId',
        $result,
    )
    || $result['messageId'] !== null
) {
    exit(1);
}

if (
    !isset($result['captureMessageId'])
    || !is_string($result['captureMessageId'])
    || $result['captureMessageId'] === ''
) {
    exit(1);
}

echo "STATUS=captured\n";
PHP
)"

grep -Fxq \
    'STATUS=captured' \
    <<<"$RESULT" \
    || fail "SDK did not report local capture status"

pass "same PHP SDK builder switches to local capture by environment only"

FOUND=false

for _ in $(seq 1 20); do
    JSON="$(
        curl \
            -fsS \
            http://127.0.0.1:8025/api/v1/message/latest \
            2>/dev/null \
            || true
    )"

    if printf '%s' "$JSON" \
        | python3 \
            -c '
import json
import sys

subject, text_token, html_token = sys.argv[1:]

try:
    message = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)

ok = (
    message.get("Subject") == subject
    and text_token in (message.get("Text") or "")
    and html_token in (message.get("HTML") or "")
)

raise SystemExit(0 if ok else 1)
' \
            "$SUBJECT" \
            "$TEXT_TOKEN" \
            "$HTML_TOKEN"
    then
        FOUND=true
        break
    fi

    sleep 1
done

[ "$FOUND" = true ] \
    || fail "SDK capture message not found in Mailpit"

pass "SDK capture message is visible with text and HTML bodies"

set +e
UNSAFE_OUTPUT="$(
    docker run \
        --rm \
        -i \
        -e HEYMAIL_MODE=capture \
        -e HEYMAIL_CAPTURE_DSN=smtp://smtp.example.com:25 \
        -e HEYMAIL_DEFAULT_FROM=dev@heymail.test \
        -v "$ROOT_DIR/packages/heymail-php:/sdk:ro" \
        php:8.4.25-cli-alpine3.23 \
        php 2>&1 <<'PHP'
<?php

declare(strict_types=1);

require '/sdk/src/Exception/ApiException.php';
require '/sdk/src/Exception/TransportException.php';
require '/sdk/src/HeyMailHub.php';
require '/sdk/src/MessageBuilder.php';

use HeyMail\HeyMailHub;

HeyMailHub::fromEnvironment();

fwrite(
    STDERR,
    "unsafe capture DSN was accepted\n",
);

exit(2);
PHP
)"
UNSAFE_STATUS=$?
set -e

[ "$UNSAFE_STATUS" -ne 0 ] \
    || fail "capture mode accepted a non-local SMTP host"

grep -Fq \
    'host must be loopback or the capture service' \
    <<<"$UNSAFE_OUTPUT" \
    || fail "capture mode rejected unsafe DSN for an unexpected reason"

pass "capture mode refuses non-local SMTP destinations"

echo "ALL PHP SDK CAPTURE-MODE E2E TESTS PASSED"
