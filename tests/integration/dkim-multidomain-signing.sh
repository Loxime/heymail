#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
        && pwd
)"

cd "$ROOT_DIR"

BASE_URL='https://api.heymail.test:8443'

TEMP_DIR=""
AUTH_CONFIG=""

DOMAIN_A=""
DOMAIN_B=""
DOMAIN_A_ID=""
DOMAIN_B_ID=""

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

    if [ -n "${DOMAIN_A:-}" ] || [ -n "${DOMAIN_B:-}" ]; then
        docker compose exec \
            -T \
            -e DOMAIN_A="${DOMAIN_A:-}" \
            -e DOMAIN_B="${DOMAIN_B:-}" \
            api \
            php <<'PHP' \
            >/dev/null 2>&1
<?php

declare(strict_types=1);

$a = getenv('DOMAIN_A');
$b = getenv('DOMAIN_B');

$domains = array_values(
    array_filter(
        [$a, $b],
        static fn ($value): bool =>
            is_string($value)
            && $value !== '',
    ),
);

if ($domains === []) {
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

$stmt = $pdo->prepare(
    <<<'SQL'
DELETE FROM sending_domain
WHERE domain = :a
   OR domain = :b
SQL
);

$stmt->execute([
    'a' => $domains[0] ?? '',
    'b' => $domains[1] ?? '',
]);
PHP

        docker compose exec \
            -T \
            -e DOMAIN_A="${DOMAIN_A:-}" \
            -e DOMAIN_B="${DOMAIN_B:-}" \
            dkim-provisioner \
            sh -c '
                set +e

                for domain in "$DOMAIN_A" "$DOMAIN_B"
                do
                    case "$domain" in
                        dkim-a-*.heymail.test|dkim-b-*.heymail.test)
                            rm -rf -- "/run/heymail-dkim/$domain"
                            ;;
                    esac
                done
            ' \
            >/dev/null 2>&1 \
            || true
    fi

    docker compose exec -T fake-dns \
        sh -c 'printf "{}\n" > /records/records.json' \
        >/dev/null 2>&1 \
        || true

    docker compose exec -T fake-mx-success \
        rm -f /capture/last.eml \
        >/dev/null 2>&1 \
        || true

    if [ -n "${TEMP_DIR:-}" ]; then
        rm -rf "$TEMP_DIR"
    fi

    exit "$RESULT"
}

trap cleanup EXIT

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

create_domain() {
    local domain="$1"
    local output="$2"
    local code=""

    code="$(
        curl_auth \
            --header 'Content-Type: application/json' \
            --data-binary "{\"domain\":\"${domain}\"}" \
            --output "$output" \
            --write-out '%{http_code}' \
            "${BASE_URL}/api/v1/domains"
    )"

    [ "$code" = "201" ] \
        || fail "domain creation for ${domain} returned HTTP ${code}"
}

verify_domain() {
    local id="$1"
    local code=""

    code="$(
        curl_auth \
            --request POST \
            --output /dev/null \
            --write-out '%{http_code}' \
            "${BASE_URL}/api/v1/domains/${id}/verify"
    )"

    [ "$code" = "202" ] \
        || fail "domain verification request ${id} returned HTTP ${code}"
}

wait_dkim_ready() {
    local id="$1"
    local output="$2"
    local ready="false"

    for _ in $(seq 1 90)
    do
        curl_auth \
            --output "$output" \
            "${BASE_URL}/api/v1/domains/${id}"

        ready="$(
            python3 \
                - "$output" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

print(
    "true"
    if (
        data.get("status") == "verified"
        and data.get("dkim", {}).get("ready") is True
    )
    else "false"
)
PY
        )"

        [ "$ready" = "true" ] \
            && return 0

        sleep 1
    done

    return 1
}

