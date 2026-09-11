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
        /tmp/heymail-sender-e2e.XXXXXX
)"

trap 'rm -rf "$TEMP_DIR"' EXIT

chmod 0700 "$TEMP_DIR"

AUTH_CONFIG="$TEMP_DIR/auth.conf"

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

BASE_URL='https://api.heymail.test:8443'

curl_auth() {
    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --config "$AUTH_CONFIG" \
        "$@"
}

MARKER="$(
    openssl rand -hex 8
)"

DOMAIN="sender-${MARKER}.heymail.test"
SENDER_EMAIL="sender@${DOMAIN}"
OTHER_EMAIL="other@${DOMAIN}"

DOMAIN_BODY="$TEMP_DIR/domain.json"
SENDER_BODY="$TEMP_DIR/sender.json"
VERIFY_BODY="$TEMP_DIR/verify.json"
GET_BODY="$TEMP_DIR/get.json"
SEND_BODY="$TEMP_DIR/send.json"
SEND_RESPONSE="$TEMP_DIR/send-response.json"

echo "=== HeyMail sender identity E2E ==="

docker compose up \
    -d \
    --wait \
    fake-dns \
    domain-verifier \
    gateway \
    >/dev/null

# PASS_6C_MAIL_WORKER_ISOLATION
#
# Sender authorization is tested while the outbound worker is stopped.
# SMTP/DKIM has a dedicated integration test.
docker compose stop \
    mail-worker \
    >/dev/null 2>&1 \
    || true


printf '{}\n' \
    | docker compose exec \
        -T \
        fake-dns \
        sh -c \
        'cat > /records/records.json'

DOMAIN_CODE="$(
    curl_auth \
        --header 'Content-Type: application/json' \
        --data-binary "{\"domain\":\"${DOMAIN}\"}" \
        --output "$DOMAIN_BODY" \
        --write-out '%{http_code}' \
        "${BASE_URL}/api/v1/domains"
)"

[ "$DOMAIN_CODE" = "201" ] \
    || fail "sending domain creation returned HTTP $DOMAIN_CODE"

mapfile -t DOMAIN_INFO < <(
    python3 \
        - "$DOMAIN_BODY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

print(data["id"])
print(data["verification"]["name"])
print(data["verification"]["value"])
PY
)

DOMAIN_ID="${DOMAIN_INFO[0]}"
DNS_NAME="${DOMAIN_INFO[1]}"
DNS_VALUE="${DOMAIN_INFO[2]}"

pass "pending domain created"

PENDING_SENDER_CODE="$(
    curl_auth \
        --header 'Content-Type: application/json' \
        --data-binary "{\"email\":\"${SENDER_EMAIL}\"}" \
        --output "$SENDER_BODY" \
        --write-out '%{http_code}' \
        "${BASE_URL}/api/v1/senders"
)"

[ "$PENDING_SENDER_CODE" = "409" ] \
    || fail "sender registration on pending domain returned HTTP $PENDING_SENDER_CODE"

pass "pending domain cannot authorize sender identity"

python3 \
    - "$DNS_NAME" "$DNS_VALUE" <<'PY' \
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

VERIFY_CODE="$(
    curl_auth \
        --request POST \
        --output "$VERIFY_BODY" \
        --write-out '%{http_code}' \
        "${BASE_URL}/api/v1/domains/${DOMAIN_ID}/verify"
)"

[ "$VERIFY_CODE" = "202" ] \
    || fail "domain verification returned HTTP $VERIFY_CODE"

DOMAIN_STATUS=""

for _ in $(seq 1 30)
do
    curl_auth \
        --output "$GET_BODY" \
        "${BASE_URL}/api/v1/domains/${DOMAIN_ID}"

    DOMAIN_STATUS="$(
        python3 \
            - "$GET_BODY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["status"])
PY
    )"

    [ "$DOMAIN_STATUS" = "verified" ] \
        && break

    sleep 1
done

[ "$DOMAIN_STATUS" = "verified" ] \
    || fail "domain did not become VERIFIED"

pass "domain ownership verified"

UNAUTHORIZED_PAYLOAD="$(
    python3 \
        - "$SENDER_EMAIL" <<'PY'
import json
import sys

print(
    json.dumps(
        {
            "from": {
                "email": sys.argv[1],
            },
            "to": [
                {
                    "email": "before-registration@success.test",
                },
            ],
            "subject": "Unauthorized sender",
            "text": "UNAUTHORIZED-SENDER",
        },
        separators=(",", ":"),
    )
)
PY
)"

UNAUTHORIZED_CODE="$(
    curl_auth \
        --header 'Content-Type: application/json' \
        --header "Idempotency-Key: sender-before-${MARKER}" \
        --data-binary "$UNAUTHORIZED_PAYLOAD" \
        --output "$SEND_RESPONSE" \
        --write-out '%{http_code}' \
        "${BASE_URL}/api/v1/send"
)"

[ "$UNAUTHORIZED_CODE" = "403" ] \
    || fail "unregistered sender returned HTTP $UNAUTHORIZED_CODE"

pass "verified domain alone does not authorize an unregistered From address"

SENDER_CODE="$(
    curl_auth \
        --header 'Content-Type: application/json' \
        --data-binary "{\"email\":\"${SENDER_EMAIL}\"}" \
        --output "$SENDER_BODY" \
        --write-out '%{http_code}' \
        "${BASE_URL}/api/v1/senders"
)"

