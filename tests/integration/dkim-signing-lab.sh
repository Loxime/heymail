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

wait_for_health() {
    local service="$1"
    local container=""
    local health=""

    container="$(
        docker compose ps -q "$service"
    )"

    [ -n "$container" ] \
        || return 1

    for _ in $(seq 1 120)
    do
        health="$(
            docker inspect "$container" \
                --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
        )"

        case "$health" in
            healthy)
                return 0
                ;;

            unhealthy)
                return 1
                ;;
        esac

        sleep 2
    done

    return 1
}

clear_capture() {
    docker compose exec -T fake-mx-success \
        rm -f /capture/last.eml \
        >/dev/null 2>&1 \
        || true
}

capture_exists() {
    docker compose exec -T fake-mx-success \
        test -s /capture/last.eml
}

capture_contains() {
    local value="$1"

    docker compose exec -T fake-mx-success \
        grep -aF "$value" /capture/last.eml \
        >/dev/null 2>&1
}

wait_for_capture() {
    local value="$1"

    for _ in $(seq 1 30)
    do
        if capture_exists \
            && capture_contains "$value"
        then
            return 0
        fi

        sleep 1
    done

    return 1
}

queue_contains() {
    local recipient="$1"

    docker compose exec -T postfix \
        postqueue -p \
        | grep -F "$recipient" \
        >/dev/null
}

send_message() {
    local recipient="$1"
    local subject="$2"
    local body="$3"

    timeout 20s \
        docker compose exec -T postfix \
        /usr/sbin/sendmail \
        -f 'lab@heymail.test' \
        -- "$recipient" <<MAIL
From: lab@heymail.test
To: ${recipient}
Subject: ${subject}

${body}
MAIL
}

verify_capture() {
    docker compose exec -T fake-mx-success \
        cat /capture/last.eml \
        | docker compose run \
            --rm \
            --no-deps \
            -T \
            dkim-verifier
}


echo "=== HeyMail DKIM signing integration tests ==="

docker compose config --quiet \
    || fail "Compose configuration is invalid"

COMPOSE_JSON="$(
    docker compose config --format json
)"

if python3 -c '
import json
import sys

config = json.load(sys.stdin)
verifier = config["services"]["dkim-verifier"]

assert verifier["network_mode"] == "none"
assert str(verifier["user"]) == "10002:10002"
assert verifier["read_only"] is True
assert verifier.get("privileged", False) is False
assert set(verifier.get("cap_drop") or []) == {"ALL"}

security_opt = verifier.get("security_opt") or []

assert "no-new-privileges:true" in security_opt

volumes = verifier.get("volumes") or []

assert len(volumes) == 1

public = volumes[0]

assert public.get("type") == "volume"
assert public.get("source") == "rspamd_dkim_public"
assert public.get("target") == "/public"
assert public.get("read_only") is True
' <<<"$COMPOSE_JSON"
then
    pass "DKIM verifier is offline, non-root and public-key-only"
else
    fail "DKIM verifier trust boundary is invalid"
fi

docker compose build \
    dkim-verifier \
    >/dev/null

docker compose up \
    -d \
    --build \
    fake-mx-success \
    fake-mx-tempfail \
    fake-mx-permfail \
    rspamd \
    postfix \
    >/dev/null

wait_for_health rspamd \
    || fail "Rspamd did not become healthy"

wait_for_health postfix \
    || fail "Postfix did not become healthy"

wait_for_health fake-mx-success \
    || fail "fake-mx-success did not become healthy"

pass "DKIM laboratory services are healthy"


POSTFIX_NETWORKS="$(
    docker compose exec -T postfix \
        sh -lc 'hostname' \
        >/dev/null

    POSTFIX_CONTAINER="$(
        docker compose ps -q postfix
    )"

    docker inspect "$POSTFIX_CONTAINER" \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        | sed '/^[[:space:]]*$/d' \
        | sort
)"

EXPECTED_POSTFIX_NETWORKS="$(
    printf '%s\n' \
        heymail_filter \
        heymail_smtp_lab \
        | sort
)"

[ "$POSTFIX_NETWORKS" = "$EXPECTED_POSTFIX_NETWORKS" ] \
    || fail "unexpected Postfix network boundary"

pass "Postfix bridges only smtp_lab_net and filter_net"


docker compose exec -T postfix \
    postsuper -d ALL \
    >/dev/null 2>&1 \
    || true

clear_capture

RUN_ID="$(date +%s)-$$"

RECIPIENT="dkim-${RUN_ID}@success.test"
BODY_MARKER="DKIM-INTEGRITY-${RUN_ID}"

send_message \
    "$RECIPIENT" \
    "HeyMail DKIM integration ${RUN_ID}" \
    "$BODY_MARKER" \
    || fail "signed message submission failed"

