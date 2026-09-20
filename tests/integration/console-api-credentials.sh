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
        /tmp/heymail-console-api-credentials.XXXXXX
)"

OWNER_TOKEN="$(
    openssl rand -hex 32
)"
MEMBER_TOKEN="$(
    openssl rand -hex 32
)"
MARKER="$(
    openssl rand -hex 8
)"

OWNER_USER_ID=""
MEMBER_USER_ID=""
WORKSPACE_ID=""
FOREIGN_WORKSPACE_ID=""
FOREIGN_CREDENTIAL_ID=""

cleanup() {
    RESULT=$?
    trap - EXIT
    set +e

    docker compose exec \
        -T \
        -e OWNER_USER_ID="${OWNER_USER_ID:-}" \
        -e MEMBER_USER_ID="${MEMBER_USER_ID:-}" \
        -e WORKSPACE_ID="${WORKSPACE_ID:-}" \
        -e FOREIGN_WORKSPACE_ID="${FOREIGN_WORKSPACE_ID:-}" \
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
        PDO::ATTR_ERRMODE
            => PDO::ERRMODE_EXCEPTION,
    ],
);

foreach ([
    getenv('OWNER_USER_ID'),
    getenv('MEMBER_USER_ID'),
] as $id) {
    if (
        is_string($id)
        && preg_match('/^[1-9][0-9]*$/D', $id) === 1
    ) {
        $stmt = $pdo->prepare(
            'DELETE FROM console_user WHERE id = :id',
        );
        $stmt->execute([
            'id' => $id,
        ]);
    }
}

