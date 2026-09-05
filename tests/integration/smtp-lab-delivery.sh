#!/usr/bin/env bash

set -euo pipefail

echo "=== HeyMail SMTP laboratory delivery tests ==="

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

wait_for_postfix_health() {
    local container="$1"
    local health=""

    for _ in $(seq 1 30); do
        health="$(
            docker inspect "$container" \
                --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
        )"

        case "$health" in
            healthy)
                return 0
                ;;
            unhealthy)
                docker compose logs --tail=100 postfix >&2 || true
                return 1
                ;;
        esac

        sleep 1
    done

    return 1
}

wait_for_recipient_status() {
    local recipient="$1"
    local expected_status="$2"
    local logs=""
    local matching_lines=""

    for _ in $(seq 1 20); do
        logs="$(
            docker compose logs \
                --no-color \
                postfix \
                2>/dev/null \
                || true
        )"

        matching_lines="$(
            grep -F -- "$recipient" <<<"$logs" \
                || true
        )"

        if [[ "$matching_lines" == *"status=${expected_status}"* ]]; then
            return 0
        fi

        sleep 1
    done

    echo "$logs" >&2
    return 1
}

queue_contains() {
    local recipient="$1"
    local queue=""

    queue="$(
        docker compose exec -T postfix postqueue -p
    )"

    [[ "$queue" == *"$recipient"* ]]
}

send_test_message() {
    local recipient="$1"
    local subject="$2"
    local body="$3"

    timeout 15s \
        docker compose exec -T postfix \
        /usr/sbin/sendmail \
        -f '<>' \
        -- "$recipient" <<MAIL
From: lab@heymail.test
To: ${recipient}
Subject: ${subject}

${body}
MAIL
}

docker compose config --quiet \
    || fail "Compose configuration is invalid"

docker compose up -d \
    fake-mx-success \
    fake-mx-tempfail \
    fake-mx-permfail \
    postfix \
    >/dev/null

POSTFIX_CONTAINER="$(docker compose ps -q postfix)"

[ -n "$POSTFIX_CONTAINER" ] \
    || fail "Postfix container does not exist"

wait_for_postfix_health "$POSTFIX_CONTAINER" \
    || fail "Postfix did not become healthy"

pass "Postfix is healthy"

docker compose exec -T postfix \
    postsuper -d ALL \
    >/dev/null 2>&1 \
    || true

RUN_ID="$(date +%s)-$$"

SUCCESS_RECIPIENT="heymail-success-${RUN_ID}@success.test"
TEMPFAIL_RECIPIENT="heymail-tempfail-${RUN_ID}@tempfail.test"
PERMFAIL_RECIPIENT="heymail-permfail-${RUN_ID}@permfail.test"
FORBIDDEN_RECIPIENT="heymail-forbidden-${RUN_ID}@example.com"

# ---------------------------------------------------------------------------
# 250 success
# ---------------------------------------------------------------------------

send_test_message \
    "$SUCCESS_RECIPIENT" \
    "HeyMail automated success test ${RUN_ID}" \
    "Expected result: successful SMTP delivery."

wait_for_recipient_status \
    "$SUCCESS_RECIPIENT" \
    "sent" \
    || fail "success.test was not delivered successfully"

if queue_contains "$SUCCESS_RECIPIENT"; then
    fail "success.test message remained in queue"
fi

pass "250 response produces status=sent and removes message from queue"

# ---------------------------------------------------------------------------
# 450 temporary failure
# ---------------------------------------------------------------------------

send_test_message \
    "$TEMPFAIL_RECIPIENT" \
    "HeyMail automated temporary failure test ${RUN_ID}" \
    "Expected result: deferred SMTP delivery."

wait_for_recipient_status \
    "$TEMPFAIL_RECIPIENT" \
    "deferred" \
    || fail "tempfail.test was not deferred"

queue_contains "$TEMPFAIL_RECIPIENT" \
    || fail "450 message was not retained in queue"

pass "450 response produces status=deferred and retains message"

docker compose exec -T postfix \
    postsuper -d ALL \
    >/dev/null

# ---------------------------------------------------------------------------
# 550 permanent failure
# ---------------------------------------------------------------------------

send_test_message \
    "$PERMFAIL_RECIPIENT" \
    "HeyMail automated permanent failure test ${RUN_ID}" \
    "Expected result: permanent SMTP failure."

wait_for_recipient_status \
    "$PERMFAIL_RECIPIENT" \
    "bounced" \
    || fail "permfail.test was not treated as permanent failure"

if queue_contains "$PERMFAIL_RECIPIENT"; then
    fail "550 message remained in queue"
fi

pass "550 response produces status=bounced and removes message from queue"

# ---------------------------------------------------------------------------
# Forbidden Internet domain
# ---------------------------------------------------------------------------

send_test_message \
    "$FORBIDDEN_RECIPIENT" \
    "HeyMail automated forbidden domain test ${RUN_ID}" \
    "This message must never leave the SMTP laboratory."

wait_for_recipient_status \
    "$FORBIDDEN_RECIPIENT" \
    "bounced" \
    || fail "forbidden domain was not rejected"

LOGS="$(
    docker compose logs \
        --no-color \
        postfix
)"

FORBIDDEN_LINE="$(
    grep -F -- "$FORBIDDEN_RECIPIENT" <<<"$LOGS" \
        | tail -n 1 \
        || true
)"

[[ "$FORBIDDEN_LINE" == *"postfix/error["* ]] \
    || fail "forbidden domain did not use the local error transport"

[[ "$FORBIDDEN_LINE" == *"relay=none"* ]] \
    || fail "forbidden domain unexpectedly attempted a relay"

[[ "$FORBIDDEN_LINE" == *"Outbound delivery outside HeyMail SMTP lab is disabled"* ]] \
    || fail "expected laboratory transport rejection was not observed"

pass "non-laboratory domain is rejected locally without SMTP relay"

# ---------------------------------------------------------------------------
# Final queue state
# ---------------------------------------------------------------------------

FINAL_QUEUE="$(
    docker compose exec -T postfix postqueue -p
)"

[[ "$FINAL_QUEUE" == *"Mail queue is empty"* ]] \
    || fail "Postfix queue is not empty after tests"

pass "Postfix queue is empty"

echo
echo "ALL SMTP LABORATORY DELIVERY TESTS PASSED"
