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
    || preg_match('/^[1-9][0-9]*$/', $id) !== 1
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
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
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

$deleteMessenger = $pdo->prepare(
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
        $deleteMessenger->execute([
            'id' => $row['id'],
        ]);
    }
}

$stmt = $pdo->prepare(
    'DELETE FROM outbound_message WHERE id = :id',
);

$stmt->execute([
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

echo "=== HeyMail encrypted business delivery integration ==="

docker compose config --quiet \
    || fail "Compose configuration is invalid"

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

pass "business delivery laboratory is ready"

DISPATCH_OUTPUT="$(
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
use App\Entity\OutboundMessagePayload;
use App\Kernel;
use App\Mail\EmailAddress;
use App\Mail\OutboundEmailPayload;
use App\Mail\OutboundEmailPayloadCipher;
use App\Message\SendOutboundEmail;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Component\Messenger\MessageBusInterface;

require '/app/vendor/autoload.php';

$environment = getenv('APP_ENV');

if ($environment !== 'integration') {
    throw new RuntimeException(
        'Integration environment is required.',
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

$bus = $container->get(
    'messenger.default_bus',
);

$cipher = $container->get(
    OutboundEmailPayloadCipher::class,
);

if (
    !$entityManager
    instanceof EntityManagerInterface
) {
    throw new RuntimeException(
        'Doctrine entity manager unavailable.',
    );
}

if (!$bus instanceof MessageBusInterface) {
    throw new RuntimeException(
        'Messenger bus unavailable.',
    );
}

if (
    !$cipher
    instanceof OutboundEmailPayloadCipher
) {
    throw new RuntimeException(
        'Outbound payload cipher unavailable.',
    );
}

$token = bin2hex(
    random_bytes(12),
);

$idempotencyKey =
    'business-delivery-' . $token;

$recipient =
    'business-' . $token
    . '@success.test';

$subject =
    'HeyMail business ' . $token;

$bodyMarker =
    'HEYMAIL-BUSINESS-BODY-' . $token;

$outbound = new OutboundMessage(
    $idempotencyKey,
);

$payload = new OutboundEmailPayload(
    from: new EmailAddress(
        'sender@heymail.test',
        'HeyMail',
    ),
    to: [
        new EmailAddress(
            $recipient,
        ),
    ],
    subject: $subject,
    textPart: $bodyMarker,
);

$encrypted = $cipher->encrypt(
    $outbound->getIdempotencyKeyHash(),
    $payload,
);

$storedPayload =
    new OutboundMessagePayload(
        $outbound,
        $encrypted,
    );

$entityManager->persist(
    $outbound,
);

$entityManager->persist(
    $storedPayload,
);

$entityManager->flush();

$id = $outbound->getId();

if (!is_int($id) || $id < 1) {
    throw new RuntimeException(
        'Outbound message has no identifier.',
    );
}

$bus->dispatch(
    new SendOutboundEmail(
        $id,
    ),
);

echo 'OUTBOUND_ID=', $id, PHP_EOL;
echo 'RECIPIENT=', $recipient, PHP_EOL;
echo 'SUBJECT=', $subject, PHP_EOL;
echo 'BODY_MARKER=', $bodyMarker, PHP_EOL;

$kernel->shutdown();
PHP
)"

echo "$DISPATCH_OUTPUT"

OUTBOUND_ID="$(
    awk -F= \
        '/^OUTBOUND_ID=/{print $2}' \
        <<<"$DISPATCH_OUTPUT"
)"

RECIPIENT="$(
    awk -F= \
        '/^RECIPIENT=/{print $2}' \
        <<<"$DISPATCH_OUTPUT"
)"

SUBJECT="$(
    awk -F= \
        '/^SUBJECT=/{print substr($0, index($0, "=")+1)}' \
        <<<"$DISPATCH_OUTPUT"
)"

BODY_MARKER="$(
    awk -F= \
        '/^BODY_MARKER=/{print $2}' \
        <<<"$DISPATCH_OUTPUT"
)"

