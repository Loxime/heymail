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
        /tmp/heymail-webhook-outbox.XXXXXX
)"

AUTH_CONFIG="$TMP_DIR/auth.conf"

WEBHOOK_ID=""
HISTORICAL_MESSAGE_ID=""
NEW_MESSAGE_ID=""
OUTBOX_WAS_RUNNING=0
WEBHOOK_WORKER_WAS_RUNNING=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

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

with open(
    sys.argv[2],
    encoding="utf-8",
) as handle:
    payload = json.load(handle)

value = payload[sys.argv[1]]

if value is None:
    print("null")
else:
    print(value)
PY
}

cleanup() {
    RESULT=$?

    trap - EXIT
    set +e

    docker compose stop \
        webhook-outbox \
        webhook-worker \
        >/dev/null 2>&1 \
        || true

    if [ -n "${WEBHOOK_ID:-}" ]; then
        docker compose exec \
            -T \
            -e WEBHOOK_ID="$WEBHOOK_ID" \
            -e HISTORICAL_MESSAGE_ID="${HISTORICAL_MESSAGE_ID:-}" \
            -e NEW_MESSAGE_ID="${NEW_MESSAGE_ID:-}" \
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

$webhookId =
    getenv('WEBHOOK_ID');

if (
    is_string($webhookId)
    && $webhookId !== ''
) {
    $endpoint =
        $pdo->prepare(
            <<<'SQL'
SELECT id
FROM webhook_endpoint
WHERE public_id = :public_id
SQL
        );

    $endpoint->execute([
        'public_id' => $webhookId,
    ]);

    $endpointId =
        $endpoint->fetchColumn();

    if (
        is_string($endpointId)
        || is_int($endpointId)
    ) {
        $deliveries =
            $pdo->prepare(
                <<<'SQL'
SELECT id
FROM webhook_delivery
WHERE webhook_endpoint_id = :endpoint_id
SQL
            );

        $deliveries->execute([
            'endpoint_id' => $endpointId,
        ]);

        $deliveryIds =
            array_map(
                'intval',
                $deliveries
                    ->fetchAll(
                        PDO::FETCH_COLUMN,
                    ),
            );

        if ($deliveryIds !== []) {
            $messages =
                $pdo->query(
                    <<<'SQL'
SELECT id, body
FROM messenger_messages
WHERE queue_name = 'webhook_delivery'
SQL
                );

            $deleteMessenger =
                $pdo->prepare(
                    <<<'SQL'
DELETE FROM messenger_messages
WHERE id = :id
SQL
                );

            foreach (
                $messages->fetchAll(
                    PDO::FETCH_ASSOC,
                )
                as $message
            ) {
                $body =
                    json_decode(
                        (string) $message['body'],
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
                    $deleteMessenger
                        ->execute([
                            'id'
                                => $message['id'],
                        ]);
                }
            }
        }

        $deleteDeliveries =
            $pdo->prepare(
                <<<'SQL'
DELETE FROM webhook_delivery
WHERE webhook_endpoint_id = :endpoint_id
SQL
            );

        $deleteDeliveries->execute([
            'endpoint_id' => $endpointId,
        ]);

        $deleteEndpoint =
            $pdo->prepare(
                <<<'SQL'
DELETE FROM webhook_endpoint
WHERE id = :id
SQL
            );

        $deleteEndpoint->execute([
            'id' => $endpointId,
        ]);
    }
}

$deleteMessage =
    $pdo->prepare(
        <<<'SQL'
DELETE FROM outbound_message
WHERE id = :id
SQL
    );

foreach ([
    getenv(
        'HISTORICAL_MESSAGE_ID',
    ),
    getenv(
        'NEW_MESSAGE_ID',
    ),
] as $id) {
    if (
        is_string($id)
        && preg_match(
            '/^[1-9][0-9]*$/D',
            $id,
        ) === 1
    ) {
        $deleteMessage->execute([
            'id' => $id,
        ]);
    }
}
PHP
    fi

    if [ "$OUTBOX_WAS_RUNNING" -eq 1 ]; then
        docker compose start \
            webhook-outbox \
            >/dev/null 2>&1 \
            || true
    fi

    if [ "$WEBHOOK_WORKER_WAS_RUNNING" -eq 1 ]; then
        docker compose start \
            webhook-worker \
            >/dev/null 2>&1 \
            || true
    fi

    rm -rf "$TMP_DIR"

    exit "$RESULT"
}

trap cleanup EXIT

echo "=== HeyMail webhook registry + transactional outbox E2E ==="

docker compose up \
    -d \
    --wait \
    api \
    gateway \
    webhook-outbox \
    >/dev/null

