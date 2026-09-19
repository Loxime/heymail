#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
        && pwd
)"
cd "$ROOT_DIR"

TMP_DIR="$(
    mktemp \
        -d \
        /tmp/heymail-workspace-api-credentials.XXXXXX
)"

WORKSPACE_A=""
WORKSPACE_B=""
MESSAGE_A=""
MESSAGE_B=""

cleanup() {
    RESULT=$?
    trap - EXIT
    set +e

    docker compose exec \
        -T \
        -e WORKSPACE_A="${WORKSPACE_A:-}" \
        -e WORKSPACE_B="${WORKSPACE_B:-}" \
        -e MESSAGE_A="${MESSAGE_A:-}" \
        -e MESSAGE_B="${MESSAGE_B:-}" \
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
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ],
);

foreach ([
    getenv('MESSAGE_A'),
    getenv('MESSAGE_B'),
] as $messageId) {
    if (
        is_string($messageId)
        && preg_match('/^[1-9][0-9]*$/D', $messageId) === 1
    ) {
        $stmt = $pdo->prepare(
            'DELETE FROM outbound_message WHERE id = :id',
        );
        $stmt->execute([
            'id' => $messageId,
        ]);
    }
}

foreach ([
    getenv('WORKSPACE_A'),
    getenv('WORKSPACE_B'),
] as $workspaceId) {
    if (
        is_string($workspaceId)
        && preg_match('/^[1-9][0-9]*$/D', $workspaceId) === 1
    ) {
        $stmt = $pdo->prepare(
            'DELETE FROM workspace WHERE id = :id',
        );
        $stmt->execute([
            'id' => $workspaceId,
        ]);
    }
}
PHP

    rm -rf "$TMP_DIR"

    exit "$RESULT"
}

trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

http_code() {
    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --output "$2" \
        --write-out '%{http_code}' \
        --user "$1" \
        https://api.heymail.test:8443/api/v1/dashboard
}

echo "=== HeyMail workspace API credentials E2E ==="

docker compose up \
    -d \
    --wait \
    database \
    api \
    gateway \
    >/dev/null

FIXTURE="$(
    docker compose exec \
        -T \
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
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ],
);

$now = (new DateTimeImmutable(
    'now',
    new DateTimeZone('UTC'),
))->format('Y-m-d H:i:s');

$workspaceInsert = $pdo->prepare(
    <<<'SQL'
INSERT INTO workspace (
    name,
    created_at
)
VALUES (
    :name,
    :created_at
)
RETURNING id
SQL
);

$workspaceInsert->execute([
    'name' => 'Credential Gate A ' . bin2hex(random_bytes(4)),
    'created_at' => $now,
]);
$workspaceA = $workspaceInsert->fetchColumn();

$workspaceInsert->execute([
    'name' => 'Credential Gate B ' . bin2hex(random_bytes(4)),
    'created_at' => $now,
]);
$workspaceB = $workspaceInsert->fetchColumn();

$keyA = 'hm_' . bin2hex(random_bytes(16));
$keyB = 'hm_' . bin2hex(random_bytes(16));
$secretA = bin2hex(random_bytes(32));
$secretB = bin2hex(random_bytes(32));

$credentialInsert = $pdo->prepare(
    <<<'SQL'
INSERT INTO api_credential (
    workspace_id,
    api_key,
    key_fingerprint,
    secret_hash,
    label,
    created_at
)
VALUES (
    :workspace_id,
    :api_key,
    :fingerprint,
    :secret_hash,
    :label,
    :created_at
)
SQL
);

$credentialInsert->execute([
    'workspace_id' => $workspaceA,
    'api_key' => $keyA,
    'fingerprint' => hash('sha256', $keyA),
    'secret_hash' => password_hash(
        $secretA,
        PASSWORD_DEFAULT,
    ),
    'label' => 'Credential gate A',
    'created_at' => $now,
]);

$credentialInsert->execute([
    'workspace_id' => $workspaceB,
    'api_key' => $keyB,
    'fingerprint' => hash('sha256', $keyB),
    'secret_hash' => password_hash(
        $secretB,
        PASSWORD_DEFAULT,
    ),
    'label' => 'Credential gate B',
    'created_at' => $now,
]);

$idempotencyHash = hash(
    'sha256',
    'shared-across-workspaces',
);

$messageInsert = $pdo->prepare(
    <<<'SQL'
INSERT INTO outbound_message (
    workspace_id,
    idempotency_key_hash,
    status,
    created_at
)
VALUES (
    :workspace_id,
    :hash,
    'queued',
    :created_at
)
RETURNING id
SQL
);

$messageInsert->execute([
    'workspace_id' => $workspaceA,
    'hash' => $idempotencyHash,
    'created_at' => $now,
]);
$messageA = $messageInsert->fetchColumn();

$messageInsert->execute([
    'workspace_id' => $workspaceB,
    'hash' => $idempotencyHash,
    'created_at' => $now,
]);
$messageB = $messageInsert->fetchColumn();

$duplicateRejected = false;

try {
    $messageInsert->execute([
        'workspace_id' => $workspaceA,
        'hash' => $idempotencyHash,
        'created_at' => $now,
    ]);
} catch (PDOException) {
    $duplicateRejected = true;
}

