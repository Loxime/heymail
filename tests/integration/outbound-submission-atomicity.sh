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

echo "=== HeyMail atomic outbound submission ==="

docker compose config --quiet \
    || fail "Compose configuration invalid"

docker compose up \
    -d \
    --wait \
    api \
    mail-worker \
    >/dev/null

docker compose stop \
    mail-worker \
    >/dev/null

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

use App\Entity\OutboundMessage;
use App\Kernel;
use App\Mail\EmailAddress;
use App\Mail\OutboundEmailPayload;
use App\Mail\OutboundEmailPayloadCipher;
use App\Mail\IdempotencyConflictException;
use App\Mail\OutboundMessageSubmissionService;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Component\Messenger\Envelope;
use Symfony\Component\Messenger\MessageBusInterface;

require '/app/vendor/autoload.php';

$environment = getenv('APP_ENV');

if ($environment !== 'integration') {
    throw new RuntimeException(
        'Integration environment required.',
    );
}

$kernel = new Kernel(
    $environment,
    false,
);

$kernel->boot();

$container = $kernel
    ->getContainer()
    ->get('test.service_container');

$entityManager = $container->get(
    'doctrine.orm.entity_manager',
);

$cipher = $container->get(
    OutboundEmailPayloadCipher::class,
);

$messageBus = $container->get(
    'messenger.default_bus',
);

if (
    !$entityManager
    instanceof EntityManagerInterface
) {
    throw new RuntimeException(
        'Entity manager unavailable.',
    );
}

if (
    !$cipher
    instanceof OutboundEmailPayloadCipher
) {
    throw new RuntimeException(
        'Payload cipher unavailable.',
    );
}

if (
    !$messageBus
    instanceof MessageBusInterface
) {
    throw new RuntimeException(
        'Messenger bus unavailable.',
    );
}

$submission =
    new OutboundMessageSubmissionService(
        $entityManager,
        $cipher,
        $messageBus,
    );

$token = bin2hex(
    random_bytes(16),
);

$idempotencyKey =
    'atomic-' . $token;

$payload = new OutboundEmailPayload(
    from: new EmailAddress(
        'sender@heymail.test',
        'HeyMail',
    ),
    to: [
        new EmailAddress(
            'atomic@success.test',
        ),
    ],
    subject: 'Atomic submission',
    textPart: 'ATOMIC-' . $token,
);

$first = $submission->submit(
    $idempotencyKey,
    $payload,
);

$second = $submission->submit(
    $idempotencyKey,
    $payload,
);

if (
    $first->messageId
    !== $second->messageId
) {
    throw new RuntimeException(
        'Idempotent replay created another message.',
    );
}

if ($first->replayed) {
    throw new RuntimeException(
        'First submission marked as replay.',
    );
}

if (!$second->replayed) {
    throw new RuntimeException(
        'Second submission was not marked as replay.',
    );
}

$conflictDetected = false;

try {
    $submission->submit(
        $idempotencyKey,
        new OutboundEmailPayload(
            from: new EmailAddress(
                'sender@heymail.test',
                'HeyMail',
            ),
            to: [
                new EmailAddress(
                    'atomic@success.test',
                ),
            ],
            subject: 'Conflicting submission',
            textPart: 'DIFFERENT-PAYLOAD',
        ),
    );
} catch (IdempotencyConflictException) {
    $conflictDetected = true;
}

if (!$conflictDetected) {
    throw new RuntimeException(
        'Conflicting idempotent replay was accepted.',
    );
}

$connection =
    $entityManager->getConnection();

$payloadRows = (int) $connection
    ->fetchOne(
        <<<'SQL'
SELECT COUNT(*)
FROM outbound_message_payload
WHERE outbound_message_id = :id
SQL,
        [
            'id' => $first->messageId,
        ],
    );

$queueRows = $connection
    ->fetchAllAssociative(
        <<<'SQL'
SELECT body
FROM messenger_messages
WHERE queue_name = 'outbound'
SQL
    );

$matchingQueueRows = 0;

foreach ($queueRows as $row) {
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
        && (
            $body['outboundMessageId']
            ?? null
        ) === $first->messageId
    ) {
        ++$matchingQueueRows;
    }
}

$rollbackKey =
    'rollback-' . bin2hex(
        random_bytes(16),
    );

$throwingBus =
    new class implements MessageBusInterface {
        public function dispatch(
            object $message,
            array $stamps = [],
        ): Envelope {
            throw new RuntimeException(
                'forced dispatch failure',
            );
        }
    };

$failingSubmission =
    new OutboundMessageSubmissionService(
        $entityManager,
        $cipher,
        $throwingBus,
    );

try {
    $failingSubmission->submit(
        $rollbackKey,
        $payload,
    );

    throw new RuntimeException(
        'Forced dispatch failure was not propagated.',
    );
} catch (RuntimeException $exception) {
    if (
        $exception->getMessage()
        !== 'forced dispatch failure'
    ) {
        throw $exception;
    }
}

$rollbackHash = hash(
    'sha256',
    $rollbackKey,
);

$rollbackRows = (int) $connection
    ->fetchOne(
        <<<'SQL'
SELECT COUNT(*)
FROM outbound_message
WHERE idempotency_key_hash = :hash
SQL,
        [
            'hash' => $rollbackHash,
        ],
    );

echo 'OUTBOUND_ID=',
    $first->messageId,
    PHP_EOL;

echo 'PAYLOAD_ROWS=',
    $payloadRows,
    PHP_EOL;

echo 'QUEUE_ROWS=',
    $matchingQueueRows,
    PHP_EOL;

echo 'ROLLBACK_ROWS=',
    $rollbackRows,
    PHP_EOL;

echo 'CONFLICT_REJECTED=',
    $conflictDetected ? 'yes' : 'no',
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

PAYLOAD_ROWS="$(
    awk -F= \
        '/^PAYLOAD_ROWS=/{print $2}' \
        <<<"$OUTPUT"
)"

QUEUE_ROWS="$(
    awk -F= \
        '/^QUEUE_ROWS=/{print $2}' \
        <<<"$OUTPUT"
)"

ROLLBACK_ROWS="$(
    awk -F= \
        '/^ROLLBACK_ROWS=/{print $2}' \
        <<<"$OUTPUT"
)"

CONFLICT_REJECTED="$(
    awk -F= \
        '/^CONFLICT_REJECTED=/{print $2}' \
        <<<"$OUTPUT"
)"

[[ "$OUTBOUND_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid outbound id"

[ "$PAYLOAD_ROWS" = "1" ] \
    || fail "expected exactly one encrypted payload"

[ "$QUEUE_ROWS" = "1" ] \
    || fail "expected exactly one Messenger row"

[ "$ROLLBACK_ROWS" = "0" ] \
    || fail "failed dispatch left database state behind"

[ "$CONFLICT_REJECTED" = "yes" ] \
    || fail "conflicting idempotency payload was accepted"

pass "same idempotency key produced exactly one message"
pass "same key with different payload is rejected"
pass "message, encrypted payload and queue row were created"
pass "failed dispatch rolled database state back"

echo
echo "ALL ATOMIC SUBMISSION TESTS PASSED"
