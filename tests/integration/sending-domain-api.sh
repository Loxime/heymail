#!/usr/bin/env bash

set -euo pipefail

cd "$(
    dirname "$0"
)/../.."

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

for FILE in \
    secrets/api_key \
    secrets/api_secret \
    secrets/gateway_tls_cert.pem
do
    test -r "$FILE" \
        || fail "required file is unreadable: $FILE"
done

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

AUTH_CONFIG="$(
    mktemp /tmp/heymail-domain-auth.XXXXXX
)"

FIRST_BODY="$(
    mktemp /tmp/heymail-domain-first.XXXXXX
)"

REPLAY_BODY="$(
    mktemp /tmp/heymail-domain-replay.XXXXXX
)"

GET_BODY="$(
    mktemp /tmp/heymail-domain-get.XXXXXX
)"

INVALID_BODY="$(
    mktemp /tmp/heymail-domain-invalid.XXXXXX
)"

UNAUTH_BODY="$(
    mktemp /tmp/heymail-domain-unauth.XXXXXX
)"

RACE_A_BODY="$(
    mktemp /tmp/heymail-domain-race-a.XXXXXX
)"

RACE_B_BODY="$(
    mktemp /tmp/heymail-domain-race-b.XXXXXX
)"

RACE_A_CODE="$(
    mktemp /tmp/heymail-domain-race-a-code.XXXXXX
)"

RACE_B_CODE="$(
    mktemp /tmp/heymail-domain-race-b-code.XXXXXX
)"

cleanup() {
    rm -f \
        "$AUTH_CONFIG" \
        "$FIRST_BODY" \
        "$REPLAY_BODY" \
        "$GET_BODY" \
        "$INVALID_BODY" \
        "$UNAUTH_BODY" \
        "$RACE_A_BODY" \
        "$RACE_B_BODY" \
        "$RACE_A_CODE" \
        "$RACE_B_CODE"

    unset \
        API_KEY \
        API_SECRET \
        AUTH_B64
}

trap cleanup EXIT

chmod 0600 \
    "$AUTH_CONFIG"

printf \
    'header = "Authorization: Basic %s"\n' \
    "$AUTH_B64" \
    > "$AUTH_CONFIG"

BASE_URL='https://api.heymail.test:8443'

curl_request() {
    local method="$1"
    local path="$2"
    local output="$3"
    local body="${4-}"
    local authenticated="${5-yes}"

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

    if [ -n "$body" ]
    then
        args+=(
            --header 'Content-Type: application/json'
            --data-binary "$body"
        )
    fi

    args+=(
        "${BASE_URL}${path}"
    )

    "${args[@]}"
}

database_count() {
    local domain="$1"

    printf '%s\n' \
        "SELECT count(*) FROM sending_domain WHERE domain = :'domain';" \
        | docker compose exec \
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
                    -v domain="$1" \
                    -At
            ' \
            sh \
            "$domain"
}

MARKER="$(
    openssl rand -hex 8
)"

DOMAIN="sender-${MARKER}.heymail.test"

REPLAY_DOMAIN="$(
    printf '%s' \
        "$DOMAIN" \
        | tr '[:lower:]' '[:upper:]'
)."

REQUEST_BODY="$(
    printf \
        '{"domain":"%s"}' \
        "$DOMAIN"
)"

REPLAY_REQUEST_BODY="$(
    printf \
        '{"domain":"%s"}' \
        "$REPLAY_DOMAIN"
)"

echo "=== HeyMail sending domain HTTPS API ==="

UNAUTH_CODE="$(
    curl_request \
        POST \
        /api/v1/domains \
        "$UNAUTH_BODY" \
        "$REQUEST_BODY" \
        no
)"

[ "$UNAUTH_CODE" = "401" ] \
    || fail "unauthenticated registration returned HTTP $UNAUTH_CODE"

pass "domain registration authentication boundary returns 401"

FIRST_CODE="$(
    curl_request \
        POST \
        /api/v1/domains \
        "$FIRST_BODY" \
        "$REQUEST_BODY"
)"

[ "$FIRST_CODE" = "201" ] \
    || fail "first domain registration returned HTTP $FIRST_CODE"

DOMAIN_ID="$(
    python3 \
        - "$FIRST_BODY" "$DOMAIN" <<'PY'
import json
import re
import sys

path, expected_domain = sys.argv[1:3]

with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert isinstance(data["id"], int)
assert data["id"] > 0
assert data["domain"] == expected_domain
assert data["status"] == "pending"
assert data["replayed"] is False
assert data["verifiedAt"] is None
assert data["disabledAt"] is None

verification = data["verification"]

