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
        /tmp/heymail-ambiguous-redelivery.XXXXXX
)"

OUTBOUND_ID=""
SENDER_EMAIL=""

cleanup() {
    RESULT=$?

    trap - EXIT
    set +e

    if [ -n "${OUTBOUND_ID:-}" ]; then
        docker compose exec \
            -T \
            -e OUTBOUND_ID="$OUTBOUND_ID" \
            -e SENDER_EMAIL="${SENDER_EMAIL:-}" \
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

$deleteQueue =
    $pdo->prepare(
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

$deletePayload =
    $pdo->prepare(
        <<<'SQL'
DELETE FROM outbound_message_payload
WHERE outbound_message_id = :id
SQL
    );

$deletePayload->execute([
    'id' => $id,
]);

$deleteMessage =
    $pdo->prepare(
        'DELETE FROM outbound_message WHERE id = :id',
    );

$deleteMessage->execute([
    'id' => $id,
]);

$email = getenv('SENDER_EMAIL');

if (
    is_string($email)
    && $email !== ''
) {
    $deleteSender =
        $pdo->prepare(
            'DELETE FROM sender_identity WHERE email = :email',
        );

    $deleteSender->execute([
        'email' => $email,
    ]);
}
PHP
    fi

    rm -rf "$TMP_DIR"

    exit "$RESULT"
}

trap cleanup EXIT

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

print(payload[sys.argv[1]])
PY
}

echo "=== HeyMail ambiguous redelivery safety ==="

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

AUTH_CONFIG="$TMP_DIR/auth.conf"

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
print(secrets.token_hex(16))
PY
)"

MARKER="HEYMAIL-AMBIGUOUS-$TOKEN"
IDEMPOTENCY_KEY="ambiguous-$TOKEN"
SENDER_EMAIL="ambiguous-$TOKEN@heymail.test"

docker compose exec \
    -T \
    -e SENDER_EMAIL="$SENDER_EMAIL" \
    api \
    php <<'PHP'
<?php

declare(strict_types=1);

$email = getenv('SENDER_EMAIL');

if (
    !is_string($email)
    || $email === ''
) {
    fwrite(
        STDERR,
        "Invalid sender fixture email.\n",
    );

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

$domain =
    $pdo->query(
        <<<'SQL'
SELECT id
FROM sending_domain
WHERE domain = 'heymail.test'
  AND status = 'verified'
  AND dkim_selector IS NOT NULL
  AND dkim_public_key IS NOT NULL
  AND dkim_provisioned_at IS NOT NULL
LIMIT 1
SQL
    )
    ->fetchColumn();

if (
    !is_string($domain)
    && !is_int($domain)
) {
    fwrite(
        STDERR,
        "heymail.test is not verified and DKIM-ready.\n",
    );

    exit(1);
}

$createdAt =
    (new DateTimeImmutable(
        'now',
        new DateTimeZone('UTC'),
    ))
    ->format('Y-m-d H:i:s');

$insert =
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
ON CONFLICT (email) DO NOTHING
SQL
    );

$insert->execute([
    'domain_id' => $domain,
    'email' => $email,
    'created_at' => $createdAt,
]);
PHP

pass "exact sender identity fixture is authorized"

PAYLOAD="$TMP_DIR/payload.json"

python3 \
    - "$SENDER_EMAIL" "$MARKER" \
    > "$PAYLOAD" <<'PY'
import json
import sys

sender = sys.argv[1]
marker = sys.argv[2]

print(
    json.dumps(
        {
            "from": {
                "email": sender,
                "name": "HeyMail",
            },
            "to": [
                {
                    "email": "ambiguous@success.test",
                },
            ],
            "subject": marker,
            "text": marker,
        },
        separators=(",", ":"),
    )
)
PY

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
    --header "Idempotency-Key: $IDEMPOTENCY_KEY" \
    --data-binary "@$PAYLOAD" \
    "$API_ORIGIN/api/v1/send"

[ "$(http_code "$CREATE_HEADERS")" = "202" ] \
    || fail "initial HTTPS request did not return 202"

OUTBOUND_ID="$(
    json_field \
        messageId \
        "$CREATE_BODY"
)"

