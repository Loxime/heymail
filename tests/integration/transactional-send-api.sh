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

OUTBOUND_ID=""

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

$delete = $pdo->prepare(
    'DELETE FROM outbound_message WHERE id = :id',
);

$delete->execute([
    'id' => $id,
]);
PHP
    fi

    docker compose start \
        mail-worker \
        >/dev/null 2>&1 \
        || true

    exit "$RESULT"
}

trap cleanup EXIT

echo "=== HeyMail transactional Send API ==="

docker compose up \
    -d \
    --wait \
    --build \
    api \
    mail-worker \
    postfix \
    fake-mx-success \
    >/dev/null

docker compose stop \
    mail-worker \
    >/dev/null

docker compose exec -T fake-mx-success \
    rm -f /capture/last.eml \
    >/dev/null 2>&1 \
    || true

OUTPUT="$(
    docker compose run \
        --rm \
        --no-deps \
        -T \
        -e APP_ENV=integration \
        -e APP_DEBUG=0 \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

use App\Kernel;
use Symfony\Component\HttpFoundation\Request;

require '/app/vendor/autoload.php';

$kernel = new Kernel(
    'integration',
    false,
);

$kernel->boot();

$key = trim(
    file_get_contents(
        '/run/secrets/api_key',
    ),
);

$secret = trim(
    file_get_contents(
        '/run/secrets/api_secret',
    ),
);

$authorization = 'Basic '
    . base64_encode(
        $key . ':' . $secret,
    );

$token = bin2hex(
    random_bytes(12),
);

$idempotencyKey =
    'send-api-' . $token;

$recipient =
    'api-' . $token
    . '@success.test';

$subject =
    'HeyMail Send API ' . $token;

$bodyMarker =
    'HEYMAIL-SEND-API-' . $token;

$payload = json_encode(
    [
        'from' => [
            'email'
                => 'sender@heymail.test',
            'name'
                => 'HeyMail',
        ],
        'to' => [
            [
                'email' => $recipient,
            ],
        ],
        'subject' => $subject,
        'text' => $bodyMarker,
    ],
    JSON_THROW_ON_ERROR,
);

$makeRequest = static function (
    string $authorization,
    string $idempotencyKey,
    string $payload,
): Request {
    return Request::create(
        '/api/v1/send',
        'POST',
        [],
        [],
        [],
        [
            'CONTENT_TYPE'
                => 'application/json',
            'HTTP_AUTHORIZATION'
                => $authorization,
            'HTTP_IDEMPOTENCY_KEY'
                => $idempotencyKey,
            'HTTP_ACCEPT'
                => 'application/json',
        ],
        $payload,
    );
};

$unauthorized = Request::create(
    '/api/v1/send',
    'POST',
    [],
    [],
    [],
    [
        'CONTENT_TYPE'
            => 'application/json',
        'HTTP_IDEMPOTENCY_KEY'
            => $idempotencyKey,
    ],
    $payload,
);

$response = $kernel->handle(
    $unauthorized,
);

if ($response->getStatusCode() !== 401) {
    throw new RuntimeException(
        'Unauthenticated Send API request was accepted.',
    );
}

$firstResponse = $kernel->handle(
    $makeRequest(
        $authorization,
        $idempotencyKey,
        $payload,
    ),
);

if ($firstResponse->getStatusCode() !== 202) {
    throw new RuntimeException(
        'First Send API request did not return 202.',
    );
}

$first = json_decode(
    $firstResponse->getContent(),
    true,
    512,
    JSON_THROW_ON_ERROR,
);

if (
    !is_array($first)
    || !is_int(
        $first['messageId']
        ?? null,
    )
    || ($first['replayed'] ?? null)
        !== false
) {
    throw new RuntimeException(
        'Invalid first Send API response.',
    );
}

$replayResponse = $kernel->handle(
    $makeRequest(
        $authorization,
        $idempotencyKey,
        $payload,
    ),
);

if ($replayResponse->getStatusCode() !== 200) {
    throw new RuntimeException(
        'Idempotent replay did not return 200.',
    );
}

$replay = json_decode(
    $replayResponse->getContent(),
    true,
    512,
    JSON_THROW_ON_ERROR,
);

if (
    !is_array($replay)
    || ($replay['messageId'] ?? null)
        !== $first['messageId']
    || ($replay['replayed'] ?? null)
        !== true
) {
    throw new RuntimeException(
        'Invalid replay response.',
    );
}

