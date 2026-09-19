#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
        && pwd
)"
cd "$ROOT_DIR"

echo "=== WORKSPACE OWNERSHIP BACKFILL ==="

RESULT="$(
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

$legacy = $pdo->query(
    <<<'SQL'
SELECT id
FROM workspace
WHERE name = 'HeyMail Legacy Workspace'
ORDER BY id ASC
LIMIT 1
SQL
)->fetchColumn();

if (
    !is_int($legacy)
    && !is_string($legacy)
) {
    exit(2);
}

$legacyId = (int) $legacy;

if ($legacyId < 1) {
    exit(3);
}

echo 'LEGACY_WORKSPACE_ID=', $legacyId, PHP_EOL;

$tables = [
    'sending_domain',
    'outbound_message',
    'webhook_endpoint',
];

foreach ($tables as $table) {
    if (
        preg_match(
            '/^[a-z_]+$/D',
            $table,
        ) !== 1
    ) {
        exit(4);
    }

    $missing = (int) $pdo
        ->query(
            sprintf(
                'SELECT COUNT(*) FROM %s WHERE workspace_id IS NULL',
                $table,
            ),
        )
        ->fetchColumn();

    $foreign = $pdo->prepare(
        sprintf(
            'SELECT COUNT(*) FROM %s WHERE workspace_id <> :workspace_id',
            $table,
        ),
    );

    $foreign->execute([
        'workspace_id' => $legacyId,
    ]);

    $otherWorkspace = (int) $foreign
        ->fetchColumn();

    echo strtoupper($table),
        '_MISSING=',
        $missing,
        PHP_EOL;

    echo strtoupper($table),
        '_OTHER_WORKSPACE=',
        $otherWorkspace,
        PHP_EOL;

    if (
        $missing !== 0
        || $otherWorkspace !== 0
    ) {
        exit(5);
    }
}

$columns = $pdo->query(
    <<<'SQL'
SELECT
    table_name,
    is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND column_name = 'workspace_id'
  AND table_name IN (
      'sending_domain',
      'outbound_message',
      'webhook_endpoint'
  )
ORDER BY table_name
SQL
)->fetchAll(PDO::FETCH_ASSOC);

if (count($columns) !== 3) {
    exit(6);
}

foreach ($columns as $column) {
    echo strtoupper((string) $column['table_name']),
        '_NULLABLE=',
        (string) $column['is_nullable'],
        PHP_EOL;

    /*
     * Expected during the expand phase. The next ownership commit will
     * enforce non-null writes before the contract migration.
     */
    if ($column['is_nullable'] !== 'YES') {
        exit(7);
    }
}

$constraints = $pdo->query(
    <<<'SQL'
SELECT
    tc.constraint_name,
    rc.delete_rule
FROM information_schema.table_constraints tc
INNER JOIN information_schema.referential_constraints rc
    ON rc.constraint_schema = tc.constraint_schema
   AND rc.constraint_name = tc.constraint_name
WHERE tc.constraint_schema = 'public'
  AND tc.constraint_name IN (
      'fk_sending_domain_workspace',
      'fk_outbound_message_workspace',
      'fk_webhook_endpoint_workspace'
  )
ORDER BY tc.constraint_name
SQL
)->fetchAll(PDO::FETCH_ASSOC);

if (count($constraints) !== 3) {
    exit(8);
}

foreach ($constraints as $constraint) {
    echo strtoupper((string) $constraint['constraint_name']),
        '_DELETE_RULE=',
        (string) $constraint['delete_rule'],
        PHP_EOL;

    if ($constraint['delete_rule'] !== 'RESTRICT') {
        exit(9);
    }
}

echo 'WORKSPACE_OWNERSHIP_BACKFILL=true', PHP_EOL;
PHP
)"

printf '%s\n' "$RESULT"

grep -Fxq 'SENDING_DOMAIN_MISSING=0' <<<"$RESULT"
grep -Fxq 'OUTBOUND_MESSAGE_MISSING=0' <<<"$RESULT"
grep -Fxq 'WEBHOOK_ENDPOINT_MISSING=0' <<<"$RESULT"

grep -Fxq 'SENDING_DOMAIN_OTHER_WORKSPACE=0' <<<"$RESULT"
grep -Fxq 'OUTBOUND_MESSAGE_OTHER_WORKSPACE=0' <<<"$RESULT"
grep -Fxq 'WEBHOOK_ENDPOINT_OTHER_WORKSPACE=0' <<<"$RESULT"

grep -Fxq 'SENDING_DOMAIN_NULLABLE=YES' <<<"$RESULT"
grep -Fxq 'OUTBOUND_MESSAGE_NULLABLE=YES' <<<"$RESULT"
grep -Fxq 'WEBHOOK_ENDPOINT_NULLABLE=YES' <<<"$RESULT"

grep -Fxq 'FK_SENDING_DOMAIN_WORKSPACE_DELETE_RULE=RESTRICT' <<<"$RESULT"
grep -Fxq 'FK_OUTBOUND_MESSAGE_WORKSPACE_DELETE_RULE=RESTRICT' <<<"$RESULT"
grep -Fxq 'FK_WEBHOOK_ENDPOINT_WORKSPACE_DELETE_RULE=RESTRICT' <<<"$RESULT"

grep -Fxq 'WORKSPACE_OWNERSHIP_BACKFILL=true' <<<"$RESULT"

echo "PASS: WORKSPACE OWNERSHIP BACKFILL GATE GREEN"
