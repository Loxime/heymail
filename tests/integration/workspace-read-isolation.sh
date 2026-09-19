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
        /tmp/heymail-workspace-read-isolation.XXXXXX
)"

AUTH_CONFIG="$TMP_DIR/auth.conf"

TOKEN="$(
    python3 - <<'PY'
import secrets
print(secrets.token_hex(12))
PY
)"

WORKSPACE_NAME="HeyMail 3B Hostile $TOKEN"
FOREIGN_DOMAIN="foreign-$TOKEN.test"
FOREIGN_SENDER="sender@$FOREIGN_DOMAIN"
FOREIGN_WEBHOOK_ID="$(
    python3 - "$TOKEN" <<'PY'
import hashlib
import sys

print(
    "wh_"
    + hashlib.sha256(
        ("foreign-webhook:" + sys.argv[1]).encode()
    ).hexdigest()[:32]
)
PY
)"

LEGACY_WEBHOOK_ID=""

OUTBOX_WAS_RUNNING=0
WEBHOOK_WORKER_WAS_RUNNING=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

service_running() {
    local service="$1"
    local container

    container="$(
        docker compose ps \
            -q \
            "$service"
    )"

    [ -n "$container" ] || return 1

    [ "$(
        docker inspect \
            --format '{{.State.Running}}' \
            "$container"
    )" = "true" ]
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

authenticated_request() {
    local method="$1"
    local url="$2"
    local headers="$3"
    local body="$4"

    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --config "$AUTH_CONFIG" \
        --request "$method" \
        --dump-header "$headers" \
        --output "$body" \
        "$url"
}

