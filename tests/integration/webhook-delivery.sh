#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
        && pwd
)"

cd "$ROOT_DIR"

API_ORIGIN="https://api.heymail.test:8443"

TMP_DIR="$(
    mktemp \
        -d \
        /tmp/heymail-webhook-delivery.XXXXXX
)"

AUTH_CONFIG="$TMP_DIR/auth.conf"

SUCCESS_WEBHOOK_ID=""
SUCCESS_SECRET=""

RETRY_WEBHOOK_ID=""
RETRY_SECRET=""

DEAD_WEBHOOK_ID=""
DEAD_SECRET=""

MESSAGE_ID=""

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

    docker compose stop \
        webhook-worker \
        webhook-outbox \
        >/dev/null 2>&1 \
        || true

    docker compose exec \
        -T \
        -e SUCCESS_WEBHOOK_ID="$SUCCESS_WEBHOOK_ID" \
        -e RETRY_WEBHOOK_ID="$RETRY_WEBHOOK_ID" \
        -e DEAD_WEBHOOK_ID="$DEAD_WEBHOOK_ID" \
        -e MESSAGE_ID="$MESSAGE_ID" \
        api \
        php <<'PHP' >/dev/null 2>&1
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

$publicIds = array_values(
    array_filter([
        getenv('SUCCESS_WEBHOOK_ID'),
        getenv('RETRY_WEBHOOK_ID'),
        getenv('DEAD_WEBHOOK_ID'),
    ], static fn ($value): bool =>
        is_string($value)
        && $value !== '',
    ),
);

if ($publicIds !== []) {
    $endpointIds = [];

    $lookup =
        $pdo->prepare(
            <<<'SQL'
SELECT id
FROM webhook_endpoint
WHERE public_id = :public_id
SQL
        );

    foreach ($publicIds as $publicId) {
        $lookup->execute([
            'public_id' => $publicId,
        ]);

        $id =
            $lookup->fetchColumn();

        if (
            is_string($id)
            || is_int($id)
        ) {
            $endpointIds[] =
                (int) $id;
        }
    }

    if ($endpointIds !== []) {
        $placeholders =
            implode(
                ',',
                array_fill(
                    0,
                    count($endpointIds),
                    '?',
                ),
            );

        $deliveryStmt =
            $pdo->prepare(
                sprintf(
                    <<<'SQL'
SELECT id
FROM webhook_delivery
WHERE webhook_endpoint_id IN (%s)
SQL,
                    $placeholders,
                ),
            );

        $deliveryStmt->execute(
            $endpointIds,
        );

        $deliveryIds =
            array_map(
                'intval',
                $deliveryStmt
                    ->fetchAll(
                        PDO::FETCH_COLUMN,
                    ),
            );

        if ($deliveryIds !== []) {
            $jobs =
                $pdo->query(
                    <<<'SQL'
SELECT id, body
FROM messenger_messages
WHERE queue_name = 'webhook_delivery'
SQL
                );

            $deleteJob =
                $pdo->prepare(
                    <<<'SQL'
DELETE FROM messenger_messages
WHERE id = :id
SQL
                );

            foreach (
                $jobs->fetchAll(
                    PDO::FETCH_ASSOC,
                )
                as $job
            ) {
                $body =
                    json_decode(
                        (string) $job['body'],
                        true,
                    );

                if (
                    !is_array($body)
                    || !isset(
                        $body[
                            'webhookDeliveryId'
                        ],
                    )
                ) {
                    continue;
                }

                if (
                    in_array(
                        (int) $body[
                            'webhookDeliveryId'
                        ],
                        $deliveryIds,
                        true,
                    )
                ) {
                    $deleteJob->execute([
                        'id' => $job['id'],
                    ]);
                }
            }
        }

        $deleteDelivery =
            $pdo->prepare(
                sprintf(
                    'DELETE FROM webhook_delivery '
                    . 'WHERE webhook_endpoint_id IN (%s)',
                    $placeholders,
                ),
            );

        $deleteDelivery->execute(
            $endpointIds,
        );

        $deleteEndpoint =
            $pdo->prepare(
                sprintf(
                    'DELETE FROM webhook_endpoint '
                    . 'WHERE id IN (%s)',
                    $placeholders,
                ),
            );

        $deleteEndpoint->execute(
            $endpointIds,
        );
    }
}

