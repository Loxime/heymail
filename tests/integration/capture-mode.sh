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

COMPOSE=(
    docker compose
    -p heymail-capture
    -f compose.capture.yaml
)

PROBE_IMAGE='alpine:3.23.5@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40'

echo "=== HeyMail hardened capture E2E ==="

"${COMPOSE[@]}" config >/dev/null
docker pull "$PROBE_IMAGE" >/dev/null

# Remove the old capture service created under the main HeyMail project by
# earlier development iterations. This touches only the capture container.
docker rm \
    -f \
    heymail-capture-1 \
    >/dev/null 2>&1 \
    || true

"${COMPOSE[@]}" down \
    --remove-orphans \
    >/dev/null 2>&1 \
    || true

docker network rm \
    heymail_capture_net \
    heymail_capture_ingress_net \
    >/dev/null 2>&1 \
    || true

"${COMPOSE[@]}" up \
    -d \
    --force-recreate \
    capture \
    ingress \
    >/dev/null

READY=false

for _ in $(seq 1 30); do
    if curl \
        -fsS \
        http://127.0.0.1:8025/ \
        >/dev/null 2>&1
    then
        READY=true
        break
    fi

    sleep 1
done

if [ "$READY" != true ]; then
    echo
    echo "=== CAPTURE STATE ===" >&2
    "${COMPOSE[@]}" ps >&2 || true
    echo
    echo "=== CAPTURE LOGS ===" >&2
    "${COMPOSE[@]}" logs \
        --no-color \
        --tail=200 \
        capture \
        ingress \
        >&2 || true
    fail "capture UI did not become ready"
fi

echo "PASS: capture UI ready"

ss -lnt \
    | grep -Eq '127\.0\.0\.1:1025[[:space:]]' \
    || fail "SMTP is not bound on loopback"

ss -lnt \
    | grep -Eq '127\.0\.0\.1:8025[[:space:]]' \
    || fail "UI is not bound on loopback"

if ss -lnt \
    | grep -Eq '0\.0\.0\.0:(1025|8025)[[:space:]]'
then
    fail "capture is exposed on all IPv4 interfaces"
fi

echo "PASS: capture ports are loopback-only"

CAPTURE_CID="$(
    "${COMPOSE[@]}" ps -q capture
)"

INGRESS_CID="$(
    "${COMPOSE[@]}" ps -q ingress
)"

[ -n "$CAPTURE_CID" ] \
    || fail "capture container id is empty"

[ -n "$INGRESS_CID" ] \
    || fail "ingress container id is empty"

for cid in "$CAPTURE_CID" "$INGRESS_CID"; do
    [ "$(
        docker inspect \
            --format '{{.HostConfig.ReadonlyRootfs}}' \
            "$cid"
    )" = "true" ] \
        || fail "a capture container rootfs is not read-only"

    docker inspect \
        --format '{{json .HostConfig.CapDrop}}' \
        "$cid" \
        | grep -q '"ALL"' \
        || fail "a capture container did not drop all capabilities"

    docker inspect \
        --format '{{json .HostConfig.SecurityOpt}}' \
        "$cid" \
        | grep -q 'no-new-privileges' \
        || fail "a capture container lacks no-new-privileges"
done

echo "PASS: capture privilege boundary"

[ "$(
    docker network inspect \
        heymail_capture_net \
        --format '{{.Internal}}'
)" = "true" ] \
    || fail "Mailpit network is not internal"

CAPTURE_NETWORKS="$(
    docker inspect \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        "$CAPTURE_CID" \
        | sed '/^[[:space:]]*$/d' \
        | sort
)"

[ "$CAPTURE_NETWORKS" = "heymail_capture_net" ] \
    || {
        echo "capture_networks=$CAPTURE_NETWORKS" >&2
        fail "Mailpit is attached to a non-internal network"
    }

echo "PASS: Mailpit is attached only to the internal network"

if docker run \
    --rm \
    --network heymail_capture_net \
    "$PROBE_IMAGE" \
    sh -ec 'nc -z -w 2 1.1.1.1 443' \
    >/dev/null 2>&1
then
    fail "Mailpit internal network unexpectedly has Internet egress"
fi

echo "PASS: Mailpit network has no TCP Internet egress"

TOKEN="$(
    openssl rand -hex 8
)"
SUBJECT="HeyMail Capture Hardened E2E $TOKEN"

python3 \
    - "$SUBJECT" <<'PY'
import smtplib
import sys
from email.message import EmailMessage

message = EmailMessage()
message["From"] = "errors@heymail.test"
message["To"] = "capture-recipient@example.test"
message["Subject"] = sys.argv[1]
message.set_content(
    "This message must remain inside the capture sandbox."
)