cleanup() {
    local result=$?

    trap - EXIT
    set +e

    docker compose exec \
        -T \
        -e TOKEN="$TOKEN" \
        -e WORKSPACE_NAME="$WORKSPACE_NAME" \
        -e FOREIGN_DOMAIN="$FOREIGN_DOMAIN" \
        -e FOREIGN_SENDER="$FOREIGN_SENDER" \
        -e FOREIGN_WEBHOOK_ID="$FOREIGN_WEBHOOK_ID" \
        -e LEGACY_WEBHOOK_ID="${LEGACY_WEBHOOK_ID:-}" \
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

$token =
    (string) getenv('TOKEN');

$publicIds =
    array_values(
        array_filter(
            [
                getenv('LEGACY_WEBHOOK_ID'),
                getenv('FOREIGN_WEBHOOK_ID'),
            ],
            static fn (
                mixed $value,
            ): bool =>
                is_string($value)
                && $value !== '',
        ),
    );

$pdo->beginTransaction();

try {
    $deliveryIds = [];

    if ($publicIds !== []) {
        $placeholders =
            implode(
                ',',
                array_fill(
                    0,
                    count($publicIds),
                    '?',
                ),
            );

        $stmt =
            $pdo->prepare(
                sprintf(
                    <<<'SQL'
SELECT wd.id
FROM webhook_delivery wd
INNER JOIN webhook_endpoint we
    ON we.id = wd.webhook_endpoint_id
WHERE we.public_id IN (%s)
SQL,
                    $placeholders,
                ),
            );

        $stmt->execute(
            $publicIds,
        );

        $deliveryIds =
            array_map(
                'intval',
                $stmt->fetchAll(
                    PDO::FETCH_COLUMN,
                ),
            );
    }

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
                'DELETE FROM messenger_messages WHERE id = :id',
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
                is_array($body)
                && isset(
                    $body['webhookDeliveryId'],
                )
                && in_array(
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

    if ($publicIds !== []) {
        $placeholders =
            implode(
                ',',
                array_fill(
                    0,
                    count($publicIds),
                    '?',
                ),
            );

        $deleteDeliveries =
            $pdo->prepare(
                sprintf(
                    <<<'SQL'
DELETE FROM webhook_delivery
WHERE webhook_endpoint_id IN (
    SELECT id
    FROM webhook_endpoint
    WHERE public_id IN (%s)
)
SQL,
                    $placeholders,
                ),
            );

        $deleteDeliveries->execute(
            $publicIds,
        );

        $deleteEndpoints =
            $pdo->prepare(
                sprintf(
                    'DELETE FROM webhook_endpoint WHERE public_id IN (%s)',
                    $placeholders,
                ),
            );

        $deleteEndpoints->execute(
            $publicIds,
        );
    }

    $deleteSender =
        $pdo->prepare(
            'DELETE FROM sender_identity WHERE email = :email',
        );

    $deleteSender->execute([
        'email'
            => getenv('FOREIGN_SENDER'),
    ]);

    $deleteDomain =
        $pdo->prepare(
            'DELETE FROM sending_domain WHERE domain = :domain',
        );

    $deleteDomain->execute([
        'domain'
            => getenv('FOREIGN_DOMAIN'),
    ]);

    $hashes = [];

    foreach ([
        'legacy-message',
        'foreign-message',
        'nullable-message',
    ] as $suffix) {
        $hashes[] =
            hash(
                'sha256',
                $token
                    . ':'
                    . $suffix,
            );
    }

    $placeholders =
        implode(
            ',',
            array_fill(
                0,
                count($hashes),
                '?',
            ),
        );

    $deleteMessages =
        $pdo->prepare(
            sprintf(
                <<<'SQL'
DELETE FROM outbound_message
WHERE idempotency_key_hash IN (%s)
SQL,
                $placeholders,
            ),
        );

    $deleteMessages->execute(
        $hashes,
    );

    $deleteWorkspace =
        $pdo->prepare(
            'DELETE FROM workspace WHERE name = :name',
        );

    $deleteWorkspace->execute([
        'name'
            => getenv('WORKSPACE_NAME'),
    ]);

    $pdo->commit();
} catch (Throwable $exception) {
    if ($pdo->inTransaction()) {
        $pdo->rollBack();
    }
}
PHP

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

    exit "$result"
}

trap cleanup EXIT

echo "=== HeyMail workspace read/outbox isolation E2E ==="

docker compose up \
    -d \
    --wait \
    api \
    gateway \
    >/dev/null

if service_running webhook-outbox; then
    OUTBOX_WAS_RUNNING=1
fi

if service_running webhook-worker; then
    WEBHOOK_WORKER_WAS_RUNNING=1
fi

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

# ---------------------------------------------------------------------------
# Register one real legacy endpoint before the hostile events exist.
# ---------------------------------------------------------------------------

CREATE_HEADERS="$TMP_DIR/webhook-create.headers"
CREATE_BODY="$TMP_DIR/webhook-create.body"
CREATE_JSON="$TMP_DIR/webhook-create.json"

python3 \
    - "$CREATE_JSON" "$TOKEN" <<'PY'
import json
import sys

path, token = sys.argv[1:]

with open(
    path,
    "w",
    encoding="utf-8",
) as handle:
    json.dump(
        {
            "url":
                f"https://hooks.example.test/"
                f"workspace-isolation/{token}",
            "events": ["delivered"],
        },
        handle,
        separators=(",", ":"),
    )
PY

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
    --data-binary "@$CREATE_JSON" \
    "$API_ORIGIN/api/v1/webhooks"

[ "$(http_code "$CREATE_HEADERS")" = "201" ] \
    || fail "legacy webhook fixture did not return 201"

LEGACY_WEBHOOK_ID="$(
    python3 \
        - "$CREATE_BODY" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    print(
        json.load(handle)["webhookId"]
    )
PY
)"

[[ "$LEGACY_WEBHOOK_ID" =~ ^wh_[a-f0-9]{32}$ ]] \
    || fail "invalid legacy webhook fixture ID"

pass "created legacy webhook control fixture"

# ---------------------------------------------------------------------------
# Seed a foreign workspace and resources, plus explicit and NULL legacy
# messages. Both endpoints exist before the delivery events, so outbox
# pairing is a real 2x2 workspace matrix.
# ---------------------------------------------------------------------------

FIXTURE="$(
    docker compose exec \
        -T \
        -e TOKEN="$TOKEN" \
        -e WORKSPACE_NAME="$WORKSPACE_NAME" \
        -e FOREIGN_DOMAIN="$FOREIGN_DOMAIN" \
        -e FOREIGN_SENDER="$FOREIGN_SENDER" \
        -e FOREIGN_WEBHOOK_ID="$FOREIGN_WEBHOOK_ID" \
        -e LEGACY_WEBHOOK_ID="$LEGACY_WEBHOOK_ID" \
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

$token =
    (string) getenv('TOKEN');

$pdo->beginTransaction();

