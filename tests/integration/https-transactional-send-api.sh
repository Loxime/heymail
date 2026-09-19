#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
        && pwd
)"

cd "$ROOT_DIR"

API_ORIGIN="https://api.heymail.test:8443"

OUTBOUND_ID=""
AUTH_CONFIG=""
TEMP_DIR=""
SENDER_DOMAIN=""
SENDER_EMAIL=""

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

cleanup() {
    RESULT=$?

    trap - EXIT
    set +e

    if [ -n "${OUTBOUND_ID:-}" ]; then
        docker compose exec \
            -T \
            -e OUTBOUND_ID="$OUTBOUND_ID" \
            api \
            php <<'PHP' >/dev/null 2>&1
<?php

declare(strict_types=1);

$id = getenv('OUTBOUND_ID');

if (
    !is_string($id)
    || preg_match('/^[1-9][0-9]*$/D', $id) !== 1
) {
    exit(0);
}

$pdo = new PDO(
    sprintf(
        'pgsql:host=%s;port=%s;dbname=%s',
        getenv('DB_HOST'),
        getenv('DB_PORT'),
        getenv('DB_NAME'),
    ),
    getenv('DB_USER'),
    trim(
        file_get_contents(
            (string) getenv('DB_PASSWORD_FILE'),
        ),
    ),
    [
        PDO::ATTR_ERRMODE
            => PDO::ERRMODE_EXCEPTION,
    ],
);

$rows = $pdo
    ->query(
        <<<'SQL'
SELECT id, body
FROM messenger_messages
WHERE queue_name IN ('outbound', 'failed')
SQL
    )
    ->fetchAll(PDO::FETCH_ASSOC);

$deleteQueue = $pdo->prepare(
    'DELETE FROM messenger_messages WHERE id = :id',
);

foreach ($rows as $row) {
    try {
        $body = json_decode(
            (string) $row['body'],
            true,
            512,
            JSON_THROW_ON_ERROR,
        );
    } catch (JsonException) {
        continue;
    }

    if (
        is_array($body)
        && (string) (
            $body['outboundMessageId']
            ?? ''
        ) === $id
    ) {
        $deleteQueue->execute([
            'id' => $row['id'],
        ]);
    }
}

$deleteMessage = $pdo->prepare(
    'DELETE FROM outbound_message WHERE id = :id',
);

$deleteMessage->execute([
    'id' => $id,
]);
PHP
    fi

    docker compose start \
        mail-worker \
        >/dev/null 2>&1 \
        || true

    if [ -n "${TEMP_DIR:-}" ]; then
        rm -rf "$TEMP_DIR"
    fi

    exit "$RESULT"
}

trap cleanup EXIT

http_code() {
    awk '
        /^HTTP\/[0-9.]+ [0-9][0-9][0-9]/ {
            code = $2
        }

        END {
            print code
        }
    ' "$1"
}

json_field() {
    FIELD="$1"
    FILE="$2"

    python3 \
        - "$FIELD" "$FILE" <<'PY'
import json
import sys

field = sys.argv[1]
path = sys.argv[2]

with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

value = data[field]

if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

authenticated_curl() {
    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --config "$AUTH_CONFIG" \
        "$@"
}

echo "=== HeyMail HTTPS transactional E2E ==="

TEMP_DIR="$(
    mktemp \
        -d \
        /tmp/heymail-https-e2e.XXXXXX
)"

chmod 0700 "$TEMP_DIR"

AUTH_CONFIG="$TEMP_DIR/auth.conf"

AUTH_B64="$(
    printf '%s:%s' \
        "$(cat secrets/api_key)" \
        "$(cat secrets/api_secret)" \
        | base64 -w 0
)"

printf \
    'header = "Authorization: Basic %s"\n' \
    "$AUTH_B64" \
    > "$AUTH_CONFIG"

chmod 0600 "$AUTH_CONFIG"

unset AUTH_B64

