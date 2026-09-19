#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
        && pwd
)"
cd "$ROOT_DIR"

API_ORIGIN="https://api.heymail.test:8443"
TMP_DIR="$(mktemp -d /tmp/heymail-workspace-write.XXXXXX)"
AUTH_CONFIG="$TMP_DIR/auth.conf"
TOKEN="$(openssl rand -hex 12)"

DOMAIN="write-${TOKEN}.example.test"
SENDER="sender-${TOKEN}@${DOMAIN}"
WEBHOOK_URL="https://example.test/heymail-${TOKEN}"
MESSAGE_ID=""
WEBHOOK_ID=""
DOMAIN_ID=""

cleanup() {
    RESULT=$?
    trap - EXIT
    set +e

    docker compose exec \
        -T \
        -e DOMAIN="$DOMAIN" \
        -e SENDER="$SENDER" \
        -e WEBHOOK_URL="$WEBHOOK_URL" \
        -e MESSAGE_ID="${MESSAGE_ID:-}" \
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
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ],
);

$messageId = getenv('MESSAGE_ID');

if (
    is_string($messageId)
    && preg_match('/^[1-9][0-9]*$/D', $messageId) === 1
) {
    $rows = $pdo->query(
        "SELECT id, body FROM messenger_messages WHERE queue_name IN ('outbound', 'failed')"
    )->fetchAll(PDO::FETCH_ASSOC);

    $deleteQueue = $pdo->prepare(
        'DELETE FROM messenger_messages WHERE id = :id'
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
            && (string) ($body['outboundMessageId'] ?? '') === $messageId
        ) {
            $deleteQueue->execute([
                'id' => $row['id'],
            ]);
        }
    }

    $stmt = $pdo->prepare(
        'DELETE FROM outbound_message WHERE id = :id'
    );
    $stmt->execute([
        'id' => $messageId,
    ]);
}

$stmt = $pdo->prepare(
    'DELETE FROM webhook_endpoint WHERE url = :url'
);
$stmt->execute([
    'url' => getenv('WEBHOOK_URL'),
]);

$stmt = $pdo->prepare(
    'DELETE FROM sender_identity WHERE email = :email'
);
$stmt->execute([
    'email' => getenv('SENDER'),
]);

$stmt = $pdo->prepare(
    'DELETE FROM sending_domain WHERE domain = :domain'
);
$stmt->execute([
    'domain' => getenv('DOMAIN'),
]);
PHP

    rm -rf "$TMP_DIR"
    exit "$RESULT"
}

trap cleanup EXIT

docker compose up \
    -d \
    --wait \
    api \
    gateway \
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

chmod 0600 "$AUTH_CONFIG"
unset AUTH_B64

legacy_workspace_id() {
    docker compose exec \
        -T \
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
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ],
);

$ids = $pdo->query(
    <<<'SQL'
SELECT id
FROM workspace
WHERE name = 'HeyMail Legacy Workspace'
ORDER BY id ASC
LIMIT 2
SQL
)->fetchAll(PDO::FETCH_COLUMN);

if (count($ids) !== 1) {
    exit(2);
}

echo $ids[0];
PHP
}

LEGACY_ID="$(legacy_workspace_id)"
[[ "$LEGACY_ID" =~ ^[1-9][0-9]*$ ]] \
    || {
        echo "FAIL: invalid legacy workspace id" >&2
        exit 1
    }

echo "LEGACY_WORKSPACE_ID=$LEGACY_ID"

DOMAIN_BODY="$TMP_DIR/domain.json"
printf '{"domain":"%s"}' "$DOMAIN" > "$DOMAIN_BODY"

DOMAIN_RESPONSE="$TMP_DIR/domain-response.json"
DOMAIN_HTTP="$(
    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --config "$AUTH_CONFIG" \
        --output "$DOMAIN_RESPONSE" \
        --write-out '%{http_code}' \
        --header 'Content-Type: application/json' \
        --data-binary "@$DOMAIN_BODY" \
        "$API_ORIGIN/api/v1/domains"
)"

[ "$DOMAIN_HTTP" = "201" ] \
    || {
        cat "$DOMAIN_RESPONSE" >&2
        echo "FAIL: domain creation returned HTTP $DOMAIN_HTTP" >&2
        exit 1
    }

DOMAIN_ID="$(
    python3 - "$DOMAIN_RESPONSE" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["id"])
PY
)"

docker compose exec \
    -T \
    -e DOMAIN="$DOMAIN" \
    -e SENDER="$SENDER" \
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
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ],
);

$domain = (string) getenv('DOMAIN');
$sender = (string) getenv('SENDER');
$now = gmdate('Y-m-d H:i:s');

$stmt = $pdo->prepare(
    <<<'SQL'
UPDATE sending_domain
SET
    status = 'verified',
    verification_checked_at = :now,
    verified_at = :now,
    dkim_selector = 'test',
    dkim_public_key = 'dGVzdA==',
    dkim_provisioned_at = :now
WHERE domain = :domain
SQL
);
$stmt->execute([
    'now' => $now,
    'domain' => $domain,
]);