wait_for_capture "$BODY_MARKER" \
    || fail "signed message was not captured by fake MX"

docker compose exec -T fake-mx-success \
    grep -a '^DKIM-Signature:' \
    /capture/last.eml \
    >/dev/null \
    || fail "captured message has no DKIM-Signature header"

docker compose exec -T fake-mx-success \
    grep -aE \
        '^DKIM-Signature: .*a=rsa-sha256;' \
        /capture/last.eml \
    >/dev/null \
    || fail "DKIM signature does not use rsa-sha256"

capture_contains 'd=heymail.test' \
    || fail "DKIM signature does not use d=heymail.test"

capture_contains 's=lab' \
    || fail "DKIM signature does not use selector s=lab"

pass "captured SMTP message uses the expected DKIM domain and selector"


verify_capture \
    || fail "DKIM signature failed cryptographic verification"

pass "captured DKIM signature is cryptographically valid"


# ---------------------------------------------------------------------------
# Tamper resistance
# ---------------------------------------------------------------------------

capture_contains "$BODY_MARKER" \
    || fail "body marker is absent before tamper test"

set +e

docker compose exec -T fake-mx-success \
    cat /capture/last.eml \
    | python3 -c '
import sys

old = sys.argv[1].encode("ascii")
data = sys.stdin.buffer.read()

if old not in data:
    raise SystemExit(2)

sys.stdout.buffer.write(
    data.replace(
        old,
        b"DKIM-TAMPERED-CONTENT",
        1,
    )
)
' "$BODY_MARKER" \
    | docker compose run \
        --rm \
        --no-deps \
        -T \
        dkim-verifier

PIPELINE_STATUS=("${PIPESTATUS[@]}")

set -e

[ "${PIPELINE_STATUS[0]}" -eq 0 ] \
    || fail "could not read captured message for tamper test"

[ "${PIPELINE_STATUS[1]}" -eq 0 ] \
    || fail "tamper transformation failed"

[ "${PIPELINE_STATUS[2]}" -ne 0 ] \
    || fail "tampered message still has a valid DKIM signature"

pass "body tampering invalidates the DKIM signature"


# ---------------------------------------------------------------------------
# Fail-closed behaviour when Rspamd is unavailable
# ---------------------------------------------------------------------------

clear_capture

OUTAGE_RECIPIENT="dkim-outage-${RUN_ID}@success.test"
OUTAGE_MARKER="DKIM-OUTAGE-${RUN_ID}"

docker compose stop rspamd \
    >/dev/null

if send_message \
    "$OUTAGE_RECIPIENT" \
    "HeyMail DKIM outage ${RUN_ID}" \
    "$OUTAGE_MARKER"
then
    OUTAGE_SEND_STATUS=0
else
    OUTAGE_SEND_STATUS=$?
fi

sleep 2

if capture_exists; then
    fail "message reached fake MX while Rspamd was unavailable"
fi

pass "no message reaches fake MX while signer is unavailable"


if queue_contains "$OUTAGE_RECIPIENT"; then
    OUTAGE_OUTCOME="queued"
else
    OUTAGE_OUTCOME="rejected"

    [ "$OUTAGE_SEND_STATUS" -ne 0 ] \
        || fail "message disappeared without queueing or submission failure"
fi

printf 'Observed fail-closed outcome: %s\n' \
    "$OUTAGE_OUTCOME"


docker compose start rspamd \
    >/dev/null

wait_for_health rspamd \
    || fail "Rspamd did not recover after outage"

case "$OUTAGE_OUTCOME" in
    queued)
        # Postfix may retry automatically as soon as the Milter becomes
        # available again. The capture was already cleared before the
        # outage, so an outage marker appearing now is valid evidence of
        # successful fail-closed recovery.
        if wait_for_capture "$OUTAGE_MARKER"; then
            pass "queued outage message was delivered automatically after signer recovery"

        elif queue_contains "$OUTAGE_RECIPIENT"; then
            docker compose exec -T postfix \
                postqueue -f \
                >/dev/null

            wait_for_capture "$OUTAGE_MARKER" \
                || fail "queued outage message was not delivered after explicit queue flush"

            pass "queued outage message was delivered after explicit queue flush"

        else
            fail "queued outage message disappeared after signer recovery"
        fi
        ;;

    rejected)
        clear_capture

        send_message \
            "$OUTAGE_RECIPIENT" \
            "HeyMail DKIM outage retry ${RUN_ID}" \
            "$OUTAGE_MARKER" \
            || fail "message resubmission failed after signer recovery"

        wait_for_capture "$OUTAGE_MARKER" \
            || fail "resubmitted message was not delivered after signer recovery"
        ;;
esac

verify_capture \
    || fail "post-outage message was delivered without valid DKIM"

pass "post-outage delivery is cryptographically DKIM signed"