try {
    $legacyIds =
        $pdo->query(
            <<<'SQL'
SELECT id
FROM workspace
WHERE name = 'HeyMail Legacy Workspace'
ORDER BY id ASC
LIMIT 2
SQL
        )
        ->fetchAll(
            PDO::FETCH_COLUMN,
        );

    if (count($legacyIds) !== 1) {
        throw new RuntimeException(
            'Expected exactly one legacy workspace.',
        );
    }

    $legacyWorkspaceId =
        (int) $legacyIds[0];

    $workspace =
        $pdo->prepare(
            <<<'SQL'
INSERT INTO workspace (
    name,
    created_at
)
VALUES (
    :name,
    timezone('UTC', CURRENT_TIMESTAMP)
)
RETURNING id
SQL
        );

    $workspace->execute([
        'name'
            => getenv('WORKSPACE_NAME'),
    ]);

    $foreignWorkspaceId =
        (int) $workspace
            ->fetchColumn();

    $domain =
        $pdo->prepare(
            <<<'SQL'
INSERT INTO sending_domain (
    workspace_id,
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
    :workspace_id,
    :domain,
    'verified',
    :verification_token,
    timezone('UTC', CURRENT_TIMESTAMP),
    timezone('UTC', CURRENT_TIMESTAMP),
    timezone('UTC', CURRENT_TIMESTAMP),
    NULL,
    'hm1',
    'QUJD',
    timezone('UTC', CURRENT_TIMESTAMP)
)
RETURNING id
SQL
        );

    $domain->execute([
        'workspace_id'
            => $foreignWorkspaceId,
        'domain'
            => getenv('FOREIGN_DOMAIN'),
        'verification_token'
            => hash(
                'sha256',
                $token
                    . ':foreign-domain',
            ),
    ]);

    $foreignDomainId =
        (int) $domain
            ->fetchColumn();

    $sender =
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
    timezone('UTC', CURRENT_TIMESTAMP)
)
RETURNING id
SQL
        );

    $sender->execute([
        'domain_id'
            => $foreignDomainId,
        'email'
            => getenv('FOREIGN_SENDER'),
    ]);

    $foreignSenderId =
        (int) $sender
            ->fetchColumn();

    $watermark =
        (int) $pdo
            ->query(
                <<<'SQL'
SELECT COALESCE(MAX(id), 0)
FROM outbound_message_event
SQL
            )
            ->fetchColumn();

    $foreignEndpoint =
        $pdo->prepare(
            <<<'SQL'
INSERT INTO webhook_endpoint (
    workspace_id,
    public_id,
    url,
    enabled,
    starts_after_event_id,
    secret_ciphertext,
    secret_nonce,
    secret_algorithm,
    secret_key_version,
    created_at
)
VALUES (
    :workspace_id,
    :public_id,
    :url,
    TRUE,
    :watermark,
    'fixture-ciphertext',
    'fixture-nonce',
    'fixture-algorithm',
    1,
    timezone('UTC', CURRENT_TIMESTAMP)
)
RETURNING id
SQL
        );

    $foreignEndpoint->execute([
        'workspace_id'
            => $foreignWorkspaceId,
        'public_id'
            => getenv('FOREIGN_WEBHOOK_ID'),
        'url'
            => 'https://foreign.example.test/'
                . $token,
        'watermark'
            => $watermark,
    ]);

    $foreignEndpointId =
        (int) $foreignEndpoint
            ->fetchColumn();

    $subscription =
        $pdo->prepare(
            <<<'SQL'
INSERT INTO webhook_endpoint_subscription (
    webhook_endpoint_id,
    event_type
)
VALUES (
    :endpoint_id,
    'delivered'
)
SQL
        );

    $subscription->execute([
        'endpoint_id'
            => $foreignEndpointId,
    ]);

    $legacyEndpoint =
        $pdo->prepare(
            <<<'SQL'
SELECT id
FROM webhook_endpoint
WHERE public_id = :public_id
SQL
        );

    $legacyEndpoint->execute([
        'public_id'
            => getenv('LEGACY_WEBHOOK_ID'),
    ]);

    $legacyEndpointId =
        (int) $legacyEndpoint
            ->fetchColumn();

    if ($legacyEndpointId < 1) {
        throw new RuntimeException(
            'Legacy endpoint fixture missing.',
        );
    }

    $insertMessage =
        $pdo->prepare(
            <<<'SQL'
INSERT INTO outbound_message (
    workspace_id,
    idempotency_key_hash,
    status,
    created_at,
    ready_for_submission_at,
    submitting_at,
    submission_uncertain_at,
    submitted_at
)
VALUES (
    :workspace_id,
    :hash,
    :status,
    :created_at,
    :ready_at,
    :submitting_at,
    NULL,
    :submitted_at
)
RETURNING id
SQL
        );

    $insertEvent =
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
    :occurred_at,
    :recipient_hash,
    :smtp_status,
    :detail,
    :source_event_id
)
RETURNING id
SQL
        );

    $insertSubmittedMessage =
        static function (
            PDOStatement $insertMessage,
            PDOStatement $insertEvent,
            ?int $workspaceId,
            string $hash,
            string $createdAt,
            string $sourcePrefix,
        ): array {
            $insertMessage->execute([
                'workspace_id'
                    => $workspaceId,
                'hash'
                    => $hash,
                'status'
                    => 'submitted',
                'created_at'
                    => $createdAt,
                'ready_at'
                    => $createdAt,
                'submitting_at'
                    => $createdAt,
                'submitted_at'
                    => $createdAt,
            ]);

            $messageId =
                (int) $insertMessage
                    ->fetchColumn();

            $insertEvent->execute([
                'message_id'
                    => $messageId,
                'event_type'
                    => 'submitted',
                'occurred_at'
                    => $createdAt,
                'recipient_hash'
                    => null,
                'smtp_status'
                    => null,
                'detail'
                    => null,
                'source_event_id'
                    => null,
            ]);

            $insertEvent->execute([
                'message_id'
                    => $messageId,
                'event_type'
                    => 'delivered',
                'occurred_at'
                    => $createdAt,
                'recipient_hash'
                    => hash(
                        'sha256',
                        $sourcePrefix
                            . '@example.test',
                    ),
                'smtp_status'
                    => '2.0.0',
                'detail'
                    => 'workspace isolation fixture',
                'source_event_id'
                    => hash(
                        'sha256',
                        $sourcePrefix
                            . ':delivered',
                    ),
            ]);

            $eventId =
                (int) $insertEvent
                    ->fetchColumn();

            return [
                $messageId,
                $eventId,
            ];
        };

    [
        $legacyMessageId,
        $legacyEventId,
    ] =
        $insertSubmittedMessage(
            $insertMessage,
            $insertEvent,
            $legacyWorkspaceId,
            hash(
                'sha256',
                $token
                    . ':legacy-message',
            ),
            '2099-07-10 10:00:00',
            $token
                . ':legacy',
        );

    [
        $foreignMessageId,
        $foreignEventId,
    ] =
        $insertSubmittedMessage(
            $insertMessage,
            $insertEvent,
            $foreignWorkspaceId,
            hash(
                'sha256',
                $token
                    . ':foreign-message',
            ),
            '2099-07-10 11:00:00',
            $token
                . ':foreign',
        );

    $insertMessage->execute([
        'workspace_id'
            => null,
        'hash'
            => hash(
                'sha256',
                $token
                    . ':nullable-message',
            ),
        'status'
            => 'queued',
        'created_at'
            => '2099-07-11 10:00:00',
        'ready_at'
            => null,
        'submitting_at'
            => null,
        'submitted_at'
            => null,
    ]);

    $nullableMessageId =
        (int) $insertMessage
            ->fetchColumn();

    $insertEvent->execute([
        'message_id'
            => $nullableMessageId,
        'event_type'
            => 'queued',
        'occurred_at'
            => '2099-07-11 10:00:00',
        'recipient_hash'
            => null,
        'smtp_status'
            => null,
        'detail'
            => null,
        'source_event_id'
            => null,
    ]);

    $pdo->commit();

    foreach ([
        'LEGACY_WORKSPACE_ID'
            => $legacyWorkspaceId,
        'FOREIGN_WORKSPACE_ID'
            => $foreignWorkspaceId,
        'FOREIGN_DOMAIN_ID'
            => $foreignDomainId,
        'FOREIGN_SENDER_ID'
            => $foreignSenderId,
        'LEGACY_ENDPOINT_ID'
            => $legacyEndpointId,
        'FOREIGN_ENDPOINT_ID'
            => $foreignEndpointId,
        'LEGACY_MESSAGE_ID'
            => $legacyMessageId,
        'FOREIGN_MESSAGE_ID'
            => $foreignMessageId,
        'NULLABLE_MESSAGE_ID'
            => $nullableMessageId,
        'LEGACY_EVENT_ID'
            => $legacyEventId,
        'FOREIGN_EVENT_ID'
            => $foreignEventId,
    ] as $name => $value) {
        echo $name,
            '=',
            $value,
            PHP_EOL;
    }
} catch (Throwable $exception) {
    if ($pdo->inTransaction()) {
        $pdo->rollBack();
    }

    throw $exception;
}
PHP
)"