TOKEN="$(
    python3 - <<'PY'
import secrets
print(secrets.token_hex(12))
PY
)"

IDEMPOTENCY_KEY="https-e2e-$TOKEN"
RECIPIENT="https-e2e-$TOKEN@success.test"
SUBJECT="HeyMail HTTPS E2E $TOKEN"
BODY_MARKER="HEYMAIL-HTTPS-E2E-$TOKEN"

SENDER_DOMAIN="heymail.test"
SENDER_EMAIL="sender-$TOKEN@$SENDER_DOMAIN"

PAYLOAD="$TEMP_DIR/payload.json"

python3 \
    - "$SENDER_EMAIL" "$RECIPIENT" "$SUBJECT" "$BODY_MARKER" \
    > "$PAYLOAD" <<'PY'
import json
import sys

sender = sys.argv[1]
recipient = sys.argv[2]
subject = sys.argv[3]
body = sys.argv[4]

print(
    json.dumps(
        {
            "from": {
                "email": sender,
                "name": "HeyMail",
            },
            "to": [
                {
                    "email": recipient,
                },
            ],
            "subject": subject,
            "text": body,
        },
        separators=(",", ":"),
    )
)
PY

CONFLICT_PAYLOAD="$TEMP_DIR/conflict.json"

python3 \
    - "$SENDER_EMAIL" "$RECIPIENT" \
    > "$CONFLICT_PAYLOAD" <<'PY'
import json
import sys

print(
    json.dumps(
        {
            "from": {
                "email": sys.argv[1],
            },
            "to": [
                {
                    "email": sys.argv[2],
                },
            ],
            "subject": "Conflicting HTTPS payload",
            "text": "CONFLICTING-PAYLOAD",
        },
        separators=(",", ":"),
    )
)
PY

docker compose up \
    -d \
    --wait \
    --build \
    gateway \
    mail-worker \
    postfix \
    rspamd \
    fake-mx-success \
    fake-mx-tempfail \
    fake-mx-permfail \
    >/dev/null

docker compose stop \
    mail-worker \
    >/dev/null

LEGACY_DKIM_PUBLIC_KEY="$(
    docker compose run \
        --rm \
        --no-deps \
        -T \
        --entrypoint python3 \
        dkim-verifier \
        - <<'PY_DKIM'
import re

from pathlib import Path

text = Path(
    "/public/heymail.test.lab.dns.txt"
).read_text(
    encoding="ascii"
)

record = "".join(
    re.findall(
        r'"([^"]*)"',
        text,
    )
)

match = re.search(
    r"(?:^|;\s*)p=([^;\s]+)",
    record,
)

if match is None:
    raise SystemExit(
        "legacy DKIM public key not found"
    )

print(
    match.group(1)
)
PY_DKIM
)"

[ -n "$LEGACY_DKIM_PUBLIC_KEY" ] \
    || fail "legacy DKIM public key is empty"

docker compose exec \
    -T \
    -e SENDER_DOMAIN="$SENDER_DOMAIN" \
    -e SENDER_EMAIL="$SENDER_EMAIL" \
    -e DKIM_PUBLIC_KEY="$LEGACY_DKIM_PUBLIC_KEY" \
    api \
    php <<'PHP'
<?php

declare(strict_types=1);

$domain = getenv('SENDER_DOMAIN');
$email = getenv('SENDER_EMAIL');
$dkimPublicKey = getenv('DKIM_PUBLIC_KEY');

if (
    !is_string($domain)
    || $domain === ''
    || !is_string($email)
    || $email === ''
    || !is_string($dkimPublicKey)
    || $dkimPublicKey === ''
) {
    exit(1);
}

$pdo = new PDO(
    sprintf(
        'pgsql:host=%s;port=%s;dbname=%s',
        getenv('DB_HOST'),
        getenv('DB_PORT'),
        getenv('DB_NAME'),
    ),
    getenv('DB_USER'),
    trim(
        file_get_contents(
            (string) getenv('DB_PASSWORD_FILE'),
        ),
    ),
    [
        PDO::ATTR_ERRMODE
            => PDO::ERRMODE_EXCEPTION,
    ],
);