OUTBOX_CONTAINER="$(
    docker compose ps \
        -q \
        webhook-outbox
)"

if [ -n "$OUTBOX_CONTAINER" ] \
    && [ "$(
        docker inspect \
            --format '{{.State.Running}}' \
            "$OUTBOX_CONTAINER"
    )" = "true" ]
then
    OUTBOX_WAS_RUNNING=1
fi

WEBHOOK_WORKER_CONTAINER="$(
    docker compose ps \
        -q \
        webhook-worker
)"

if [ -n "$WEBHOOK_WORKER_CONTAINER" ] \
    && [ "$(
        docker inspect \
            --format '{{.State.Running}}' \
            "$WEBHOOK_WORKER_CONTAINER"
    )" = "true" ]
then
    WEBHOOK_WORKER_WAS_RUNNING=1
fi

# Stop both scheduler and consumer so this test can inspect the queued
# Messenger job deterministically before any HTTP delivery attempt.

docker compose stop \
    webhook-outbox \
    webhook-worker \
    >/dev/null 2>&1 \
    || true

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

chmod 0600 \
    "$AUTH_CONFIG"

unset AUTH_B64

TOKEN="$(
    python3 - <<'PY'
import secrets

print(
    secrets.token_hex(12)
)
PY
)"

# ---------------------------------------------------------------------------
# Historical event BEFORE endpoint registration.
# It must never generate a webhook delivery.
# ---------------------------------------------------------------------------

HISTORICAL="$(
    docker compose exec \
        -T \
        -e TOKEN="$TOKEN" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

$token =
    (string) getenv('TOKEN');

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

$pdo->beginTransaction();

try {
    $message =
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

    $message->execute([
        'hash' => hash(
            'sha256',
            $token
                . ':historical',
        ),
    ]);

    $messageId =
        (int) $message
            ->fetchColumn();

    $event =
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
    'delivered',
    timezone('UTC', CURRENT_TIMESTAMP),
    :recipient_hash,
    '2.0.0',
    'historical accepted',
    :source_event_id
)
RETURNING id
SQL
        );

    $event->execute([
        'message_id'
            => $messageId,
        'recipient_hash'
            => hash(
                'sha256',
                'historical@example.test',
            ),
        'source_event_id'
            => hash(
                'sha256',
                $token
                    . ':historical:event',
            ),
    ]);

    $eventId =
        (int) $event
            ->fetchColumn();

    $pdo->commit();

    echo 'MESSAGE_ID=',
        $messageId,
        PHP_EOL;

    echo 'EVENT_ID=',
        $eventId,
        PHP_EOL;
} catch (Throwable $exception) {
    if ($pdo->inTransaction()) {
        $pdo->rollBack();
    }

    throw $exception;
}
PHP
)"

HISTORICAL_MESSAGE_ID="$(
    awk \
        -F= \
        '$1 == "MESSAGE_ID" { print $2 }' \
        <<<"$HISTORICAL"
)"

HISTORICAL_EVENT_ID="$(
    awk \
        -F= \
        '$1 == "EVENT_ID" { print $2 }' \
        <<<"$HISTORICAL"
)"