$messageId =
    getenv('MESSAGE_ID');

if (
    is_string($messageId)
    && preg_match(
        '/^[1-9][0-9]*$/D',
        $messageId,
    ) === 1
) {
    $delete =
        $pdo->prepare(
            <<<'SQL'
DELETE FROM outbound_message
WHERE id = :id
SQL
        );

    $delete->execute([
        'id' => $messageId,
    ]);
}
PHP

    docker compose start \
        webhook-outbox \
        webhook-worker \
        >/dev/null 2>&1 \
        || true

    rm -rf "$TMP_DIR"

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

create_webhook() {
    NAME="$1"
    PATH_PART="$2"
    EVENT="$3"

    BODY="$TMP_DIR/${NAME}.request.json"
    HEADERS="$TMP_DIR/${NAME}.headers"
    RESPONSE="$TMP_DIR/${NAME}.response.json"

    cat > "$BODY" <<EOF_JSON
{
  "url": "https://api.heymail.test:9443/$PATH_PART",
  "events": [
    "$EVENT"
  ]
}
EOF_JSON

    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --config "$AUTH_CONFIG" \
        --dump-header "$HEADERS" \
        --output "$RESPONSE" \
        --header 'Content-Type: application/json' \
        --data-binary "@$BODY" \
        "$API_ORIGIN/api/v1/webhooks"

    [ "$(http_code "$HEADERS")" = "201" ] \
        || fail "unable to register $NAME webhook"

    python3 \
        - "$RESPONSE" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    payload = json.load(handle)

print(
    payload["webhookId"],
    payload["secret"],
)
PY
}

insert_event() {
    TYPE="$1"
    RECIPIENT="$2"
    SMTP_STATUS="$3"
    DETAIL="$4"
    SOURCE="$5"

    docker compose exec \
        -T \
        -e MESSAGE_ID="$MESSAGE_ID" \
        -e EVENT_TYPE="$TYPE" \
        -e RECIPIENT="$RECIPIENT" \
        -e SMTP_STATUS="$SMTP_STATUS" \
        -e DETAIL="$DETAIL" \
        -e SOURCE="$SOURCE" \
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

$stmt =
    $pdo->prepare(
        <<<'SQL'
INSERT INTO outbound_message_event (
    outbound_message_id,
    event_type,
    occurred_at,
    recipient_hash,
    smtp_status,
    detail,
    source_event_id
)
VALUES (
    :message_id,
    :event_type,
    timezone('UTC', CURRENT_TIMESTAMP),
    :recipient_hash,
    :smtp_status,
    :detail,
    :source_event_id
)
RETURNING id
SQL
    );

$stmt->execute([
    'message_id'
        => getenv('MESSAGE_ID'),
    'event_type'
        => getenv('EVENT_TYPE'),
    'recipient_hash'
        => hash(
            'sha256',
            strtolower(
                (string) getenv(
                    'RECIPIENT',
                ),
            ),
        ),
    'smtp_status'
        => getenv('SMTP_STATUS'),
    'detail'
        => getenv('DETAIL'),
    'source_event_id'
        => hash(
            'sha256',
            (string) getenv(
                'SOURCE',
            ),
        ),
]);

echo $stmt->fetchColumn();
PHP
}

run_outbox_once() {
    docker compose run \
        --rm \
        webhook-outbox \
        php \
        bin/console \
        app:webhook-outbox \
        --once \
        --batch=50
}

run_worker_once() {
    ALLOW_PRIVATE="$1"

    EXTRA_ARGS=()

    if [ "$ALLOW_PRIVATE" = "1" ]; then
        EXTRA_ARGS+=(
            -e
            WEBHOOK_PRIVATE_HOST_ALLOWLIST=api.heymail.test

            -e
            WEBHOOK_CA_FILE=/run/heymail-webhook-ca.pem

            -v
            "$ROOT_DIR/secrets/gateway_tls_cert.pem:/run/heymail-webhook-ca.pem:ro"
        )
    fi

    docker compose run \
        --rm \
        "${EXTRA_ARGS[@]}" \
        webhook-worker \
        php \
        bin/console \
        messenger:consume \
        webhook_delivery \
        --limit=1 \
        --time-limit=20 \
        --memory-limit=128M \
        --sleep=1 \
        --no-interaction
}

