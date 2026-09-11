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

TEMP_DIR="$(
    mktemp \
        -d \
        /tmp/heymail-domain-verification.XXXXXX
)"

AUTH_CONFIG="$TEMP_DIR/auth.conf"
CREATE_BODY="$TEMP_DIR/create.json"
GET_BODY="$TEMP_DIR/get.json"
VERIFY_BODY="$TEMP_DIR/verify.json"

cleanup() {
    set +e

    printf '{}\n' \
        | docker compose exec \
            -T \
            fake-dns \
            sh -c \
            'cat > /records/records.json' \
            >/dev/null 2>&1

    rm -rf \
        "$TEMP_DIR"
}

trap cleanup EXIT

chmod 0700 \
    "$TEMP_DIR"

API_KEY="$(
    cat secrets/api_key
)"

API_SECRET="$(
    cat secrets/api_secret
)"

AUTH_B64="$(
    printf '%s:%s' \
        "$API_KEY" \
        "$API_SECRET" \
        | base64 -w 0
)"

printf \
    'header = "Authorization: Basic %s"\n' \
    "$AUTH_B64" \
    > "$AUTH_CONFIG"

chmod 0600 \
    "$AUTH_CONFIG"

unset \
    API_KEY \
    API_SECRET \
    AUTH_B64

BASE_URL='https://api.heymail.test:8443'

curl_request() {
    local method="$1"
    local path="$2"
    local output="$3"
    local authenticated="${4-yes}"

    local args=(
        curl
        --noproxy '*'
        --silent
        --show-error
        --cacert secrets/gateway_tls_cert.pem
        --resolve api.heymail.test:8443:127.0.0.1
        --request "$method"
        --output "$output"
        --write-out '%{http_code}'
    )

    if [ "$authenticated" = "yes" ]
    then
        args+=(
            --config "$AUTH_CONFIG"
        )
    fi

    args+=(
        "${BASE_URL}${path}"
    )

    "${args[@]}"
}

set_dns_record() {
    local name="$1"
    local value="$2"

    python3 \
        - "$name" "$value" <<'PY' \
        | docker compose exec \
            -T \
            fake-dns \
            sh -c \
            'cat > /records/records.json'
import json
import sys

name, value = sys.argv[1:3]

print(
    json.dumps(
        {
            name: [
                value,
            ],
        },
        separators=(",", ":"),
    )
)
PY
}

clear_dns_records() {
    printf '{}\n' \
        | docker compose exec \
            -T \
            fake-dns \
            sh -c \
            'cat > /records/records.json'
}

LAST_STATUS=''
LAST_CHECKED=''
LAST_VERIFIED=''

read_current_domain() {
    local id="$1"

    local code

    code="$(
        curl_request \
            GET \
            "/api/v1/domains/${id}" \
            "$GET_BODY"
    )"

    [ "$code" = "200" ] \
        || fail "domain GET returned HTTP $code"

    mapfile -t STATE < <(
        python3 \
            - "$GET_BODY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

print(data["status"])
print(data["verificationCheckedAt"] or "null")
print(data["verifiedAt"] or "null")
PY
    )

    LAST_STATUS="${STATE[0]}"
    LAST_CHECKED="${STATE[1]}"
    LAST_VERIFIED="${STATE[2]}"
}

wait_for_pending_check() {
    local id="$1"
    local previous="${2-}"

    for _ in $(seq 1 60)
    do
        read_current_domain "$id"

        if \
            [ "$LAST_STATUS" = "pending" ] \
            && [ "$LAST_CHECKED" != "null" ] \
            && {
                [ -z "$previous" ] \
                || [ "$LAST_CHECKED" != "$previous" ]
            }
        then
            return 0
        fi

        sleep 1
    done

    fail "domain did not record a pending DNS verification check"
}

wait_for_verified() {
    local id="$1"

    for _ in $(seq 1 60)
    do
        read_current_domain "$id"

        if \
            [ "$LAST_STATUS" = "verified" ] \
            && [ "$LAST_CHECKED" != "null" ] \
            && [ "$LAST_VERIFIED" != "null" ]
        then
            return 0
        fi

        sleep 1
    done

    fail "domain did not transition to VERIFIED"
}

echo "=== HeyMail sending-domain DNS verification E2E ==="

docker compose up \
    -d \
    --wait \
    fake-dns \
    domain-verifier \
    gateway \
    >/dev/null

clear_dns_records

MARKER="$(
    openssl rand -hex 8
)"

DOMAIN="verify-${MARKER}.heymail.test"