printf '%s\n' "$FIXTURE"

value_from_fixture() {
    local name="$1"

    awk \
        -F= \
        -v name="$name" \
        '$1 == name { print $2 }' \
        <<<"$FIXTURE"
}

FOREIGN_DOMAIN_ID="$(
    value_from_fixture \
        FOREIGN_DOMAIN_ID
)"
FOREIGN_SENDER_ID="$(
    value_from_fixture \
        FOREIGN_SENDER_ID
)"
LEGACY_ENDPOINT_ID="$(
    value_from_fixture \
        LEGACY_ENDPOINT_ID
)"
FOREIGN_ENDPOINT_ID="$(
    value_from_fixture \
        FOREIGN_ENDPOINT_ID
)"
LEGACY_MESSAGE_ID="$(
    value_from_fixture \
        LEGACY_MESSAGE_ID
)"
FOREIGN_MESSAGE_ID="$(
    value_from_fixture \
        FOREIGN_MESSAGE_ID
)"
NULLABLE_MESSAGE_ID="$(
    value_from_fixture \
        NULLABLE_MESSAGE_ID
)"
LEGACY_EVENT_ID="$(
    value_from_fixture \
        LEGACY_EVENT_ID
)"
FOREIGN_EVENT_ID="$(
    value_from_fixture \
        FOREIGN_EVENT_ID
)"

