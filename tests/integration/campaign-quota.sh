#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

MARKER="$(openssl rand -hex 8)"
TEST_EMAIL="campaign-quota-${MARKER}@example.test"
USER_ID=""
WORKSPACE_ID=""
CAMPAIGN_ID=""

cleanup() {
  rc=$?
  trap - EXIT
  set +e

  docker compose exec \
    -T \
    -e TEST_EMAIL="$TEST_EMAIL" \
    api \
    php <<'PHP' >/dev/null 2>&1
<?php
declare(strict_types=1);

require '/app/vendor/autoload.php';

use App\Console\ConsoleUserProvisioner;
use Doctrine\DBAL\DriverManager;

$c = DriverManager::getConnection([
    'driver' => 'pdo_pgsql',
    'host' => getenv('DB_HOST'),
    'port' => getenv('DB_PORT'),
    'dbname' => getenv('DB_NAME'),
    'user' => getenv('DB_USER'),
    'password' => trim(file_get_contents((string) getenv('DB_PASSWORD_FILE'))),
]);

$userId = $c->fetchOne(
    'SELECT id FROM console_user WHERE email = :email',
    ['email' => getenv('TEST_EMAIL')],
);

if ($userId === false) {
    exit;
}

$userId = (int) $userId;
$workspaceIds = $c->fetchFirstColumn(
    'SELECT workspace_id FROM workspace_member WHERE user_id = :user_id',
    ['user_id' => $userId],
);

foreach ($workspaceIds as $workspaceId) {
    $workspaceId = (int) $workspaceId;

    $messageIds = $c->fetchFirstColumn(
        'SELECT id FROM outbound_message WHERE workspace_id = :workspace_id',
        ['workspace_id' => $workspaceId],
    );

    $c->executeStatement(
        'DELETE FROM campaign WHERE workspace_id = :workspace_id',
        ['workspace_id' => $workspaceId],
    );

    foreach ($messageIds as $messageId) {
        $messageId = (int) $messageId;

        $c->executeStatement(
            'DELETE FROM messenger_messages
             WHERE queue_name = :queue
               AND body LIKE :needle',
            [
                'queue' => 'outbound',
                'needle' => '%"outboundMessageId":' . $messageId . '%',
            ],
        );

        $c->delete(
            'outbound_message',
            ['id' => $messageId],
        );
    }
}

(new ConsoleUserProvisioner($c))->delete($userId);
PHP

  rm -rf "${TMP_DIR:-}"
  exit "$rc"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

TMP_DIR="$(mktemp -d /tmp/heymail-campaign-quota.XXXXXX)"

echo "=== HeyMail campaign quota E2E ==="

docker compose up -d --wait database api gateway >/dev/null
docker compose stop mail-worker campaign-worker >/dev/null 2>&1 || true

FIXTURE="$(
  docker compose exec \
    -T \
    -e TEST_EMAIL="$TEST_EMAIL" \
    -e MARKER="$MARKER" \
    api \
    php <<'PHP'
<?php
declare(strict_types=1);

require '/app/vendor/autoload.php';

use App\Campaign\CampaignSnapshotCipher;
use App\Console\ConsoleUserProvisioner;
use Doctrine\DBAL\DriverManager;

$c = DriverManager::getConnection([
    'driver' => 'pdo_pgsql',
    'host' => getenv('DB_HOST'),
    'port' => getenv('DB_PORT'),
    'dbname' => getenv('DB_NAME'),
    'user' => getenv('DB_USER'),
    'password' => trim(file_get_contents((string) getenv('DB_PASSWORD_FILE'))),
]);

$now = new DateTimeImmutable('now', new DateTimeZone('UTC'));
$hash = password_hash(bin2hex(random_bytes(24)), PASSWORD_DEFAULT);

if (!is_string($hash)) {
    throw new RuntimeException('Password hash failed.');
}

$userId = (new ConsoleUserProvisioner($c))->create(
    (string) getenv('TEST_EMAIL'),
    'Quota',
    'Campaign',
    $hash,
    $now,
);

$workspaceId = (int) $c->fetchOne(
    'SELECT workspace_id FROM workspace_member WHERE user_id = :user_id',
    ['user_id' => $userId],
);

$campaignId = (int) $c->fetchOne(
    <<<'SQL'
INSERT INTO campaign (
    workspace_id,
    name,
    status,
    scheduled_for,
    snapshot_at,
    template_version,
    recipient_count,
    snapshot_ciphertext,
    snapshot_nonce,
    snapshot_wrapped_dek,
    snapshot_wrap_nonce,
    snapshot_algorithm,
    snapshot_key_version,
    created_at,
    updated_at
)
VALUES (
    :workspace_id,
    :name,
    'ready',
    :now,
    :now,
    1,
    3,
    'placeholder',
    'placeholder',
    'placeholder',
    'placeholder',
    'placeholder',
    1,
    :now,
    :now
)
RETURNING id
SQL,
    [
        'workspace_id' => $workspaceId,
        'name' => 'Quota ' . getenv('MARKER'),
        'now' => $now->format('Y-m-d H:i:s'),
    ],
);

$recipients = [];

for ($index = 0; $index < 3; ++$index) {
    $recipients[] = [
        'email' => sprintf(
            'quota-%d-%s@example.test',
            $index,
            getenv('MARKER'),
        ),
        'name' => 'Quota Recipient ' . $index,
        'variables' => [
            'first_name' => 'User' . $index,
        ],
    ];
}

$encrypted = (
    new CampaignSnapshotCipher(
        (string) getenv('PAYLOAD_KEK_FILE'),
    )
)->encrypt(
    $workspaceId,
    $campaignId,
    [
        'sender' => [
            'email' => 'sender@example.test',
        ],
        'template' => [
            'version' => 1,
            'subject' => 'Hello {{first_name}}',
            'text' => 'Quota {{first_name}}',
            'html' => null,
        ],
        'recipients' => $recipients,
    ],
);

$c->update(
    'campaign',
    [
        'snapshot_ciphertext' => $encrypted['ciphertext'],
        'snapshot_nonce' => $encrypted['nonce'],
        'snapshot_wrapped_dek' => $encrypted['wrappedDek'],
        'snapshot_wrap_nonce' => $encrypted['wrapNonce'],
        'snapshot_algorithm' => $encrypted['algorithm'],
        'snapshot_key_version' => $encrypted['keyVersion'],
    ],
    ['id' => $campaignId],
);

echo "USER_ID=$userId\n";
echo "WORKSPACE_ID=$workspaceId\n";
echo "CAMPAIGN_ID=$campaignId\n";
PHP
)"