foreach ([
    getenv('WORKSPACE_ID'),
    getenv('FOREIGN_WORKSPACE_ID'),
] as $id) {
    if (
        is_string($id)
        && preg_match('/^[1-9][0-9]*$/D', $id) === 1
    ) {
        $stmt = $pdo->prepare(
            <<<'SQL'
DELETE FROM workspace
WHERE id = :id
  AND NOT EXISTS (
      SELECT 1
      FROM workspace_member
      WHERE workspace_id = :id
  )
SQL
        );
        $stmt->execute([
            'id' => $id,
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

request() {
    local token="$1"
    local method="$2"
    local path="$3"
    local body_file="$4"
    local output="$5"
    local headers="$6"

    local args=(
        --noproxy '*'
        --silent
        --show-error
        --cacert secrets/gateway_tls_cert.pem
        --resolve api.heymail.test:8443:127.0.0.1
        --dump-header "$headers"
        --output "$output"
        --write-out '%{http_code}'
        --request "$method"
    )

    if [ -n "$token" ]; then
        args+=(
            --header "Cookie: heymail_session=${token}"
        )
    fi

    if [ -n "$body_file" ]; then
        args+=(
            --header 'Content-Type: application/json'
            --data-binary "@$body_file"
        )
    fi

    curl \
        "${args[@]}" \
        "$API_ORIGIN$path"
}

api_status() {
    local credentials="$1"
    local output="$2"

    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --output "$output" \
        --write-out '%{http_code}' \
        --user "$credentials" \
        "$API_ORIGIN/api/v1/dashboard"
}

echo "=== HeyMail console API credential management E2E ==="

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
        -e OWNER_TOKEN="$OWNER_TOKEN" \
        -e MEMBER_TOKEN="$MEMBER_TOKEN" \
        -e MARKER="$MARKER" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

require '/app/vendor/autoload.php';

use App\Console\ConsoleUserProvisioner;
use Doctrine\DBAL\DriverManager;

$ownerToken = getenv('OWNER_TOKEN');
$memberToken = getenv('MEMBER_TOKEN');
$marker = getenv('MARKER');

if (
    !is_string($ownerToken)
    || !is_string($memberToken)
    || !is_string($marker)
) {
    exit(2);
}

$connection = DriverManager::getConnection([
    'driver' => 'pdo_pgsql',
    'host' => getenv('DB_HOST'),
    'port' => getenv('DB_PORT'),
    'dbname' => getenv('DB_NAME'),
    'user' => getenv('DB_USER'),
    'password' => trim(
        file_get_contents(
            (string) getenv('DB_PASSWORD_FILE'),
        ),
    ),
]);

$now = new DateTimeImmutable(
    'now',
    new DateTimeZone('UTC'),
);

$hash = password_hash(
    bin2hex(random_bytes(24)),
    PASSWORD_DEFAULT,
);

if (!is_string($hash)) {
    exit(3);
}

$provisioner = new ConsoleUserProvisioner(
    $connection,
);

$ownerId = $provisioner->create(
    email: 'credential-owner-' . $marker . '@example.test',
    firstName: 'Credential',
    lastName: 'Owner',
    passwordHash: $hash,
    now: $now,
);

$workspaceId = $connection->fetchOne(
    <<<'SQL'
SELECT workspace_id
FROM workspace_member
WHERE user_id = :user_id
SQL,
    [
        'user_id' => $ownerId,
    ],
);

$memberId = $connection->fetchOne(
    <<<'SQL'
INSERT INTO console_user (
    email,
    first_name,
    last_name,
    password_hash,
    created_at,
    updated_at
)
VALUES (
    :email,
    'Credential',
    'Member',
    :password_hash,
    :created_at,
    :updated_at
)
RETURNING id
SQL,
    [
        'email'
            => 'credential-member-'
                . $marker
                . '@example.test',
        'password_hash'
            => $hash,
        'created_at'
            => $now->format('Y-m-d H:i:s'),
        'updated_at'
            => $now->format('Y-m-d H:i:s'),
    ],
);

$connection->insert(
    'workspace_member',
    [
        'workspace_id'
            => $workspaceId,
        'user_id'
            => $memberId,
        'role'
            => 'member',
        'created_at'
            => $now->format('Y-m-d H:i:s'),
    ],
);

foreach ([
    [$ownerId, $ownerToken],
    [$memberId, $memberToken],
] as [$userId, $token]) {
    $connection->insert(
        'console_session',
        [
            'token_hash'
                => hash(
                    'sha256',
                    $token,
                ),
            'user_id'
                => $userId,
            'created_at'
                => $now->format('Y-m-d H:i:s'),
            'last_seen_at'
                => $now->format('Y-m-d H:i:s'),
            'expires_at'
                => $now
                    ->modify('+1 hour')
                    ->format('Y-m-d H:i:s'),
        ],
    );
}

$foreignWorkspaceId = $connection->fetchOne(
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
SQL,
    [
        'name'
            => 'Credential Foreign '
                . $marker,
        'created_at'
            => $now->format('Y-m-d H:i:s'),
    ],
);

$foreignKey =
    'hm_'
    . bin2hex(
        random_bytes(16),
    );

$foreignCredentialId = $connection->fetchOne(
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
    'Foreign credential',
    :created_at
)
RETURNING id
SQL,
    [
        'workspace_id'
            => $foreignWorkspaceId,
        'api_key'
            => $foreignKey,
        'fingerprint'
            => hash(
                'sha256',
                $foreignKey,
            ),
        'secret_hash'
            => password_hash(
                bin2hex(
                    random_bytes(32),
                ),
                PASSWORD_DEFAULT,
            ),
        'created_at'
            => $now->format('Y-m-d H:i:s'),
    ],
);

foreach ([
    'OWNER_USER_ID' => $ownerId,
    'MEMBER_USER_ID' => $memberId,
    'WORKSPACE_ID' => $workspaceId,
    'FOREIGN_WORKSPACE_ID' => $foreignWorkspaceId,
    'FOREIGN_CREDENTIAL_ID' => $foreignCredentialId,
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
        '$1 == name { print $2 }' \
        <<<"$FIXTURE"
}

OWNER_USER_ID="$(fixture_value OWNER_USER_ID)"
MEMBER_USER_ID="$(fixture_value MEMBER_USER_ID)"
WORKSPACE_ID="$(fixture_value WORKSPACE_ID)"
FOREIGN_WORKSPACE_ID="$(fixture_value FOREIGN_WORKSPACE_ID)"
FOREIGN_CREDENTIAL_ID="$(fixture_value FOREIGN_CREDENTIAL_ID)"

for value in \
    "$OWNER_USER_ID" \
    "$MEMBER_USER_ID" \
    "$WORKSPACE_ID" \
    "$FOREIGN_WORKSPACE_ID" \
    "$FOREIGN_CREDENTIAL_ID"
do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] \
        || fail "invalid fixture identifier"
done

echo "PASS: console workspace credential fixtures created"

UNAUTH_BODY="$TMP_DIR/unauth.json"
UNAUTH_HEADERS="$TMP_DIR/unauth.headers"

[ "$(
    request \
        "" \
        GET \
        /console/api-credentials \
        "" \
        "$UNAUTH_BODY" \
        "$UNAUTH_HEADERS"
)" = "401" ] \
    || fail "credential list did not require console authentication"

MEMBER_BODY="$TMP_DIR/member.json"
MEMBER_HEADERS="$TMP_DIR/member.headers"

[ "$(
    request \
        "$MEMBER_TOKEN" \
        GET \
        /console/api-credentials \
        "" \
        "$MEMBER_BODY" \
        "$MEMBER_HEADERS"
)" = "403" ] \
    || fail "workspace member could manage API credentials"

echo "PASS: credential management requires owner/admin console access"

CREATE_PAYLOAD="$TMP_DIR/create.json"

printf '%s\n' \
    '{"label":"Primary integration"}' \
    > "$CREATE_PAYLOAD"

CREATE_BODY="$TMP_DIR/create-response.json"
CREATE_HEADERS="$TMP_DIR/create.headers"

[ "$(
    request \
        "$OWNER_TOKEN" \
        POST \
        /console/api-credentials \
        "$CREATE_PAYLOAD" \
        "$CREATE_BODY" \
        "$CREATE_HEADERS"
)" = "201" ] \
    || {
        cat "$CREATE_BODY" >&2
        fail "credential creation failed"
    }

grep -Eiq \
    '^Cache-Control:[[:space:]]*no-store' \
    "$CREATE_HEADERS" \
    || fail "credential secret response is cacheable"

CREDENTIAL_ID="$(
    python3 \
        - "$CREATE_BODY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

print(data["credential"]["id"])
PY
)"

API_KEY="$(
    python3 \
        - "$CREATE_BODY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

print(data["credential"]["apiKey"])
PY
)"