for value in \
    "$FOREIGN_DOMAIN_ID" \
    "$FOREIGN_SENDER_ID" \
    "$LEGACY_ENDPOINT_ID" \
    "$FOREIGN_ENDPOINT_ID" \
    "$LEGACY_MESSAGE_ID" \
    "$FOREIGN_MESSAGE_ID" \
    "$NULLABLE_MESSAGE_ID" \
    "$LEGACY_EVENT_ID" \
    "$FOREIGN_EVENT_ID"
do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] \
        || fail "invalid hostile fixture identifier"
done

pass "seeded explicit legacy, nullable legacy-compatible and foreign resources"

# ---------------------------------------------------------------------------
# Message list and detail isolation.
# ---------------------------------------------------------------------------

MESSAGE_LIST_HEADERS="$TMP_DIR/messages.headers"
MESSAGE_LIST_BODY="$TMP_DIR/messages.body"

authenticated_request \
    GET \
    "$API_ORIGIN/api/v1/messages?limit=100&createdAfter=2099-07-10T00:00:00Z&createdBefore=2099-07-12T00:00:00Z" \
    "$MESSAGE_LIST_HEADERS" \
    "$MESSAGE_LIST_BODY"

[ "$(http_code "$MESSAGE_LIST_HEADERS")" = "200" ] \
    || fail "message list did not return 200"

python3 \
    - "$MESSAGE_LIST_BODY" \
    "$LEGACY_MESSAGE_ID" \
    "$NULLABLE_MESSAGE_ID" \
    "$FOREIGN_MESSAGE_ID" <<'PY'
import json
import sys

path, legacy_id, nullable_id, foreign_id = sys.argv[1:]

with open(
    path,
    encoding="utf-8",
) as handle:
    payload = json.load(handle)

ids = {
    str(item["messageId"])
    for item in payload["items"]
}

if legacy_id not in ids:
    raise SystemExit(
        "explicit legacy message missing"
    )

if nullable_id not in ids:
    raise SystemExit(
        "NULL legacy-compatible message missing"
    )

if foreign_id in ids:
    raise SystemExit(
        "foreign message leaked in list"
    )
PY

pass "message list hides foreign workspace and preserves NULL legacy compatibility"

FOREIGN_MESSAGE_HEADERS="$TMP_DIR/foreign-message.headers"
FOREIGN_MESSAGE_BODY="$TMP_DIR/foreign-message.body"