CREATE_CODE="$(
    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --config "$AUTH_CONFIG" \
        --header 'Content-Type: application/json' \
        --data-binary "{\"domain\":\"${DOMAIN}\"}" \
        --output "$CREATE_BODY" \
        --write-out '%{http_code}' \
        "${BASE_URL}/api/v1/domains"
)"

[ "$CREATE_CODE" = "201" ] \
    || fail "domain creation returned HTTP $CREATE_CODE"

mapfile -t CREATED < <(
    python3 \
        - "$CREATE_BODY" "$DOMAIN" <<'PY'
import json
import sys

path, expected_domain = sys.argv[1:3]

with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data["domain"] == expected_domain
assert data["status"] == "pending"
assert data["verificationCheckedAt"] is None

print(data["id"])
print(data["verification"]["name"])
print(data["verification"]["value"])
PY
)

DOMAIN_ID="${CREATED[0]}"
DNS_NAME="${CREATED[1]}"
DNS_VALUE="${CREATED[2]}"

pass "domain starts PENDING with an unpublished DNS challenge"

UNAUTH_CODE="$(
    curl_request \
        POST \
        "/api/v1/domains/${DOMAIN_ID}/verify" \
        "$VERIFY_BODY" \
        no
)"

[ "$UNAUTH_CODE" = "401" ] \
    || fail "unauthenticated verification returned HTTP $UNAUTH_CODE"

pass "DNS verification endpoint enforces API authentication"

VERIFY_CODE="$(
    curl_request \
        POST \
        "/api/v1/domains/${DOMAIN_ID}/verify" \
        "$VERIFY_BODY"
)"

[ "$VERIFY_CODE" = "202" ] \
    || fail "verification request without TXT returned HTTP $VERIFY_CODE"

wait_for_pending_check \
    "$DOMAIN_ID"

FIRST_CHECKED="$LAST_CHECKED"

pass "missing DNS TXT keeps domain PENDING and records the check"

sleep 2

set_dns_record \
    "$DNS_NAME" \
    "${DNS_VALUE}-wrong"

VERIFY_CODE="$(
    curl_request \
        POST \
        "/api/v1/domains/${DOMAIN_ID}/verify" \
        "$VERIFY_BODY"
)"

[ "$VERIFY_CODE" = "202" ] \
    || fail "verification request with wrong TXT returned HTTP $VERIFY_CODE"

wait_for_pending_check \
    "$DOMAIN_ID" \
    "$FIRST_CHECKED"

SECOND_CHECKED="$LAST_CHECKED"

pass "wrong DNS TXT keeps domain PENDING"

sleep 2

set_dns_record \
    "$DNS_NAME" \
    "$DNS_VALUE"

VERIFY_CODE="$(
    curl_request \
        POST \
        "/api/v1/domains/${DOMAIN_ID}/verify" \
        "$VERIFY_BODY"
)"

[ "$VERIFY_CODE" = "202" ] \
    || fail "verification request with correct TXT returned HTTP $VERIFY_CODE"

wait_for_verified \
    "$DOMAIN_ID"

VERIFIED_AT="$LAST_VERIFIED"
VERIFIED_CHECKED_AT="$LAST_CHECKED"

[ "$VERIFIED_AT" = "$VERIFIED_CHECKED_AT" ] \
    || fail "verification timestamps are inconsistent"

pass "correct authoritative TXT transitions domain to VERIFIED"

sleep 1

VERIFY_CODE="$(
    curl_request \
        POST \
        "/api/v1/domains/${DOMAIN_ID}/verify" \
        "$VERIFY_BODY"
)"

[ "$VERIFY_CODE" = "200" ] \
    || fail "already verified domain returned HTTP $VERIFY_CODE"

python3 \
    - "$VERIFY_BODY" "$VERIFIED_AT" <<'PY'
import json
import sys

path, expected_verified_at = sys.argv[1:3]

with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data["status"] == "verified"
assert data["verificationQueued"] is False
assert data["verifiedAt"] == expected_verified_at
PY

read_current_domain \
    "$DOMAIN_ID"

[ "$LAST_VERIFIED" = "$VERIFIED_AT" ] \
    || fail "idempotent verification changed verifiedAt"

pass "already verified domain is idempotent and queues no new verification"

echo
echo "DOMAIN_ID=$DOMAIN_ID"
echo "FINAL_STATUS=$LAST_STATUS"
echo "VERIFIED_AT=$LAST_VERIFIED"
echo
echo "ALL SENDING DOMAIN DNS VERIFICATION E2E TESTS PASSED"