[ "$SENDER_CODE" = "201" ] \
    || fail "sender registration returned HTTP $SENDER_CODE"

SENDER_ID="$(
    python3 \
        - "$SENDER_BODY" "$SENDER_EMAIL" "$DOMAIN" <<'PY'
import json
import sys

path, expected_email, expected_domain = sys.argv[1:4]

with open(path, encoding="utf-8") as handle:
    data = json.load(handle)

assert data["email"] == expected_email
assert data["domain"] == expected_domain
assert data["authorized"] is True
assert data["replayed"] is False

print(data["id"])
PY
)"

pass "verified domain can register sender identity"

REPLAY_CODE="$(
    curl_auth \
        --header 'Content-Type: application/json' \
        --data-binary "{\"email\":\"SENDER@${DOMAIN^^}\"}" \
        --output "$SENDER_BODY" \
        --write-out '%{http_code}' \
        "${BASE_URL}/api/v1/senders"
)"

[ "$REPLAY_CODE" = "200" ] \
    || fail "canonical sender replay returned HTTP $REPLAY_CODE"

python3 \
    - "$SENDER_BODY" "$SENDER_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert str(data["id"]) == sys.argv[2]
assert data["replayed"] is True
assert data["authorized"] is True
PY

pass "canonical sender replay returns the existing identity"

AUTHORIZED_CODE="$(
    curl_auth \
        --header 'Content-Type: application/json' \
        --header "Idempotency-Key: sender-before-${MARKER}" \
        --data-binary "$UNAUTHORIZED_PAYLOAD" \
        --output "$SEND_RESPONSE" \
        --write-out '%{http_code}' \
        "${BASE_URL}/api/v1/send"
)"

[ "$AUTHORIZED_CODE" = "202" ] \
    || fail "registered sender returned HTTP $AUTHORIZED_CODE"

OUTBOUND_ID="$(
    python3 \
        - "$SEND_RESPONSE" <<'PY_AUTH'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert isinstance(data["messageId"], int)
assert data["messageId"] > 0
assert data["status"] == "queued"
assert data["replayed"] is False

print(data["messageId"])
PY_AUTH
)"

[[ "$OUTBOUND_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "authorized sender returned invalid messageId"

pass "registered sender authorizes From and prior 403 did not reserve idempotency key"

docker compose exec \
    -T \
    -e OUTBOUND_ID="$OUTBOUND_ID" \
    api \
    php <<'PHP_CLEAN'
<?php

declare(strict_types=1);

$id = getenv('OUTBOUND_ID');

if (
    !is_string($id)
    || preg_match(
        '/^[1-9][0-9]*$/D',
        $id,
    ) !== 1
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

$deleteQueue =
    $pdo->prepare(
        <<<'SQL'
DELETE FROM messenger_messages
WHERE queue_name IN ('outbound', 'failed')
  AND body::jsonb ->> 'outboundMessageId' = :id
SQL
    );

$deleteQueue->execute([
    'id' => $id,
]);

$deleteMessage =
    $pdo->prepare(
        'DELETE FROM outbound_message WHERE id = :id',
    );

$deleteMessage->execute([
    'id' => $id,
]);
PHP_CLEAN

OUTBOUND_ID=""

docker compose start \
    mail-worker \
    >/dev/null

pass "sender authorization fixture cleaned before SMTP consumption"

GET_CODE="$(
    curl_auth \
        --output "$GET_BODY" \
        --write-out '%{http_code}' \
        "${BASE_URL}/api/v1/senders/${SENDER_ID}"
)"

[ "$GET_CODE" = "200" ] \
    || fail "sender GET returned HTTP $GET_CODE"

pass "sender identity can be retrieved"

OTHER_PAYLOAD="$(
    python3 \
        - "$OTHER_EMAIL" <<'PY'
import json
import sys

print(
    json.dumps(
        {
            "from": {
                "email": sys.argv[1],
            },
            "to": [
                {
                    "email": "other-sender@success.test",
                },
            ],
            "subject": "Other sender",
            "text": "OTHER-SENDER",
        },
        separators=(",", ":"),
    )
)
PY
)"

OTHER_CODE="$(
    curl_auth \
        --header 'Content-Type: application/json' \
        --header "Idempotency-Key: other-sender-${MARKER}" \
        --data-binary "$OTHER_PAYLOAD" \
        --output "$SEND_RESPONSE" \
        --write-out '%{http_code}' \
        "${BASE_URL}/api/v1/send"
)"

[ "$OTHER_CODE" = "403" ] \
    || fail "unregistered sibling sender returned HTTP $OTHER_CODE"

pass "sender authorization is address-specific"

COUNT="$(
    docker compose exec \
        -T \
        -e SENDER_EMAIL="$SENDER_EMAIL" \
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
    'SELECT COUNT(*) FROM sender_identity WHERE email = :email',
);

$stmt->execute([
    'email' => getenv('SENDER_EMAIL'),
]);

echo $stmt->fetchColumn();
PHP
)"

[ "$COUNT" = "1" ] \
    || fail "sender replay persisted $COUNT identities"

pass "sender registration is persisted exactly once"

echo
echo "SENDER_ID=$SENDER_ID"
echo "AUTHORIZED=true"
echo
echo "ALL SENDER IDENTITY API TESTS PASSED"