$now =
    (new DateTimeImmutable(
        'now',
        new DateTimeZone('UTC'),
    ))
    ->format('Y-m-d H:i:s');

$token =
    hash(
        'sha256',
        'transactional-fixture:'
        . $domain,
    );

$domainInsert =
    $pdo->prepare(
        <<<'SQL'
INSERT INTO sending_domain (
    domain,
    status,
    verification_token,
    created_at,
    verification_checked_at,
    verified_at,
    disabled_at,
    dkim_selector,
    dkim_public_key,
    dkim_provisioned_at
)
VALUES (
    :domain,
    'verified',
    :token,
    :created_at,
    :verified_at,
    :verified_at,
    NULL,
    'lab',
    :dkim_public_key,
    :verified_at
)
ON CONFLICT (domain) DO UPDATE
SET
    status = 'verified',
    verification_checked_at = EXCLUDED.verification_checked_at,
    verified_at = EXCLUDED.verified_at,
    disabled_at = NULL,
    dkim_selector = 'lab',
    dkim_public_key = EXCLUDED.dkim_public_key,
    dkim_provisioned_at = EXCLUDED.dkim_provisioned_at
RETURNING id
SQL
    );

$domainInsert->execute([
    'domain' => $domain,
    'token' => $token,
    'created_at' => $now,
    'verified_at' => $now,
    'dkim_public_key'
        => $dkimPublicKey,
]);

$domainId =
    $domainInsert->fetchColumn();

if (
    !is_string($domainId)
    && !is_int($domainId)
) {
    exit(1);
}

$senderInsert =
    $pdo->prepare(
        <<<'SQL'
INSERT INTO sender_identity (
    sending_domain_id,
    email,
    created_at
)
VALUES (
    :domain_id,
    :email,
    :created_at
)
SQL
    );

$senderInsert->execute([
    'domain_id' => $domainId,
    'email' => $email,
    'created_at' => $now,
]);
PHP

docker compose exec -T fake-mx-success \
    rm -f /capture/last.eml \
    >/dev/null 2>&1 \
    || true

# ---------------------------------------------------------------------------
# 401 - authentication boundary
# ---------------------------------------------------------------------------

UNAUTH_HEADERS="$TEMP_DIR/unauth.headers"
UNAUTH_BODY="$TEMP_DIR/unauth.body"

curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --dump-header "$UNAUTH_HEADERS" \
    --output "$UNAUTH_BODY" \
    --header 'Content-Type: application/json' \
    --header "Idempotency-Key: $IDEMPOTENCY_KEY" \
    --data-binary "@$PAYLOAD" \
    "$API_ORIGIN/api/v1/send"

[ "$(http_code "$UNAUTH_HEADERS")" = "401" ] \
    || fail "unauthenticated HTTPS submission was not rejected"

grep -Eiq \
    '^WWW-Authenticate:[[:space:]]*Basic' \
    "$UNAUTH_HEADERS" \
    || fail "401 response lacks WWW-Authenticate"

pass "HTTPS authentication boundary returns 401"

# ---------------------------------------------------------------------------
# 202 - first authenticated submission
# ---------------------------------------------------------------------------

CREATE_HEADERS="$TEMP_DIR/create.headers"
CREATE_BODY="$TEMP_DIR/create.body"

authenticated_curl \
    --dump-header "$CREATE_HEADERS" \
    --output "$CREATE_BODY" \
    --header 'Content-Type: application/json' \
    --header "Idempotency-Key: $IDEMPOTENCY_KEY" \
    --data-binary "@$PAYLOAD" \
    "$API_ORIGIN/api/v1/send"