force_retry_due() {
    DELIVERY_ID="$1"

    docker compose exec \
        -T \
        -e DELIVERY_ID="$DELIVERY_ID" \
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

$stmt =
    $pdo->prepare(
        <<<'SQL'
UPDATE webhook_delivery
SET next_attempt_at =
    timezone(
        'UTC',
        CURRENT_TIMESTAMP
    ) - INTERVAL '1 second'
WHERE id = :id
  AND status = 'pending'
SQL
    );

$stmt->execute([
    'id'
        => getenv('DELIVERY_ID'),
]);
PHP
}

delivery_state() {
    WEBHOOK_ID="$1"
    EVENT_ID="$2"

    docker compose exec \
        -T \
        -e WEBHOOK_ID="$WEBHOOK_ID" \
        -e EVENT_ID="$EVENT_ID" \
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

$stmt =
    $pdo->prepare(
        <<<'SQL'
SELECT
    wd.id,
    wd.public_id,
    wd.status,
    wd.attempt_count,
    wd.queued_at,
    wd.next_attempt_at,
    wd.succeeded_at,
    wd.last_error
FROM webhook_delivery wd
INNER JOIN webhook_endpoint we
    ON we.id = wd.webhook_endpoint_id
WHERE we.public_id = :webhook_id
  AND wd.outbound_message_event_id = :event_id
SQL
    );

$stmt->execute([
    'webhook_id'
        => getenv('WEBHOOK_ID'),
    'event_id'
        => getenv('EVENT_ID'),
]);

$row =
    $stmt->fetch(
        PDO::FETCH_ASSOC,
    );

if (!is_array($row)) {
    exit(1);
}

foreach ($row as $key => $value) {
    echo strtoupper(
        $key,
    ),
    '=',
    $value === null
        ? 'NULL'
        : $value,
    PHP_EOL;
}
PHP
}

receiver_requests() {
    docker compose exec \
        -T \
        fake-webhook \
        sh -c '
            if test -f /capture/requests.ndjson
            then
                cat /capture/requests.ndjson
            fi
        '
}

verify_request_signature() {
    PATH_PART="$1"
    SECRET="$2"
    EXPECTED_TYPE="$3"
    EXPECTED_COUNT="$4"

    receiver_requests \
        > "$TMP_DIR/receiver.ndjson"

    python3 \
        - "$TMP_DIR/receiver.ndjson" \
        "/$PATH_PART" \
        "$SECRET" \
        "$EXPECTED_TYPE" \
        "$EXPECTED_COUNT" <<'PY'
import hashlib
import hmac
import json
import sys
import time

(
    path,
    expected_path,
    secret,
    expected_type,
    expected_count,
) = sys.argv[1:]

with open(
    path,
    encoding="utf-8",
) as handle:
    rows = [
        json.loads(line)
        for line in handle
        if line.strip()
    ]

rows = [
    row
    for row in rows
    if row["path"] == expected_path
]

if len(rows) != int(expected_count):
    raise SystemExit(
        f"expected {expected_count} requests "
        f"for {expected_path}, got {len(rows)}"
    )

for row in rows:
    headers = row["headers"]

    timestamp = headers.get(
        "x-heymail-webhook-timestamp"
    )

    signature = headers.get(
        "x-heymail-webhook-signature"
    )

    webhook_id = headers.get(
        "x-heymail-webhook-id"
    )

    if not timestamp or not signature or not webhook_id:
        raise SystemExit(
            "missing HeyMail signature headers"
        )

    if not signature.startswith("v1="):
        raise SystemExit(
            "invalid signature version"
        )

    try:
        timestamp_int = int(timestamp)
    except ValueError as exc:
        raise SystemExit(
            "invalid timestamp"
        ) from exc

    if abs(
        int(time.time())
        - timestamp_int
    ) > 120:
        raise SystemExit(
            "webhook timestamp outside freshness window"
        )

    expected = hmac.new(
        secret.encode(),
        (
            timestamp
            + "."
            + row["body"]
        ).encode(),
        hashlib.sha256,
    ).hexdigest()

    actual = signature[3:]

    if not hmac.compare_digest(
        expected,
        actual,
    ):
        raise SystemExit(
            "invalid webhook HMAC"
        )

    body = json.loads(
        row["body"]
    )

    if body["id"] != webhook_id:
        raise SystemExit(
            "payload/header webhook delivery ID mismatch"
        )

    if body["type"] != expected_type:
        raise SystemExit(
            "unexpected webhook event type"
        )

    if "sourceEventId" in row["body"]:
        raise SystemExit(
            "internal source event ID leaked"
        )

    if "idempotency" in row["body"].lower():
        raise SystemExit(
            "internal idempotency data leaked"
        )
PY
}

