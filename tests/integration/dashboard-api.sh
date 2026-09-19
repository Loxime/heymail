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
        /tmp/heymail-dashboard.XXXXXX
)"

AUTH_CONFIG="$TMP_DIR/auth.conf"

MESSAGE_IDS=()
OUTBOX_WAS_RUNNING=0
WORKER_WAS_RUNNING=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

service_running() {
    SERVICE="$1"

    CONTAINER="$(
        docker compose ps \
            -q \
            "$SERVICE"
    )"

    if [ -z "$CONTAINER" ]; then
        return 1
    fi

    [ "$(
        docker inspect \
            --format '{{.State.Running}}' \
            "$CONTAINER"
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

$ids =
    array_values(
        array_filter(
            explode(
                ',',
                $raw,
            ),
            static fn (
                string $value,
            ): bool =>
                preg_match(
                    '/^[1-9][0-9]*$/D',
                    $value,
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

$stmt =
    $pdo->prepare(
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

    if [ "$OUTBOX_WAS_RUNNING" -eq 1 ]; then
        docker compose start \
            webhook-outbox \
            >/dev/null 2>&1 \
            || true
    fi

    if [ "$WORKER_WAS_RUNNING" -eq 1 ]; then
        docker compose start \
            webhook-worker \
            >/dev/null 2>&1 \
            || true
    fi

    rm -rf "$TMP_DIR"

    exit "$RESULT"
}

trap cleanup EXIT

echo "=== HeyMail dashboard API E2E ==="

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
    WORKER_WAS_RUNNING=1
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

python3 \
    - "$AUTH_CONFIG" <<'PY'
from pathlib import Path
import sys

Path(
    sys.argv[1]
).chmod(0o600)
PY

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
# Deterministic fixtures
#
# Dashboard period:
#   [2042-03-01T00:00:00Z, 2042-03-05T00:00:00Z)
#
# M0 is created before the period but BOUNCED inside it.
# M5 is exactly on the exclusive upper boundary and must be excluded.
# ---------------------------------------------------------------------------

FIXTURE="$(
    docker compose exec \
        -T \
        -e TOKEN="$TOKEN" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

$token =
    (string) getenv('TOKEN');

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
    (
        SELECT id
        FROM workspace
        WHERE name = 'HeyMail Legacy Workspace'
        ORDER BY id ASC
        LIMIT 1
    ),
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

    $message =
        static function (
            string $suffix,
            string $status,
            string $createdAt,
            ?string $readyAt = null,
            ?string $submittingAt = null,
            ?string $uncertainAt = null,
            ?string $submittedAt = null,
        ) use (
            $insertMessage,
            $token,
        ): int {
            $insertMessage->execute([
                'hash'
                    => hash(
                        'sha256',
                        $token
                            . ':'
                            . $suffix,
                    ),
                'status'
                    => $status,
                'created_at'
                    => $createdAt,
                'ready_at'
                    => $readyAt,
                'submitting_at'
                    => $submittingAt,
                'uncertain_at'
                    => $uncertainAt,
                'submitted_at'
                    => $submittedAt,
            ]);

            return (int) $insertMessage
                ->fetchColumn();
        };

    $event =
        static function (
            int $messageId,
            string $type,
            string $occurredAt,
            ?string $recipient = null,
            ?string $smtpStatus = null,
            ?string $detail = null,
            ?string $source = null,
        ) use (
            $insertEvent,
        ): int {
            $insertEvent->execute([
                'message_id'
                    => $messageId,
                'event_type'
                    => $type,
                'occurred_at'
                    => $occurredAt,
                'recipient_hash'
                    => $recipient === null
                        ? null
                        : hash(
                            'sha256',
                            strtolower(
                                $recipient,
                            ),
                        ),
                'smtp_status'
                    => $smtpStatus,
                'detail'
                    => $detail,
                'source_event_id'
                    => $source === null
                        ? null
                        : hash(
                            'sha256',
                            $source,
                        ),
            ]);

            return (int) $insertEvent
                ->fetchColumn();
        };

    /*
     * Outside message period.
     * Its delivery event IS inside the dashboard period.
     */
    $m0 =
        $message(
            'm0',
            'submitted',
            '2042-02-28 23:00:00',
            '2042-02-28 23:00:01',
            '2042-02-28 23:00:02',
            null,
            '2042-02-28 23:00:03',
        );

    $event(
        $m0,
        'submitted',
        '2042-02-28 23:00:03',
    );

    $event(
        $m0,
        'bounced',
        '2042-03-02 14:00:00',
        'outside-created@example.test',
        '5.1.1',
        '550 permanent rejection',
        $token . ':m0:bounced',
    );

    /*
     * Day 1: submitted + delivered.
     */
    $m1 =
        $message(
            'm1',
            'submitted',
            '2042-03-01 09:00:00',
            '2042-03-01 09:00:01',
            '2042-03-01 09:00:02',
            null,
            '2042-03-01 09:00:03',
        );

    $event(
        $m1,
        'submitted',
        '2042-03-01 09:00:03',
    );

    $event(
        $m1,
        'delivered',
        '2042-03-01 09:01:00',
        'one@example.test',
        '2.0.0',
        '250 accepted',
        $token . ':m1:delivered',
    );

    /*
     * Day 2: submitted + tempfail.
     * Final delivery happens day 3.
     */
    $m2 =
        $message(
            'm2',
            'submitted',
            '2042-03-02 10:00:00',
            '2042-03-02 10:00:01',
            '2042-03-02 10:00:02',
            null,
            '2042-03-02 10:00:03',
        );

    $event(
        $m2,
        'submitted',
        '2042-03-02 10:00:03',
    );

    $event(
        $m2,
        'tempfail',
        '2042-03-02 10:01:00',
        'two@example.test',
        '4.1.1',
        '450 temporary rejection',
        $token . ':m2:tempfail',
    );

    $event(
        $m2,
        'delivered',
        '2042-03-03 11:00:00',
        'two@example.test',
        '2.0.0',
        '250 accepted after retry',
        $token . ':m2:delivered',
    );

    /*
     * Day 3: submission uncertain, no delivery result.
     */
    $m3 =
        $message(
            'm3',
            'submission_uncertain',
            '2042-03-03 12:00:00',
            '2042-03-03 12:00:01',
            '2042-03-03 12:00:02',
            '2042-03-03 12:00:03',
            null,
        );

    $event(
        $m3,
        'submission_uncertain',
        '2042-03-03 12:00:03',
    );

    /*
     * Day 4: queued only.
     */
    $m4 =
        $message(
            'm4',
            'queued',
            '2042-03-04 13:00:00',
        );

    $event(
        $m4,
        'queued',
        '2042-03-04 13:00:00',
    );

    /*
     * Exact upper boundary: completely excluded.
     */
    $m5 =
        $message(
            'm5',
            'submitted',
            '2042-03-05 00:00:00',
            '2042-03-05 00:00:00',
            '2042-03-05 00:00:00',
            null,
            '2042-03-05 00:00:00',
        );

    $event(
        $m5,
        'submitted',
        '2042-03-05 00:00:00',
    );

    $event(
        $m5,
        'delivered',
        '2042-03-05 00:00:00',
        'upper-boundary@example.test',
        '2.0.0',
        '250 boundary accepted',
        $token . ':m5:delivered',
    );

    $pdo->commit();

    foreach ([
        'M0' => $m0,
        'M1' => $m1,
        'M2' => $m2,
        'M3' => $m3,
        'M4' => $m4,
        'M5' => $m5,
    ] as $name => $id) {
        echo $name,
            '=',
            $id,
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

for NAME in M0 M1 M2 M3 M4 M5
do
    ID="$(
        awk \
            -F= \
            -v name="$NAME" \
            '$1 == name { print $2 }' \
            <<<"$FIXTURE"
    )"

    [[ "$ID" =~ ^[1-9][0-9]*$ ]] \
        || fail "invalid fixture ID for $NAME"

    MESSAGE_IDS+=(
        "$ID"
    )
done

pass "seeded deterministic multi-day dashboard fixtures"

FROM='2042-03-01T00:00:00Z'
TO='2042-03-05T00:00:00Z'

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
    "$API_ORIGIN/api/v1/dashboard?from=$FROM&to=$TO"

[ "$(http_code "$UNAUTH_HEADERS")" = "401" ] \
    || fail "dashboard authentication boundary is not enforced"

pass "dashboard requires authentication"

# ---------------------------------------------------------------------------
# Main deterministic dashboard result
# ---------------------------------------------------------------------------

DASH_HEADERS="$TMP_DIR/dashboard.headers"
DASH_BODY="$TMP_DIR/dashboard.body"

authenticated_get \
    "$API_ORIGIN/api/v1/dashboard?from=$FROM&to=$TO" \
    "$DASH_HEADERS" \
    "$DASH_BODY"

[ "$(http_code "$DASH_HEADERS")" = "200" ] \
    || fail "dashboard did not return 200"

python3 \
    - "$DASH_BODY" <<'PY'
import json
import math
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    payload = json.load(handle)

assert payload["period"] == {
    "from": "2042-03-01T00:00:00+00:00",
    "to": "2042-03-05T00:00:00+00:00",
}

assert payload["messages"] == {
    "total": 4,
    "queued": 1,
    "readyForSubmission": 0,
    "submitting": 0,
    "submissionUncertain": 1,
    "submitted": 2,
}

delivery = payload["delivery"]

assert delivery["delivered"] == 2
assert delivery["tempfail"] == 1
assert delivery["bounced"] == 1
assert delivery["terminalOutcomes"] == 3

assert math.isclose(
    delivery["deliveryRate"],
    0.6667,
    abs_tol=0.00001,
)

assert math.isclose(
    delivery["bounceRate"],
    0.3333,
    abs_tol=0.00001,
)

assert payload["activity"] == [
    {
        "date": "2042-03-01",
        "submitted": 1,
        "tempfail": 0,
        "delivered": 1,
        "bounced": 0,
    },
    {
        "date": "2042-03-02",
        "submitted": 1,
        "tempfail": 1,
        "delivered": 0,
        "bounced": 1,
    },
    {
        "date": "2042-03-03",
        "submitted": 0,
        "tempfail": 0,
        "delivered": 1,
        "bounced": 0,
    },
    {
        "date": "2042-03-04",
        "submitted": 0,
        "tempfail": 0,
        "delivered": 0,
        "bounced": 0,
    },
]
PY

pass "dashboard aggregates message states correctly"
pass "delivery metrics use recipient events and terminal outcomes"
pass "daily activity is zero-filled in UTC"
pass "dashboard period uses inclusive-from and exclusive-to semantics"

# ---------------------------------------------------------------------------
# Prove event-period semantics:
# M0 was created before FROM, but its bounced event is counted.
# M5 is exactly TO and is excluded.
# ---------------------------------------------------------------------------

python3 \
    - "$DASH_BODY" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    payload = json.load(handle)

if payload["messages"]["total"] != 4:
    raise SystemExit(
        "message creation boundary semantics failed"
    )

if payload["delivery"]["bounced"] != 1:
    raise SystemExit(
        "event occurred_at semantics failed"
    )

if payload["delivery"]["delivered"] != 2:
    raise SystemExit(
        "exclusive upper event boundary failed"
    )
PY

pass "delivery aggregation is independent from message creation date"

# ---------------------------------------------------------------------------
# >90 day period rejected
# ---------------------------------------------------------------------------

RANGE_HEADERS="$TMP_DIR/range.headers"
RANGE_BODY="$TMP_DIR/range.body"

authenticated_get \
    "$API_ORIGIN/api/v1/dashboard?from=2042-01-01T00:00:00Z&to=2042-05-01T00:00:00Z" \
    "$RANGE_HEADERS" \
    "$RANGE_BODY"

[ "$(http_code "$RANGE_HEADERS")" = "400" ] \
    || fail "dashboard accepted period longer than 90 days"

grep -Fq \
    '"code":"invalid_query"' \
    "$RANGE_BODY" \
    || fail "long dashboard period did not return invalid_query"

pass "dashboard rejects periods longer than 90 days"

# ---------------------------------------------------------------------------
# Partial periods and unexpected parameters rejected
# ---------------------------------------------------------------------------

PARTIAL_HEADERS="$TMP_DIR/partial.headers"
PARTIAL_BODY="$TMP_DIR/partial.body"

authenticated_get \
    "$API_ORIGIN/api/v1/dashboard?from=$FROM" \
    "$PARTIAL_HEADERS" \
    "$PARTIAL_BODY"

[ "$(http_code "$PARTIAL_HEADERS")" = "400" ] \
    || fail "dashboard accepted only one period boundary"

UNKNOWN_HEADERS="$TMP_DIR/unknown.headers"
UNKNOWN_BODY="$TMP_DIR/unknown.body"

authenticated_get \
    "$API_ORIGIN/api/v1/dashboard?from=$FROM&to=$TO&foo=bar" \
    "$UNKNOWN_HEADERS" \
    "$UNKNOWN_BODY"

[ "$(http_code "$UNKNOWN_HEADERS")" = "400" ] \
    || fail "dashboard accepted unexpected query parameter"

ARRAY_HEADERS="$TMP_DIR/array.headers"
ARRAY_BODY="$TMP_DIR/array.body"

authenticated_get \
    "$API_ORIGIN/api/v1/dashboard?from%5B%5D=$FROM&to=$TO" \
    "$ARRAY_HEADERS" \
    "$ARRAY_BODY"

[ "$(http_code "$ARRAY_HEADERS")" = "400" ] \
    || fail "dashboard accepted structured query parameter"

pass "dashboard query surface fails closed"

# ---------------------------------------------------------------------------
# Security: response is aggregate-only.
# ---------------------------------------------------------------------------

for FORBIDDEN in \
    recipientHash \
    smtpStatus \
    detail \
    sourceEventId \
    idempotency \
    ciphertext \
    secret
do
    if grep -Fiq \
        "$FORBIDDEN" \
        "$DASH_BODY"
    then
        fail "dashboard leaked non-aggregate field: $FORBIDDEN"
    fi
done

pass "dashboard exposes aggregate data only"

echo
echo "MESSAGES=4"
echo "DELIVERED=2"
echo "TEMPFAIL=1"
echo "BOUNCED=1"
echo "DELIVERY_RATE=0.6667"
echo "BOUNCE_RATE=0.3333"
echo
echo "ALL DASHBOARD API E2E TESTS PASSED"
