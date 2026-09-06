#!/usr/bin/env bash

set -euo pipefail

echo "=== HeyMail outbound Messenger integration test ==="

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
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

$pdo->beginTransaction();

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
        !is_array($body)
        || (string) ($body['outboundMessageId'] ?? '') !== $id
    ) {
        continue;
    }

    $deleteMessenger->execute([
        'id' => $row['id'],
    ]);
}

$deleteOutbound = $pdo->prepare(
    'DELETE FROM outbound_message WHERE id = :id',
);

$deleteOutbound->execute([
    'id' => $id,
]);

$pdo->commit();
PHP
    fi

    docker compose start \
        mail-worker \
        >/dev/null 2>&1 \
        || true

    exit "$RESULT"
}

trap cleanup EXIT


# ---------------------------------------------------------------------------
# Build / runtime
# ---------------------------------------------------------------------------

docker compose config --quiet \
    || fail "Compose configuration is invalid"

docker compose up \
    -d \
    --build \
    api \
    mail-worker \
    >/dev/null

pass "current API/worker image is built"


# ---------------------------------------------------------------------------
# Freeze consumer before dispatch
# ---------------------------------------------------------------------------

WORKER_CONTAINER="$(
    docker compose ps -q mail-worker
)"

[ -n "$WORKER_CONTAINER" ] \
    || fail "mail-worker container does not exist before stop"

docker compose stop \
    mail-worker \
    >/dev/null

WORKER_RUNNING="$(
    docker inspect \
        "$WORKER_CONTAINER" \
        --format '{{.State.Running}}'
)"

[ "$WORKER_RUNNING" = "false" ] \
    || fail "mail-worker did not stop"

pass "mail-worker stopped before queue inspection"


# ---------------------------------------------------------------------------
# Create domain entity and dispatch through the real Symfony bus
# ---------------------------------------------------------------------------

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
use App\Kernel;
use App\Message\SendOutboundEmail;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Component\Messenger\MessageBusInterface;

require '/app/vendor/autoload.php';

$environment = getenv('APP_ENV');

if ($environment !== 'integration') {
    throw new RuntimeException(
        'Integration harness must run with APP_ENV=integration.',
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

if (!$entityManager instanceof EntityManagerInterface) {
    throw new RuntimeException(
        'Doctrine entity manager is unavailable.',
    );
}

if (!$bus instanceof MessageBusInterface) {
    throw new RuntimeException(
        'Messenger default bus is unavailable.',
    );
}

$idempotencyKey = sprintf(
    'integration-%s',
    bin2hex(random_bytes(32)),
);

$outbound = new OutboundMessage(
    $idempotencyKey,
);

$entityManager->persist(
    $outbound,
);

$entityManager->flush();

$id = $outbound->getId();

if (!is_int($id) || $id < 1) {
    throw new RuntimeException(
        'OutboundMessage did not receive a valid identifier.',
    );
}

$bus->dispatch(
    new SendOutboundEmail($id),
);

echo 'OUTBOUND_ID=', $id, PHP_EOL;
echo 'IDEMPOTENCY_HASH=',
    $outbound->getIdempotencyKeyHash(),
    PHP_EOL;

$kernel->shutdown();
PHP
)"

echo "$DISPATCH_OUTPUT"

OUTBOUND_ID="$(
    awk \
        -F= \
        '/^OUTBOUND_ID=/{print $2}' \
        <<<"$DISPATCH_OUTPUT"
)"

if ! [[ "$OUTBOUND_ID" =~ ^[1-9][0-9]*$ ]]; then
    fail "invalid outbound identifier returned by dispatcher"
fi

pass "OutboundMessage $OUTBOUND_ID persisted and dispatched"


# ---------------------------------------------------------------------------
# Inspect raw Doctrine Messenger row BEFORE consumption
# ---------------------------------------------------------------------------

QUEUE_CHECK="$(
    docker compose exec \
        -T \
        -e OUTBOUND_ID="$OUTBOUND_ID" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

$target = getenv('OUTBOUND_ID');

