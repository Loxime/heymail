#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

TMP_DIR="$(mktemp -d /tmp/heymail-campaign-batch.XXXXXX)"
TOKEN="$(openssl rand -hex 32)"
MARKER="$(openssl rand -hex 8)"
USER_ID=""
CAMPAIGN_ID=""

cleanup() {
  rc=$?
  trap - EXIT
  set +e

  docker compose exec \
    -T \
    -e USER_ID="${USER_ID:-}" \
    api \
    php <<'PHP' >/dev/null 2>&1
<?php
declare(strict_types=1);
require '/app/vendor/autoload.php';
use App\Console\ConsoleUserProvisioner;
use Doctrine\DBAL\DriverManager;

$id=(int)getenv('USER_ID');
if($id<1){exit;}
$c=DriverManager::getConnection([
 'driver'=>'pdo_pgsql','host'=>getenv('DB_HOST'),'port'=>getenv('DB_PORT'),
 'dbname'=>getenv('DB_NAME'),'user'=>getenv('DB_USER'),
 'password'=>trim(file_get_contents((string)getenv('DB_PASSWORD_FILE'))),
]);

$w=(int)$c->fetchOne(
 'SELECT workspace_id FROM workspace_member WHERE user_id=:id',
 ['id'=>$id],
);
if($w>0){
 $messageIds=$c->fetchFirstColumn(
  'SELECT outbound_message_id
   FROM campaign_delivery d
   INNER JOIN campaign c ON c.id=d.campaign_id
   WHERE c.workspace_id=:w',
  ['w'=>$w],
 );

 $c->executeStatement(
  'DELETE FROM campaign_quota_reservation WHERE workspace_id=:w',
  ['w'=>$w],
 );
 $c->executeStatement(
  'DELETE FROM campaign WHERE workspace_id=:w',
  ['w'=>$w],
 );

 foreach($messageIds as $messageId){
  $c->executeStatement(
   'DELETE FROM messenger_messages
    WHERE queue_name = :queue
      AND body LIKE :message_id',
   [
    'queue'=>'outbound',
    'message_id'=>'%"outboundMessageId":'.(int)$messageId.'%',
   ],
  );
  $c->delete(
   'outbound_message',
   ['id'=>(int)$messageId],
  );
 }

 $c->executeStatement(
  'DELETE FROM sender_identity WHERE sending_domain_id IN (
     SELECT id FROM sending_domain WHERE workspace_id=:w
   )',
  ['w'=>$w],
 );
 $c->executeStatement(
  'DELETE FROM sending_domain WHERE workspace_id=:w',
  ['w'=>$w],
 );
}
try{(new ConsoleUserProvisioner($c))->delete($id);}catch(Throwable){}
PHP

  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== HeyMail campaign batch processing E2E ==="

docker compose up -d --wait database api gateway >/dev/null
docker compose stop mail-worker campaign-worker >/dev/null 2>&1 || true

FIXTURE="$(
docker compose exec -T -e TOKEN="$TOKEN" -e MARKER="$MARKER" api php <<'PHP'
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
$m=(string)getenv('MARKER');
$u=(new ConsoleUserProvisioner($c))->create("batch-$m@example.test",'Batch','Campaign',$hash,$now);
$w=(int)$c->fetchOne('SELECT workspace_id FROM workspace_member WHERE user_id=:u',['u'=>$u]);

$c->insert('console_session',[
 'token_hash'=>hash('sha256',(string)getenv('TOKEN')),
 'user_id'=>$u,
 'created_at'=>$now->format('Y-m-d H:i:s'),
 'last_seen_at'=>$now->format('Y-m-d H:i:s'),
 'expires_at'=>$now->modify('+1 hour')->format('Y-m-d H:i:s'),
]);

$cid=(int)$c->fetchOne(
 "INSERT INTO campaign(
    workspace_id,name,status,scheduled_for,snapshot_at,template_version,
    recipient_count,snapshot_ciphertext,snapshot_nonce,snapshot_wrapped_dek,
    snapshot_wrap_nonce,snapshot_algorithm,snapshot_key_version,created_at,updated_at
  ) VALUES(
    :w,:name,'ready',:now,:now,1,30,'placeholder','placeholder','placeholder',
    'placeholder','placeholder',1,:now,:now
  ) RETURNING id",
 ['w'=>$w,'name'=>"Batch $m",'now'=>$now->format('Y-m-d H:i:s')],
);

$recipients=[];
for($i=0;$i<30;$i++){
 $recipients[]=[
  'email'=>sprintf('recipient-%02d-%s@example.test',$i,$m),
  'name'=>'Recipient '.$i,
  'variables'=>['first_name'=>'User'.$i],
 ];
}
$snapshot=[
 'sender'=>['email'=>'sender@example.test'],
 'template'=>[
  'version'=>1,
  'subject'=>'Hello {{first_name}}',
  'text'=>'Batch {{first_name}}',
  'html'=>null,
 ],
 'recipients'=>$recipients,
];

$e=(new CampaignSnapshotCipher((string)getenv('PAYLOAD_KEK_FILE')))->encrypt($w,$cid,$snapshot);
$c->update('campaign',[
 'snapshot_ciphertext'=>$e['ciphertext'],
 'snapshot_nonce'=>$e['nonce'],
 'snapshot_wrapped_dek'=>$e['wrappedDek'],
 'snapshot_wrap_nonce'=>$e['wrapNonce'],
 'snapshot_algorithm'=>$e['algorithm'],
 'snapshot_key_version'=>$e['keyVersion'],
],['id'=>$cid]);

