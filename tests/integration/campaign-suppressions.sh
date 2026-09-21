#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

MARKER="$(openssl rand -hex 8)"
TEST_EMAIL="campaign-suppression-$MARKER@example.test"
USER_ID=""
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

$c=DriverManager::getConnection([
 'driver'=>'pdo_pgsql',
 'host'=>getenv('DB_HOST'),
 'port'=>getenv('DB_PORT'),
 'dbname'=>getenv('DB_NAME'),
 'user'=>getenv('DB_USER'),
 'password'=>trim(file_get_contents((string)getenv('DB_PASSWORD_FILE'))),
]);

$userId=$c->fetchOne(
 'SELECT id FROM console_user WHERE email=:email',
 ['email'=>getenv('TEST_EMAIL')],
);

if($userId===false){exit;}

$userId=(int)$userId;
$workspaceId=(int)$c->fetchOne(
 'SELECT workspace_id FROM workspace_member WHERE user_id=:id',
 ['id'=>$userId],
);

$messageIds=$c->fetchFirstColumn(
 'SELECT id FROM outbound_message WHERE workspace_id=:workspace_id',
 ['workspace_id'=>$workspaceId],
);

$c->executeStatement(
 'DELETE FROM campaign WHERE workspace_id=:workspace_id',
 ['workspace_id'=>$workspaceId],
);

foreach($messageIds as $messageId){
 $messageId=(int)$messageId;

 $c->executeStatement(
  'DELETE FROM messenger_messages
   WHERE queue_name=:queue
     AND body LIKE :needle',
  [
   'queue'=>'outbound',
   'needle'=>'%"outboundMessageId":'.$messageId.'%',
  ],
 );

 $c->delete(
  'outbound_message',
  ['id'=>$messageId],
 );
}

(new ConsoleUserProvisioner($c))->delete($userId);
PHP

  exit "$rc"
}
trap cleanup EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== HeyMail campaign suppression enforcement E2E ==="

docker compose up \
  -d \
  --wait \
  database \
  api \
  >/dev/null

docker compose stop \
  mail-worker \
  campaign-worker \
  >/dev/null 2>&1 || true

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
use App\Suppression\EmailSuppressionService;
use Doctrine\DBAL\DriverManager;

$c=DriverManager::getConnection([
 'driver'=>'pdo_pgsql',
 'host'=>getenv('DB_HOST'),
 'port'=>getenv('DB_PORT'),
 'dbname'=>getenv('DB_NAME'),
 'user'=>getenv('DB_USER'),
 'password'=>trim(file_get_contents((string)getenv('DB_PASSWORD_FILE'))),
]);

$now=new DateTimeImmutable('now',new DateTimeZone('UTC'));
$hash=password_hash(bin2hex(random_bytes(24)),PASSWORD_DEFAULT);
if(!is_string($hash)){throw new RuntimeException('hash');}

$userId=(new ConsoleUserProvisioner($c))->create(
 (string)getenv('TEST_EMAIL'),
 'Campaign',
 'Suppression',
 $hash,
 $now,
);

$workspaceId=(int)$c->fetchOne(
 'SELECT workspace_id FROM workspace_member WHERE user_id=:id',
 ['id'=>$userId],
);

$listId=(int)$c->fetchOne(
 'INSERT INTO contact_list(workspace_id,name,created_at,updated_at)
  VALUES(:w,:n,:t,:t) RETURNING id',
 [
  'w'=>$workspaceId,
  'n'=>'Suppressed audience '.getenv('MARKER'),
  't'=>$now->format('Y-m-d H:i:s'),
 ],
);