# ---------------------------------------------------------------------------
# Signing-policy enforcement
# ---------------------------------------------------------------------------

echo
echo "=== DKIM signing-policy enforcement ==="


# A legitimate null reverse-path must still receive a valid DKIM signature.
docker compose exec -T postfix \
    postsuper -d ALL \
    >/dev/null 2>&1 \
    || true

clear_capture

NULL_RUN_ID="null-${RUN_ID}"
NULL_RECIPIENT="dkim-${NULL_RUN_ID}@success.test"
NULL_MARKER="HEYMAIL-NULL-${NULL_RUN_ID}"

timeout 20s \
    docker compose exec -T postfix \
    /usr/sbin/sendmail \
    -f '<>' \
    -- "$NULL_RECIPIENT" <<MAIL
From: lab@heymail.test
To: ${NULL_RECIPIENT}
Subject: HeyMail null-envelope signing test

${NULL_MARKER}
MAIL

wait_for_capture "$NULL_MARKER" \
    || fail "null-envelope message was not delivered"

docker compose exec -T fake-mx-success \
    grep -aE \
        '^DKIM-Signature: .*a=rsa-sha256;' \
        /capture/last.eml \
    >/dev/null \
    || fail "null-envelope message escaped without rsa-sha256 DKIM"

verify_capture \
    || fail "null-envelope message has invalid DKIM signature"

pass "null-envelope message is delivered with valid rsa-sha256 DKIM"


# A header/envelope domain mismatch must never reach the MX unsigned.
docker compose exec -T postfix \
    postsuper -d ALL \
    >/dev/null 2>&1 \
    || true

clear_capture

MISMATCH_RUN_ID="mismatch-${RUN_ID}"
MISMATCH_RECIPIENT="dkim-${MISMATCH_RUN_ID}@success.test"
MISMATCH_MARKER="HEYMAIL-MISMATCH-${MISMATCH_RUN_ID}"

if timeout 20s \
    docker compose exec -T postfix \
    /usr/sbin/sendmail \
    -f 'lab@heymail.test' \
    -- "$MISMATCH_RECIPIENT" <<MAIL
From: attacker@other.test
To: ${MISMATCH_RECIPIENT}
Subject: HeyMail mismatch enforcement test

${MISMATCH_MARKER}
MAIL
then
    MISMATCH_STATUS=0
else
    MISMATCH_STATUS=$?
fi

sleep 7

if capture_contains "$MISMATCH_MARKER"; then
    fail "mismatched From message reached fake MX"
fi

if queue_contains "$MISMATCH_RECIPIENT"; then
    pass "mismatched From message is fail-closed in Postfix queue"
elif [ "$MISMATCH_STATUS" -ne 0 ]; then
    pass "mismatched From message was rejected during submission"
else
    fail "mismatched message vanished without delivery, queueing or rejection"
fi


# Multiple From headers must also never escape unsigned.
docker compose exec -T postfix \
    postsuper -d ALL \
    >/dev/null 2>&1 \
    || true

clear_capture

MULTI_RUN_ID="multi-from-${RUN_ID}"
MULTI_RECIPIENT="dkim-${MULTI_RUN_ID}@success.test"
MULTI_MARKER="HEYMAIL-MULTIFROM-${MULTI_RUN_ID}"

if timeout 20s \
    docker compose exec -T postfix \
    /usr/sbin/sendmail \
    -f 'lab@heymail.test' \
    -- "$MULTI_RECIPIENT" <<MAIL
From: lab@heymail.test
From: attacker@other.test
To: ${MULTI_RECIPIENT}
Subject: HeyMail multiple-From enforcement test

${MULTI_MARKER}
MAIL
then
    MULTI_STATUS=0
else
    MULTI_STATUS=$?
fi

sleep 7

if capture_contains "$MULTI_MARKER"; then
    fail "multiple-From message reached fake MX"
fi

if queue_contains "$MULTI_RECIPIENT"; then
    pass "multiple-From message is fail-closed in Postfix queue"
elif [ "$MULTI_STATUS" -ne 0 ]; then
    pass "multiple-From message was rejected during submission"
else
    fail "multiple-From message vanished without delivery, queueing or rejection"
fi


# Leave the laboratory clean.
docker compose exec -T postfix \
    postsuper -d ALL \
    >/dev/null 2>&1 \
    || true

clear_capture

FINAL_QUEUE="$(
    docker compose exec -T postfix \
        postqueue -p
)"

grep -F \
    'Mail queue is empty' \
    <<<"$FINAL_QUEUE" \
    >/dev/null \
    || fail "Postfix queue is not empty after DKIM policy tests"

pass "DKIM signing-policy enforcement is fail-closed"


echo
echo "ALL DKIM SIGNING INTEGRATION TESTS PASSED"
