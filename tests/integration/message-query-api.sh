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
        /tmp/heymail-message-query.XXXXXX
)"

AUTH_CONFIG="$TMP_DIR/auth.conf"

MESSAGE_IDS=()

cleanup() {
    RESULT=$?

    trap - EXIT
    set +e

    if [ "${#MESSAGE_IDS[@]}" -gt 0 ]; then
        IDS="$(
            IFS=,
            printf '%s' "${MESSAGE_IDS[*]}"
        )"

        docker compose exec \
            -T \
            -e MESSAGE_IDS="$IDS" \
            api \
            php <<'PHP' >/dev/null 2>&1
<?php

declare(strict_types=1);

$raw = getenv('MESSAGE_IDS');

if (
    !is_string($raw)
    || $raw === ''
) {
    exit(0);
}

$ids = array_values(
    array_filter(
        explode(
            ',',
            $raw,
        ),
        static fn (
            string $id,
        ): bool => preg_match(
            '/^[1-9][0-9]*$/D',
            $id,
        ) === 1,
    ),
);

if ($ids === []) {
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

$placeholders =
    implode(
        ',',
        array_fill(
            0,
            count($ids),
            '?',
        ),
    );

$stmt = $pdo->prepare(
    sprintf(
        'DELETE FROM outbound_message WHERE id IN (%s)',
        $placeholders,
    ),
);

$stmt->execute(
    $ids,
);
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

json_value() {
    EXPRESSION="$1"
    FILE="$2"

    python3 \
        - "$EXPRESSION" "$FILE" <<'PY'
import json
import sys

expression = sys.argv[1]

with open(
    sys.argv[2],
    encoding="utf-8",
) as handle:
    value = json.load(handle)

for part in expression.split("."):
    if part.isdigit():
        value = value[int(part)]
    else:
        value = value[part]

if value is None:
    print("null")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

json_item_ids() {
    FILE="$1"

    python3 \
        - "$FILE" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    payload = json.load(handle)

print(
    ",".join(
        str(item["messageId"])
        for item in payload["items"]
    )
)
PY
}

authenticated_get() {
    URL="$1"
    HEADERS="$2"
    BODY="$3"

    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --config "$AUTH_CONFIG" \
        --dump-header "$HEADERS" \
        --output "$BODY" \
        "$URL"
}

echo "=== HeyMail message query API E2E ==="

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
# Seed deterministic query fixtures.
#
# The 2042 date window intentionally isolates them from real project data.
# No payload rows are created: this API must not require payload decryption.
# ---------------------------------------------------------------------------

FIXTURE="$(
    docker compose exec \
        -T \
        -e FIXTURE_TOKEN="$TOKEN" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

$token = getenv('FIXTURE_TOKEN');

if (
    !is_string($token)
    || $token === ''
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

$pdo->beginTransaction();

try {
    $insertMessage = $pdo->prepare(
        <<<'SQL'
INSERT INTO outbound_message (
    idempotency_key_hash,
    status,
    created_at,
    ready_for_submission_at,
    submitting_at,
    submission_uncertain_at,
    submitted_at
)
VALUES (
    :hash,
    :status,
    :created_at,
    :ready_at,
    :submitting_at,
    :uncertain_at,
    :submitted_at
)
RETURNING id
SQL
    );

    $insertEvent = $pdo->prepare(
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
SQL
    );

    $createMessage = static function (
        string $suffix,
        string $status,
        string $createdAt,
        ?string $readyAt,
        ?string $submittingAt,
        ?string $uncertainAt,
        ?string $submittedAt,
    ) use (
        $insertMessage,
        $token,
    ): int {
        $insertMessage->execute([
            'hash' => hash(
                'sha256',
                $token
                    . ':'
                    . $suffix,
            ),
            'status' => $status,
            'created_at' => $createdAt,
            'ready_at' => $readyAt,
            'submitting_at' => $submittingAt,
            'uncertain_at' => $uncertainAt,
            'submitted_at' => $submittedAt,
        ]);

        return (int) $insertMessage->fetchColumn();
    };

    $event = static function (
        int $messageId,
        string $type,
        string $at,
        ?string $recipient = null,
        ?string $smtpStatus = null,
        ?string $detail = null,
        ?string $source = null,
    ) use (
        $insertEvent,
    ): void {
        $insertEvent->execute([
            'message_id' => $messageId,
            'event_type' => $type,
            'occurred_at' => $at,
            'recipient_hash'
                => $recipient === null
                    ? null
                    : hash(
                        'sha256',
                        strtolower(
                            $recipient,
                        ),
                    ),
            'smtp_status' => $smtpStatus,
            'detail' => $detail,
            'source_event_id'
                => $source === null
                    ? null
                    : hash(
                        'sha256',
                        $source,
                    ),
        ]);
    };

    /*
     * M1 - oldest / QUEUED
     */
    $m1 = $createMessage(
        'm1',
        'queued',
        '2042-01-01 00:00:01',
        null,
        null,
        null,
        null,
    );

    $event(
        $m1,
        'queued',
        '2042-01-01 00:00:01',
    );

    /*
     * M2 - SUBMITTED + DELIVERED
     */
    $m2 = $createMessage(
        'm2',
        'submitted',
        '2042-01-01 00:00:02',
        '2042-01-01 00:00:02',
        '2042-01-01 00:00:02',
        null,
        '2042-01-01 00:00:03',
    );

    $event(
        $m2,
        'queued',
        '2042-01-01 00:00:02',
    );

    $event(
        $m2,
        'ready_for_submission',
        '2042-01-01 00:00:02',
    );

    $event(
        $m2,
        'submitting',
        '2042-01-01 00:00:02',
    );

    $event(
        $m2,
        'submitted',
        '2042-01-01 00:00:03',
    );

    $event(
        $m2,
        'delivered',
        '2042-01-01 00:00:04',
        'recipient-delivered@example.test',
        '2.0.0',
        '250 accepted',
        $token . ':m2:delivered',
    );

    /*
     * M3 - SUBMISSION_UNCERTAIN
     */
    $m3 = $createMessage(
        'm3',
        'submission_uncertain',
        '2042-01-01 00:00:03',
        '2042-01-01 00:00:03',
        '2042-01-01 00:00:03',
        '2042-01-01 00:00:04',
        null,
    );

    $event(
        $m3,
        'queued',
        '2042-01-01 00:00:03',
    );

    $event(
        $m3,
        'ready_for_submission',
        '2042-01-01 00:00:03',
    );

    $event(
        $m3,
        'submitting',
        '2042-01-01 00:00:03',
    );

    $event(
        $m3,
        'submission_uncertain',
        '2042-01-01 00:00:04',
    );

    /*
     * M4 - newest / SUBMITTED + TEMPFAIL + BOUNCED
     */
    $m4 = $createMessage(
        'm4',
        'submitted',
        '2042-01-01 00:00:04',
        '2042-01-01 00:00:04',
        '2042-01-01 00:00:04',
        null,
        '2042-01-01 00:00:05',
    );

    $event(
        $m4,
        'queued',
        '2042-01-01 00:00:04',
    );

    $event(
        $m4,
        'ready_for_submission',
        '2042-01-01 00:00:04',
    );

    $event(
        $m4,
        'submitting',
        '2042-01-01 00:00:04',
    );

    $event(
        $m4,
        'submitted',
        '2042-01-01 00:00:05',
    );

    $event(
        $m4,
        'tempfail',
        '2042-01-01 00:00:06',
        'recipient-bounced@example.test',
        '4.1.1',
        '450 temporary rejection',
        $token . ':m4:tempfail',
    );

    $event(
        $m4,
        'bounced',
        '2042-01-01 00:00:07',
        'recipient-bounced@example.test',
        '5.1.1',
        '550 permanent rejection',
        $token . ':m4:bounced',
    );

    $pdo->commit();

    echo 'M1=', $m1, PHP_EOL;
    echo 'M2=', $m2, PHP_EOL;
    echo 'M3=', $m3, PHP_EOL;
    echo 'M4=', $m4, PHP_EOL;
} catch (Throwable $exception) {
    if ($pdo->inTransaction()) {
        $pdo->rollBack();
    }

    throw $exception;
}
PHP
)"

printf '%s\n' "$FIXTURE"

M1="$(
    awk -F= '$1 == "M1" { print $2 }' <<<"$FIXTURE"
)"

M2="$(
    awk -F= '$1 == "M2" { print $2 }' <<<"$FIXTURE"
)"

