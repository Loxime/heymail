#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
        && pwd
)"
cd "$ROOT_DIR"

USER_ID=""
WORKSPACE_ID=""
FOREIGN_WORKSPACE_ID=""
OWN_MESSAGE_ID=""
FOREIGN_MESSAGE_ID=""
BODY=""

TOKEN="$(
    openssl rand -hex 32
)"
MARKER="$(
    openssl rand -hex 8
)"
EMAIL="profile-scope-${MARKER}@example.test"

cleanup() {
    RESULT=$?
    trap - EXIT
    set +e

    docker compose exec \
        -T \
        -e USER_ID="${USER_ID:-}" \
        -e WORKSPACE_ID="${WORKSPACE_ID:-}" \
        -e FOREIGN_WORKSPACE_ID="${FOREIGN_WORKSPACE_ID:-}" \
        -e OWN_MESSAGE_ID="${OWN_MESSAGE_ID:-}" \
        -e FOREIGN_MESSAGE_ID="${FOREIGN_MESSAGE_ID:-}" \
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
    getenv('OWN_MESSAGE_ID'),
    getenv('FOREIGN_MESSAGE_ID'),
] as $id) {
    if (
        is_string($id)
        && preg_match('/^[1-9][0-9]*$/D', $id) === 1
    ) {
        $stmt = $pdo->prepare(
            'DELETE FROM outbound_message WHERE id = :id',
        );

        $stmt->execute([
            'id' => $id,
        ]);
    }
}

$userId = getenv('USER_ID');

if (
    is_string($userId)
    && preg_match('/^[1-9][0-9]*$/D', $userId) === 1
) {
    $stmt = $pdo->prepare(
        'DELETE FROM console_user WHERE id = :id',
    );

    $stmt->execute([
        'id' => $userId,
    ]);
}

foreach ([
    getenv('WORKSPACE_ID'),
    getenv('FOREIGN_WORKSPACE_ID'),
] as $workspaceId) {
    if (
        is_string($workspaceId)
        && preg_match('/^[1-9][0-9]*$/D', $workspaceId) === 1
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
            'id' => $workspaceId,
        ]);
    }
}
PHP

    if [ -n "${BODY:-}" ]; then
        rm -f "$BODY"
    fi

    exit "$RESULT"
}

trap cleanup EXIT

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
        -e TEST_EMAIL="$EMAIL" \
        -e TEST_TOKEN="$TOKEN" \
        -e MARKER="$MARKER" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

require '/app/vendor/autoload.php';

use App\Console\ConsoleUserProvisioner;
use Doctrine\DBAL\DriverManager;

$email = getenv('TEST_EMAIL');
$token = getenv('TEST_TOKEN');
$marker = getenv('MARKER');

if (
    !is_string($email)
    || !is_string($token)
    || !is_string($marker)
    || preg_match('/^[a-f0-9]{64}$/D', $token) !== 1
    || preg_match('/^[a-f0-9]{16}$/D', $marker) !== 1
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

$userId = $provisioner->create(
    email: $email,
    firstName: 'Scope',
    lastName: 'Gate',
    passwordHash: $hash,
    now: $now,
);

$workspaceIdRaw = $connection->fetchOne(
    <<<'SQL'
SELECT workspace_id
FROM workspace_member
WHERE user_id = :user_id
SQL,
    [
        'user_id' => $userId,
    ],
);

$workspaceId = filter_var(
    $workspaceIdRaw,
    FILTER_VALIDATE_INT,
    [
        'options' => [
            'min_range' => 1,
        ],
    ],
);

if (!is_int($workspaceId)) {
    exit(4);
}

$foreignWorkspaceIdRaw = $connection->fetchOne(
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
        'name' => 'Foreign Scope ' . $marker,
        'created_at' => $now->format('Y-m-d H:i:s'),
    ],
);

$foreignWorkspaceId = filter_var(
    $foreignWorkspaceIdRaw,
    FILTER_VALIDATE_INT,
    [
        'options' => [
            'min_range' => 1,
        ],
    ],
);

if (!is_int($foreignWorkspaceId)) {
    exit(5);
}