[[ "$HISTORICAL_MESSAGE_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid historical message ID"

[[ "$HISTORICAL_EVENT_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid historical event ID"

pass "created historical delivery event before webhook registration"

# ---------------------------------------------------------------------------
# Register endpoint through real HTTPS API.
# ---------------------------------------------------------------------------

CREATE_PAYLOAD="$TMP_DIR/create.json"

cat > "$CREATE_PAYLOAD" <<EOF_JSON
{
  "url": "https://hooks.example.test/heymail/$TOKEN",
  "events": [
    "delivered"
  ]
}
EOF_JSON

CREATE_HEADERS="$TMP_DIR/create.headers"
CREATE_BODY="$TMP_DIR/create.body"

curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --config "$AUTH_CONFIG" \
    --dump-header "$CREATE_HEADERS" \
    --output "$CREATE_BODY" \
    --header 'Content-Type: application/json' \
    --data-binary "@$CREATE_PAYLOAD" \
    "$API_ORIGIN/api/v1/webhooks"

[ "$(http_code "$CREATE_HEADERS")" = "201" ] \
    || fail "webhook registration did not return 201"

WEBHOOK_ID="$(
    json_field \
        webhookId \
        "$CREATE_BODY"
)"

WEBHOOK_SECRET="$(
    json_field \
        secret \
        "$CREATE_BODY"
)"

[[ "$WEBHOOK_ID" =~ ^wh_[a-f0-9]{32}$ ]] \
    || fail "invalid webhook public ID"

[[ "$WEBHOOK_SECRET" == whsec_* ]] \
    || fail "invalid webhook secret format"

grep -Fiq \
    'Cache-Control: no-store' \
    "$CREATE_HEADERS" \
    || fail "webhook creation response is cacheable"

pass "webhook registry returns secret once with no-store response"

# ---------------------------------------------------------------------------
# GET registry must never reveal secret.
# ---------------------------------------------------------------------------

LIST_HEADERS="$TMP_DIR/list.headers"
LIST_BODY="$TMP_DIR/list.body"

curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --config "$AUTH_CONFIG" \
    --dump-header "$LIST_HEADERS" \
    --output "$LIST_BODY" \
    "$API_ORIGIN/api/v1/webhooks"

[ "$(http_code "$LIST_HEADERS")" = "200" ] \
    || fail "webhook list did not return 200"

python3 \
    - "$LIST_BODY" \
    "$WEBHOOK_ID" \
    "$WEBHOOK_SECRET" <<'PY'
import json
import sys

path, webhook_id, secret = sys.argv[1:]

with open(
    path,
    encoding="utf-8",
) as handle:
    payload = json.load(handle)

matches = [
    item
    for item in payload["items"]
    if item["webhookId"] == webhook_id
]

if len(matches) != 1:
    raise SystemExit(
        "registered webhook missing from list"
    )

item = matches[0]

if "secret" in item:
    raise SystemExit(
        "webhook secret field leaked in GET"
    )

if secret in json.dumps(
    payload,
    separators=(",", ":"),
):
    raise SystemExit(
        "webhook secret value leaked in GET"
    )
PY

pass "webhook GET never returns signing secret"

# ---------------------------------------------------------------------------
# Plaintext secret must not exist in PostgreSQL.
# Also verify watermark includes the historical event.
# ---------------------------------------------------------------------------

SECRET_STATE="$(
    docker compose exec \
        -T \
        -e WEBHOOK_ID="$WEBHOOK_ID" \
        -e WEBHOOK_SECRET="$WEBHOOK_SECRET" \
        -e HISTORICAL_EVENT_ID="$HISTORICAL_EVENT_ID" \
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
    starts_after_event_id,
    secret_ciphertext,
    secret_nonce,
    secret_algorithm,
    secret_key_version
FROM webhook_endpoint
WHERE public_id = :public_id
SQL
    );

$stmt->execute([
    'public_id'
        => getenv('WEBHOOK_ID'),
]);

$row =
    $stmt->fetch(
        PDO::FETCH_ASSOC,
    );

if (!is_array($row)) {
    exit(1);
}

$secret =
    (string) getenv(
        'WEBHOOK_SECRET',
    );

$serialized =
    implode(
        '|',
        array_map(
            'strval',
            $row,
        ),
    );

echo 'WATERMARK_OK=',
    (int) $row[
        'starts_after_event_id'
    ] >= (int) getenv(
        'HISTORICAL_EVENT_ID',
    )
        ? '1'
        : '0',
    PHP_EOL;

echo 'PLAINTEXT_SECRET=',
    str_contains(
        $serialized,
        $secret,
    )
        ? '1'
        : '0',
    PHP_EOL;

echo 'CIPHERTEXT_PRESENT=',
    (string) $row[
        'secret_ciphertext'
    ] !== ''
        ? '1'
        : '0',
    PHP_EOL;
PHP
)"

printf '%s\n' "$SECRET_STATE"

grep -Fxq \
    'WATERMARK_OK=1' \
    <<<"$SECRET_STATE" \
    || fail "webhook registration watermark does not cover historical event"

grep -Fxq \
    'PLAINTEXT_SECRET=0' \
    <<<"$SECRET_STATE" \
    || fail "webhook secret is stored in plaintext"

grep -Fxq \
    'CIPHERTEXT_PRESENT=1' \
    <<<"$SECRET_STATE" \
    || fail "encrypted webhook secret is missing"

pass "webhook signing secret is encrypted at rest"

# ---------------------------------------------------------------------------
# New delivery event AFTER registration.
# ---------------------------------------------------------------------------

NEW_FIXTURE="$(
    docker compose exec \
        -T \
        -e TOKEN="$TOKEN" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

$token =
    (string) getenv('TOKEN');

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

$pdo->beginTransaction();