M3="$(
    awk -F= '$1 == "M3" { print $2 }' <<<"$FIXTURE"
)"

M4="$(
    awk -F= '$1 == "M4" { print $2 }' <<<"$FIXTURE"
)"

for ID in \
    "$M1" \
    "$M2" \
    "$M3" \
    "$M4"
do
    [[ "$ID" =~ ^[1-9][0-9]*$ ]] \
        || fail "invalid seeded message identifier"

    MESSAGE_IDS+=(
        "$ID"
    )
done

pass "seeded deterministic query fixtures"

WINDOW_START="2042-01-01T00:00:00Z"
WINDOW_END="2042-01-01T00:00:10Z"

# ---------------------------------------------------------------------------
# Authentication boundary
# ---------------------------------------------------------------------------

UNAUTH_HEADERS="$TMP_DIR/unauth.headers"
UNAUTH_BODY="$TMP_DIR/unauth.body"

curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --dump-header "$UNAUTH_HEADERS" \
    --output "$UNAUTH_BODY" \
    "$API_ORIGIN/api/v1/messages"

[ "$(http_code "$UNAUTH_HEADERS")" = "401" ] \
    || fail "message list authentication boundary is not enforced"

pass "message list requires authentication"

# ---------------------------------------------------------------------------
# First page: M4, M3
# ---------------------------------------------------------------------------