[ "$(http_code "$CREATE_HEADERS")" = "202" ] \
    || fail "first HTTPS submission did not return 202"

OUTBOUND_ID="$(
    json_field \
        messageId \
        "$CREATE_BODY"
)"

[[ "$OUTBOUND_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "Send API returned invalid messageId"

[ "$(
    json_field \
        replayed \
        "$CREATE_BODY"
)" = "false" ] \
    || fail "first submission was incorrectly marked replayed"

LOCATION_HEADER="$(
    awk '
        BEGIN {
            IGNORECASE = 1
        }

        /^Location:/ {
            sub(/\r$/, "")
            print
            exit
        }
    ' "$CREATE_HEADERS"
)"

[ "$LOCATION_HEADER" = "Location: /api/v1/messages/$OUTBOUND_ID" ] \
    || fail "202 response has invalid Location header: ${LOCATION_HEADER:-missing}"

CACHE_HEADERS="$(
    awk '
        BEGIN {
            IGNORECASE = 1
        }

        /^Cache-Control:/ {
            sub(/\r$/, "")
            print
        }
    ' "$CREATE_HEADERS"
)"

CACHE_COUNT="$(
    printf '%s\n' "$CACHE_HEADERS" \
        | sed '/^$/d' \
        | wc -l \
        | tr -d ' '
)"

[ "$CACHE_COUNT" -eq 1 ] \
    || fail "API returned multiple Cache-Control headers"

[ "$CACHE_HEADERS" = "Cache-Control: no-store" ] \
    || fail "API does not enforce Cache-Control: no-store"

pass "first HTTPS submission returns 202 with hardened headers"

# ---------------------------------------------------------------------------
# GET before worker - message must still be queued
# ---------------------------------------------------------------------------

QUEUED_HEADERS="$TEMP_DIR/queued.headers"
QUEUED_BODY="$TEMP_DIR/queued.body"

authenticated_curl \
    --dump-header "$QUEUED_HEADERS" \
    --output "$QUEUED_BODY" \
    "$API_ORIGIN/api/v1/messages/$OUTBOUND_ID"

[ "$(http_code "$QUEUED_HEADERS")" = "200" ] \
    || fail "queued status endpoint did not return 200"

[ "$(
    json_field \
        status \
        "$QUEUED_BODY"
)" = "queued" ] \
    || fail "message was not QUEUED while worker was stopped"

pass "GET status reports QUEUED before consumption"

# ---------------------------------------------------------------------------
# 200 - same key, same payload
# ---------------------------------------------------------------------------

REPLAY_HEADERS="$TEMP_DIR/replay.headers"
REPLAY_BODY="$TEMP_DIR/replay.body"

authenticated_curl \
    --dump-header "$REPLAY_HEADERS" \
    --output "$REPLAY_BODY" \
    --header 'Content-Type: application/json' \
    --header "Idempotency-Key: $IDEMPOTENCY_KEY" \
    --data-binary "@$PAYLOAD" \
    "$API_ORIGIN/api/v1/send"

REPLAY_HTTP="$(
    http_code "$REPLAY_HEADERS"
)"

if [ "$REPLAY_HTTP" != "200" ]; then
    echo
    echo "=== REPLAY DEBUG ==="
    echo "HTTP=$REPLAY_HTTP"
    echo "--- headers ---"
    tr -d '\r' < "$REPLAY_HEADERS"
    echo "--- body ---"
    cat "$REPLAY_BODY"
    echo
    fail "idempotent HTTPS replay did not return 200"
fi

[ "$(
    json_field \
        messageId \
        "$REPLAY_BODY"
)" = "$OUTBOUND_ID" ] \
    || fail "idempotent replay returned another message"

[ "$(
    json_field \
        replayed \
        "$REPLAY_BODY"
)" = "true" ] \
    || fail "idempotent replay was not marked replayed"

pass "same HTTPS idempotency request replays existing message"