[[ "$OUTBOUND_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid outbound identifier"

[ -n "$RECIPIENT" ] \
    || fail "recipient marker missing"

[ -n "$BODY_MARKER" ] \
    || fail "body marker missing"

pass "encrypted business message persisted and queued"

docker compose exec \
    -T \
    -e OUTBOUND_ID="$OUTBOUND_ID" \
    -e RECIPIENT="$RECIPIENT" \
    -e SUBJECT="$SUBJECT" \
    -e BODY_MARKER="$BODY_MARKER" \
    api \
    php <<'PHP' \
    || fail "plaintext leaked into encrypted payload row"
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

$stmt = $pdo->prepare(
    <<<'SQL'
SELECT ciphertext
FROM outbound_message_payload
WHERE outbound_message_id = :id
SQL
);

$stmt->execute([
    'id' => getenv('OUTBOUND_ID'),
]);

$ciphertext = $stmt->fetchColumn();

if (!is_string($ciphertext)) {
    exit(1);
}

foreach ([
    getenv('RECIPIENT'),
    getenv('SUBJECT'),
    getenv('BODY_MARKER'),
] as $plaintext) {
    if (
        is_string($plaintext)
        && $plaintext !== ''
        && str_contains(
            $ciphertext,
            $plaintext,
        )
    ) {
        exit(2);
    }
}

echo "ENCRYPTED_ROW_OK\n";
PHP

pass "mail content remains encrypted before worker consumption"

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
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ],
);

$stmt = $pdo->prepare(
    <<<'SQL'
SELECT
    status,
    CASE
        WHEN ready_for_submission_at IS NULL
            THEN 0
        ELSE 1
    END AS ready_at,
    CASE
        WHEN submitted_at IS NULL
            THEN 0
        ELSE 1
    END AS submitted_at
FROM outbound_message
WHERE id = :id
SQL
);

$stmt->execute([
    'id' => getenv('OUTBOUND_ID'),
]);

$row = $stmt->fetch(
    PDO::FETCH_ASSOC,
);

if (!is_array($row)) {
    echo 'missing';
    exit(0);
}

echo $row['status'],
    '|',
    $row['ready_at'],
    '|',
    $row['submitted_at'];
PHP
    )"

    if [ "$FINAL_STATE" = "submitted|1|1" ]; then
        break
    fi

    sleep 1
done

[ "$FINAL_STATE" = "submitted|1|1" ] \
    || fail "unexpected final state: $FINAL_STATE"

pass "worker marked message SUBMITTED after Postfix acceptance"

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
    || fail "message never reached fake MX"

docker compose exec -T fake-mx-success \
    grep -a '^DKIM-Signature:' \
    /capture/last.eml \
    >/dev/null \
    || fail "delivered business mail has no DKIM signature"

docker compose exec -T fake-mx-success \
    grep -aF \
    "Subject: $SUBJECT" \
    /capture/last.eml \
    >/dev/null \
    || fail "delivered subject mismatch"

docker compose exec -T fake-mx-success \
    grep -aF \
    "$RECIPIENT" \
    /capture/last.eml \
    >/dev/null \
    || fail "delivered recipient mismatch"

pass "business mail reached fake MX with DKIM, subject and recipient"

REMAINING="$(
    docker compose exec \
        -T \
        -e OUTBOUND_ID="$OUTBOUND_ID" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

$target = getenv('OUTBOUND_ID');

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

$rows = $pdo
    ->query(
        <<<'SQL'
SELECT body
FROM messenger_messages
WHERE queue_name IN ('outbound', 'failed')
SQL
    )
    ->fetchAll(PDO::FETCH_COLUMN);

$count = 0;

foreach ($rows as $bodyJson) {
    try {
        $body = json_decode(
            (string) $bodyJson,
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
        ) === $target
    ) {
        ++$count;
    }
}

echo $count;
PHP
)"

[ "$REMAINING" = "0" ] \
    || fail "business message remains in Messenger queue"

pass "business Messenger job was acknowledged"

echo
echo "ALL OUTBOUND BUSINESS DELIVERY TESTS PASSED"