API_SECRET="$(
    python3 \
        - "$CREATE_BODY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

print(data["secret"])
PY
)"

[[ "$CREDENTIAL_ID" =~ ^[1-9][0-9]*$ ]] \
    || fail "created credential id is invalid"

[[ "$API_KEY" =~ ^hm_[a-f0-9]{32}$ ]] \
    || fail "created API key format is invalid"

[[ "$API_SECRET" =~ ^[a-f0-9]{64}$ ]] \
    || fail "created API secret format is invalid"

python3 \
    - "$CREATE_BODY" "$API_KEY" <<'PY'
import hashlib
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

credential = data["credential"]

assert credential["fingerprint"] == hashlib.sha256(
    sys.argv[2].encode()
).hexdigest()
assert credential["label"] == "Primary integration"
assert credential["lastUsedAt"] is None
assert credential["revokedAt"] is None
PY

echo "PASS: creation returns one-time secret and stable fingerprint"

LIST_BODY="$TMP_DIR/list.json"
LIST_HEADERS="$TMP_DIR/list.headers"

[ "$(
    request \
        "$OWNER_TOKEN" \
        GET \
        /console/api-credentials \
        "" \
        "$LIST_BODY" \
        "$LIST_HEADERS"
)" = "200" ] \
    || fail "credential list failed"

python3 \
    - "$LIST_BODY" "$CREDENTIAL_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

serialized = json.dumps(
    data,
    sort_keys=True,
)

assert "secret" not in serialized.lower()

credential_id = int(sys.argv[2])

matching = [
    item
    for item in data["items"]
    if item["id"] == credential_id
]

assert len(matching) == 1
assert matching[0]["lastUsedAt"] is None
assert matching[0]["revokedAt"] is None
PY

echo "PASS: credential listing never returns secrets"

API_BODY="$TMP_DIR/api.json"

[ "$(
    api_status \
        "$API_KEY:$API_SECRET" \
        "$API_BODY"
)" = "200" ] \
    || fail "new console-created credential cannot authenticate API"

LIST_USED="$TMP_DIR/list-used.json"

[ "$(
    request \
        "$OWNER_TOKEN" \
        GET \
        /console/api-credentials \
        "" \
        "$LIST_USED" \
        "$LIST_HEADERS"
)" = "200" ] \
    || fail "credential list after API use failed"

python3 \
    - "$LIST_USED" "$CREDENTIAL_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

credential_id = int(sys.argv[2])