# ---------------------------------------------------------------------------
# 409 - same key, different payload
# ---------------------------------------------------------------------------

CONFLICT_HEADERS="$TEMP_DIR/conflict.headers"
CONFLICT_BODY="$TEMP_DIR/conflict.body"

authenticated_curl \
    --dump-header "$CONFLICT_HEADERS" \
    --output "$CONFLICT_BODY" \
    --header 'Content-Type: application/json' \
    --header "Idempotency-Key: $IDEMPOTENCY_KEY" \
    --data-binary "@$CONFLICT_PAYLOAD" \
    "$API_ORIGIN/api/v1/send"

[ "$(http_code "$CONFLICT_HEADERS")" = "409" ] \
    || fail "conflicting HTTPS idempotency request did not return 409"

pass "different payload with same idempotency key returns 409"

# ---------------------------------------------------------------------------
# Messenger persistence must still contain one message only
# ---------------------------------------------------------------------------

COUNTS="$(
    docker compose exec \
        -T \
        -e OUTBOUND_ID="$OUTBOUND_ID" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

$pdo = new PDO(
    sprintf(
        'pgsql:host=%s;port=%s;dbname=%s',
        getenv('DB_HOST'),
        getenv('DB_PORT'),
        getenv('DB_NAME'),
    ),
    getenv('DB_USER'),
    trim(
        file_get_contents(
            (string) getenv('DB_PASSWORD_FILE'),
        ),
    ),
    [
        PDO::ATTR_ERRMODE
            => PDO::ERRMODE_EXCEPTION,
    ],
);

$id = getenv('OUTBOUND_ID');

$message = $pdo->prepare(
    'SELECT COUNT(*) FROM outbound_message WHERE id = :id',
);

$message->execute([
    'id' => $id,
]);

$payload = $pdo->prepare(
    'SELECT COUNT(*) FROM outbound_message_payload WHERE outbound_message_id = :id',
);

$payload->execute([
    'id' => $id,
]);

$queueRows = $pdo
    ->query(
        <<<'SQL'
SELECT body
FROM messenger_messages
WHERE queue_name = 'outbound'
SQL
    )
    ->fetchAll(PDO::FETCH_COLUMN);

$queueCount = 0;

foreach ($queueRows as $body) {
    try {
        $decoded = json_decode(
            (string) $body,
            true,
            512,
            JSON_THROW_ON_ERROR,
        );
    } catch (JsonException) {
        continue;
    }

    if (
        is_array($decoded)
        && (string) (
            $decoded['outboundMessageId']
            ?? ''
        ) === $id
    ) {
        ++$queueCount;
    }
}

echo 'MESSAGES=',
    $message->fetchColumn(),
    PHP_EOL;

echo 'PAYLOADS=',
    $payload->fetchColumn(),
    PHP_EOL;

echo 'QUEUE=',
    $queueCount,
    PHP_EOL;
PHP
)"

echo "$COUNTS"

grep -Fxq 'MESSAGES=1' <<<"$COUNTS" \
    || fail "idempotency created more than one outbound message"

grep -Fxq 'PAYLOADS=1' <<<"$COUNTS" \
    || fail "idempotency created more than one encrypted payload"

grep -Fxq 'QUEUE=1' <<<"$COUNTS" \
    || fail "idempotency created more than one outbound Messenger job"

pass "idempotency persists one message, payload and queue job"

# ---------------------------------------------------------------------------
# Consume
# ---------------------------------------------------------------------------

docker compose start \
    mail-worker \
    >/dev/null

FINAL_STATUS=""

for _ in $(seq 1 90)
do
    FINAL_HEADERS="$TEMP_DIR/final.headers"
    FINAL_BODY="$TEMP_DIR/final.body"

    authenticated_curl \
        --dump-header "$FINAL_HEADERS" \
        --output "$FINAL_BODY" \
        "$API_ORIGIN/api/v1/messages/$OUTBOUND_ID"

    [ "$(http_code "$FINAL_HEADERS")" = "200" ] \
        || fail "status endpoint failed while waiting for submission"

    FINAL_STATUS="$(
        json_field \
            status \
            "$FINAL_BODY"
    )"

    [ "$FINAL_STATUS" = "submitted" ] \
        && break

    sleep 1