db_dkim_material() {
    local domain="$1"

    docker compose exec \
        -T \
        -e DKIM_DOMAIN="$domain" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

$domain = getenv('DKIM_DOMAIN');

if (!is_string($domain) || $domain === '') {
    exit(2);
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

$stmt = $pdo->prepare(
    <<<'SQL'
SELECT
    dkim_selector,
    dkim_public_key
FROM sending_domain
WHERE domain = :domain
  AND status = 'verified'
  AND dkim_provisioned_at IS NOT NULL
SQL
);

$stmt->execute([
    'domain' => $domain,
]);

$row = $stmt->fetch(PDO::FETCH_ASSOC);

if (!is_array($row)) {
    exit(3);
}

$selector = $row['dkim_selector'] ?? null;
$publicKey = $row['dkim_public_key'] ?? null;

if (
    !is_string($selector)
    || $selector === ''
    || !is_string($publicKey)
    || $publicKey === ''
) {
    exit(4);
}

echo $selector, PHP_EOL;
echo base64_encode($publicKey), PHP_EOL;
PHP
}

normalize_public_key() {
    python3 - "$1" <<'PY'
import base64
import re
import sys

raw = base64.b64decode(
    sys.argv[1],
    validate=True,
).decode("ascii").strip()

if "BEGIN" in raw:
    raise SystemExit(
        "database contains PEM material instead of a DKIM p= value"
    )

if raw.startswith("v=DKIM1;"):
    match = re.search(
        r"(?:^|;)\s*p=([A-Za-z0-9+/=]+)",
        raw,
    )

    if not match:
        raise SystemExit(
            "cannot extract p= from stored DKIM record"
        )

    raw = match.group(1)

if not re.fullmatch(
    r"[A-Za-z0-9+/]+={0,2}",
    raw,
):
    raise SystemExit(
        "stored DKIM public key is malformed"
    )

print(raw)
PY
}

clear_capture() {
    docker compose exec -T fake-mx-success \
        rm -f /capture/last.eml \
        >/dev/null 2>&1 \
        || true
}

wait_capture() {
    local marker="$1"

    for _ in $(seq 1 60)
    do
        if docker compose exec -T fake-mx-success \
            grep -aF \
            "$marker" \
            /capture/last.eml \
            >/dev/null 2>&1
        then
            return 0
        fi

        sleep 1
    done

    return 1
}

send_message() {
    local domain="$1"
    local marker="$2"
    local recipient="$3"

    timeout 20s \
        docker compose exec -T postfix \
        /usr/sbin/sendmail \
        -f "sender@${domain}" \
        -- "$recipient" <<MAIL
From: sender@${domain}
To: ${recipient}
Subject: HeyMail multi-domain DKIM ${marker}

${marker}
MAIL
}

assert_signature_identity() {
    local capture="$1"
    local domain="$2"
    local selector="$3"

    python3 \
        - "$capture" "$domain" "$selector" <<'PY'
from email import policy
from email.parser import BytesParser
import re
import sys

path, expected_domain, expected_selector = sys.argv[1:4]

with open(path, "rb") as handle:
    message = BytesParser(
        policy=policy.default,
    ).parse(handle)

signature = message.get("DKIM-Signature")

if signature is None:
    raise SystemExit("missing DKIM-Signature")

value = str(signature)

domain_match = re.search(
    r"(?:^|;)\s*d=([^;\s]+)",
    value,
)

selector_match = re.search(
    r"(?:^|;)\s*s=([^;\s]+)",
    value,
)

if not domain_match:
    raise SystemExit("missing d= tag")

if not selector_match:
    raise SystemExit("missing s= tag")

actual_domain = domain_match.group(1).lower()
actual_selector = selector_match.group(1).lower()

if actual_domain != expected_domain.lower():
    raise SystemExit(
        f"unexpected d=: {actual_domain}"
    )

if actual_selector != expected_selector.lower():
    raise SystemExit(
        f"unexpected s=: {actual_selector}"
    )
PY
}

verify_capture() {
    local capture="$1"
    local domain="$2"
    local selector="$3"
    local public_key="$4"

    docker compose run \
        --rm \
        --no-deps \
        -T \
        -e DKIM_VERIFY_DOMAIN="$domain" \
        -e DKIM_VERIFY_SELECTOR="$selector" \
        -e DKIM_VERIFY_PUBLIC_KEY="$public_key" \
        dkim-verifier \
        < "$capture"
}

key_hash() {
    local domain="$1"
    local selector="$2"

    docker compose exec \
        -T \
        dkim-provisioner \
        sha256sum \
        "/run/heymail-dkim/${domain}/${selector}.key" \
        | awk '{print $1}'
}

key_metadata() {
    local domain="$1"
    local selector="$2"

    docker compose exec \
        -T \
        dkim-provisioner \
        stat \
        -c '%u:%g:%a' \
        "/run/heymail-dkim/${domain}/${selector}.key"
}


echo "=== HeyMail multi-domain DKIM E2E ==="

TEMP_DIR="$(
    mktemp \
        -d \
        /tmp/heymail-dkim-multidomain.XXXXXX
)"

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

RUN_ID="$(
    python3 - <<'PY'
import secrets
print(secrets.token_hex(8))
PY
)"

DOMAIN_A="dkim-a-${RUN_ID}.heymail.test"
DOMAIN_B="dkim-b-${RUN_ID}.heymail.test"

DOMAIN_A_CREATE="$TEMP_DIR/domain-a-create.json"
DOMAIN_B_CREATE="$TEMP_DIR/domain-b-create.json"

