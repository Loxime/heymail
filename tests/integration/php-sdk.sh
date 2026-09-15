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

TMP_DIR="$(
    mktemp \
        -d \
        /tmp/heymail-php-sdk-e2e.XXXXXX
)"

chmod 0700 "$TMP_DIR"

RESULT_FILE="$TMP_DIR/sdk-result.txt"
OUTBOUND_ID=""
WORKER_WAS_RUNNING="false"

cleanup() {
    RESULT=$?

    trap - EXIT
    set +e

    if [ -z "${OUTBOUND_ID:-}" ] \
        && [ -f "$RESULT_FILE" ]
    then
        OUTBOUND_ID="$(
            awk -F= '
                /^MESSAGE_ID=[1-9][0-9]*$/ {
                    print $2
                    exit
                }
            ' "$RESULT_FILE"
        )"
    fi

    if [[ "${OUTBOUND_ID:-}" =~ ^[1-9][0-9]*$ ]]; then
        docker compose exec \
            -T \
            -e OUTBOUND_ID="$OUTBOUND_ID" \
            api \
            php <<'PHP_CLEAN' >/dev/null 2>&1
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
PHP_CLEAN
    fi

    if [ "$WORKER_WAS_RUNNING" = "true" ]; then
        docker compose start \
            mail-worker \
            >/dev/null 2>&1 \
            || true
    fi

    rm -rf "$TMP_DIR"

    exit "$RESULT"
}

trap cleanup EXIT

get_authorized_sender() {
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
        PDO::ATTR_ERRMODE
            => PDO::ERRMODE_EXCEPTION,
    ],
);

$sql =
    <<<'SQL'
SELECT si.email
FROM sender_identity si
INNER JOIN sending_domain sd
    ON sd.id = si.sending_domain_id
WHERE sd.status = 'verified'
  AND sd.disabled_at IS NULL
ORDER BY si.id DESC
LIMIT 1
SQL;

$value = $pdo
    ->query($sql)
    ->fetchColumn();

if (is_string($value)) {
    echo $value;
}
PHP
}

echo "=== HeyMail PHP SDK E2E ==="

docker compose up \
    -d \
    --wait \
    database \
    api \
    gateway \
    >/dev/null

SENDER_EMAIL="$(
    get_authorized_sender
)"

if [ -z "$SENDER_EMAIL" ]; then
    echo "No authorized sender fixture found; provisioning one with the existing sender E2E..."
    bash tests/integration/sender-identity-api.sh

    SENDER_EMAIL="$(
        get_authorized_sender
    )"
fi

[ -n "$SENDER_EMAIL" ] \
    || fail "could not obtain an authorized sender fixture"

printf 'SENDER=%s\n' "$SENDER_EMAIL"

if [ -n "$(
    docker compose ps \
        --status running \
        -q \
        mail-worker
)" ]; then
    WORKER_WAS_RUNNING="true"
fi

docker compose stop \
    mail-worker \
    >/dev/null 2>&1 \
    || true

TOKEN="$(
    python3 - <<'PY'
import secrets
print(secrets.token_hex(12))
PY
)"

IDEMPOTENCY_KEY="php-sdk-e2e-$TOKEN"
RECIPIENT="php-sdk-$TOKEN@success.test"
SUBJECT="HeyMail PHP SDK E2E $TOKEN"
BODY="HEYMAIL-PHP-SDK-E2E-$TOKEN"

echo
echo "=== BUILD DISPOSABLE SDK RUNNER ==="

docker build \
    -t heymail-php-sdk-e2e:v1.1 \
    -f - \
    "$TMP_DIR" <<'DOCKERFILE'
FROM php:8.4.25-cli-alpine3.23

RUN set -eux; \
    apk add --no-cache \
        ca-certificates \
        libcurl; \
    apk add --no-cache --virtual .build-deps \
        ${PHPIZE_DEPS} \
        curl-dev; \
    docker-php-ext-install -j"$(nproc)" curl; \
    apk del .build-deps

WORKDIR /work
DOCKERFILE

pass "disposable PHP runner has ext-curl"

GATEWAY_ID="$(
    docker compose ps -q gateway
)"

[ -n "$GATEWAY_ID" ] \
    || fail "gateway container id is empty"

NETWORK_AND_IP="$(
    docker inspect \
        --format \
        '{{range $name, $net := .NetworkSettings.Networks}}{{printf "%s %s\n" $name $net.IPAddress}}{{end}}' \
        "$GATEWAY_ID" \
        | head -n 1
)"

NETWORK="$(
    printf '%s\n' "$NETWORK_AND_IP" \
        | awk '{print $1}'
)"

GATEWAY_IP="$(
    printf '%s\n' "$NETWORK_AND_IP" \
        | awk '{print $2}'
)"

[ -n "$NETWORK" ] \
    || fail "gateway Docker network not found"

[ -n "$GATEWAY_IP" ] \
    || fail "gateway Docker IP not found"

echo
echo "=== SDK SUBMISSION + IDEMPOTENCY ==="

set +e
docker run \
    --rm \
    -i \
    --network "$NETWORK" \
    --add-host "api.heymail.test:$GATEWAY_IP" \
    -e "SENDER_EMAIL=$SENDER_EMAIL" \
    -e "RECIPIENT=$RECIPIENT" \
    -e "SUBJECT=$SUBJECT" \
    -e "BODY=$BODY" \
    -e "IDEMPOTENCY_KEY=$IDEMPOTENCY_KEY" \
    -v "$ROOT_DIR/packages/heymail-php:/sdk:ro" \
    -v "$ROOT_DIR/secrets/api_key:/run/heymail/api_key:ro" \
    -v "$ROOT_DIR/secrets/api_secret:/run/heymail/api_secret:ro" \
    -v "$ROOT_DIR/secrets/gateway_tls_cert.pem:/run/heymail/ca.pem:ro" \
    heymail-php-sdk-e2e:v1.1 \
    php <<'PHP_SDK' \
    | tee "$RESULT_FILE"
