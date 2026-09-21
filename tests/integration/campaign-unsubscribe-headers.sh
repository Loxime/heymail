#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

MARKER="$(openssl rand -hex 8)"
TEST_EMAIL="campaign-unsubscribe-$MARKER@example.test"
USER_ID=""
WORKSPACE_ID=""
CAMPAIGN_ID=""
OUTBOUND_ID=""

cleanup() {
  rc=$?
  trap - EXIT
  set +e

  docker compose exec -T fake-mx-success \
    rm -f /capture/last.eml \
    >/dev/null 2>&1 || true

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
 'driver'=>'pdo_pgsql','host'=>getenv('DB_HOST'),'port'=>getenv('DB_PORT'),
 'dbname'=>getenv('DB_NAME'),'user'=>getenv('DB_USER'),
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
 'SELECT id FROM outbound_message WHERE workspace_id=:w',
 ['w'=>$workspaceId],
);

$c->executeStatement(
 'DELETE FROM campaign WHERE workspace_id=:w',
 ['w'=>$workspaceId],
);

foreach($messageIds as $messageId){
 $c->executeStatement(
  'DELETE FROM messenger_messages
   WHERE queue_name=:queue
     AND body LIKE :needle',
  [
   'queue'=>'outbound',
   'needle'=>'%"outboundMessageId":'.(int)$messageId.'%',
  ],
 );
 $c->delete('outbound_message',['id'=>(int)$messageId]);
}

try{
 (new ConsoleUserProvisioner($c))->delete($userId);
}catch(Throwable){}
PHP

  exit "$rc"
}
trap cleanup EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== HeyMail campaign unsubscribe headers E2E ==="

docker compose up \
  -d \
  --wait \
  --build \
  database \
  api \
  postfix \
  rspamd \
  fake-mx-success \
  mail-worker \
  >/dev/null

docker compose stop \
  mail-worker \
  campaign-worker \
  >/dev/null 2>&1 || true

docker compose exec -T fake-mx-success \
  rm -f /capture/last.eml \
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
use Doctrine\DBAL\DriverManager;

$c=DriverManager::getConnection([
 'driver'=>'pdo_pgsql','host'=>getenv('DB_HOST'),'port'=>getenv('DB_PORT'),
 'dbname'=>getenv('DB_NAME'),'user'=>getenv('DB_USER'),
 'password'=>trim(file_get_contents((string)getenv('DB_PASSWORD_FILE'))),
]);

$now=new DateTimeImmutable('now',new DateTimeZone('UTC'));
$hash=password_hash(bin2hex(random_bytes(24)),PASSWORD_DEFAULT);
if(!is_string($hash)){throw new RuntimeException('hash');}

$userId=(new ConsoleUserProvisioner($c))->create(
 (string)getenv('TEST_EMAIL'),
 'Campaign',
 'Unsubscribe',
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
  'n'=>'Campaign unsubscribe '.getenv('MARKER'),
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
 :w,:name,:list,'ready',:now,:now,1,1,
 'placeholder','placeholder','placeholder','placeholder','placeholder',1,
 :now,:now
)
RETURNING id
SQL,
 [
  'w'=>$workspaceId,
  'name'=>'Unsubscribe '.getenv('MARKER'),
  'list'=>$listId,
  'now'=>$now->format('Y-m-d H:i:s'),
 ],
);

$recipient='unsubscribe-'.getenv('MARKER').'@success.test';

$encrypted=(new CampaignSnapshotCipher(
 (string)getenv('PAYLOAD_KEK_FILE'),
))->encrypt(
 $workspaceId,
 $campaignId,
 [
  'sender'=>['email'=>'sender@heymail.test'],
  'template'=>[
   'version'=>1,
   'subject'=>'Campaign unsubscribe',
   'text'=>'Visible text body',
   'html'=>'<p>Visible HTML body</p>',
  ],
  'recipients'=>[
   [
    'email'=>$recipient,
    'name'=>'Unsubscribe Test',
    'variables'=>[],
   ],
  ],
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

echo "USER_ID=$userId\n";
echo "WORKSPACE_ID=$workspaceId\n";
echo "CAMPAIGN_ID=$campaignId\n";
echo "RECIPIENT=$recipient\n";
PHP
)"

value(){ awk -F= -v key="$1" '$1==key{print substr($0,index($0,"=")+1)}' <<<"$FIXTURE"; }

USER_ID="$(value USER_ID)"
WORKSPACE_ID="$(value WORKSPACE_ID)"
CAMPAIGN_ID="$(value CAMPAIGN_ID)"
RECIPIENT="$(value RECIPIENT)"

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

OUTBOUND_ID="$(
docker compose exec \
  -T \
  -e CID="$CAMPAIGN_ID" \
  api \
  php -r '
$pdo=new PDO(
 sprintf("pgsql:host=%s;port=%s;dbname=%s",getenv("DB_HOST"),getenv("DB_PORT"),getenv("DB_NAME")),
 getenv("DB_USER"),trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$stmt=$pdo->prepare(
 "SELECT outbound_message_id FROM campaign_delivery WHERE campaign_id=:id"
);
$stmt->execute(["id"=>(int)getenv("CID")]);
echo $stmt->fetchColumn();
' </dev/null
)"

[[ "$OUTBOUND_ID" =~ ^[1-9][0-9]*$ ]] || fail "campaign outbound missing"

PLAIN="$(
docker compose exec \
  -T \
  -e OUTBOUND_ID="$OUTBOUND_ID" \
  -e RECIPIENT="$RECIPIENT" \
  api \
  php -r '
$pdo=new PDO(
 sprintf("pgsql:host=%s;port=%s;dbname=%s",getenv("DB_HOST"),getenv("DB_PORT"),getenv("DB_NAME")),
 getenv("DB_USER"),trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$stmt=$pdo->prepare("SELECT ciphertext FROM outbound_message_payload WHERE outbound_message_id=:id");
$stmt->execute(["id"=>(int)getenv("OUTBOUND_ID")]);
$c=(string)$stmt->fetchColumn();
echo str_contains($c,(string)getenv("RECIPIENT")) ? "LEAK" : "OK";
' </dev/null
)"
[ "$PLAIN" = OK ] || fail "campaign payload leaked recipient plaintext"
echo "PASS: campaign unsubscribe payload remains encrypted at rest"

docker compose start mail-worker >/dev/null

CAPTURED=false
for _ in $(seq 1 60); do
  if docker compose exec -T fake-mx-success \
      grep -aF 'Visible HTML body' \
      /capture/last.eml \
      >/dev/null 2>&1
  then
    CAPTURED=true
    break
  fi
  sleep 1
done

[ "$CAPTURED" = true ] || fail "campaign mail never reached fake MX"

docker compose exec -T fake-mx-success \
  grep -aE '^List-Unsubscribe: <https://api\.heymail\.test:8443/unsubscribe/u1\.' \
  /capture/last.eml \
  >/dev/null \
  || fail "List-Unsubscribe header missing"

docker compose exec -T fake-mx-success \
  grep -aF 'List-Unsubscribe-Post: List-Unsubscribe=One-Click' \
  /capture/last.eml \
  >/dev/null \
  || fail "List-Unsubscribe-Post header missing"

docker compose exec -T fake-mx-success \
  grep -aF 'https://api.heymail.test:8443/unsubscribe/u1.' \
  /capture/last.eml \
  >/dev/null \
  || fail "visible unsubscribe URL missing from campaign body"

echo "PASS: campaign delivery contains RFC one-click headers and visible unsubscribe link"
echo "ALL CAMPAIGN UNSUBSCRIBE HEADER TESTS PASSED"