try {
    $message =
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

    $message->execute([
        'hash' => hash(
            'sha256',
            $token
                . ':new',
        ),
    ]);

    $messageId =
        (int) $message
            ->fetchColumn();

    $event =
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
    'delivered',
    timezone('UTC', CURRENT_TIMESTAMP),
    :recipient_hash,
    '2.0.0',
    'new accepted',
    :source_event_id
)
RETURNING id
SQL
        );

    $event->execute([
        'message_id'
            => $messageId,
        'recipient_hash'
            => hash(
                'sha256',
                'new@example.test',
            ),
        'source_event_id'
            => hash(
                'sha256',
                $token
                    . ':new:event',
            ),
    ]);

    $eventId =
        (int) $event
            ->fetchColumn();

    $pdo->commit();

    echo 'MESSAGE_ID=',
        $messageId,
        PHP_EOL;

    echo 'EVENT_ID=',
        $eventId,
        PHP_EOL;
} catch (Throwable $exception) {
    if ($pdo->inTransaction()) {
        $pdo->rollBack();
    }

    throw $exception;
}
PHP
)"

NEW_MESSAGE_ID="$(
    awk \
        -F= \
        '$1 == "MESSAGE_ID" { print $2 }' \
        <<<"$NEW_FIXTURE"
)"

NEW_EVENT_ID="$(
    awk \
        -F= \
        '$1 == "EVENT_ID" { print $2 }' \
        <<<"$NEW_FIXTURE"
)"

[[ "$NEW_MESSAGE_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid new message ID"

[[ "$NEW_EVENT_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid new event ID"

pass "created delivery event after webhook registration"

# ---------------------------------------------------------------------------
# First deterministic outbox pass.
# ---------------------------------------------------------------------------

FIRST_PASS="$(
    docker compose run \
        --rm \
        --no-deps \
        -T \
        webhook-outbox \
        php \
        bin/console \
        app:webhook-outbox \
        --once \
        --batch=50 \
        </dev/null
)"

printf '%s\n' "$FIRST_PASS"

STATE="$(
    docker compose exec \
        -T \
        -e WEBHOOK_ID="$WEBHOOK_ID" \
        -e HISTORICAL_EVENT_ID="$HISTORICAL_EVENT_ID" \
        -e NEW_EVENT_ID="$NEW_EVENT_ID" \
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

$endpoint =
    $pdo->prepare(
        <<<'SQL'
SELECT id
FROM webhook_endpoint
WHERE public_id = :public_id
SQL
    );

$endpoint->execute([
    'public_id'
        => getenv('WEBHOOK_ID'),
]);

$endpointId =
    $endpoint->fetchColumn();

if (
    !is_string($endpointId)
    && !is_int($endpointId)
) {
    exit(1);
}

$count =
    $pdo->prepare(
        <<<'SQL'
SELECT COUNT(*)
FROM webhook_delivery
WHERE webhook_endpoint_id = :endpoint_id
SQL
    );

$count->execute([
    'endpoint_id'
        => $endpointId,
]);

echo 'TOTAL_DELIVERIES=',
    $count->fetchColumn(),
    PHP_EOL;

$historical =
    $pdo->prepare(
        <<<'SQL'
SELECT COUNT(*)
FROM webhook_delivery
WHERE webhook_endpoint_id = :endpoint_id
  AND outbound_message_event_id = :event_id
SQL
    );

$historical->execute([
    'endpoint_id'
        => $endpointId,
    'event_id'
        => getenv(
            'HISTORICAL_EVENT_ID',
        ),
]);

echo 'HISTORICAL_DELIVERIES=',
    $historical->fetchColumn(),
    PHP_EOL;

$new =
    $pdo->prepare(
        <<<'SQL'
SELECT
    id,
    public_id,
    status,
    attempt_count,
    queued_at
FROM webhook_delivery
WHERE webhook_endpoint_id = :endpoint_id
  AND outbound_message_event_id = :event_id
SQL
    );

$new->execute([
    'endpoint_id'
        => $endpointId,
    'event_id'
        => getenv(
            'NEW_EVENT_ID',
        ),
]);

$row =
    $new->fetch(
        PDO::FETCH_ASSOC,
    );

if (!is_array($row)) {
    echo 'NEW_DELIVERIES=0',
        PHP_EOL;

    exit(0);
}

echo 'NEW_DELIVERIES=1',
    PHP_EOL;

echo 'DELIVERY_ID=',
    $row['id'],
    PHP_EOL;

echo 'DELIVERY_PUBLIC_ID=',
    $row['public_id'],
    PHP_EOL;

echo 'STATUS=',
    $row['status'],
    PHP_EOL;

echo 'ATTEMPTS=',
    $row['attempt_count'],
    PHP_EOL;

echo 'QUEUED=',
    $row['queued_at'] === null
        ? '0'
        : '1',
    PHP_EOL;

$jobs =
    $pdo->query(
        <<<'SQL'
SELECT id, body
FROM messenger_messages
WHERE queue_name = 'webhook_delivery'
ORDER BY id ASC
SQL
    );

$jobCount = 0;

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
        is_array($body)
        && isset(
            $body[
                'webhookDeliveryId'
            ],
        )
        && (int) $body[
            'webhookDeliveryId'
        ] === (int) $row['id']
    ) {
        ++$jobCount;
    }
}

echo 'MESSENGER_JOBS=',
    $jobCount,
    PHP_EOL;
PHP
)"