$conflicting = json_encode(
    [
        'from' => [
            'email'
                => 'sender@heymail.test',
        ],
        'to' => [
            [
                'email'
                    => $recipient,
            ],
        ],
        'subject'
            => 'Different payload',
        'text'
            => 'Different body',
    ],
    JSON_THROW_ON_ERROR,
);

$conflictResponse = $kernel->handle(
    $makeRequest(
        $authorization,
        $idempotencyKey,
        $conflicting,
    ),
);

if (
    $conflictResponse->getStatusCode()
    !== 409
) {
    throw new RuntimeException(
        'Conflicting replay did not return HTTP 409.',
    );
}

echo 'OUTBOUND_ID=',
    $first['messageId'],
    PHP_EOL;

echo 'RECIPIENT=',
    $recipient,
    PHP_EOL;

echo 'BODY_MARKER=',
    $bodyMarker,
    PHP_EOL;

echo 'AUTH=401',
    PHP_EOL;

echo 'CREATE=202',
    PHP_EOL;

echo 'REPLAY=200',
    PHP_EOL;

echo 'CONFLICT=409',
    PHP_EOL;

$kernel->shutdown();
PHP
)"

echo "$OUTPUT"

OUTBOUND_ID="$(
    awk -F= \
        '/^OUTBOUND_ID=/{print $2}' \
        <<<"$OUTPUT"
)"

BODY_MARKER="$(
    awk -F= \
        '/^BODY_MARKER=/{print $2}' \
        <<<"$OUTPUT"
)"

[[ "$OUTBOUND_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid outbound id"

grep -Fxq 'AUTH=401' <<<"$OUTPUT" \
    || fail "auth rejection failed"

grep -Fxq 'CREATE=202' <<<"$OUTPUT" \
    || fail "initial submission failed"

grep -Fxq 'REPLAY=200' <<<"$OUTPUT" \
    || fail "idempotent replay failed"

grep -Fxq 'CONFLICT=409' <<<"$OUTPUT" \
    || fail "idempotency conflict failed"

pass "Send API auth and idempotency semantics are correct"

docker compose start \
    mail-worker \
    >/dev/null

FINAL_STATE=""

for _ in $(seq 1 60); do
    FINAL_STATE="$(
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
    'SELECT status FROM outbound_message WHERE id = :id',
);

$stmt->execute([
    'id' => getenv('OUTBOUND_ID'),
]);

echo (string) $stmt->fetchColumn();
PHP
    )"

    [ "$FINAL_STATE" = "submitted" ] \
        && break

    sleep 1
done

[ "$FINAL_STATE" = "submitted" ] \
    || fail "message did not become SUBMITTED"

CAPTURED="false"

for _ in $(seq 1 60); do
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
    || fail "Send API message did not reach fake MX"

docker compose exec -T fake-mx-success \
    grep -a '^DKIM-Signature:' \
    /capture/last.eml \
    >/dev/null \
    || fail "Send API message has no DKIM"

pass "Send API message reached fake MX with DKIM"

STATUS_OUTPUT="$(
    docker compose run \
        --rm \
        --no-deps \
        -T \
        -e APP_ENV=integration \
        -e APP_DEBUG=0 \
        -e OUTBOUND_ID="$OUTBOUND_ID" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

use App\Kernel;
use Symfony\Component\HttpFoundation\Request;

require '/app/vendor/autoload.php';

$kernel = new Kernel(
    'integration',
    false,
);

$kernel->boot();

$key = trim(
    file_get_contents(
        '/run/secrets/api_key',
    ),
);

$secret = trim(
    file_get_contents(
        '/run/secrets/api_secret',
    ),
);

$id = getenv('OUTBOUND_ID');

$request = Request::create(
    '/api/v1/messages/' . $id,
    'GET',
    [],
    [],
    [],
    [
        'HTTP_AUTHORIZATION'
            => 'Basic '
            . base64_encode(
                $key . ':' . $secret,
            ),
    ],
);

$response = $kernel->handle(
    $request,
);

echo 'STATUS_HTTP=',
    $response->getStatusCode(),
    PHP_EOL;

echo 'STATUS_BODY=',
    $response->getContent(),
    PHP_EOL;

$kernel->shutdown();
PHP
)"

echo "$STATUS_OUTPUT"

grep -Fq \
    'STATUS_HTTP=200' \
    <<<"$STATUS_OUTPUT" \
    || fail "message status endpoint failed"

grep -Fq \
    '"status":"submitted"' \
    <<<"$STATUS_OUTPUT" \
    || fail "status endpoint does not report submitted"

pass "message status endpoint reports SUBMITTED"

echo
echo "ALL TRANSACTIONAL SEND API TESTS PASSED"