with smtplib.SMTP(
    "127.0.0.1",
    1025,
    timeout=5,
) as client:
    client.send_message(message)
PY

FOUND=false

for _ in $(seq 1 20); do
    if curl \
        -fsS \
        http://127.0.0.1:8025/api/v1/messages \
        | grep -Fq "$SUBJECT"
    then
        FOUND=true
        break
    fi

    sleep 1
done

[ "$FOUND" = true ] \
    || fail "SMTP message was not captured"

echo "PASS: SMTP mail captured locally"

RICH_TOKEN="$(
    openssl rand -hex 8
)"
RICH_SUBJECT="HeyMail Capture Rich MIME $RICH_TOKEN"
PLAIN_TOKEN="plain-$RICH_TOKEN"
HTML_TOKEN="html-$RICH_TOKEN"
ATTACHMENT_TOKEN="attachment-$RICH_TOKEN"

python3 \
    - \
    "$RICH_SUBJECT" \
    "$PLAIN_TOKEN" \
    "$HTML_TOKEN" \
    "$ATTACHMENT_TOKEN" <<'PY'
import smtplib
import sys
from email.message import EmailMessage

subject, plain_token, html_token, attachment_token = sys.argv[1:]

message = EmailMessage()
message["From"] = "newsletter@heymail.test"
message["To"] = "capture-recipient@example.test"
message["Subject"] = subject
message.set_content(f"Plain newsletter body {plain_token}\n")
message.add_alternative(
    "<!doctype html><html><body>"
    f"<h1>HeyMail newsletter {html_token}</h1>"
    "<p>This HTML must remain inside local capture.</p>"
    "</body></html>",
    subtype="html",
)
message.add_attachment(
    (attachment_token + "\n").encode("utf-8"),
    maintype="text",
    subtype="plain",
    filename="heymail-capture-proof.txt",
)

with smtplib.SMTP("127.0.0.1", 1025, timeout=5) as client:
    client.send_message(message)
PY

RICH_JSON=""
RICH_FOUND=false

for _ in $(seq 1 20); do
    RICH_JSON="$(
        curl \
            -fsS \
            http://127.0.0.1:8025/api/v1/message/latest \
            2>/dev/null \
            || true
    )"

    if printf '%s' "$RICH_JSON" \
        | python3 \
            -c '
import json
import sys

subject, plain_token, html_token = sys.argv[1:]

try:
    message = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)

attachments = message.get("Attachments") or []

ok = (
    message.get("Subject") == subject
    and plain_token in (message.get("Text") or "")
    and html_token in (message.get("HTML") or "")
    and len(attachments) == 1
    and attachments[0].get("FileName") == "heymail-capture-proof.txt"
    and bool(attachments[0].get("PartID"))
)

raise SystemExit(0 if ok else 1)
' \
            "$RICH_SUBJECT" \
            "$PLAIN_TOKEN" \
            "$HTML_TOKEN"
    then
        RICH_FOUND=true
        break
    fi

    sleep 1
done

[ "$RICH_FOUND" = true ] \
    || fail "rich MIME message was not captured with text/html/attachment metadata"

PART_ID="$(
    printf '%s' "$RICH_JSON" \
        | python3 \
            -c '
import json
import sys

message = json.load(sys.stdin)
attachments = message.get("Attachments") or []

if len(attachments) != 1:
    raise SystemExit("attachment count mismatch")

attachment = attachments[0]

if attachment.get("FileName") != "heymail-capture-proof.txt":
    raise SystemExit("attachment filename mismatch")

print(attachment["PartID"])
'
)"

[ -n "$PART_ID" ] \
    || fail "captured attachment PartID is empty"

curl \
    -fsS \
    "http://127.0.0.1:8025/api/v1/message/latest/part/${PART_ID}" \
    | grep -Fq "$ATTACHMENT_TOKEN" \
    || fail "captured attachment content does not match"

curl \
    -fsS \
    http://127.0.0.1:8025/view/latest.txt \
    | grep -Fq "$PLAIN_TOKEN" \
    || fail "rendered text view is missing newsletter body"

curl \
    -fsS \
    http://127.0.0.1:8025/view/latest.html \
    | grep -Fq "$HTML_TOKEN" \
    || fail "rendered HTML view is missing newsletter body"

echo "PASS: rich MIME text + HTML + attachment captured locally"
echo "PASS: Mailpit text and HTML preview endpoints render the captured newsletter"
echo "ALL HARDENED CAPTURE TESTS PASSED"