[[ "$OUTBOUND_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid outbound message id"

pass "created queued outbound message $OUTBOUND_ID"

STATE="$(
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

$pdo->beginTransaction();

try {
    $message = $pdo->prepare(
        <<<'SQL'
SELECT status
FROM outbound_message
WHERE id = :id
FOR UPDATE
SQL
    );

    $message->execute([
        'id' => $id,
    ]);

    if ($message->fetchColumn() !== 'queued') {
        throw new RuntimeException(
            'Outbound message is not QUEUED.',
        );
    }

    $readyAt =
        (new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        ))
        ->format('Y-m-d H:i:s');

    $submittingAt =
        (new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        ))
        ->format('Y-m-d H:i:s');

    $update = $pdo->prepare(
        <<<'SQL'
UPDATE outbound_message
SET
    status = 'submitting',
    ready_for_submission_at = :ready_at,
    submitting_at = :submitting_at
WHERE id = :id
  AND status = 'queued'
SQL
    );

    $update->execute([
        'id' => $id,
        'ready_at' => $readyAt,
        'submitting_at' => $submittingAt,
    ]);

    if ($update->rowCount() !== 1) {
        throw new RuntimeException(
            'Unable to persist SUBMITTING state.',
        );
    }

    $event = $pdo->prepare(
        <<<'SQL'
INSERT INTO outbound_message_event (
    outbound_message_id,
    event_type,
    occurred_at
)
VALUES (
    :id,
    :event_type,
    :occurred_at
)
SQL
    );

    $event->execute([
        'id' => $id,
        'event_type' => 'ready_for_submission',
        'occurred_at' => $readyAt,
    ]);

    $event->execute([
        'id' => $id,
        'event_type' => 'submitting',
        'occurred_at' => $submittingAt,
    ]);

    $pdo->commit();

    echo 'submitting';
} catch (Throwable $exception) {
    if ($pdo->inTransaction()) {
        $pdo->rollBack();
    }

    fwrite(
        STDERR,
        $exception->getMessage() . PHP_EOL,
    );

    exit(1);
}
PHP
)"

[ "$STATE" = "submitting" ] \
    || fail "database did not persist SUBMITTING"

pass "simulated crash state is durably SUBMITTING"
docker compose start \
    mail-worker \
    >/dev/null

FINAL_STATUS=""

for _ in $(seq 1 60)
do
    STATUS_HEADERS="$TMP_DIR/status.headers"
    STATUS_BODY="$TMP_DIR/status.body"

    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --config "$AUTH_CONFIG" \
        --dump-header "$STATUS_HEADERS" \
        --output "$STATUS_BODY" \
        "$API_ORIGIN/api/v1/messages/$OUTBOUND_ID"

    if [ "$(http_code "$STATUS_HEADERS")" = "200" ]; then
        FINAL_STATUS="$(
            json_field \
                status \
                "$STATUS_BODY"
        )"

        if [ "$FINAL_STATUS" = "submission_uncertain" ]; then
            break
        fi
    fi

    sleep 1
done

[ "$FINAL_STATUS" = "submission_uncertain" ] \
    || fail "redelivery did not become SUBMISSION_UNCERTAIN"

pass "redelivery became SUBMISSION_UNCERTAIN"

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

[ "$TIMELINE" = "queued>ready_for_submission>submitting>submission_uncertain" ] \
    || fail "unexpected uncertain submission timeline: $TIMELINE"

pass "ambiguous redelivery persists the complete immutable event timeline"

if docker compose exec -T fake-mx-success \
    grep -aF \
    "$MARKER" \
    /capture/last.eml \
    >/dev/null 2>&1
then
    fail "SUBMITTING redelivery was incorrectly submitted to SMTP"
fi

pass "SUBMITTING redelivery produced no SMTP delivery"

QUEUE_COUNT="$(
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

$count = 0;

$rows = $pdo
    ->query(
        <<<'SQL'
SELECT body
FROM messenger_messages
WHERE queue_name = 'outbound'
SQL
    )
    ->fetchAll(PDO::FETCH_COLUMN);

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
        ++$count;
    }
}

echo $count;
PHP
)"

[ "$QUEUE_COUNT" = "0" ] \
    || fail "ambiguous Messenger job was not acknowledged"

pass "ambiguous Messenger delivery was acknowledged without retry"

echo
echo "OUTBOUND_ID=$OUTBOUND_ID"
echo "FINAL_STATUS=$FINAL_STATUS"
echo
echo "ALL AMBIGUOUS REDELIVERY SAFETY TESTS PASSED"