item = next(
    item
    for item in data["items"]
    if item["id"] == credential_id
)

assert item["lastUsedAt"] is not None
PY

echo "PASS: console-created credential updates last-used metadata"

ROTATE_BODY="$TMP_DIR/rotate.json"
ROTATE_HEADERS="$TMP_DIR/rotate.headers"

[ "$(
    request \
        "$OWNER_TOKEN" \
        POST \
        "/console/api-credentials/$CREDENTIAL_ID/rotate" \
        "" \
        "$ROTATE_BODY" \
        "$ROTATE_HEADERS"
)" = "200" ] \
    || {
        cat "$ROTATE_BODY" >&2
        fail "credential rotation failed"
    }

grep -Eiq \
    '^Cache-Control:[[:space:]]*no-store' \
    "$ROTATE_HEADERS" \
    || fail "rotated credential secret response is cacheable"

ROTATED_KEY="$(
    python3 \
        - "$ROTATE_BODY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["credential"]["apiKey"])
PY
)"

ROTATED_SECRET="$(
    python3 \
        - "$ROTATE_BODY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["secret"])
PY
)"

[ "$ROTATED_KEY" = "$API_KEY" ] \
    || fail "rotation changed API key identity"

[ "$ROTATED_SECRET" != "$API_SECRET" ] \
    || fail "rotation reused the API secret"

OLD_BODY="$TMP_DIR/old-secret.json"

[ "$(
    api_status \
        "$API_KEY:$API_SECRET" \
        "$OLD_BODY"
)" = "401" ] \
    || fail "old secret still authenticates after rotation"

[ "$(
    api_status \
        "$ROTATED_KEY:$ROTATED_SECRET" \
        "$API_BODY"
)" = "200" ] \
    || fail "rotated secret cannot authenticate"

echo "PASS: rotation invalidates old secret immediately"

FOREIGN_BODY="$TMP_DIR/foreign.json"
FOREIGN_HEADERS="$TMP_DIR/foreign.headers"

[ "$(
    request \
        "$OWNER_TOKEN" \
        DELETE \
        "/console/api-credentials/$FOREIGN_CREDENTIAL_ID" \
        "" \
        "$FOREIGN_BODY" \
        "$FOREIGN_HEADERS"
)" = "404" ] \
    || fail "foreign workspace credential was addressable"

echo "PASS: foreign workspace credentials fail closed"

REVOKE_BODY="$TMP_DIR/revoke.json"
REVOKE_HEADERS="$TMP_DIR/revoke.headers"

[ "$(
    request \
        "$OWNER_TOKEN" \
        DELETE \
        "/console/api-credentials/$CREDENTIAL_ID" \
        "" \
        "$REVOKE_BODY" \
        "$REVOKE_HEADERS"
)" = "204" ] \
    || fail "credential revocation failed"

[ "$(
    api_status \
        "$ROTATED_KEY:$ROTATED_SECRET" \
        "$API_BODY"
)" = "401" ] \
    || fail "revoked credential still authenticates"

LIST_REVOKED="$TMP_DIR/list-revoked.json"

[ "$(
    request \
        "$OWNER_TOKEN" \
        GET \
        /console/api-credentials \
        "" \
        "$LIST_REVOKED" \
        "$LIST_HEADERS"
)" = "200" ] \
    || fail "credential list after revocation failed"

python3 \
    - "$LIST_REVOKED" "$CREDENTIAL_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

credential_id = int(sys.argv[2])

item = next(
    item
    for item in data["items"]
    if item["id"] == credential_id
)

assert item["revokedAt"] is not None
PY

HASH="$(
    docker compose exec \
        -T \
        -e API_KEY="$API_KEY" \
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
    'SELECT secret_hash FROM api_credential WHERE api_key = :api_key',
);

$stmt->execute([
    'api_key' => getenv('API_KEY'),
]);

echo $stmt->fetchColumn();
PHP
)"

[ -n "$HASH" ] \
    || fail "stored credential hash missing"

[ "$HASH" != "$API_SECRET" ] \
    || fail "original API secret stored in plaintext"

[ "$HASH" != "$ROTATED_SECRET" ] \
    || fail "rotated API secret stored in plaintext"

echo "PASS: revocation is immediate and secrets remain one-way hashed"

echo "ALL CONSOLE API CREDENTIAL TESTS PASSED"
