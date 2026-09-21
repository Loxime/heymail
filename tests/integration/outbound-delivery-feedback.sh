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
        /tmp/heymail-delivery-feedback.XXXXXX
)"

OUTBOUND_ID=""
SENDER_EMAIL=""

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

    docker compose exec \
        -T \
        postfix \
        postsuper -d ALL \
        >/dev/null 2>&1 \
        || true

    if [ -n "${OUTBOUND_ID:-}" ]; then
        docker compose exec \
            -T \
            -e OUTBOUND_ID="$OUTBOUND_ID" \
            -e SENDER_EMAIL="${SENDER_EMAIL:-}" \
            -e BOUNCE_EMAIL="${BOUNCE_EMAIL:-}" \
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

$id = getenv('OUTBOUND_ID');

if (
    is_string($id)
    && preg_match('/^[1-9][0-9]*$/D', $id) === 1
) {
    $delete = $pdo->prepare(
        'DELETE FROM outbound_message WHERE id = :id',
    );

    $delete->execute([
        'id' => $id,
    ]);
}

$email = getenv('SENDER_EMAIL');

if (
    is_string($email)
    && $email !== ''
) {
    $delete = $pdo->prepare(
        'DELETE FROM sender_identity WHERE email = :email',
    );

    $delete->execute([
        'email' => $email,
    ]);
}

$bounceEmail = getenv('BOUNCE_EMAIL');

if (
    is_string($bounceEmail)
    && $bounceEmail !== ''
) {
    $delete = $pdo->prepare(
        'DELETE FROM email_suppression WHERE email_hash = :email_hash',
    );

    $delete->execute([
        'email_hash' => hash(
            'sha256',
            strtolower($bounceEmail),
        ),
    ]);
}
PHP
    fi

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

echo "=== HeyMail per-recipient delivery feedback E2E ==="

docker compose up \
    -d \
    --wait \
    --build \
    gateway \
    mail-worker \
    postfix \
    delivery-observer \
    rspamd \
    fake-mx-success \
    fake-mx-tempfail \
    fake-mx-permfail \
    >/dev/null

docker compose stop \
    mail-worker \
    >/dev/null

docker compose exec \
    -T \
    postfix \
    postsuper -d ALL \
    >/dev/null 2>&1 \
    || true

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
print(secrets.token_hex(12))
PY
)"

SENDER_EMAIL="feedback-$TOKEN@heymail.test"
SUCCESS_EMAIL="success-$TOKEN@success.test"
TEMPFAIL_EMAIL="tempfail-$TOKEN@tempfail.test"
BOUNCE_EMAIL="bounce-$TOKEN@permfail.test"
IDEMPOTENCY_KEY="delivery-feedback-$TOKEN"

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

$domainId =
    $pdo
        ->query(
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
    !is_string($domainId)
    && !is_int($domainId)
) {
    fwrite(
        STDERR,
        "heymail.test is not DKIM-ready.\n",
    );

    exit(1);
}

$insert = $pdo->prepare(
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

$insert->execute([
    'domain_id' => $domainId,
    'email' => $email,
    'created_at'
        => (new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        ))
            ->format('Y-m-d H:i:s'),
]);
PHP

pass "exact sender fixture is authorized"

PAYLOAD="$TMP_DIR/payload.json"

python3 \
    - "$SENDER_EMAIL" \
    "$SUCCESS_EMAIL" \
    "$TEMPFAIL_EMAIL" \
    "$BOUNCE_EMAIL" \
    > "$PAYLOAD" <<'PY'
import json
import sys

sender, success, tempfail, bounced = sys.argv[1:]

print(
    json.dumps(
        {
            "from": {
                "email": sender,
                "name": "HeyMail",
            },
            "to": [
                {"email": success},
                {"email": tempfail},
                {"email": bounced},
            ],
            "subject": "HeyMail delivery feedback E2E",
            "text": "Per-recipient delivery feedback",
        },
        separators=(",", ":"),
    )
)
PY

HEADERS="$TMP_DIR/create.headers"
BODY="$TMP_DIR/create.body"

curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --config "$AUTH_CONFIG" \
    --dump-header "$HEADERS" \
    --output "$BODY" \
    --header 'Content-Type: application/json' \
    --header "Idempotency-Key: $IDEMPOTENCY_KEY" \
    --data-binary "@$PAYLOAD" \
    "$API_ORIGIN/api/v1/send"

[ "$(http_code "$HEADERS")" = "202" ] \
    || fail "multi-recipient submission did not return 202"

OUTBOUND_ID="$(
    json_field \
        messageId \
        "$BODY"
)"

[[ "$OUTBOUND_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid outbound message id"

pass "created outbound message $OUTBOUND_ID"

docker compose start \
    mail-worker \
    >/dev/null

RESULT=""

for _ in $(seq 1 90)
do
    RESULT="$(
        docker compose exec \
            -T \
            -e OUTBOUND_ID="$OUTBOUND_ID" \
            -e SUCCESS_EMAIL="$SUCCESS_EMAIL" \
            -e TEMPFAIL_EMAIL="$TEMPFAIL_EMAIL" \
            -e BOUNCE_EMAIL="$BOUNCE_EMAIL" \
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

$status = $pdo->prepare(
    'SELECT status FROM outbound_message WHERE id = :id',
);

$status->execute([
    'id' => $id,
]);

echo 'STATUS=',
    $status->fetchColumn(),
    PHP_EOL;

$query = $pdo->prepare(
    <<<'SQL'
SELECT
    event_type,
    recipient_hash,
    smtp_status,
    detail
FROM outbound_message_event
WHERE outbound_message_id = :id
  AND event_type IN (
      'delivered',
      'tempfail',
      'bounced'
  )
ORDER BY id ASC
SQL
);

$query->execute([
    'id' => $id,
]);

$expected = [
    hash(
        'sha256',
        strtolower(
            (string) getenv('SUCCESS_EMAIL'),
        ),
    ) => 'SUCCESS',
    hash(
        'sha256',
        strtolower(
            (string) getenv('TEMPFAIL_EMAIL'),
        ),
    ) => 'TEMPFAIL',
    hash(
        'sha256',
        strtolower(
            (string) getenv('BOUNCE_EMAIL'),
        ),
    ) => 'BOUNCE',
];

$counts = [
    'SUCCESS' => 0,
    'TEMPFAIL' => 0,
    'BOUNCE' => 0,
];

$plaintextLeak = false;
$invalidHash = false;

foreach ($query->fetchAll(PDO::FETCH_ASSOC) as $row) {
    $hash = (string) $row['recipient_hash'];

    if (
        preg_match(
            '/^[a-f0-9]{64}$/D',
            $hash,
        ) !== 1
    ) {
        $invalidHash = true;
    }

    $label = $expected[$hash] ?? null;

    if ($label !== null) {
        ++$counts[$label];

        echo $label,
            '=',
            $row['event_type'],
            ':',
            $row['smtp_status'],
            PHP_EOL;
    }

    $detail =
        strtolower(
            (string) $row['detail'],
        );

    foreach ([
        getenv('SUCCESS_EMAIL'),
        getenv('TEMPFAIL_EMAIL'),
        getenv('BOUNCE_EMAIL'),
    ] as $email) {
        if (
            is_string($email)
            && $email !== ''
            && str_contains(
                $detail,
                strtolower($email),
            )
        ) {
            $plaintextLeak = true;
        }
    }
}

echo 'SUCCESS_COUNT=',
    $counts['SUCCESS'],
    PHP_EOL;

echo 'TEMPFAIL_COUNT=',
    $counts['TEMPFAIL'],
    PHP_EOL;

echo 'BOUNCE_COUNT=',
    $counts['BOUNCE'],
    PHP_EOL;

echo 'PLAINTEXT_LEAK=',
    $plaintextLeak
        ? '1'
        : '0',
    PHP_EOL;

echo 'INVALID_HASH=',
    $invalidHash
        ? '1'
        : '0',
    PHP_EOL;
PHP
    )"

    if \
        grep -Fxq 'STATUS=submitted' <<<"$RESULT" \
        && grep -Eq '^SUCCESS=delivered:2\.' <<<"$RESULT" \
        && grep -Eq '^TEMPFAIL=tempfail:4\.' <<<"$RESULT" \
        && grep -Eq '^BOUNCE=bounced:5\.' <<<"$RESULT"
    then
        break
    fi

    sleep 1
done

printf '%s\n' "$RESULT"

grep -Fxq 'STATUS=submitted' <<<"$RESULT" \
    || fail "message did not remain SUBMITTED"

grep -Eq '^SUCCESS=delivered:2\.' <<<"$RESULT" \
    || fail "success recipient has no DELIVERED event"

grep -Eq '^TEMPFAIL=tempfail:4\.' <<<"$RESULT" \
    || fail "temporary recipient has no TEMPFAIL event"

grep -Eq '^BOUNCE=bounced:5\.' <<<"$RESULT" \
    || fail "permanent recipient has no BOUNCED event"

grep -Fxq 'SUCCESS_COUNT=1' <<<"$RESULT" \
    || fail "successful recipient does not have exactly one terminal delivery event"

grep -Eq '^TEMPFAIL_COUNT=[1-9][0-9]*$' <<<"$RESULT" \
    || fail "temporary recipient has no temporary failure history"

grep -Fxq 'BOUNCE_COUNT=1' <<<"$RESULT" \
    || fail "permanent recipient does not have exactly one bounce event"

grep -Fxq 'PLAINTEXT_LEAK=0' <<<"$RESULT" \
    || fail "recipient plaintext leaked into delivery metadata"

grep -Fxq 'INVALID_HASH=0' <<<"$RESULT" \
    || fail "invalid recipient hash persisted"

pass "message remains SUBMITTED after downstream delivery outcomes"
pass "success recipient persisted DELIVERED"
pass "temporary recipient persisted TEMPFAIL"
pass "permanent recipient persisted BOUNCED"
pass "delivery metadata stores recipient hashes without plaintext leakage"

SUPPRESSION="$(
    docker compose exec \
        -T \
        -e OUTBOUND_ID="$OUTBOUND_ID" \
        -e SUCCESS_EMAIL="$SUCCESS_EMAIL" \
        -e TEMPFAIL_EMAIL="$TEMPFAIL_EMAIL" \
        -e BOUNCE_EMAIL="$BOUNCE_EMAIL" \
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

foreach ([
    'SUCCESS' => getenv('SUCCESS_EMAIL'),
    'TEMPFAIL' => getenv('TEMPFAIL_EMAIL'),
    'BOUNCE' => getenv('BOUNCE_EMAIL'),
] as $label => $email) {
    $stmt = $pdo->prepare(
        <<<'SQL'
SELECT
    scope,
    reason,
    source_outbound_message_id
FROM email_suppression
WHERE email_hash = :email_hash
SQL
    );

    $stmt->execute([
        'email_hash' => hash(
            'sha256',
            strtolower((string) $email),
        ),
    ]);

    $row = $stmt->fetch(PDO::FETCH_ASSOC);

    if ($row === false) {
        echo $label, "=NONE\n";

        continue;
    }

    echo $label,
        '=',
        $row['scope'],
        ':',
        $row['reason'],
        ':',
        $row['source_outbound_message_id'],
        "\n";
}
PHP
)"

printf '%s\n' "$SUPPRESSION"

grep -Fxq 'SUCCESS=NONE' <<<"$SUPPRESSION" \
    || fail "successful recipient was unexpectedly suppressed"

grep -Fxq 'TEMPFAIL=NONE' <<<"$SUPPRESSION" \
    || fail "temporary failure was unexpectedly suppressed"

grep -Fxq "BOUNCE=global:hard_bounce:$OUTBOUND_ID" <<<"$SUPPRESSION" \
    || fail "hard bounce did not create the expected global suppression"

pass "hard bounce automatically creates a workspace-global suppression"

echo
echo "OUTBOUND_ID=$OUTBOUND_ID"
echo
echo "ALL OUTBOUND DELIVERY FEEDBACK E2E TESTS PASSED"