echo "=== HeyMail signed webhook delivery E2E ==="

docker compose up \
    -d \
    --wait \
    api \
    gateway \
    fake-webhook \
    webhook-outbox \
    webhook-worker \
    >/dev/null

docker compose stop \
    webhook-outbox \
    webhook-worker \
    >/dev/null

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

python3 \
    - "$AUTH_CONFIG" <<'PY'
from pathlib import Path
import sys

Path(
    sys.argv[1]
).chmod(0o600)
PY

unset AUTH_B64

TOKEN="$(
    python3 - <<'PY'
import secrets

print(
    secrets.token_hex(12)
)
PY
)"

read -r \
    SUCCESS_WEBHOOK_ID \
    SUCCESS_SECRET \
    < <(
        create_webhook \
            success \
            success \
            delivered
    )

read -r \
    RETRY_WEBHOOK_ID \
    RETRY_SECRET \
    < <(
        create_webhook \
            retry \
            retry-once \
            tempfail
    )

read -r \
    DEAD_WEBHOOK_ID \
    DEAD_SECRET \
    < <(
        create_webhook \
            dead \
            dead \
            bounced
    )

pass "registered isolated webhook endpoints"

MESSAGE_ID="$(
    docker compose exec \
        -T \
        -e TOKEN="$TOKEN" \
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

$stmt =
    $pdo->prepare(
        <<<'SQL'
INSERT INTO outbound_message (
    workspace_id,
    idempotency_key_hash,
    status,
    created_at,
    ready_for_submission_at,
    submitting_at,
    submitted_at
)
VALUES (
    (
        SELECT id
        FROM workspace
        WHERE name = 'HeyMail Legacy Workspace'
        ORDER BY id ASC
        LIMIT 1
    ),
    :hash,
    'submitted',
    timezone('UTC', CURRENT_TIMESTAMP),
    timezone('UTC', CURRENT_TIMESTAMP),
    timezone('UTC', CURRENT_TIMESTAMP),
    timezone('UTC', CURRENT_TIMESTAMP)
)
RETURNING id
SQL
    );

$stmt->execute([
    'hash'
        => hash(
            'sha256',
            (string) getenv(
                'TOKEN',
            ),
        ),
]);

echo $stmt->fetchColumn();
PHP
)"

[[ "$MESSAGE_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid webhook fixture message"

# ===========================================================================
# SUCCESS + SSRF gate
# ===========================================================================

SUCCESS_EVENT_ID="$(
    insert_event \
        delivered \
        success@example.test \
        2.0.0 \
        '250 accepted' \
        "$TOKEN:success"
)"

run_outbox_once \
    >/dev/null

SUCCESS_INITIAL="$(
    delivery_state \
        "$SUCCESS_WEBHOOK_ID" \
        "$SUCCESS_EVENT_ID"
)"

SUCCESS_DELIVERY_ID="$(
    awk \
        -F= \
        '$1 == "ID" { print $2 }' \
        <<<"$SUCCESS_INITIAL"
)"

run_worker_once 0 \
    >/dev/null

SUCCESS_BLOCKED="$(
    delivery_state \
        "$SUCCESS_WEBHOOK_ID" \
        "$SUCCESS_EVENT_ID"
)"