value() {
  awk -F= -v key="$1" '$1 == key { print $2 }' <<<"$FIXTURE"
}

USER_ID="$(value USER_ID)"
WORKSPACE_ID="$(value WORKSPACE_ID)"
CAMPAIGN_ID="$(value CAMPAIGN_ID)"

for id in "$USER_ID" "$WORKSPACE_ID" "$CAMPAIGN_ID"; do
  [[ "$id" =~ ^[1-9][0-9]*$ ]] || fail "invalid fixture identifier"
done

run_worker() {
  docker compose run \
    --rm \
    --no-deps \
    -T \
    -e HEYMAIL_CAMPAIGN_QUOTA_PER_HOUR=2 \
    api \
    php bin/console app:campaign:worker \
    --once \
    --no-interaction \
    </dev/null \
    >/dev/null
}

state() {
  docker compose exec \
    -T \
    -e CAMPAIGN_ID="$CAMPAIGN_ID" \
    -e WORKSPACE_ID="$WORKSPACE_ID" \
    api \
    php <<'PHP'
<?php
declare(strict_types=1);

require '/app/vendor/autoload.php';

use Doctrine\DBAL\DriverManager;

$c = DriverManager::getConnection([
    'driver' => 'pdo_pgsql',
    'host' => getenv('DB_HOST'),
    'port' => getenv('DB_PORT'),
    'dbname' => getenv('DB_NAME'),
    'user' => getenv('DB_USER'),
    'password' => trim(file_get_contents((string) getenv('DB_PASSWORD_FILE'))),
]);

$campaignId = (int) getenv('CAMPAIGN_ID');
$workspaceId = (int) getenv('WORKSPACE_ID');

$row = $c->fetchAssociative(
    'SELECT status, processed_count, last_error, completed_at
     FROM campaign
     WHERE id = :id',
    ['id' => $campaignId],
);

$deliveries = (int) $c->fetchOne(
    'SELECT COUNT(*) FROM campaign_delivery WHERE campaign_id = :id',
    ['id' => $campaignId],
);

$distinctMessages = (int) $c->fetchOne(
    'SELECT COUNT(DISTINCT outbound_message_id)
     FROM campaign_delivery
     WHERE campaign_id = :id',
    ['id' => $campaignId],
);

$reservations = (int) $c->fetchOne(
    'SELECT COUNT(*)
     FROM campaign_quota_reservation
     WHERE workspace_id = :workspace_id
       AND campaign_id = :campaign_id',
    [
        'workspace_id' => $workspaceId,
        'campaign_id' => $campaignId,
    ],
);

$outbound = (int) $c->fetchOne(
    'SELECT COUNT(*)
     FROM outbound_message
     WHERE workspace_id = :workspace_id',
    ['workspace_id' => $workspaceId],
);

echo 'STATUS=', $row['status'], "\n";
echo 'PROCESSED=', $row['processed_count'], "\n";
echo 'LAST_ERROR=', $row['last_error'] ?? '', "\n";
echo 'COMPLETED=', $row['completed_at'] === null ? 'no' : 'yes', "\n";
echo 'DELIVERIES=', $deliveries, "\n";
echo 'DISTINCT_MESSAGES=', $distinctMessages, "\n";
echo 'RESERVATIONS=', $reservations, "\n";
echo 'OUTBOUND=', $outbound, "\n";
PHP
}