$campaignId=(int)$c->fetchOne(
 <<<'SQL'
INSERT INTO campaign(
 workspace_id,
 name,
 source_list_id,
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
VALUES(
 :workspace_id,
 :name,
 :list_id,
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
  'workspace_id'=>$workspaceId,
  'name'=>'Suppression '.getenv('MARKER'),
  'list_id'=>$listId,
  'now'=>$now->format('Y-m-d H:i:s'),
 ],
);

$emails=[
 'global-'.getenv('MARKER').'@example.test',
 'list-'.getenv('MARKER').'@example.test',
 'active-'.getenv('MARKER').'@example.test',
];

$recipients=[];

foreach($emails as $index=>$email){
 $recipients[]=[
  'email'=>$email,
  'name'=>'Recipient '.$index,
  'variables'=>[
   'first_name'=>'User'.$index,
  ],
 ];
}

$encrypted=(new CampaignSnapshotCipher(
 (string)getenv('PAYLOAD_KEK_FILE'),
))->encrypt(
 $workspaceId,
 $campaignId,
 [
  'sender'=>[
   'email'=>'sender@example.test',
  ],
  'template'=>[
   'version'=>1,
   'subject'=>'Hello {{first_name}}',
   'text'=>'Body {{first_name}}',
   'html'=>null,
  ],
  'recipients'=>$recipients,
 ],
);

$c->update(
 'campaign',
 [
  'snapshot_ciphertext'=>$encrypted['ciphertext'],
  'snapshot_nonce'=>$encrypted['nonce'],
  'snapshot_wrapped_dek'=>$encrypted['wrappedDek'],
  'snapshot_wrap_nonce'=>$encrypted['wrapNonce'],
  'snapshot_algorithm'=>$encrypted['algorithm'],
  'snapshot_key_version'=>$encrypted['keyVersion'],
 ],
 ['id'=>$campaignId],
);

$suppressions=new EmailSuppressionService($c);

$suppressions->suppressGlobal(
 $workspaceId,
 $emails[0],
 'manual',
);

$suppressions->suppressList(
 $workspaceId,
 $listId,
 $emails[1],
 'manual',
);

echo "USER_ID=$userId\n";
echo "WORKSPACE_ID=$workspaceId\n";
echo "CAMPAIGN_ID=$campaignId\n";
PHP
)"

value(){ awk -F= -v key="$1" '$1==key{print $2}' <<<"$FIXTURE"; }

USER_ID="$(value USER_ID)"
WORKSPACE_ID="$(value WORKSPACE_ID)"
CAMPAIGN_ID="$(value CAMPAIGN_ID)"

for x in "$USER_ID" "$WORKSPACE_ID" "$CAMPAIGN_ID"; do
  [[ "$x" =~ ^[1-9][0-9]*$ ]] || fail "invalid fixture id"
done

docker compose run \
  --rm \
  --no-deps \
  -T \
  api \
  php bin/console app:campaign:worker \
  --once \
  --no-interaction \
  </dev/null \
  >/dev/null

STATE="$(
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

$c=DriverManager::getConnection([
 'driver'=>'pdo_pgsql',
 'host'=>getenv('DB_HOST'),
 'port'=>getenv('DB_PORT'),
 'dbname'=>getenv('DB_NAME'),
 'user'=>getenv('DB_USER'),
 'password'=>trim(file_get_contents((string)getenv('DB_PASSWORD_FILE'))),
]);

$campaignId=(int)getenv('CAMPAIGN_ID');
$workspaceId=(int)getenv('WORKSPACE_ID');

$row=$c->fetchAssociative(
 'SELECT status,processed_count
  FROM campaign
  WHERE id=:id',
 ['id'=>$campaignId],
);

echo 'STATUS=',$row['status'],"\n";
echo 'PROCESSED=',$row['processed_count'],"\n";

echo 'DELIVERIES=',(int)$c->fetchOne(
 'SELECT COUNT(*)
  FROM campaign_delivery
  WHERE campaign_id=:id',
 ['id'=>$campaignId],
),"\n";

echo 'SKIPS=',(int)$c->fetchOne(
 'SELECT COUNT(*)
  FROM campaign_recipient_skip
  WHERE campaign_id=:id',
 ['id'=>$campaignId],
),"\n";

echo 'QUOTA=',(int)$c->fetchOne(
 'SELECT COUNT(*)
  FROM campaign_quota_reservation
  WHERE campaign_id=:id',
 ['id'=>$campaignId],
),"\n";

echo 'OUTBOUND=',(int)$c->fetchOne(
 'SELECT COUNT(*)
  FROM outbound_message
  WHERE workspace_id=:workspace_id',
 ['workspace_id'=>$workspaceId],
),"\n";

$reasons=$c->fetchFirstColumn(
 'SELECT reason
  FROM campaign_recipient_skip
  WHERE campaign_id=:id
  ORDER BY recipient_index',
 ['id'=>$campaignId],
);

echo 'REASONS=',implode(',',$reasons),"\n";
PHP
)"

printf '%s\n' "$STATE"

grep -Fqx 'STATUS=completed' <<<"$STATE"
grep -Fqx 'PROCESSED=3' <<<"$STATE"
grep -Fqx 'DELIVERIES=1' <<<"$STATE"
grep -Fqx 'SKIPS=2' <<<"$STATE"
grep -Fqx 'QUOTA=1' <<<"$STATE"
grep -Fqx 'OUTBOUND=1' <<<"$STATE"
grep -Fqx 'REASONS=manual,manual' <<<"$STATE"

echo "PASS: global and list suppressions skip campaign recipients without consuming send quota"
echo "ALL CAMPAIGN SUPPRESSION TESTS PASSED"