grep -Fxq \
    'STATUS=pending' \
    <<<"$SUCCESS_BLOCKED" \
    || fail "SSRF-blocked delivery is not pending"

grep -Fxq \
    'ATTEMPT_COUNT=1' \
    <<<"$SUCCESS_BLOCKED" \
    || fail "SSRF rejection did not count one attempt"

grep -Fq \
    'Webhook hostname has no allowed address.' \
    <<<"$SUCCESS_BLOCKED" \
    || fail "private webhook target was not rejected"

if receiver_requests \
    | grep -Fq '"path":"/success"'
then
    fail "private target received traffic without explicit allowlist"
fi

pass "private webhook target fails closed without allowlist"

force_retry_due \
    "$SUCCESS_DELIVERY_ID"

run_outbox_once \
    >/dev/null

run_worker_once 1 \
    >/dev/null

SUCCESS_FINAL="$(
    delivery_state \
        "$SUCCESS_WEBHOOK_ID" \
        "$SUCCESS_EVENT_ID"
)"

grep -Fxq \
    'STATUS=succeeded' \
    <<<"$SUCCESS_FINAL" \
    || fail "allowlisted webhook did not succeed"

grep -Fxq \
    'ATTEMPT_COUNT=2' \
    <<<"$SUCCESS_FINAL" \
    || fail "success retry attempt count is incorrect"

verify_request_signature \
    success \
    "$SUCCESS_SECRET" \
    delivered \
    1

pass "signed HTTPS webhook succeeds and HMAC verifies"

# ===========================================================================
# 500 -> retry -> 204
# ===========================================================================

RETRY_EVENT_ID="$(
    insert_event \
        tempfail \
        retry@example.test \
        4.1.1 \
        '450 temporary rejection' \
        "$TOKEN:retry"
)"

run_outbox_once \
    >/dev/null

RETRY_INITIAL="$(
    delivery_state \
        "$RETRY_WEBHOOK_ID" \
        "$RETRY_EVENT_ID"
)"

RETRY_DELIVERY_ID="$(
    awk \
        -F= \
        '$1 == "ID" { print $2 }' \
        <<<"$RETRY_INITIAL"
)"

run_worker_once 1 \
    >/dev/null

RETRY_FAILED="$(
    delivery_state \
        "$RETRY_WEBHOOK_ID" \
        "$RETRY_EVENT_ID"
)"

grep -Fxq \
    'STATUS=pending' \
    <<<"$RETRY_FAILED" \
    || fail "HTTP 500 did not remain pending"

grep -Fxq \
    'ATTEMPT_COUNT=1' \
    <<<"$RETRY_FAILED" \
    || fail "HTTP 500 attempt count incorrect"

grep -Fq \
    'Webhook returned HTTP 500.' \
    <<<"$RETRY_FAILED" \
    || fail "HTTP 500 diagnostic missing"

verify_request_signature \
    retry-once \
    "$RETRY_SECRET" \
    tempfail \
    1

force_retry_due \
    "$RETRY_DELIVERY_ID"

run_outbox_once \
    >/dev/null

run_worker_once 1 \
    >/dev/null

RETRY_FINAL="$(
    delivery_state \
        "$RETRY_WEBHOOK_ID" \
        "$RETRY_EVENT_ID"
)"

grep -Fxq \
    'STATUS=succeeded' \
    <<<"$RETRY_FINAL" \
    || fail "retry-once webhook did not recover"

grep -Fxq \
    'ATTEMPT_COUNT=2' \
    <<<"$RETRY_FINAL" \
    || fail "retry success attempt count incorrect"

verify_request_signature \
    retry-once \
    "$RETRY_SECRET" \
    tempfail \
    2

pass "HTTP 500 is retried and later 204 succeeds"

# ===========================================================================
# Five failures -> DEAD
# ===========================================================================

DEAD_EVENT_ID="$(
    insert_event \
        bounced \
        dead@example.test \
        5.1.1 \
        '550 permanent rejection' \
        "$TOKEN:dead"
)"

run_outbox_once \
    >/dev/null

DEAD_INITIAL="$(
    delivery_state \
        "$DEAD_WEBHOOK_ID" \
        "$DEAD_EVENT_ID"
)"