PAGE1_HEADERS="$TMP_DIR/page1.headers"
PAGE1_BODY="$TMP_DIR/page1.body"

authenticated_get \
    "$API_ORIGIN/api/v1/messages?limit=2&createdAfter=$WINDOW_START&createdBefore=$WINDOW_END" \
    "$PAGE1_HEADERS" \
    "$PAGE1_BODY"

[ "$(http_code "$PAGE1_HEADERS")" = "200" ] \
    || fail "first message page did not return 200"

PAGE1_IDS="$(
    json_item_ids \
        "$PAGE1_BODY"
)"

[ "$PAGE1_IDS" = "$M4,$M3" ] \
    || fail "unexpected first page order: $PAGE1_IDS"

CURSOR="$(
    json_value \
        nextCursor \
        "$PAGE1_BODY"
)"

[ "$CURSOR" != "null" ] \
    || fail "first page did not return nextCursor"

pass "first page is newest-first and returns an opaque cursor"

# ---------------------------------------------------------------------------
# Insert a newer row AFTER page 1.
#
# Cursor pagination must not inject it into page 2.
# ---------------------------------------------------------------------------

M5="$(
    docker compose exec \
        -T \
        -e FIXTURE_TOKEN="$TOKEN" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

$token = getenv('FIXTURE_TOKEN');

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
INSERT INTO outbound_message (
    idempotency_key_hash,
    status,
    created_at
)
VALUES (
    :hash,
    'queued',
    '2042-01-01 00:00:05'
)
RETURNING id
SQL
);

$stmt->execute([
    'hash' => hash(
        'sha256',
        $token . ':m5',
    ),
]);

$id = (int) $stmt->fetchColumn();

$event = $pdo->prepare(
    <<<'SQL'
INSERT INTO outbound_message_event (
    outbound_message_id,
    event_type,
    occurred_at
)
VALUES (
    :id,
    'queued',
    '2042-01-01 00:00:05'
)
SQL
);

$event->execute([
    'id' => $id,
]);

echo $id;
PHP
)"