$connection->executeStatement(
    <<<'SQL'
INSERT INTO console_session (
    token_hash,
    user_id,
    created_at,
    last_seen_at,
    expires_at
)
VALUES (
    :token_hash,
    :user_id,
    :created_at,
    :last_seen_at,
    :expires_at
)
SQL,
    [
        'token_hash' => hash(
            'sha256',
            $token,
        ),
        'user_id' => $userId,
        'created_at' => $now->format('Y-m-d H:i:s'),
        'last_seen_at' => $now->format('Y-m-d H:i:s'),
        'expires_at' => $now
            ->modify('+1 hour')
            ->format('Y-m-d H:i:s'),
    ],
);

$messageSql = <<<'SQL'
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
SQL;

$ownMessageIdRaw = $connection->fetchOne(
    $messageSql,
    [
        'workspace_id' => $workspaceId,
        'hash' => hash(
            'sha256',
            'profile-scope-own:' . $marker,
        ),
        'created_at' => $now->format('Y-m-d H:i:s'),
    ],
);

$foreignMessageIdRaw = $connection->fetchOne(
    $messageSql,
    [
        'workspace_id' => $foreignWorkspaceId,
        'hash' => hash(
            'sha256',
            'profile-scope-foreign:' . $marker,
        ),
        'created_at' => $now->format('Y-m-d H:i:s'),
    ],
);

$ownMessageId = filter_var(
    $ownMessageIdRaw,
    FILTER_VALIDATE_INT,
    [
        'options' => [
            'min_range' => 1,
        ],
    ],
);

$foreignMessageId = filter_var(
    $foreignMessageIdRaw,
    FILTER_VALIDATE_INT,
    [
        'options' => [
            'min_range' => 1,
        ],
    ],
);

if (
    !is_int($ownMessageId)
    || !is_int($foreignMessageId)
) {
    exit(6);
}

foreach ([
    'USER_ID' => $userId,
    'WORKSPACE_ID' => $workspaceId,
    'FOREIGN_WORKSPACE_ID' => $foreignWorkspaceId,
    'OWN_MESSAGE_ID' => $ownMessageId,
    'FOREIGN_MESSAGE_ID' => $foreignMessageId,
] as $name => $value) {
    echo $name,
        '=',
        $value,
        PHP_EOL;
}
PHP
)"

printf '%s\n' "$FIXTURE"

value_from_fixture() {
    local name="$1"

    awk \
        -F= \
        -v name="$name" \
        '$1 == name { print $2 }' \
        <<<"$FIXTURE"
}

USER_ID="$(value_from_fixture USER_ID)"
WORKSPACE_ID="$(value_from_fixture WORKSPACE_ID)"
FOREIGN_WORKSPACE_ID="$(value_from_fixture FOREIGN_WORKSPACE_ID)"
OWN_MESSAGE_ID="$(value_from_fixture OWN_MESSAGE_ID)"
FOREIGN_MESSAGE_ID="$(value_from_fixture FOREIGN_MESSAGE_ID)"

for value in \
    "$USER_ID" \
    "$WORKSPACE_ID" \
    "$FOREIGN_WORKSPACE_ID" \
    "$OWN_MESSAGE_ID" \
    "$FOREIGN_MESSAGE_ID"
do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] \
        || {
            echo "FAIL: invalid fixture identifier" >&2
            exit 1
        }
done

BODY="$(
    mktemp \
        /tmp/heymail-profile-scope.XXXXXX
)"

STATUS="$(
    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --output "$BODY" \
        --write-out '%{http_code}' \
        --header "Cookie: heymail_session=${TOKEN}" \
        https://api.heymail.test:8443/console/profile
)"

[ "$STATUS" = "200" ] \
    || {
        cat "$BODY" >&2
        echo "FAIL: profile returned HTTP $STATUS" >&2
        exit 1
    }

python3 \
    - "$BODY" "$EMAIL" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    data = json.load(handle)

print(
    "stats="
    + json.dumps(
        data["stats"],
        sort_keys=True,
        separators=(",", ":"),
    )
)

assert data["user"]["email"] == sys.argv[2]
assert data["stats"]["messagesSent"] == 1
assert (
    data["stats"]["messagesSentScope"]
    == "workspace"
)

print(
    "messagesSent="
    f'{data["stats"]["messagesSent"]}'
)
print(
    "messagesSentScope="
    f'{data["stats"]["messagesSentScope"]}'
)
PY

echo "PASS: PROFILE MESSAGE STATS ARE WORKSPACE-SCOPED"