DEAD_DELIVERY_ID="$(
    awk \
        -F= \
        '$1 == "ID" { print $2 }' \
        <<<"$DEAD_INITIAL"
)"

for ATTEMPT in 1 2 3 4 5
do
    run_worker_once 1 \
        >/dev/null

    STATE="$(
        delivery_state \
            "$DEAD_WEBHOOK_ID" \
            "$DEAD_EVENT_ID"
    )"

    if [ "$ATTEMPT" -lt 5 ]; then
        grep -Fxq \
            'STATUS=pending' \
            <<<"$STATE" \
            || fail "dead-path attempt $ATTEMPT stopped too early"

        grep -Fxq \
            "ATTEMPT_COUNT=$ATTEMPT" \
            <<<"$STATE" \
            || fail "dead-path attempt counter mismatch"

        force_retry_due \
            "$DEAD_DELIVERY_ID"

        run_outbox_once \
            >/dev/null
    else
        grep -Fxq \
            'STATUS=dead' \
            <<<"$STATE" \
            || fail "fifth webhook failure did not become DEAD"

        grep -Fxq \
            'ATTEMPT_COUNT=5' \
            <<<"$STATE" \
            || fail "dead webhook does not have exactly five attempts"

        grep -Fxq \
            'NEXT_ATTEMPT_AT=NULL' \
            <<<"$STATE" \
            || fail "DEAD webhook still has next_attempt_at"
    fi
done

verify_request_signature \
    dead \
    "$DEAD_SECRET" \
    bounced \
    5

run_outbox_once \
    >/dev/null

POST_DEAD="$(
    delivery_state \
        "$DEAD_WEBHOOK_ID" \
        "$DEAD_EVENT_ID"
)"

grep -Fxq \
    'ATTEMPT_COUNT=5' \
    <<<"$POST_DEAD" \
    || fail "DEAD delivery was requeued"

verify_request_signature \
    dead \
    "$DEAD_SECRET" \
    bounced \
    5

pass "five failed attempts end permanently in DEAD"

# ===========================================================================
# Redirect transport gate
# ===========================================================================

REDIRECT_RESULT="$(
    docker compose run \
        --rm \
        -e WEBHOOK_PRIVATE_HOST_ALLOWLIST=api.heymail.test \
        -e WEBHOOK_CA_FILE=/run/heymail-webhook-ca.pem \
        -v "$ROOT_DIR/secrets/gateway_tls_cert.pem:/run/heymail-webhook-ca.pem:ro" \
        webhook-worker \
        php <<'PHP'
<?php

declare(strict_types=1);

require '/app/vendor/autoload.php';

use App\Webhook\WebhookHttpClient;
use App\Webhook\WebhookRequest;

$client =
    new WebhookHttpClient(
        caFile:
            '/run/heymail-webhook-ca.pem',
        privateHostAllowlist:
            'api.heymail.test',
    );

$status =
    $client->post(
        'https://api.heymail.test:9443/redirect',
        'whd_redirect_test',
        new WebhookRequest(
            body: '{}',
            timestamp:
                (string) time(),
            signature:
                'v1='
                . str_repeat(
                    '0',
                    64,
                ),
        ),
    );

echo $status;
PHP
)"

[ "$REDIRECT_RESULT" = "302" ] \
    || fail "webhook transport did not return redirect status directly"

receiver_requests \
    > "$TMP_DIR/final-requests.ndjson"

python3 \
    - "$TMP_DIR/final-requests.ndjson" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    rows = [
        json.loads(line)
        for line in handle
        if line.strip()
    ]

redirects = [
    row
    for row in rows
    if row["path"] == "/redirect"
]

if len(redirects) != 1:
    raise SystemExit(
        "expected exactly one redirect request"
    )
PY

pass "webhook HTTP client does not follow redirects"

echo
echo "SUCCESS_DELIVERY_ID=$SUCCESS_DELIVERY_ID"
echo "RETRY_DELIVERY_ID=$RETRY_DELIVERY_ID"
echo "DEAD_DELIVERY_ID=$DEAD_DELIVERY_ID"
echo
echo "ALL SIGNED WEBHOOK DELIVERY E2E TESTS PASSED"