[[ "$M5" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid concurrent fixture id"

MESSAGE_IDS+=(
    "$M5"
)

# ---------------------------------------------------------------------------
# Second page must continue old snapshot boundary: M2, M1.
# ---------------------------------------------------------------------------

PAGE2_HEADERS="$TMP_DIR/page2.headers"
PAGE2_BODY="$TMP_DIR/page2.body"

authenticated_get \
    "$API_ORIGIN/api/v1/messages?limit=2&createdAfter=$WINDOW_START&createdBefore=$WINDOW_END&cursor=$CURSOR" \
    "$PAGE2_HEADERS" \
    "$PAGE2_BODY"

[ "$(http_code "$PAGE2_HEADERS")" = "200" ] \
    || fail "second message page did not return 200"

PAGE2_IDS="$(
    json_item_ids \
        "$PAGE2_BODY"
)"

[ "$PAGE2_IDS" = "$M2,$M1" ] \
    || fail "cursor page is unstable or duplicated: $PAGE2_IDS"

[ "$(
    json_value \
        nextCursor \
        "$PAGE2_BODY"
)" = "null" ] \
    || fail "last cursor page unexpectedly has nextCursor"

pass "cursor pagination is stable when newer rows arrive"

# ---------------------------------------------------------------------------
# Status filter
# ---------------------------------------------------------------------------

STATUS_HEADERS="$TMP_DIR/status.headers"
STATUS_BODY="$TMP_DIR/status.body"

authenticated_get \
    "$API_ORIGIN/api/v1/messages?limit=100&status=submission_uncertain&createdAfter=$WINDOW_START&createdBefore=$WINDOW_END" \
    "$STATUS_HEADERS" \
    "$STATUS_BODY"

[ "$(http_code "$STATUS_HEADERS")" = "200" ] \
    || fail "status-filtered query failed"

[ "$(json_item_ids "$STATUS_BODY")" = "$M3" ] \
    || fail "status filter returned unexpected messages"

pass "status filter returns the expected message"

# ---------------------------------------------------------------------------
# Event filters
# ---------------------------------------------------------------------------

DELIVERED_HEADERS="$TMP_DIR/delivered.headers"
DELIVERED_BODY="$TMP_DIR/delivered.body"

authenticated_get \
    "$API_ORIGIN/api/v1/messages?limit=100&event=delivered&createdAfter=$WINDOW_START&createdBefore=$WINDOW_END" \
    "$DELIVERED_HEADERS" \
    "$DELIVERED_BODY"

[ "$(json_item_ids "$DELIVERED_BODY")" = "$M2" ] \
    || fail "delivered event filter returned unexpected messages"

BOUNCED_HEADERS="$TMP_DIR/bounced.headers"
BOUNCED_BODY="$TMP_DIR/bounced.body"

authenticated_get \
    "$API_ORIGIN/api/v1/messages?limit=100&event=bounced&createdAfter=$WINDOW_START&createdBefore=$WINDOW_END" \
    "$BOUNCED_HEADERS" \
    "$BOUNCED_BODY"

[ "$(json_item_ids "$BOUNCED_BODY")" = "$M4" ] \
    || fail "bounced event filter returned unexpected messages"

pass "delivery-event filters return expected messages"

# ---------------------------------------------------------------------------
# Date interval semantics: after is inclusive, before is exclusive.
# Should return M3 then M2 only.
# ---------------------------------------------------------------------------

DATE_HEADERS="$TMP_DIR/date.headers"
DATE_BODY="$TMP_DIR/date.body"

authenticated_get \
    "$API_ORIGIN/api/v1/messages?limit=100&createdAfter=2042-01-01T00:00:02Z&createdBefore=2042-01-01T00:00:04Z" \
    "$DATE_HEADERS" \
    "$DATE_BODY"

[ "$(json_item_ids "$DATE_BODY")" = "$M3,$M2" ] \
    || fail "date filters do not implement expected interval semantics"

pass "date filters use inclusive-after and exclusive-before semantics"

# ---------------------------------------------------------------------------
# Delivery summary in list.
# ---------------------------------------------------------------------------

[ "$(
    json_value \
        items.0.deliverySummary.tempfail \
        "$PAGE1_BODY"
)" = "1" ] \
    || fail "list summary lost TEMPFAIL count"

[ "$(
    json_value \
        items.0.deliverySummary.bounced \
        "$PAGE1_BODY"
)" = "1" ] \
    || fail "list summary lost BOUNCED count"

pass "message list exposes delivery counters without payload access"

# ---------------------------------------------------------------------------
# Tampered cursor must fail closed.
# ---------------------------------------------------------------------------

TAMPERED_CURSOR="$(
    python3 \
        - "$CURSOR" <<'PY'
import sys

cursor = sys.argv[1]

first = "A" if cursor[0] != "A" else "B"

print(
    first + cursor[1:]
)
PY
)"

TAMPER_HEADERS="$TMP_DIR/tamper.headers"
TAMPER_BODY="$TMP_DIR/tamper.body"

authenticated_get \
    "$API_ORIGIN/api/v1/messages?cursor=$TAMPERED_CURSOR" \
    "$TAMPER_HEADERS" \
    "$TAMPER_BODY"

[ "$(http_code "$TAMPER_HEADERS")" = "400" ] \
    || fail "tampered cursor was not rejected"

grep -Fq \
    '"code":"invalid_query"' \
    "$TAMPER_BODY" \
    || fail "tampered cursor did not return invalid_query"