authenticated_request \
    GET \
    "$API_ORIGIN/api/v1/messages/$FOREIGN_MESSAGE_ID" \
    "$FOREIGN_MESSAGE_HEADERS" \
    "$FOREIGN_MESSAGE_BODY"

[ "$(http_code "$FOREIGN_MESSAGE_HEADERS")" = "404" ] \
    || fail "foreign message detail is visible"

NULLABLE_MESSAGE_HEADERS="$TMP_DIR/nullable-message.headers"
NULLABLE_MESSAGE_BODY="$TMP_DIR/nullable-message.body"

authenticated_request \
    GET \
    "$API_ORIGIN/api/v1/messages/$NULLABLE_MESSAGE_ID" \
    "$NULLABLE_MESSAGE_HEADERS" \
    "$NULLABLE_MESSAGE_BODY"

[ "$(http_code "$NULLABLE_MESSAGE_HEADERS")" = "200" ] \
    || fail "NULL legacy-compatible message is not readable"

pass "message detail fails closed for foreign workspace"

# ---------------------------------------------------------------------------
# Domain list/detail/mutation isolation.
# ---------------------------------------------------------------------------

DOMAIN_LIST_HEADERS="$TMP_DIR/domains.headers"
DOMAIN_LIST_BODY="$TMP_DIR/domains.body"

authenticated_request \
    GET \
    "$API_ORIGIN/api/v1/domains" \
    "$DOMAIN_LIST_HEADERS" \
    "$DOMAIN_LIST_BODY"

[ "$(http_code "$DOMAIN_LIST_HEADERS")" = "200" ] \
    || fail "domain list did not return 200"

if grep -Fq \
    "$FOREIGN_DOMAIN" \
    "$DOMAIN_LIST_BODY"
then
    fail "foreign domain leaked in list"
fi

for suffix in \
    "" \
    "/verify" \
    "/dkim/provision"
do
    method="GET"

    if [ -n "$suffix" ]; then
        method="POST"
    fi

    headers="$TMP_DIR/domain-$(
        printf '%s' "$suffix" \
            | tr '/ ' '__'
    ).headers"

    body="$TMP_DIR/domain-$(
        printf '%s' "$suffix" \
            | tr '/ ' '__'
    ).body"

    authenticated_request \
        "$method" \
        "$API_ORIGIN/api/v1/domains/$FOREIGN_DOMAIN_ID$suffix" \
        "$headers" \
        "$body"

    [ "$(http_code "$headers")" = "404" ] \
        || fail "foreign domain route leaked for suffix '$suffix'"
done

pass "domain reads and mutation entry points hide foreign workspace"

# ---------------------------------------------------------------------------
# Sender list/detail isolation.
# ---------------------------------------------------------------------------

SENDER_LIST_HEADERS="$TMP_DIR/senders.headers"
SENDER_LIST_BODY="$TMP_DIR/senders.body"

authenticated_request \
    GET \
    "$API_ORIGIN/api/v1/senders" \
    "$SENDER_LIST_HEADERS" \
    "$SENDER_LIST_BODY"

[ "$(http_code "$SENDER_LIST_HEADERS")" = "200" ] \
    || fail "sender list did not return 200"

if grep -Fq \
    "$FOREIGN_SENDER" \
    "$SENDER_LIST_BODY"
then
    fail "foreign sender leaked in list"
fi

FOREIGN_SENDER_HEADERS="$TMP_DIR/foreign-sender.headers"
FOREIGN_SENDER_BODY="$TMP_DIR/foreign-sender.body"

authenticated_request \
    GET \
    "$API_ORIGIN/api/v1/senders/$FOREIGN_SENDER_ID" \
    "$FOREIGN_SENDER_HEADERS" \
    "$FOREIGN_SENDER_BODY"

[ "$(http_code "$FOREIGN_SENDER_HEADERS")" = "404" ] \
    || fail "foreign sender detail is visible"

pass "sender reads derive workspace isolation from sending domain"

# ---------------------------------------------------------------------------
# Webhook registry read isolation.
# ---------------------------------------------------------------------------

WEBHOOK_LIST_HEADERS="$TMP_DIR/webhooks.headers"
WEBHOOK_LIST_BODY="$TMP_DIR/webhooks.body"

authenticated_request \
    GET \
    "$API_ORIGIN/api/v1/webhooks" \
    "$WEBHOOK_LIST_HEADERS" \
    "$WEBHOOK_LIST_BODY"