<?php

declare(strict_types=1);

require '/sdk/src/Exception/ApiException.php';
require '/sdk/src/Exception/TransportException.php';
require '/sdk/src/HeyMailHub.php';
require '/sdk/src/MessageBuilder.php';

use HeyMail\Exception\ApiException;
use HeyMail\HeyMailHub;

function need(
    bool $condition,
    string $message,
): void {
    if (!$condition) {
        fwrite(
            STDERR,
            "FAIL: {$message}\n",
        );
        exit(1);
    }
}

$sender = (string) getenv(
    'SENDER_EMAIL',
);

$recipient = (string) getenv(
    'RECIPIENT',
);

$subject = (string) getenv(
    'SUBJECT',
);

$body = (string) getenv(
    'BODY',
);

$idempotencyKey = (string) getenv(
    'IDEMPOTENCY_KEY',
);

$hub = new HeyMailHub(
    baseUri: 'https://api.heymail.test:8443',
    apiKey: trim(
        file_get_contents(
            '/run/heymail/api_key',
        ),
    ),
    apiSecret: trim(
        file_get_contents(
            '/run/heymail/api_secret',
        ),
    ),
    defaultFrom: $sender,
    caFile: '/run/heymail/ca.pem',
);

$first = $hub
    ->message()
    ->to(
        $recipient,
        'SDK E2E',
    )
    ->subject(
        $subject,
    )
    ->text(
        $body,
    )
    ->idempotencyKey(
        $idempotencyKey,
    )
    ->send();

need(
    isset($first['messageId'])
    && is_int($first['messageId'])
    && $first['messageId'] > 0,
    'first SDK response has no valid messageId',
);

need(
    ($first['status'] ?? null) === 'queued',
    'first SDK response is not queued',
);

need(
    ($first['replayed'] ?? null) === false,
    'first SDK response is incorrectly replayed',
);

$messageId = $first['messageId'];

echo "MESSAGE_ID={$messageId}\n";
echo "FIRST_REPLAYED=false\n";
flush();

$second = $hub
    ->message()
    ->to(
        $recipient,
        'SDK E2E',
    )
    ->subject(
        $subject,
    )
    ->text(
        $body,
    )
    ->idempotencyKey(
        $idempotencyKey,
    )
    ->send();

need(
    ($second['messageId'] ?? null) === $messageId,
    'SDK replay returned another messageId',
);

need(
    ($second['replayed'] ?? null) === true,
    'SDK replay was not marked replayed',
);

echo "SECOND_REPLAYED=true\n";

try {
    $hub
        ->message()
        ->to(
            $recipient,
            'SDK E2E',
        )
        ->subject(
            $subject,
        )
        ->text(
            $body . '-CONFLICT',
        )
        ->idempotencyKey(
            $idempotencyKey,
        )
        ->send();

    need(
        false,
        'conflicting SDK request unexpectedly succeeded',
    );
} catch (ApiException $exception) {
    need(
        $exception->status === 409,
        sprintf(
            'conflicting SDK request returned HTTP %d instead of 409',
            $exception->status,
        ),
    );

    echo "CONFLICT_STATUS=409\n";
}

echo "PASS: PHP SDK builder + TLS + auth + idempotency\n";
PHP_SDK
SDK_STATUS="${PIPESTATUS[0]}"
set -e

if [ "$SDK_STATUS" -ne 0 ]; then
    fail "PHP SDK runner failed"
fi

if [ ! -s "$RESULT_FILE" ]; then
    fail "PHP SDK runner produced no output"
fi

OUTBOUND_ID="$(
    awk -F= '
        /^MESSAGE_ID=[1-9][0-9]*$/ {
            print $2
            exit
        }
    ' "$RESULT_FILE"
)"

[[ "$OUTBOUND_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "SDK did not expose a valid message id"

grep -Fxq \
    'FIRST_REPLAYED=false' \
    "$RESULT_FILE" \
    || fail "first SDK submission result missing"

grep -Fxq \
    'SECOND_REPLAYED=true' \
    "$RESULT_FILE" \
    || fail "SDK replay result missing"

grep -Fxq \
    'CONFLICT_STATUS=409' \
    "$RESULT_FILE" \
    || fail "SDK conflict result missing"

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

$rows = $pdo
    ->query(
        <<<'SQL'
SELECT body
FROM messenger_messages
WHERE queue_name = 'outbound'
SQL
    )
    ->fetchAll(PDO::FETCH_COLUMN);

$queueCount = 0;

foreach ($rows as $body) {
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

printf '%s\n' "$COUNTS"

grep -Fxq \
    'MESSAGES=1' \
    <<<"$COUNTS" \
    || fail "SDK idempotency created more than one outbound message"

grep -Fxq \
    'PAYLOADS=1' \
    <<<"$COUNTS" \
    || fail "SDK idempotency created more than one encrypted payload"

grep -Fxq \
    'QUEUE=1' \
    <<<"$COUNTS" \
    || fail "SDK idempotency created more than one queue job"

pass "SDK idempotency persisted exactly one message, payload and queue job"

echo
echo "OUTBOUND_ID=$OUTBOUND_ID"
echo "ALL PHP SDK E2E TESTS PASSED"
