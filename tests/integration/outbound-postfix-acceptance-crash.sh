#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." &&
    pwd
)"

cd "$ROOT_DIR"

API_ORIGIN="https://api.heymail.test:8443"

TMP_DIR="$(
    mktemp -d /tmp/heymail-postfix-crash.XXXXXX
)"

OUTBOUND_ID=""
TRIGGER_INSTALLED="false"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

admin_psql() {
    docker compose exec \
        -T \
        database \
        sh -c '
            export PGPASSWORD="$(
                cat /run/secrets/postgres_password
            )"

            exec psql \
                -h 127.0.0.1 \
                -U "$POSTGRES_USER" \
                -d "$POSTGRES_DB" \
                -v ON_ERROR_STOP=1 \
                "$@"
        ' \
        sh \
        "$@"
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
    local field="$1"
    local file="$2"

    python3 \
        - "$field" "$file" <<'PY'
import json
import sys

field = sys.argv[1]
path = sys.argv[2]

with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

value = data[field]

if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

db_status() {
    admin_psql \
        -At \
        -v target_id="$OUTBOUND_ID" <<'SQL'
SELECT status
FROM outbound_message
WHERE id = :'target_id';
SQL
}

capture_count() {
    docker compose exec \
        -T \
        -e MARKER="$MARKER" \
        fake-mx-success \
        sh -c '
            count=0

            for file in /capture/messages/*.eml
            do
                [ -f "$file" ] || continue

                if grep -aFq "$MARKER" "$file"
                then
                    count=$((count + 1))
                fi
            done

            printf "%s\n" "$count"
        '
}

drop_fault_trigger() {
    admin_psql >/dev/null 2>&1 <<'SQL' || true
DROP TRIGGER IF EXISTS
    heymail_test_delay_submitted
    ON outbound_message;

DROP FUNCTION IF EXISTS
    heymail_test_delay_submitted();
SQL

    TRIGGER_INSTALLED="false"
}

cleanup() {
    local result=$?

    trap - EXIT
    set +e

    docker compose kill \
        -s SIGKILL \
        mail-worker \
        >/dev/null 2>&1

    drop_fault_trigger

    if [ -n "${OUTBOUND_ID:-}" ]
    then
        admin_psql \
            -v target_id="$OUTBOUND_ID" \
            >/dev/null 2>&1 <<'SQL'
DELETE FROM messenger_messages
WHERE body::jsonb ->> 'outboundMessageId'
    = :'target_id';

DELETE FROM outbound_message_payload
WHERE outbound_message_id = :'target_id';

DELETE FROM outbound_message
WHERE id = :'target_id';
SQL
    fi

    docker compose start \
        mail-worker \
        >/dev/null 2>&1 \
        || true

    rm -rf "$TMP_DIR"

    exit "$result"
}

trap cleanup EXIT

echo "=== HeyMail crash after Postfix acceptance ==="

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

pass "complete outbound laboratory is ready"

docker compose stop \
    mail-worker \
    >/dev/null

pass "worker stopped before test message creation"

docker compose exec \
    -T \
    fake-mx-success \
    sh -c '
        rm -rf /capture/messages
        rm -f /capture/last.eml

        mkdir -p /capture/messages
        chmod 0700 /capture/messages
    '

pass "fake MX delivery history reset"

TOKEN="$(
    python3 - <<'PY'
import secrets

print(secrets.token_hex(16))
PY
)"

IDEMPOTENCY_KEY="postfix-crash-$TOKEN"
MARKER="HEYMAIL-POSTFIX-CRASH-$TOKEN"

AUTH_CONFIG="$TMP_DIR/auth.conf"

AUTH_B64="$(
    printf '%s:%s' \
        "$(cat secrets/api_key)" \
        "$(cat secrets/api_secret)" |
    base64 -w 0
)"

printf \
    'header = "Authorization: Basic %s"\n' \
    "$AUTH_B64" \
    > "$AUTH_CONFIG"

chmod 0600 "$AUTH_CONFIG"

unset AUTH_B64

PAYLOAD="$TMP_DIR/payload.json"

python3 \
    - "$MARKER" \
    > "$PAYLOAD" <<'PY'
import json
import sys

marker = sys.argv[1]

print(
    json.dumps(
        {
            "from": {
                "email": "sender@heymail.test",
                "name": "HeyMail",
            },
            "to": [
                {
                    "email": "postfix-crash@success.test",
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

CREATE_HTTP="$(
    http_code "$CREATE_HEADERS"
)"

[ "$CREATE_HTTP" = "202" ] \
    || fail "initial HTTPS submission returned HTTP $CREATE_HTTP"

OUTBOUND_ID="$(
    json_field \
        messageId \
        "$CREATE_BODY"
)"

[[ "$OUTBOUND_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "Send API returned an invalid messageId"

pass "created outbound message $OUTBOUND_ID"

INITIAL_STATUS="$(
    db_status
)"

[ "$INITIAL_STATUS" = "queued" ] \
    || fail "initial status is $INITIAL_STATUS instead of queued"

pass "message is durably QUEUED"

drop_fault_trigger

admin_psql \
    -v target_id="$OUTBOUND_ID" \
    >/dev/null <<'SQL'
CREATE FUNCTION heymail_test_delay_submitted()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM pg_sleep(45);

    RETURN NEW;
END;
$$;

CREATE TRIGGER heymail_test_delay_submitted
BEFORE UPDATE OF status
ON outbound_message
FOR EACH ROW
WHEN (
    OLD.status = 'submitting'
    AND NEW.status = 'submitted'
    AND NEW.id = :target_id
)
EXECUTE FUNCTION heymail_test_delay_submitted();
SQL

TRIGGER_INSTALLED="true"

pass "installed controlled final-commit delay"

docker compose start \
    mail-worker \
    >/dev/null

pass "worker started"

SUBMITTING_SEEN="false"

for _ in $(seq 1 150)
do
    STATUS="$(
        db_status
    )"

    if [ "$STATUS" = "submitting" ]
    then
        SUBMITTING_SEEN="true"
        break
    fi

    sleep 0.1
done

[ "$SUBMITTING_SEEN" = "true" ] \
    || fail "SUBMITTING was never durably observed"

pass "SUBMITTING persisted before SMTP outcome"

SMTP_SEEN="false"

for _ in $(seq 1 300)
do
    COPIES="$(
        capture_count
    )"

    if [ "$COPIES" = "1" ]
    then
        SMTP_SEEN="true"
        break
    fi

    if [ "$COPIES" -gt 1 ]
    then
        fail "duplicate already detected before crash: $COPIES copies"
    fi

    sleep 0.1
done

[ "$SMTP_SEEN" = "true" ] \
    || fail "message never reached fake MX"

pass "Postfix delivered exactly one copy before crash"

BLOCKED_UPDATE="false"

for _ in $(seq 1 150)
do
    ACTIVE="$(
        admin_psql \
            -At <<'SQL'
SELECT COUNT(*)
FROM pg_stat_activity
WHERE usename = 'heymail_app'
  AND state = 'active'
  AND query ~* 'UPDATE[[:space:]]+outbound_message';
SQL
    )"

    if [ "$ACTIVE" -ge 1 ]
    then
        BLOCKED_UPDATE="true"
        break
    fi

    sleep 0.1
done

[ "$BLOCKED_UPDATE" = "true" ] \
    || fail "could not observe final SUBMITTED update"

pass "worker reached post-SMTP SUBMITTED database transition"

STATUS_BEFORE_CRASH="$(
    db_status
)"

[ "$STATUS_BEFORE_CRASH" = "submitting" ] \
    || fail "durable pre-crash status is $STATUS_BEFORE_CRASH"

pass "database still reports SUBMITTING before crash"

if docker compose kill \
    -s SIGKILL \
    mail-worker \
    >/dev/null
then
    pass "worker killed with SIGKILL after SMTP delivery"
else
    fail "could not SIGKILL worker"
fi

sleep 1

STATUS_AFTER_CRASH="$(
    db_status
)"

[ "$STATUS_AFTER_CRASH" = "submitting" ] \
    || fail "status after crash is $STATUS_AFTER_CRASH"

pass "failed SUBMITTED transaction rolled back to SUBMITTING"

COPIES_AFTER_CRASH="$(
    capture_count
)"

[ "$COPIES_AFTER_CRASH" = "1" ] \
    || fail "unexpected copy count immediately after crash: $COPIES_AFTER_CRASH"

pass "exactly one SMTP copy exists after worker crash"

drop_fault_trigger

RESET_COUNT="$(
    admin_psql \
        -At \
        -v target_id="$OUTBOUND_ID" <<'SQL'
WITH reset_message AS (
    UPDATE messenger_messages
    SET
        delivered_at = NULL,
        available_at = NOW()
    WHERE queue_name = 'outbound'
      AND body::jsonb ->> 'outboundMessageId'
          = :'target_id'
    RETURNING id
)
SELECT COUNT(*)
FROM reset_message;
SQL
)"

[ "$RESET_COUNT" = "1" ] \
    || fail "expected one Messenger message to redeliver, got $RESET_COUNT"

pass "Messenger delivery made immediately available again"

docker compose start \
    mail-worker \
    >/dev/null

pass "replacement worker started"

UNCERTAIN_SEEN="false"

for _ in $(seq 1 150)
do
    FINAL_STATUS="$(
        db_status
    )"

    if [ "$FINAL_STATUS" = "submission_uncertain" ]
    then
        UNCERTAIN_SEEN="true"
        break
    fi

    sleep 0.1
done

[ "$UNCERTAIN_SEEN" = "true" ] \
    || fail "redelivery did not transition to SUBMISSION_UNCERTAIN"

pass "redelivery transitioned SUBMITTING to SUBMISSION_UNCERTAIN"

sleep 3

FINAL_CAPTURE_COUNT="$(
    capture_count
)"

[ "$FINAL_CAPTURE_COUNT" = "1" ] \
    || fail "SMTP duplicate detected: $FINAL_CAPTURE_COUNT copies"

pass "redelivery produced zero additional SMTP copies"

QUEUE_COUNT=""

for _ in $(seq 1 150)
do
    QUEUE_COUNT="$(
        admin_psql \
            -At \
            -v target_id="$OUTBOUND_ID" <<'SQL'
SELECT COUNT(*)
FROM messenger_messages
WHERE queue_name = 'outbound'
  AND body::jsonb ->> 'outboundMessageId'
      = :'target_id';
SQL
    )"

    if [ "$QUEUE_COUNT" = "0" ]
    then
        break
    fi

    sleep 0.1
done

[ "$QUEUE_COUNT" = "0" ] \
    || fail "Messenger job remains in outbound queue"

pass "ambiguous Messenger redelivery was acknowledged"

FINAL_STATUS="$(
    db_status
)"

[ "$FINAL_STATUS" = "submission_uncertain" ] \
    || fail "unexpected final state: $FINAL_STATUS"


TIMESTAMP_STATE="$(
    admin_psql \
        -At \
        -F '|' \
        -v target_id="$OUTBOUND_ID" <<'SQL'
SELECT
    CASE
        WHEN submitting_at IS NOT NULL
        THEN 'submitting-set'
        ELSE 'submitting-null'
    END,
    CASE
        WHEN submission_uncertain_at IS NOT NULL
        THEN 'uncertain-set'
        ELSE 'uncertain-null'
    END,
    CASE
        WHEN submitted_at IS NULL
        THEN 'submitted-null'
        ELSE 'submitted-set'
    END
FROM outbound_message
WHERE id = :'target_id';
SQL
)"

[ "$TIMESTAMP_STATE" = \
    "submitting-set|uncertain-set|submitted-null" ] \
    || fail "unexpected crash lifecycle timestamps: $TIMESTAMP_STATE"

pass "ambiguous lifecycle timestamps are coherent"

STATUS_HEADERS="$TMP_DIR/final-status.headers"
STATUS_BODY="$TMP_DIR/final-status.body"

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

[ "$(http_code "$STATUS_HEADERS")" = "200" ] \
    || fail "final status API request did not return 200"

API_SUBMITTING_AT="$(
    json_field \
        submittingAt \
        "$STATUS_BODY"
)"

API_UNCERTAIN_AT="$(
    json_field \
        submissionUncertainAt \
        "$STATUS_BODY"
)"

API_SUBMITTED_AT="$(
    json_field \
        submittedAt \
        "$STATUS_BODY"
)"

[ "$API_SUBMITTING_AT" != "None" ] \
    || fail "status API does not expose submittingAt"

[ "$API_UNCERTAIN_AT" != "None" ] \
    || fail "status API does not expose submissionUncertainAt"

[ "$API_SUBMITTED_AT" = "None" ] \
    || fail "uncertain message incorrectly exposes submittedAt"

pass "status API exposes ambiguous lifecycle timestamps"

echo
echo "OUTBOUND_ID=$OUTBOUND_ID"
echo "SMTP_COPIES=$FINAL_CAPTURE_COUNT"
echo "FINAL_STATUS=$FINAL_STATUS"
echo
echo "ALL POSTFIX ACCEPTANCE CRASH SAFETY TESTS PASSED"