run_worker
FIRST="$(state)"

grep -Fq 'STATUS=ready' <<<"$FIRST"
grep -Fq 'PROCESSED=2' <<<"$FIRST"
grep -Fq 'DELIVERIES=2' <<<"$FIRST"
grep -Fq 'DISTINCT_MESSAGES=2' <<<"$FIRST"
grep -Fq 'RESERVATIONS=2' <<<"$FIRST"
grep -Fq 'OUTBOUND=2' <<<"$FIRST"
grep -Fq 'partially exhausted' <<<"$FIRST"

echo "PASS: campaign quota limits first batch to exactly two recipients"

run_worker
SECOND="$(state)"

grep -Fq 'STATUS=ready' <<<"$SECOND"
grep -Fq 'PROCESSED=2' <<<"$SECOND"
grep -Fq 'DELIVERIES=2' <<<"$SECOND"
grep -Fq 'OUTBOUND=2' <<<"$SECOND"
grep -Fq 'hourly quota exhausted' <<<"$SECOND"

echo "PASS: exhausted hourly quota prevents additional submissions"

docker compose exec \
  -T \
  -e CAMPAIGN_ID="$CAMPAIGN_ID" \
  api \
  php -r '
    $pdo = new PDO(
        sprintf(
            "pgsql:host=%s;port=%s;dbname=%s",
            getenv("DB_HOST"),
            getenv("DB_PORT"),
            getenv("DB_NAME"),
        ),
        getenv("DB_USER"),
        trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION],
    );

    $statement = $pdo->prepare(
        "DELETE FROM campaign_quota_reservation WHERE campaign_id = :id"
    );
    $statement->execute([
        "id" => (int) getenv("CAMPAIGN_ID"),
    ]);
  ' \
  </dev/null

run_worker
THIRD="$(state)"

grep -Fq 'STATUS=completed' <<<"$THIRD"
grep -Fq 'PROCESSED=3' <<<"$THIRD"
grep -Fq 'COMPLETED=yes' <<<"$THIRD"
grep -Fq 'DELIVERIES=3' <<<"$THIRD"
grep -Fq 'DISTINCT_MESSAGES=3' <<<"$THIRD"
grep -Fq 'OUTBOUND=3' <<<"$THIRD"

echo "PASS: campaign resumes after quota window capacity becomes available"

docker compose exec \
  -T \
  -e CAMPAIGN_ID="$CAMPAIGN_ID" \
  api \
  php -r '
    $pdo = new PDO(
        sprintf(
            "pgsql:host=%s;port=%s;dbname=%s",
            getenv("DB_HOST"),
            getenv("DB_PORT"),
            getenv("DB_NAME"),
        ),
        getenv("DB_USER"),
        trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION],
    );

    $statement = $pdo->prepare(
        "UPDATE campaign
         SET status = '\''ready'\'',
             processed_count = 2,
             completed_at = NULL,
             updated_at = CURRENT_TIMESTAMP
         WHERE id = :id"
    );
    $statement->execute([
        "id" => (int) getenv("CAMPAIGN_ID"),
    ]);
  ' \
  </dev/null

run_worker
REPLAY="$(state)"

grep -Fq 'STATUS=completed' <<<"$REPLAY"
grep -Fq 'PROCESSED=3' <<<"$REPLAY"
grep -Fq 'DELIVERIES=3' <<<"$REPLAY"
grep -Fq 'DISTINCT_MESSAGES=3' <<<"$REPLAY"
grep -Fq 'OUTBOUND=3' <<<"$REPLAY"

echo "PASS: deterministic campaign idempotency survives recipient replay"
echo "ALL CAMPAIGN QUOTA TESTS PASSED"
