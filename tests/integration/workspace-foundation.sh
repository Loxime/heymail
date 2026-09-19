#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
        && pwd
)"
cd "$ROOT_DIR"

MARKER="$(openssl rand -hex 8)"
EMAIL="workspace-gate-${MARKER}@example.test"

echo "=== WORKSPACE FOUNDATION DB GATE ==="

RESULT="$(
    docker compose exec \
        -T \
        -e TEST_EMAIL="$EMAIL" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

require '/app/vendor/autoload.php';

use App\Console\ConsoleUserProvisioner;
use Doctrine\DBAL\DriverManager;

$email = getenv('TEST_EMAIL');

if (
    !is_string($email)
    || filter_var(
        $email,
        FILTER_VALIDATE_EMAIL,
    ) === false
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

$missingMemberships = $connection->fetchOne(
    <<<'SQL'
SELECT COUNT(*)
FROM console_user u
WHERE NOT EXISTS (
    SELECT 1
    FROM workspace_member wm
    WHERE wm.user_id = u.id
)
SQL
);

echo 'MISSING_MEMBERSHIPS=',
    (int) $missingMemberships,
    PHP_EOL;

if ((int) $missingMemberships !== 0) {
    exit(3);
}

$provisioner = new ConsoleUserProvisioner(
    $connection,
);

$now = new DateTimeImmutable(
    'now',
    new DateTimeZone('UTC'),
);

$hash = password_hash(
    bin2hex(random_bytes(32)),
    PASSWORD_DEFAULT,
);

if (!is_string($hash)) {
    exit(4);
}

$userId = $provisioner->create(
    email: $email,
    firstName: 'WorkspaceGate',
    lastName: 'User',
    passwordHash: $hash,
    now: $now,
);

echo 'USER_ID=', $userId, PHP_EOL;

$row = $connection->fetchAssociative(
    <<<'SQL'
SELECT
    w.id AS workspace_id,
    w.name,
    wm.role
FROM workspace_member wm
INNER JOIN workspace w
    ON w.id = wm.workspace_id
WHERE wm.user_id = :user_id
SQL,
    [
        'user_id' => $userId,
    ],
);

if (!is_array($row)) {
    exit(5);
}

$workspaceId = filter_var(
    $row['workspace_id'] ?? null,
    FILTER_VALIDATE_INT,
    [
        'options' => [
            'min_range' => 1,
        ],
    ],
);

if (!is_int($workspaceId)) {
    exit(6);
}

echo 'WORKSPACE_ID=', $workspaceId, PHP_EOL;
echo 'WORKSPACE_NAME=', (string) $row['name'], PHP_EOL;
echo 'ROLE=', (string) $row['role'], PHP_EOL;

if (
    $row['name'] !== 'WorkspaceGate workspace'
    || $row['role'] !== 'owner'
) {
    exit(7);
}

$provisioner->delete(
    $userId,
);

$userCount = $connection->fetchOne(
    'SELECT COUNT(*) FROM console_user WHERE id = :id',
    [
        'id' => $userId,
    ],
);

$membershipCount = $connection->fetchOne(
    'SELECT COUNT(*) FROM workspace_member WHERE user_id = :id',
    [
        'id' => $userId,
    ],
);

$workspaceCount = $connection->fetchOne(
    'SELECT COUNT(*) FROM workspace WHERE id = :id',
    [
        'id' => $workspaceId,
    ],
);

echo 'USER_AFTER_DELETE=', (int) $userCount, PHP_EOL;
echo 'MEMBERSHIP_AFTER_DELETE=', (int) $membershipCount, PHP_EOL;
echo 'WORKSPACE_AFTER_DELETE=', (int) $workspaceCount, PHP_EOL;

if (
    (int) $userCount !== 0
    || (int) $membershipCount !== 0
    || (int) $workspaceCount !== 0
) {
    exit(8);
}

echo 'WORKSPACE_FOUNDATION=true', PHP_EOL;
PHP
)"

printf '%s\n' "$RESULT"

grep -Fxq 'MISSING_MEMBERSHIPS=0' <<<"$RESULT"
grep -Fxq 'WORKSPACE_NAME=WorkspaceGate workspace' <<<"$RESULT"
grep -Fxq 'ROLE=owner' <<<"$RESULT"
grep -Fxq 'USER_AFTER_DELETE=0' <<<"$RESULT"
grep -Fxq 'MEMBERSHIP_AFTER_DELETE=0' <<<"$RESULT"
grep -Fxq 'WORKSPACE_AFTER_DELETE=0' <<<"$RESULT"
grep -Fxq 'WORKSPACE_FOUNDATION=true' <<<"$RESULT"

echo "PASS: WORKSPACE FOUNDATION DB GATE GREEN"