printf '%s\n' "$STATE"

grep -Fxq \
    'TOTAL_DELIVERIES=1' \
    <<<"$STATE" \
    || fail "unexpected webhook delivery count"

grep -Fxq \
    'HISTORICAL_DELIVERIES=0' \
    <<<"$STATE" \
    || fail "historical event generated a webhook"

grep -Fxq \
    'NEW_DELIVERIES=1' \
    <<<"$STATE" \
    || fail "new event did not create a webhook delivery"

grep -Eq \
    '^DELIVERY_PUBLIC_ID=whd_[a-f0-9]{32}$' \
    <<<"$STATE" \
    || fail "invalid webhook delivery public ID"

grep -Fxq \
    'STATUS=pending' \
    <<<"$STATE" \
    || fail "new webhook delivery is not pending"

grep -Fxq \
    'ATTEMPTS=0' \
    <<<"$STATE" \
    || fail "outbox changed attempt count before HTTP delivery"

grep -Fxq \
    'QUEUED=1' \
    <<<"$STATE" \
    || fail "webhook delivery was not marked queued"

grep -Fxq \
    'MESSENGER_JOBS=1' \
    <<<"$STATE" \
    || fail "webhook delivery does not have exactly one Messenger job"

pass "new event creates exactly one queued webhook job"
pass "historical event is excluded by registration watermark"

# ---------------------------------------------------------------------------
# Second pass must be idempotent.
# ---------------------------------------------------------------------------

SECOND_PASS="$(
    docker compose run \
        --rm \
        --no-deps \
        -T \
        webhook-outbox \
        php \
        bin/console \
        app:webhook-outbox \
        --once \
        --batch=50 \
        </dev/null
)"

SECOND_STATE="$(
    docker compose exec \
        -T \
        -e WEBHOOK_ID="$WEBHOOK_ID" \
        -e NEW_EVENT_ID="$NEW_EVENT_ID" \
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
SELECT wd.id
FROM webhook_delivery wd
INNER JOIN webhook_endpoint we
    ON we.id = wd.webhook_endpoint_id
WHERE we.public_id = :public_id
  AND wd.outbound_message_event_id = :event_id
SQL
    );

$stmt->execute([
    'public_id'
        => getenv('WEBHOOK_ID'),
    'event_id'
        => getenv('NEW_EVENT_ID'),
]);

$deliveryIds =
    array_map(
        'intval',
        $stmt->fetchAll(
            PDO::FETCH_COLUMN,
        ),
    );

echo 'DELIVERIES=',
    count(
        $deliveryIds,
    ),
    PHP_EOL;

$jobs =
    $pdo->query(
        <<<'SQL'
SELECT body
FROM messenger_messages
WHERE queue_name = 'webhook_delivery'
SQL
    );

$jobCount = 0;

foreach (
    $jobs->fetchAll(
        PDO::FETCH_COLUMN,
    )
    as $body
) {
    $decoded =
        json_decode(
            (string) $body,
            true,
        );

    if (
        is_array($decoded)
        && isset(
            $decoded[
                'webhookDeliveryId'
            ],
        )
        && in_array(
            (int) $decoded[
                'webhookDeliveryId'
            ],
            $deliveryIds,
            true,
        )
    ) {
        ++$jobCount;
    }
}

echo 'JOBS=',
    $jobCount,
    PHP_EOL;
PHP
)"

printf '%s\n' "$SECOND_STATE"

grep -Fxq \
    'DELIVERIES=1' \
    <<<"$SECOND_STATE" \
    || fail "second outbox pass duplicated webhook delivery"

grep -Fxq \
    'JOBS=1' \
    <<<"$SECOND_STATE" \
    || fail "second outbox pass duplicated Messenger job"

pass "second outbox pass is idempotent"

echo
echo "WEBHOOK_ID=$WEBHOOK_ID"
echo "HISTORICAL_EVENT_ID=$HISTORICAL_EVENT_ID"
echo "NEW_EVENT_ID=$NEW_EVENT_ID"
echo
echo "ALL WEBHOOK OUTBOX E2E TESTS PASSED"