DOMAIN_A_GET="$TEMP_DIR/domain-a-get.json"
DOMAIN_B_GET="$TEMP_DIR/domain-b-get.json"

CAPTURE_A="$TEMP_DIR/domain-a.eml"
CAPTURE_B="$TEMP_DIR/domain-b.eml"

docker compose config --quiet \
    || fail "Compose configuration is invalid"

docker compose build \
    dkim-verifier \
    >/dev/null

docker compose up \
    -d \
    --wait \
    fake-dns \
    domain-verifier \
    dkim-provisioner \
    gateway \
    fake-mx-success \
    rspamd \
    postfix \
    >/dev/null

pass "multi-domain DKIM laboratory is healthy"


printf '{}\n' \
    | docker compose exec \
        -T \
        fake-dns \
        sh -c 'cat > /records/records.json'


create_domain \
    "$DOMAIN_A" \
    "$DOMAIN_A_CREATE"

create_domain \
    "$DOMAIN_B" \
    "$DOMAIN_B_CREATE"

mapfile -t DOMAIN_A_INFO < <(
    python3 \
        - "$DOMAIN_A_CREATE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

print(data["id"])
print(data["verification"]["name"])
print(data["verification"]["value"])
PY
)

mapfile -t DOMAIN_B_INFO < <(
    python3 \
        - "$DOMAIN_B_CREATE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

print(data["id"])
print(data["verification"]["name"])
print(data["verification"]["value"])
PY
)

DOMAIN_A_ID="${DOMAIN_A_INFO[0]}"
DOMAIN_A_DNS_NAME="${DOMAIN_A_INFO[1]}"
DOMAIN_A_DNS_VALUE="${DOMAIN_A_INFO[2]}"

DOMAIN_B_ID="${DOMAIN_B_INFO[0]}"
DOMAIN_B_DNS_NAME="${DOMAIN_B_INFO[1]}"
DOMAIN_B_DNS_VALUE="${DOMAIN_B_INFO[2]}"

pass "two independent sending domains were created"


python3 \
    - \
    "$DOMAIN_A_DNS_NAME" \
    "$DOMAIN_A_DNS_VALUE" \
    "$DOMAIN_B_DNS_NAME" \
    "$DOMAIN_B_DNS_VALUE" <<'PY' \
    | docker compose exec \
        -T \
        fake-dns \
        sh -c 'cat > /records/records.json'
import json
import sys

a_name, a_value, b_name, b_value = sys.argv[1:5]

print(
    json.dumps(
        {
            a_name: [a_value],
            b_name: [b_value],
        },
        separators=(",", ":"),
    )
)
PY


verify_domain "$DOMAIN_A_ID"
verify_domain "$DOMAIN_B_ID"

wait_dkim_ready \
    "$DOMAIN_A_ID" \
    "$DOMAIN_A_GET" \
    || fail "domain A did not become DKIM-ready"

wait_dkim_ready \
    "$DOMAIN_B_ID" \
    "$DOMAIN_B_GET" \
    || fail "domain B did not become DKIM-ready"

pass "both verified domains became DKIM-ready"


if grep -E \
    'BEGIN (RSA )?PRIVATE KEY|BEGIN PRIVATE KEY' \
    "$DOMAIN_A_GET" \
    "$DOMAIN_B_GET" \
    >/dev/null
then
    fail "domain API exposed private DKIM material"
fi

pass "domain API exposes no private DKIM material"


mapfile -t MATERIAL_A < <(
    db_dkim_material "$DOMAIN_A"
)

mapfile -t MATERIAL_B < <(
    db_dkim_material "$DOMAIN_B"
)

SELECTOR_A="${MATERIAL_A[0]}"
SELECTOR_B="${MATERIAL_B[0]}"

PUBLIC_A="$(
    normalize_public_key \
        "${MATERIAL_A[1]}"
)"

PUBLIC_B="$(
    normalize_public_key \
        "${MATERIAL_B[1]}"
)"

[ "$SELECTOR_A" = "hm1" ] \
    || fail "domain A selector is ${SELECTOR_A}, expected hm1"

[ "$SELECTOR_B" = "hm1" ] \
    || fail "domain B selector is ${SELECTOR_B}, expected hm1"

[ "$PUBLIC_A" != "$PUBLIC_B" ] \
    || fail "two domains received the same DKIM public key"

pass "two domains have distinct hm1 public keys"


[ "$(
    key_metadata \
        "$DOMAIN_A" \
        "$SELECTOR_A"
)" = "1000:101:440" ] \
    || fail "domain A private-key metadata is unsafe"

[ "$(
    key_metadata \
        "$DOMAIN_B" \
        "$SELECTOR_B"
)" = "1000:101:440" ] \
    || fail "domain B private-key metadata is unsafe"