[ "$(http_code "$WEBHOOK_LIST_HEADERS")" = "200" ] \
    || fail "webhook list did not return 200"

python3 \
    - "$WEBHOOK_LIST_BODY" \
    "$LEGACY_WEBHOOK_ID" \
    "$FOREIGN_WEBHOOK_ID" <<'PY'
import json
import sys

path, legacy_id, foreign_id = sys.argv[1:]

with open(
    path,
    encoding="utf-8",
) as handle:
    payload = json.load(handle)

ids = {
    item["webhookId"]
    for item in payload["items"]
}

if legacy_id not in ids:
    raise SystemExit(
        "legacy webhook control missing"
    )

if foreign_id in ids:
    raise SystemExit(
        "foreign webhook leaked in list"
    )
PY

pass "webhook registry hides foreign endpoint"

# ---------------------------------------------------------------------------
# Dashboard must aggregate explicit + nullable legacy only.
# Foreign message/event must not inflate any metric.
# ---------------------------------------------------------------------------

DASH_HEADERS="$TMP_DIR/dashboard.headers"
DASH_BODY="$TMP_DIR/dashboard.body"

authenticated_request \
    GET \
    "$API_ORIGIN/api/v1/dashboard?from=2099-07-10T00:00:00Z&to=2099-07-12T00:00:00Z" \
    "$DASH_HEADERS" \
    "$DASH_BODY"

[ "$(http_code "$DASH_HEADERS")" = "200" ] \
    || fail "dashboard did not return 200"

python3 \
    - "$DASH_BODY" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    payload = json.load(handle)

messages = payload["messages"]

expected_messages = {
    "total": 2,
    "queued": 1,
    "readyForSubmission": 0,
    "submitting": 0,
    "submissionUncertain": 0,
    "submitted": 1,
}

if messages != expected_messages:
    raise SystemExit(
        f"unexpected scoped message totals: {messages!r}"
    )

delivery = payload["delivery"]

if delivery["delivered"] != 1:
    raise SystemExit(
        "foreign delivered event leaked into dashboard"
    )

if delivery["tempfail"] != 0:
    raise SystemExit(
        "unexpected tempfail metric"
    )

if delivery["bounced"] != 0:
    raise SystemExit(
        "unexpected bounced metric"
    )

if delivery["terminalOutcomes"] != 1:
    raise SystemExit(
        "unexpected terminal outcome count"
    )

if delivery["deliveryRate"] != 1:
    raise SystemExit(
        "unexpected delivery rate"
    )

if delivery["bounceRate"] != 0:
    raise SystemExit(
        "unexpected bounce rate"
    )

activity = payload["activity"]

if activity != [
    {
        "date": "2099-07-10",
        "submitted": 1,
        "tempfail": 0,
        "delivered": 1,
        "bounced": 0,
    },
    {
        "date": "2099-07-11",
        "submitted": 0,
        "tempfail": 0,
        "delivered": 0,
        "bounced": 0,
    },
]:
    raise SystemExit(
        f"unexpected scoped activity: {activity!r}"
    )
PY

pass "dashboard aggregates only effective legacy workspace"

# ---------------------------------------------------------------------------
# Outbox matrix:
#
# legacy endpoint  -> legacy event  = 1
# legacy endpoint  -> foreign event = 0
# foreign endpoint -> legacy event  = 0
# foreign endpoint -> foreign event = 1
#
# This proves system workers can process every workspace without crossing
# tenant boundaries.
# ---------------------------------------------------------------------------

docker compose run \
    --rm \
    -T \
    webhook-outbox \
    php \
    bin/console \
    app:webhook-outbox \
    --once \
    --batch=50 \
    </dev/null \
    >/dev/null

MATRIX="$(
    docker compose exec \
        -T \
        -e LEGACY_ENDPOINT_ID="$LEGACY_ENDPOINT_ID" \
        -e FOREIGN_ENDPOINT_ID="$FOREIGN_ENDPOINT_ID" \
        -e LEGACY_EVENT_ID="$LEGACY_EVENT_ID" \
        -e FOREIGN_EVENT_ID="$FOREIGN_EVENT_ID" \
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

$count =
    $pdo->prepare(
        <<<'SQL'
SELECT COUNT(*)
FROM webhook_delivery
WHERE webhook_endpoint_id = :endpoint_id
  AND outbound_message_event_id = :event_id
SQL
    );