if (
    !is_string($target)
    || preg_match('/^[1-9][0-9]*$/', $target) !== 1
) {
    throw new RuntimeException(
        'Invalid OUTBOUND_ID.',
    );
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
SELECT id, body, headers
FROM messenger_messages
WHERE queue_name = 'outbound'
ORDER BY id DESC
SQL
    )
    ->fetchAll(PDO::FETCH_ASSOC);

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
        !is_array($body)
        || (string) ($body['outboundMessageId'] ?? '') !== $target
    ) {
        continue;
    }

    $keys = array_keys($body);

    sort($keys);

    if ($keys !== ['outboundMessageId']) {
        throw new RuntimeException(
            'Messenger body contains unexpected fields: '
            . implode(', ', $keys),
        );
    }

    $headers = json_decode(
        (string) $row['headers'],
        true,
        512,
        JSON_THROW_ON_ERROR,
    );

    if (!is_array($headers)) {
        throw new RuntimeException(
            'Messenger headers are invalid.',
        );
    }

    if (
        ($headers['type'] ?? null)
        !== 'App\\Message\\SendOutboundEmail'
    ) {
        throw new RuntimeException(
            'Unexpected Messenger message type.',
        );
    }

    if (
        ($headers['Content-Type'] ?? null)
        !== 'application/json'
    ) {
        throw new RuntimeException(
            'Messenger payload is not JSON.',
        );
    }

    $signature = $headers['Body-Sign'] ?? null;

    if (
        !is_string($signature)
        || !str_starts_with($signature, 'v2:')
    ) {
        throw new RuntimeException(
            'Outbound Messenger payload is not signed.',
        );
    }

    if (($headers['Sign-Algo'] ?? null) !== 'sha256') {
        throw new RuntimeException(
            'Unexpected Messenger signature algorithm.',
        );
    }

    echo 'QUEUE_ROW_ID=', $row['id'], PHP_EOL;
    echo 'QUEUE_BODY=', $row['body'], PHP_EOL;
    echo 'QUEUE_TYPE=', $headers['type'], PHP_EOL;
    echo 'QUEUE_SIGNED=yes', PHP_EOL;

    exit(0);
}

fwrite(
    STDERR,
    "No matching outbound Messenger row found.\n",
);

exit(1);
PHP
)" || fail "unable to validate raw Messenger queue row"

echo "$QUEUE_CHECK"

pass "queue payload contains only outboundMessageId"
pass "queue payload is JSON and HMAC-signed"


# ---------------------------------------------------------------------------
# Consumer
# ---------------------------------------------------------------------------

docker compose start \
    mail-worker \
    >/dev/null

pass "mail-worker restarted"

FINAL_STATE=""

for _ in $(seq 1 30); do
    FINAL_STATE="$(
        docker compose exec \
            -T \
            -e OUTBOUND_ID="$OUTBOUND_ID" \
            api \
            php <<'PHP'
<?php

declare(strict_types=1);

$id = getenv('OUTBOUND_ID');

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
    END AS has_ready_timestamp
FROM outbound_message
WHERE id = :id
SQL
);

$stmt->execute([
    'id' => $id,
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
    $row['has_ready_timestamp'];
PHP
    )"

    if [ "$FINAL_STATE" = "ready_for_submission|1" ]; then
        break
    fi

    sleep 1
done

[ "$FINAL_STATE" = "ready_for_submission|1" ] \
    || fail "unexpected final entity state: $FINAL_STATE"

pass "worker transitioned entity to ready_for_submission"


# ---------------------------------------------------------------------------
# Message must have been acknowledged, not failed
# ---------------------------------------------------------------------------

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
SELECT queue_name, body
FROM messenger_messages
WHERE queue_name IN ('outbound', 'failed')
SQL
    )
    ->fetchAll(PDO::FETCH_ASSOC);

$count = 0;

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
        && (string) ($body['outboundMessageId'] ?? '') === $target
    ) {
        ++$count;
    }
}

echo $count;
PHP
)"

[ "$REMAINING" = "0" ] \
    || fail "test message remains in outbound/failed queue"

pass "worker acknowledged the Messenger message"


# ---------------------------------------------------------------------------
# Mail/network boundary must still be closed
# ---------------------------------------------------------------------------

WORKER_CONTAINER="$(
    docker compose ps -q mail-worker
)"

NETWORKS="$(
    docker inspect "$WORKER_CONTAINER" \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        | sed '/^[[:space:]]*$/d' \
        | sort
)"

[ "$NETWORKS" = "heymail_data" ] \
    || fail "unexpected worker networks: $NETWORKS"

if docker compose exec \
    -T \
    mail-worker \
    php -r '
        if (gethostbyname("postfix") !== "postfix") {
            exit(1);
        }
    '
then
    :
else
    fail "Postfix became resolvable from mail-worker"
fi

pass "mail-worker remains isolated from Postfix"

echo
echo "ALL OUTBOUND MESSENGER INTEGRATION TESTS PASSED"