HASH_A_BEFORE="$(
    key_hash \
        "$DOMAIN_A" \
        "$SELECTOR_A"
)"

HASH_B_BEFORE="$(
    key_hash \
        "$DOMAIN_B" \
        "$SELECTOR_B"
)"

[ "$HASH_A_BEFORE" != "$HASH_B_BEFORE" ] \
    || fail "two domains received identical private keys"

pass "two domains have distinct restricted private keys"


docker compose restart \
    dkim-provisioner \
    >/dev/null

docker compose up \
    -d \
    --wait \
    dkim-provisioner \
    >/dev/null

HASH_A_AFTER="$(
    key_hash \
        "$DOMAIN_A" \
        "$SELECTOR_A"
)"

HASH_B_AFTER="$(
    key_hash \
        "$DOMAIN_B" \
        "$SELECTOR_B"
)"

[ "$HASH_A_BEFORE" = "$HASH_A_AFTER" ] \
    || fail "domain A private key rotated after provisioner restart"

[ "$HASH_B_BEFORE" = "$HASH_B_AFTER" ] \
    || fail "domain B private key rotated after provisioner restart"

pass "provisioner restart does not rotate existing DKIM keys"


MARKER_A="HEYMAIL-DKIM-A-${RUN_ID}"
RECIPIENT_A="dkim-a-${RUN_ID}@success.test"

clear_capture

send_message \
    "$DOMAIN_A" \
    "$MARKER_A" \
    "$RECIPIENT_A" \
    || fail "domain A SMTP submission failed"

wait_capture "$MARKER_A" \
    || fail "domain A message did not reach fake MX"

docker compose exec -T fake-mx-success \
    cat /capture/last.eml \
    > "$CAPTURE_A"

assert_signature_identity \
    "$CAPTURE_A" \
    "$DOMAIN_A" \
    "$SELECTOR_A" \
    || fail "domain A used the wrong DKIM identity"

verify_capture \
    "$CAPTURE_A" \
    "$DOMAIN_A" \
    "$SELECTOR_A" \
    "$PUBLIC_A" \
    >/dev/null \
    || fail "domain A signature failed with domain A public key"

if verify_capture \
    "$CAPTURE_A" \
    "$DOMAIN_A" \
    "$SELECTOR_A" \
    "$PUBLIC_B" \
    >/dev/null 2>&1
then
    fail "domain A message verified with domain B public key"
fi

pass "domain A is signed only by domain A key"


MARKER_B="HEYMAIL-DKIM-B-${RUN_ID}"
RECIPIENT_B="dkim-b-${RUN_ID}@success.test"

clear_capture

send_message \
    "$DOMAIN_B" \
    "$MARKER_B" \
    "$RECIPIENT_B" \
    || fail "domain B SMTP submission failed"

wait_capture "$MARKER_B" \
    || fail "domain B message did not reach fake MX"

docker compose exec -T fake-mx-success \
    cat /capture/last.eml \
    > "$CAPTURE_B"

assert_signature_identity \
    "$CAPTURE_B" \
    "$DOMAIN_B" \
    "$SELECTOR_B" \
    || fail "domain B used the wrong DKIM identity"

verify_capture \
    "$CAPTURE_B" \
    "$DOMAIN_B" \
    "$SELECTOR_B" \
    "$PUBLIC_B" \
    >/dev/null \
    || fail "domain B signature failed with domain B public key"

if verify_capture \
    "$CAPTURE_B" \
    "$DOMAIN_B" \
    "$SELECTOR_B" \
    "$PUBLIC_A" \
    >/dev/null 2>&1
then
    fail "domain B message verified with domain A public key"
fi

pass "domain B is signed only by domain B key"


if grep -E \
    'BEGIN (RSA )?PRIVATE KEY|BEGIN PRIVATE KEY' \
    "$CAPTURE_A" \
    "$CAPTURE_B" \
    >/dev/null
then
    fail "private DKIM material leaked into SMTP capture"
fi

if docker compose logs \
    --no-color \
    dkim-provisioner \
    domain-verifier \
    rspamd \
    postfix \
    2>&1 \
    | grep -E \
        'BEGIN (RSA )?PRIVATE KEY|BEGIN PRIVATE KEY' \
    >/dev/null
then
    fail "private DKIM material leaked into service logs"
fi

pass "private DKIM material is absent from API responses, SMTP and logs"


echo
echo "DOMAIN_A=$DOMAIN_A"
echo "DOMAIN_B=$DOMAIN_B"
echo "SELECTOR_A=$SELECTOR_A"
echo "SELECTOR_B=$SELECTOR_B"
echo
echo "ALL MULTI-DOMAIN DKIM E2E TESTS PASSED"