$pairs = [
    'LL' => [
        getenv('LEGACY_ENDPOINT_ID'),
        getenv('LEGACY_EVENT_ID'),
    ],
    'LF' => [
        getenv('LEGACY_ENDPOINT_ID'),
        getenv('FOREIGN_EVENT_ID'),
    ],
    'FL' => [
        getenv('FOREIGN_ENDPOINT_ID'),
        getenv('LEGACY_EVENT_ID'),
    ],
    'FF' => [
        getenv('FOREIGN_ENDPOINT_ID'),
        getenv('FOREIGN_EVENT_ID'),
    ],
];

foreach ($pairs as $name => [$endpointId, $eventId]) {
    $count->execute([
        'endpoint_id'
            => $endpointId,
        'event_id'
            => $eventId,
    ]);

    echo $name,
        '=',
        $count->fetchColumn(),
        PHP_EOL;
}
PHP
)"

printf '%s\n' "$MATRIX"

grep -Fxq 'LL=1' <<<"$MATRIX" \
    || fail "legacy endpoint did not receive legacy event"

grep -Fxq 'LF=0' <<<"$MATRIX" \
    || fail "legacy endpoint crossed into foreign event"

grep -Fxq 'FL=0' <<<"$MATRIX" \
    || fail "foreign endpoint crossed into legacy event"

grep -Fxq 'FF=1' <<<"$MATRIX" \
    || fail "foreign same-workspace outbox pair was not materialized"

pass "webhook outbox materializes same-workspace pairs only"

# Second pass must preserve the exact matrix.
docker compose run \
    --rm \
    -T \
    webhook-outbox \
    php \
    bin/console \
    app:webhook-outbox \
    --once \
    --batch=50 \
    </dev/null \
    >/dev/null

SECOND_MATRIX="$(
    docker compose exec \
        -T \
        -e LEGACY_ENDPOINT_ID="$LEGACY_ENDPOINT_ID" \
        -e FOREIGN_ENDPOINT_ID="$FOREIGN_ENDPOINT_ID" \
        -e LEGACY_EVENT_ID="$LEGACY_EVENT_ID" \
        -e FOREIGN_EVENT_ID="$FOREIGN_EVENT_ID" \
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

$count =
    $pdo->prepare(
        <<<'SQL'
SELECT COUNT(*)
FROM webhook_delivery
WHERE webhook_endpoint_id = :endpoint_id
  AND outbound_message_event_id = :event_id
SQL
    );

$pairs = [
    'LL' => [
        getenv('LEGACY_ENDPOINT_ID'),
        getenv('LEGACY_EVENT_ID'),
    ],
    'LF' => [
        getenv('LEGACY_ENDPOINT_ID'),
        getenv('FOREIGN_EVENT_ID'),
    ],
    'FL' => [
        getenv('FOREIGN_ENDPOINT_ID'),
        getenv('LEGACY_EVENT_ID'),
    ],
    'FF' => [
        getenv('FOREIGN_ENDPOINT_ID'),
        getenv('FOREIGN_EVENT_ID'),
    ],
];

foreach ($pairs as $name => [$endpointId, $eventId]) {
    $count->execute([
        'endpoint_id'
            => $endpointId,
        'event_id'
            => $eventId,
    ]);

    echo $name,
        '=',
        $count->fetchColumn(),
        PHP_EOL;
}
PHP
)"

[ "$SECOND_MATRIX" = "$MATRIX" ] \
    || fail "second outbox pass changed workspace isolation matrix"

pass "outbox workspace isolation is idempotent"

echo
echo "FOREIGN_DOMAIN_ID=$FOREIGN_DOMAIN_ID"
echo "FOREIGN_SENDER_ID=$FOREIGN_SENDER_ID"
echo "FOREIGN_MESSAGE_ID=$FOREIGN_MESSAGE_ID"
echo "NULLABLE_MESSAGE_ID=$NULLABLE_MESSAGE_ID"
echo "LEGACY_WEBHOOK_ID=$LEGACY_WEBHOOK_ID"
echo "FOREIGN_WEBHOOK_ID=$FOREIGN_WEBHOOK_ID"
echo
echo "ALL WORKSPACE READ/OUTBOX ISOLATION TESTS PASSED"