echo "USER_ID=$u\nWORKSPACE_ID=$w\nCAMPAIGN_ID=$cid\n";
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
  </dev/null >/dev/null

STATE="$(
docker compose exec -T -e CID="$CAMPAIGN_ID" api php -r '
$pdo=new PDO(
 sprintf("pgsql:host=%s;port=%s;dbname=%s",getenv("DB_HOST"),getenv("DB_PORT"),getenv("DB_NAME")),
 getenv("DB_USER"),trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$id=(int)getenv("CID");
$r=$pdo->query("SELECT status,processed_count FROM campaign WHERE id=".$id)->fetch(PDO::FETCH_ASSOC);
$d=(int)$pdo->query("SELECT COUNT(*) FROM campaign_delivery WHERE campaign_id=".$id)->fetchColumn();
$q=(int)$pdo->query("SELECT COUNT(*) FROM messenger_messages WHERE queue_name='\''outbound'\''")->fetchColumn();
echo "STATUS=".$r["status"]."\nPROCESSED=".$r["processed_count"]."\nDELIVERIES=".$d."\nOUTBOUND_QUEUE=".$q."\n";
' </dev/null
)"

grep -Fq 'STATUS=ready' <<<"$STATE"
grep -Fq 'PROCESSED=25' <<<"$STATE"
grep -Fq 'DELIVERIES=25' <<<"$STATE"
grep -Fq 'OUTBOUND_QUEUE=25' <<<"$STATE"
echo "PASS: campaign worker processes exactly one 25-recipient batch"

PAUSE_OUT="$TMP_DIR/pause.out"
PAUSE_CODE="$(
 curl --noproxy '*' --silent --show-error \
  --cacert secrets/gateway_tls_cert.pem \
  --resolve api.heymail.test:8443:127.0.0.1 \
  --output "$PAUSE_OUT" --write-out '%{http_code}' \
  --request POST \
  --header "Cookie: heymail_session=${TOKEN}" \
  "https://api.heymail.test:8443/console/campaigns/${CAMPAIGN_ID}/pause"
)"
[ "$PAUSE_CODE" = 200 ] || { cat "$PAUSE_OUT"; fail pause; }

docker compose run \
  --rm \
  --no-deps \
  -T \
  api \
  php bin/console app:campaign:worker \
  --once \
  --no-interaction \
  </dev/null >/dev/null

PAUSED="$(
docker compose exec -T -e CID="$CAMPAIGN_ID" api php -r '
$pdo=new PDO(
 sprintf("pgsql:host=%s;port=%s;dbname=%s",getenv("DB_HOST"),getenv("DB_PORT"),getenv("DB_NAME")),
 getenv("DB_USER"),trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$r=$pdo->query("SELECT status,processed_count FROM campaign WHERE id=".(int)getenv("CID"))->fetch(PDO::FETCH_ASSOC);
echo $r["status"].":".$r["processed_count"];
' </dev/null
)"
[ "$PAUSED" = "paused:25" ] || fail "paused campaign progressed"
echo "PASS: pause prevents additional campaign batches"

RESUME_OUT="$TMP_DIR/resume.out"
RESUME_CODE="$(
 curl --noproxy '*' --silent --show-error \
  --cacert secrets/gateway_tls_cert.pem \
  --resolve api.heymail.test:8443:127.0.0.1 \
  --output "$RESUME_OUT" --write-out '%{http_code}' \
  --request POST \
  --header "Cookie: heymail_session=${TOKEN}" \
  "https://api.heymail.test:8443/console/campaigns/${CAMPAIGN_ID}/resume"
)"
[ "$RESUME_CODE" = 200 ] || { cat "$RESUME_OUT"; fail resume; }

docker compose run \
  --rm \
  --no-deps \
  -T \
  api \
  php bin/console app:campaign:worker \
  --once \
  --no-interaction \
  </dev/null >/dev/null

FINAL="$(
docker compose exec -T -e CID="$CAMPAIGN_ID" api php -r '
$pdo=new PDO(
 sprintf("pgsql:host=%s;port=%s;dbname=%s",getenv("DB_HOST"),getenv("DB_PORT"),getenv("DB_NAME")),
 getenv("DB_USER"),trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$id=(int)getenv("CID");
$r=$pdo->query("SELECT status,processed_count,completed_at FROM campaign WHERE id=".$id)->fetch(PDO::FETCH_ASSOC);
$d=(int)$pdo->query("SELECT COUNT(*) FROM campaign_delivery WHERE campaign_id=".$id)->fetchColumn();
$q=(int)$pdo->query("SELECT COUNT(*) FROM messenger_messages WHERE queue_name='\''outbound'\''")->fetchColumn();
echo "STATUS=".$r["status"]."\nPROCESSED=".$r["processed_count"]."\nCOMPLETED=".(is_string($r["completed_at"])?"yes":"no")."\nDELIVERIES=".$d."\nOUTBOUND_QUEUE=".$q."\n";
' </dev/null
)"

grep -Fq 'STATUS=completed' <<<"$FINAL"
grep -Fq 'PROCESSED=30' <<<"$FINAL"
grep -Fq 'COMPLETED=yes' <<<"$FINAL"
grep -Fq 'DELIVERIES=30' <<<"$FINAL"
grep -Fq 'OUTBOUND_QUEUE=30' <<<"$FINAL"
echo "PASS: resume completes remaining recipients without duplicates"

echo "ALL CAMPAIGN BATCH PROCESSING TESTS PASSED"