assert verification["type"] == "TXT"
assert verification["name"] == (
    "_heymail-verification."
    + expected_domain
)

assert re.fullmatch(
    r"heymail-verification=[a-f0-9]{64}",
    verification["value"],
)

print(data["id"])
PY
)" || fail "first domain response is invalid"

pass "new domain registration returns canonical pending domain and DNS challenge"

REPLAY_CODE="$(
    curl_request \
        POST \
        /api/v1/domains \
        "$REPLAY_BODY" \
        "$REPLAY_REQUEST_BODY"
)"

[ "$REPLAY_CODE" = "200" ] \
    || fail "domain replay returned HTTP $REPLAY_CODE"

python3 \
    - "$FIRST_BODY" "$REPLAY_BODY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    first = json.load(handle)

with open(sys.argv[2], encoding="utf-8") as handle:
    replay = json.load(handle)

assert replay["replayed"] is True
assert replay["id"] == first["id"]
assert replay["domain"] == first["domain"]
assert replay["status"] == first["status"]
assert replay["verification"] == first["verification"]
assert replay["createdAt"] == first["createdAt"]
PY

pass "canonical replay returns the existing sending domain"

GET_CODE="$(
    curl_request \
        GET \
        "/api/v1/domains/${DOMAIN_ID}" \
        "$GET_BODY"
)"

[ "$GET_CODE" = "200" ] \
    || fail "domain status returned HTTP $GET_CODE"

python3 \
    - "$FIRST_BODY" "$GET_BODY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    created = json.load(handle)

with open(sys.argv[2], encoding="utf-8") as handle:
    current = json.load(handle)

for key in (
    "id",
    "domain",
    "status",
    "verification",
    "createdAt",
    "verifiedAt",
    "disabledAt",
):
    assert current[key] == created[key]

assert "replayed" not in current
PY

pass "GET domain endpoint returns the persisted DNS challenge"

INVALID_CODE="$(
    curl_request \
        POST \
        /api/v1/domains \
        "$INVALID_BODY" \
        '{"domain":"https://example.com"}'
)"

[ "$INVALID_CODE" = "422" ] \
    || fail "invalid domain returned HTTP $INVALID_CODE"

pass "invalid sending domain is rejected"

COUNT="$(
    database_count \
        "$DOMAIN"
)"

[ "$COUNT" = "1" ] \
    || fail "canonical replay created $COUNT database rows"

pass "canonical replay persists exactly one sending domain"

RACE_DOMAIN="race-${MARKER}.heymail.test"

RACE_REQUEST_BODY="$(
    printf \
        '{"domain":"%s"}' \
        "$RACE_DOMAIN"
)"

(
    curl_request \
        POST \
        /api/v1/domains \
        "$RACE_A_BODY" \
        "$RACE_REQUEST_BODY" \
        > "$RACE_A_CODE"
) &

PID_A=$!

(
    curl_request \
        POST \
        /api/v1/domains \
        "$RACE_B_BODY" \
        "$RACE_REQUEST_BODY" \
        > "$RACE_B_CODE"
) &

PID_B=$!

wait "$PID_A"
wait "$PID_B"

CODE_A="$(
    cat "$RACE_A_CODE"
)"

CODE_B="$(
    cat "$RACE_B_CODE"
)"

SORTED_CODES="$(
    printf '%s\n%s\n' \
        "$CODE_A" \
        "$CODE_B" \
        | sort \
        | tr '\n' ' '
)"

[ "$SORTED_CODES" = "200 201 " ] \
    || fail "concurrent registration returned HTTP $CODE_A and $CODE_B"

python3 \
    - "$RACE_A_BODY" "$RACE_B_BODY" "$RACE_DOMAIN" <<'PY'
import json
import sys

path_a, path_b, expected_domain = sys.argv[1:4]

with open(path_a, encoding="utf-8") as handle:
    a = json.load(handle)

with open(path_b, encoding="utf-8") as handle:
    b = json.load(handle)

assert a["id"] == b["id"]
assert a["domain"] == expected_domain
assert b["domain"] == expected_domain
assert a["status"] == "pending"
assert b["status"] == "pending"
assert a["verification"] == b["verification"]
assert sorted(
    [a["replayed"], b["replayed"]]
) == [False, True]
PY

RACE_COUNT="$(
    database_count \
        "$RACE_DOMAIN"
)"

[ "$RACE_COUNT" = "1" ] \
    || fail "concurrent registration created $RACE_COUNT database rows"

pass "concurrent registration is serialized into one domain record"

echo
echo "DOMAIN_ID=$DOMAIN_ID"
echo "FINAL_STATUS=pending"
echo
echo "ALL SENDING DOMAIN HTTPS API TESTS PASSED"