$domainId = $pdo->prepare(
    'SELECT id FROM sending_domain WHERE domain = :domain'
);
$domainId->execute([
    'domain' => $domain,
]);
$id = $domainId->fetchColumn();

$stmt = $pdo->prepare(
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
$stmt->execute([
    'domain_id' => $id,
    'email' => $sender,
    'created_at' => $now,
]);
PHP

WEBHOOK_BODY="$TMP_DIR/webhook.json"
python3 - "$WEBHOOK_URL" > "$WEBHOOK_BODY" <<'PY'
import json
import sys
print(json.dumps({
    "url": sys.argv[1],
    "events": ["delivered"],
}, separators=(",", ":")))
PY

WEBHOOK_RESPONSE="$TMP_DIR/webhook-response.json"
WEBHOOK_HTTP="$(
    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --config "$AUTH_CONFIG" \
        --output "$WEBHOOK_RESPONSE" \
        --write-out '%{http_code}' \
        --header 'Content-Type: application/json' \
        --data-binary "@$WEBHOOK_BODY" \
        "$API_ORIGIN/api/v1/webhooks"
)"

[ "$WEBHOOK_HTTP" = "201" ] \
    || {
        cat "$WEBHOOK_RESPONSE" >&2
        echo "FAIL: webhook creation returned HTTP $WEBHOOK_HTTP" >&2
        exit 1
    }

WEBHOOK_ID="$(
    python3 - "$WEBHOOK_RESPONSE" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["webhookId"])
PY
)"

SEND_BODY="$TMP_DIR/send.json"
python3 - "$SENDER" "$TOKEN" > "$SEND_BODY" <<'PY'
import json
import sys
print(json.dumps({
    "from": {
        "email": sys.argv[1],
        "name": "Workspace gate",
    },
    "to": [
        {
            "email": f"recipient-{sys.argv[2]}@success.test",
        },
    ],
    "subject": f"Workspace write gate {sys.argv[2]}",
    "text": f"workspace-write-{sys.argv[2]}",
}, separators=(",", ":")))
PY

SEND_RESPONSE="$TMP_DIR/send-response.json"
SEND_HTTP="$(
    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --config "$AUTH_CONFIG" \
        --output "$SEND_RESPONSE" \
        --write-out '%{http_code}' \
        --header 'Content-Type: application/json' \
        --header "Idempotency-Key: workspace-write-$TOKEN" \
        --data-binary "@$SEND_BODY" \
        "$API_ORIGIN/api/v1/send"
)"

[ "$SEND_HTTP" = "202" ] \
    || {
        cat "$SEND_RESPONSE" >&2
        echo "FAIL: send creation returned HTTP $SEND_HTTP" >&2
        exit 1
    }

MESSAGE_ID="$(
    python3 - "$SEND_RESPONSE" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["messageId"])
PY
)"

[[ "$MESSAGE_ID" =~ ^[1-9][0-9]*$ ]] \
    || {
        echo "FAIL: invalid message id" >&2
        exit 1
    }

RESULT="$(
    docker compose exec \
        -T \
        -e DOMAIN="$DOMAIN" \
        -e WEBHOOK_ID="$WEBHOOK_ID" \
        -e MESSAGE_ID="$MESSAGE_ID" \
        -e LEGACY_ID="$LEGACY_ID" \
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
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ],
);

$expected = (int) getenv('LEGACY_ID');

$checks = [
    'DOMAIN_WORKSPACE' => [
        'SELECT workspace_id FROM sending_domain WHERE domain = :value',
        getenv('DOMAIN'),
    ],
    'WEBHOOK_WORKSPACE' => [
        'SELECT workspace_id FROM webhook_endpoint WHERE public_id = :value',
        getenv('WEBHOOK_ID'),
    ],
    'MESSAGE_WORKSPACE' => [
        'SELECT workspace_id FROM outbound_message WHERE id = :value',
        getenv('MESSAGE_ID'),
    ],
];

foreach ($checks as $label => [$sql, $value]) {
    $stmt = $pdo->prepare($sql);
    $stmt->execute([
        'value' => $value,
    ]);

    $workspaceId = (int) $stmt->fetchColumn();

    echo $label, '=', $workspaceId, PHP_EOL;

    if ($workspaceId !== $expected) {
        exit(3);
    }
}

echo 'WRITE_OWNERSHIP=true', PHP_EOL;
PHP
)"

printf '%s\n' "$RESULT"

grep -Fxq "DOMAIN_WORKSPACE=$LEGACY_ID" <<<"$RESULT"
grep -Fxq "WEBHOOK_WORKSPACE=$LEGACY_ID" <<<"$RESULT"
grep -Fxq "MESSAGE_WORKSPACE=$LEGACY_ID" <<<"$RESULT"
grep -Fxq 'WRITE_OWNERSHIP=true' <<<"$RESULT"

echo "PASS: WORKSPACE WRITE OWNERSHIP GATE GREEN"