pass "tampered HMAC cursor is rejected"

# ---------------------------------------------------------------------------
# Unknown/structured query parameters must fail closed.
# ---------------------------------------------------------------------------

UNKNOWN_HEADERS="$TMP_DIR/unknown.headers"
UNKNOWN_BODY="$TMP_DIR/unknown.body"

authenticated_get \
    "$API_ORIGIN/api/v1/messages?unexpected=value" \
    "$UNKNOWN_HEADERS" \
    "$UNKNOWN_BODY"

[ "$(http_code "$UNKNOWN_HEADERS")" = "400" ] \
    || fail "unknown query parameter was accepted"

ARRAY_HEADERS="$TMP_DIR/array.headers"
ARRAY_BODY="$TMP_DIR/array.body"

authenticated_get \
    "$API_ORIGIN/api/v1/messages?status%5B%5D=submitted" \
    "$ARRAY_HEADERS" \
    "$ARRAY_BODY"

[ "$(http_code "$ARRAY_HEADERS")" = "400" ] \
    || fail "structured query parameter was accepted"

pass "query surface rejects unexpected and structured parameters"

# ---------------------------------------------------------------------------
# Detail + immutable timeline.
# ---------------------------------------------------------------------------

DETAIL_HEADERS="$TMP_DIR/detail.headers"
DETAIL_BODY="$TMP_DIR/detail.body"

authenticated_get \
    "$API_ORIGIN/api/v1/messages/$M4" \
    "$DETAIL_HEADERS" \
    "$DETAIL_BODY"

[ "$(http_code "$DETAIL_HEADERS")" = "200" ] \
    || fail "message detail did not return 200"

[ "$(
    json_value \
        messageId \
        "$DETAIL_BODY"
)" = "$M4" ] \
    || fail "detail returned wrong message"

[ "$(
    json_value \
        status \
        "$DETAIL_BODY"
)" = "submitted" ] \
    || fail "detail returned wrong status"

[ "$(
    json_value \
        deliverySummary.delivered \
        "$DETAIL_BODY"
)" = "0" ] \
    || fail "detail has wrong DELIVERED count"

[ "$(
    json_value \
        deliverySummary.tempfail \
        "$DETAIL_BODY"
)" = "1" ] \
    || fail "detail has wrong TEMPFAIL count"

[ "$(
    json_value \
        deliverySummary.bounced \
        "$DETAIL_BODY"
)" = "1" ] \
    || fail "detail has wrong BOUNCED count"

EVENT_TYPES="$(
    python3 \
        - "$DETAIL_BODY" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    payload = json.load(handle)

print(
    ">".join(
        event["type"]
        for event in payload["events"]
    )
)
PY
)"

[ "$EVENT_TYPES" = \
    "queued>ready_for_submission>submitting>submitted>tempfail>bounced" ] \
    || fail "detail timeline is incomplete or unordered: $EVENT_TYPES"

pass "detail exposes ordered lifecycle and delivery timeline"

# ---------------------------------------------------------------------------
# Security gate: query API must not expose internal correlation/secrets.
# ---------------------------------------------------------------------------

for FORBIDDEN_FIELD in \
    sourceEventId \
    idempotencyKeyHash \
    encryptedPayload \
    ciphertext \
    nonce
do
    if grep -Fq \
        "$FORBIDDEN_FIELD" \
        "$DETAIL_BODY"
    then
        fail "detail leaked internal field: $FORBIDDEN_FIELD"
    fi

    if grep -Fq \
        "$FORBIDDEN_FIELD" \
        "$PAGE1_BODY"
    then
        fail "list leaked internal field: $FORBIDDEN_FIELD"
    fi
done

grep -Fq \
    '"recipientHash":"' \
    "$DETAIL_BODY" \
    || fail "delivery event does not expose recipient hash"

grep -Fq \
    'recipient-bounced@example.test' \
    "$DETAIL_BODY" \
    && fail "detail leaked plaintext recipient"

pass "query API exposes hashes but no internal correlation or plaintext recipient"

echo
echo "PAGE_1=$PAGE1_IDS"
echo "PAGE_2=$PAGE2_IDS"
echo "DETAIL_TIMELINE=$EVENT_TYPES"
echo
echo "ALL MESSAGE QUERY API E2E TESTS PASSED"