done

[ "$FINAL_STATUS" = "submitted" ] \
    || fail "message did not reach SUBMITTED"

pass "worker moved HTTPS-created message to SUBMITTED"

SUBMITTING_AT="$(
    json_field \
        submittingAt \
        "$FINAL_BODY"
)"

SUBMISSION_UNCERTAIN_AT="$(
    json_field \
        submissionUncertainAt \
        "$FINAL_BODY"
)"

SUBMITTED_AT="$(
    json_field \
        submittedAt \
        "$FINAL_BODY"
)"

[ "$SUBMITTING_AT" != "None" ] \
    || fail "submitted message does not expose submittingAt"

[ "$SUBMISSION_UNCERTAIN_AT" = "None" ] \
    || fail "normal submission unexpectedly exposes submissionUncertainAt"

[ "$SUBMITTED_AT" != "None" ] \
    || fail "submitted message does not expose submittedAt"

pass "normal submission exposes coherent lifecycle timestamps"

TIMELINE="$(
    docker compose exec \
        -T \
        -e OUTBOUND_ID="$OUTBOUND_ID" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

$pdo = new PDO(
    sprintf(
        'pgsql:host=%s;port=%s;dbname=%s',
        getenv('DB_HOST'),
        getenv('DB_PORT'),
        getenv('DB_NAME'),
    ),
    getenv('DB_USER'),
    trim(
        file_get_contents(
            (string) getenv('DB_PASSWORD_FILE'),
        ),
    ),
    [
        PDO::ATTR_ERRMODE
            => PDO::ERRMODE_EXCEPTION,
    ],
);

$stmt = $pdo->prepare(
    <<<'SQL'
SELECT event_type
FROM outbound_message_event
WHERE outbound_message_id = :id
  AND event_type IN (
      'queued',
      'ready_for_submission',
      'submitting',
      'submission_uncertain',
      'submitted'
  )
ORDER BY occurred_at ASC, id ASC
SQL
);

$stmt->execute([
    'id' => getenv('OUTBOUND_ID'),
]);

echo implode(
    '>',
    $stmt->fetchAll(PDO::FETCH_COLUMN),
);
PHP
)"

[ "$TIMELINE" = "queued>ready_for_submission>submitting>submitted" ] \
    || fail "unexpected successful delivery timeline: $TIMELINE"

pass "successful submission persists the complete immutable event timeline"

# ---------------------------------------------------------------------------
# Real SMTP laboratory delivery
# ---------------------------------------------------------------------------

CAPTURED="false"

for _ in $(seq 1 60)
do
    if docker compose exec -T fake-mx-success \
        grep -aF \
        "$BODY_MARKER" \
        /capture/last.eml \
        >/dev/null 2>&1
    then
        CAPTURED="true"
        break
    fi

    sleep 1
done

[ "$CAPTURED" = "true" ] \
    || fail "HTTPS-created message did not reach fake MX"

docker compose exec -T fake-mx-success \
    grep -aF \
    "Subject: $SUBJECT" \
    /capture/last.eml \
    >/dev/null \
    || fail "fake MX captured an unexpected subject"

docker compose exec -T fake-mx-success \
    grep -a '^DKIM-Signature:' \
    /capture/last.eml \
    >/dev/null \
    || fail "HTTPS-created message lacks DKIM signature"

pass "HTTPS-created message reached fake MX with DKIM"

echo
echo "OUTBOUND_ID=$OUTBOUND_ID"
echo "FINAL_STATUS=$FINAL_STATUS"
echo
echo "ALL HTTPS TRANSACTIONAL E2E TESTS PASSED"