foreach ([
    'WORKSPACE_A' => $workspaceA,
    'WORKSPACE_B' => $workspaceB,
    'MESSAGE_A' => $messageA,
    'MESSAGE_B' => $messageB,
    'KEY_A' => $keyA,
    'KEY_B' => $keyB,
    'SECRET_A' => $secretA,
    'SECRET_B' => $secretB,
    'DUPLICATE_REJECTED' => $duplicateRejected
        ? 'yes'
        : 'no',
] as $name => $value) {
    echo $name,
        '=',
        $value,
        PHP_EOL;
}
PHP
)"


fixture_value() {
    local name="$1"

    awk \
        -F= \
        -v name="$name" \
        '$1 == name { print substr($0, index($0, "=") + 1) }' \
        <<<"$FIXTURE"
}

printf 'WORKSPACE_A=%s\n' "$(fixture_value WORKSPACE_A)"
printf 'WORKSPACE_B=%s\n' "$(fixture_value WORKSPACE_B)"
printf 'MESSAGE_A=%s\n' "$(fixture_value MESSAGE_A)"
printf 'MESSAGE_B=%s\n' "$(fixture_value MESSAGE_B)"
printf 'DUPLICATE_REJECTED=%s\n' "$(fixture_value DUPLICATE_REJECTED)"

WORKSPACE_A="$(fixture_value WORKSPACE_A)"
WORKSPACE_B="$(fixture_value WORKSPACE_B)"
MESSAGE_A="$(fixture_value MESSAGE_A)"
MESSAGE_B="$(fixture_value MESSAGE_B)"
KEY_A="$(fixture_value KEY_A)"
KEY_B="$(fixture_value KEY_B)"
SECRET_A="$(fixture_value SECRET_A)"
SECRET_B="$(fixture_value SECRET_B)"

for value in \
    "$WORKSPACE_A" \
    "$WORKSPACE_B" \
    "$MESSAGE_A" \
    "$MESSAGE_B"
do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] \
        || fail "invalid fixture identifier"
done

[ "$(fixture_value DUPLICATE_REJECTED)" = "yes" ] \
    || fail "same-workspace duplicate idempotency hash was accepted"

echo "PASS: idempotency is unique per workspace and reusable across workspaces"

BODY_A="$TMP_DIR/a.json"
BODY_B="$TMP_DIR/b.json"
BODY_BAD="$TMP_DIR/bad.json"

STATUS_A="$(
    http_code \
        "$KEY_A:$SECRET_A" \
        "$BODY_A"
)"

STATUS_B="$(
    http_code \
        "$KEY_B:$SECRET_B" \
        "$BODY_B"
)"

STATUS_BAD="$(
    http_code \
        "$KEY_A:$(printf '0%.0s' $(seq 1 64))" \
        "$BODY_BAD"
)"

[ "$STATUS_A" = "200" ] \
    || fail "workspace A credential returned HTTP $STATUS_A"

[ "$STATUS_B" = "200" ] \
    || fail "workspace B credential returned HTTP $STATUS_B"

[ "$STATUS_BAD" = "401" ] \
    || fail "wrong secret was not rejected"

python3 \
    - "$BODY_A" "$BODY_B" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    a = json.load(handle)

with open(sys.argv[2], encoding="utf-8") as handle:
    b = json.load(handle)

assert a["messages"]["total"] == 1
assert b["messages"]["total"] == 1

print("A_TOTAL=1")
print("B_TOTAL=1")
PY

echo "PASS: persisted credentials resolve distinct workspace principals"

USAGE="$(
    docker compose exec \
        -T \
        -e KEY_A="$KEY_A" \
        -e KEY_B="$KEY_B" \
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
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ],
);

$stmt = $pdo->prepare(
    <<<'SQL'
SELECT
    api_key,
    CASE
        WHEN last_used_at IS NULL THEN 0
        ELSE 1
    END AS used
FROM api_credential
WHERE api_key IN (:key_a, :key_b)
ORDER BY api_key
SQL
);

$stmt->execute([
    'key_a' => getenv('KEY_A'),
    'key_b' => getenv('KEY_B'),
]);

foreach ($stmt->fetchAll(PDO::FETCH_ASSOC) as $row) {
    echo $row['api_key'],
        '=',
        $row['used'],
        PHP_EOL;
}
PHP
)"

grep -Fq "$KEY_A=1" <<<"$USAGE" \
    || fail "credential A last_used_at was not recorded"

grep -Fq "$KEY_B=1" <<<"$USAGE" \
    || fail "credential B last_used_at was not recorded"

echo "PASS: successful credential use records last_used_at"

docker compose exec \
    -T \
    -e KEY_A="$KEY_A" \
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
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ],
);

$stmt = $pdo->prepare(
    <<<'SQL'
UPDATE api_credential
SET revoked_at = CURRENT_TIMESTAMP
WHERE api_key = :api_key
SQL
);

$stmt->execute([
    'api_key' => getenv('KEY_A'),
]);
PHP

REVOKED_BODY="$TMP_DIR/revoked.json"

REVOKED_STATUS="$(
    http_code \
        "$KEY_A:$SECRET_A" \
        "$REVOKED_BODY"
)"

[ "$REVOKED_STATUS" = "401" ] \
    || fail "revoked credential was not rejected"

STILL_VALID_STATUS="$(
    http_code \
        "$KEY_B:$SECRET_B" \
        "$BODY_B"
)"

[ "$STILL_VALID_STATUS" = "200" ] \
    || fail "revoking A affected credential B"

echo "PASS: revocation is immediate and isolated"

echo "ALL WORKSPACE API CREDENTIAL TESTS PASSED"
