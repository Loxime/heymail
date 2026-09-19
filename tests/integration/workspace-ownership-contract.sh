#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
        && pwd
)"
cd "$ROOT_DIR"

EXPAND_VERSION='DoctrineMigrations\Version20260919170000'
TOKEN="$(openssl rand -hex 16)"
HASH="$(
    printf '%s' "workspace-contract:$TOKEN" \
        | sha256sum \
        | awk '{ print $1 }'
)"
TMP_DIR="$(mktemp -d /tmp/heymail-workspace-contract.XXXXXX)"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

migrate_latest() {
    docker compose run \
        --rm \
        --no-deps \
        -T \
        database-migrate \
        </dev/null
}

migrate_expand() {
    docker compose run \
        --rm \
        --no-deps \
        -T \
        database-migrate \
        "$EXPAND_VERSION" \
        </dev/null
}

delete_fixture() {
    docker compose exec \
        -T \
        -e FIXTURE_HASH="$HASH" \
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
    trim(file_get_contents((string) getenv('DB_PASSWORD_FILE'))),
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION],
);

$stmt = $pdo->prepare(
    <<<'SQL'
DELETE FROM outbound_message
WHERE idempotency_key_hash = :hash
SQL
);
$stmt->execute(['hash' => getenv('FIXTURE_HASH')]);
PHP
}

cleanup() {
    result=$?
    trap - EXIT
    set +e
    delete_fixture
    migrate_latest >/dev/null 2>&1
    rm -rf "$TMP_DIR"
    exit "$result"
}
trap cleanup EXIT

schema_state() {
    docker compose exec -T api php <<'PHP'
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
    trim(file_get_contents((string) getenv('DB_PASSWORD_FILE'))),
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION],
);

foreach (['sending_domain', 'outbound_message', 'webhook_endpoint'] as $table) {
    $column = $pdo->prepare(
        <<<'SQL'
SELECT is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = :table_name
  AND column_name = 'workspace_id'
SQL
    );
    $column->execute(['table_name' => $table]);
    $nullable = $column->fetchColumn();
    if (!is_string($nullable)) {
        exit(2);
    }
    $missing = (int) $pdo->query(
        sprintf(
            'SELECT COUNT(*) FROM %s WHERE workspace_id IS NULL',
            $table,
        ),
    )->fetchColumn();

    echo strtoupper($table), '_NULLABLE=', $nullable, PHP_EOL;
    echo strtoupper($table), '_MISSING=', $missing, PHP_EOL;
}
PHP
}

echo "=== WORKSPACE OWNERSHIP CONTRACT ==="

docker compose up -d --wait database api >/dev/null

echo
echo "=== UP: CONTRACT ==="
migrate_latest >/dev/null
STATE="$(schema_state)"
printf '%s\n' "$STATE"
for table in SENDING_DOMAIN OUTBOUND_MESSAGE WEBHOOK_ENDPOINT; do
    grep -Fxq "${table}_NULLABLE=NO" <<<"$STATE" \
        || fail "$table is still nullable after contract"
    grep -Fxq "${table}_MISSING=0" <<<"$STATE" \
        || fail "$table has NULL ownership after contract"
done
echo "PASS: contract migration sets all three ownership roots NOT NULL"

echo
echo "=== DOWN: EXPAND ==="
migrate_expand >/dev/null
DOWN_STATE="$(schema_state)"
printf '%s\n' "$DOWN_STATE"
for table in SENDING_DOMAIN OUTBOUND_MESSAGE WEBHOOK_ENDPOINT; do
    grep -Fxq "${table}_NULLABLE=YES" <<<"$DOWN_STATE" \
        || fail "$table did not become nullable after contract down"
done
echo "PASS: contract migration is reversible to expand"

echo
echo "=== HOSTILE NULL PRECONDITION ==="
docker compose exec \
    -T \
    -e FIXTURE_HASH="$HASH" \
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
    trim(file_get_contents((string) getenv('DB_PASSWORD_FILE'))),
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION],
);

$stmt = $pdo->prepare(
    <<<'SQL'
INSERT INTO outbound_message (
    workspace_id,
    idempotency_key_hash,
    status,
    created_at
)
VALUES (
    NULL,
    :hash,
    'queued',
    timezone('UTC', CURRENT_TIMESTAMP)
)
SQL
);
$stmt->execute(['hash' => getenv('FIXTURE_HASH')]);
PHP

set +e
docker compose run \
    --rm \
    --no-deps \
    -T \
    database-migrate \
    </dev/null \
    >"$TMP_DIR/expected-failure.log" \
    2>&1
RC=$?
set -e

[ "$RC" -ne 0 ] \
    || fail "contract migration accepted a NULL-owned root"

grep -Fq \
    'Cannot enforce workspace ownership contract' \
    "$TMP_DIR/expected-failure.log" \
    || {
        cat "$TMP_DIR/expected-failure.log" >&2
        fail "contract migration failed for an unexpected reason"
    }

echo "PASS: contract migration fails closed on NULL ownership"

delete_fixture

echo
echo "=== UP AGAIN: CLEAN CONTRACT ==="
migrate_latest >/dev/null
FINAL_STATE="$(schema_state)"
printf '%s\n' "$FINAL_STATE"
for table in SENDING_DOMAIN OUTBOUND_MESSAGE WEBHOOK_ENDPOINT; do
    grep -Fxq "${table}_NULLABLE=NO" <<<"$FINAL_STATE" \
        || fail "$table is nullable after final contract up"
    grep -Fxq "${table}_MISSING=0" <<<"$FINAL_STATE" \
        || fail "$table has NULL ownership after final contract up"
done

echo
echo "PASS: WORKSPACE OWNERSHIP CONTRACT GATE GREEN"
