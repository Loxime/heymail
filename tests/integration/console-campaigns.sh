#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

API_ORIGIN="https://api.heymail.test:8443"
TMP_DIR="$(mktemp -d /tmp/heymail-campaign.XXXXXX)"
TOKEN_A="$(openssl rand -hex 32)"
TOKEN_B="$(openssl rand -hex 32)"
MARKER="$(openssl rand -hex 8)"
USER_A=""
USER_B=""

cleanup() {
  rc=$?
  trap - EXIT
  set +e
  docker compose exec -T -e USER_A="${USER_A:-}" -e USER_B="${USER_B:-}" api php <<'PHP' >/dev/null 2>&1
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
$p=new ConsoleUserProvisioner($c);
foreach([getenv('USER_A'),getenv('USER_B')] as $id){
 if(!is_string($id)||preg_match('/^[1-9][0-9]*$/D',$id)!==1){
  continue;
 }

 try{
  $workspaceIds=$c->fetchFirstColumn(
   'SELECT workspace_id FROM workspace_member WHERE user_id=:user_id',
   ['user_id'=>(int)$id],
  );

  foreach($workspaceIds as $workspaceId){
   $c->executeStatement(
    'DELETE FROM sender_identity WHERE sending_domain_id IN (
       SELECT id FROM sending_domain WHERE workspace_id=:workspace_id
     )',
    ['workspace_id'=>(int)$workspaceId],
   );

   $c->executeStatement(
    'DELETE FROM sending_domain WHERE workspace_id=:workspace_id',
    ['workspace_id'=>(int)$workspaceId],
   );
  }

  $p->delete((int)$id);
 }catch(Throwable){
 }
}
PHP
  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

request(){
 local token="$1" method="$2" path="$3" body="$4" output="$5"
 local args=(--noproxy '*' --silent --show-error --cacert secrets/gateway_tls_cert.pem
   --resolve api.heymail.test:8443:127.0.0.1 --output "$output" --write-out '%{http_code}'
   --request "$method" --header "Cookie: heymail_session=${token}")
 if [ -n "$body" ]; then args+=(--header 'Content-Type: application/json' --data-binary "@$body"); fi
 curl "${args[@]}" "$API_ORIGIN$path"
}

echo "=== HeyMail campaign foundation E2E ==="
docker compose up -d --wait database api gateway >/dev/null

FIXTURE="$(
docker compose exec -T -e TOKEN_A="$TOKEN_A" -e TOKEN_B="$TOKEN_B" -e MARKER="$MARKER" api php <<'PHP'
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
$now=new DateTimeImmutable('now',new DateTimeZone('UTC'));
$hash=password_hash(bin2hex(random_bytes(24)),PASSWORD_DEFAULT);
if(!is_string($hash)){throw new RuntimeException('hash');}
$p=new ConsoleUserProvisioner($c); $m=(string)getenv('MARKER');
$ua=$p->create("camp-a-$m@example.test",'Camp','A',$hash,$now);
$ub=$p->create("camp-b-$m@example.test",'Camp','B',$hash,$now);
$wa=(int)$c->fetchOne('SELECT workspace_id FROM workspace_member WHERE user_id=:id',['id'=>$ua]);
$wb=(int)$c->fetchOne('SELECT workspace_id FROM workspace_member WHERE user_id=:id',['id'=>$ub]);
foreach([[$ua,getenv('TOKEN_A')],[$ub,getenv('TOKEN_B')]] as [$u,$t]){
 $c->insert('console_session',[
  'token_hash'=>hash('sha256',(string)$t),'user_id'=>$u,
  'created_at'=>$now->format('Y-m-d H:i:s'),'last_seen_at'=>$now->format('Y-m-d H:i:s'),
  'expires_at'=>$now->modify('+1 hour')->format('Y-m-d H:i:s')
 ]);
}
$domain=(int)$c->fetchOne(
 "INSERT INTO sending_domain(workspace_id,domain,status,verification_token,created_at,verification_checked_at,verified_at,dkim_selector,dkim_public_key,dkim_provisioned_at)
  VALUES(:w,:d,'verified',:v,:n,:n,:n,'hm1',:k,:n) RETURNING id",
 ['w'=>$wa,'d'=>"camp-$m.example.test",'v'=>hash('sha256',$m),'n'=>$now->format('Y-m-d H:i:s'),'k'=>base64_encode(random_bytes(32))]
);
$sender=(int)$c->fetchOne(
 'INSERT INTO sender_identity(sending_domain_id,email,created_at) VALUES(:d,:e,:n) RETURNING id',
 ['d'=>$domain,'e'=>"hello@camp-$m.example.test",'n'=>$now->format('Y-m-d H:i:s')]
);
$template=(int)$c->fetchOne(
 'INSERT INTO email_template(workspace_id,name,created_at,updated_at) VALUES(:w,:n,:t,:t) RETURNING id',
 ['w'=>$wa,'n'=>"Camp $m",'t'=>$now->format('Y-m-d H:i:s')]
);
$c->insert('email_template_version',[
 'template_id'=>$template,'version'=>1,'subject'=>'Hello {{first_name}}',
 'text_body'=>'Company {{company}}','html_body'=>'<p>Hello {{first_name}}</p>',
 'created_at'=>$now->format('Y-m-d H:i:s')
]);
$list=(int)$c->fetchOne(
 'INSERT INTO contact_list(workspace_id,name,created_at,updated_at) VALUES(:w,:n,:t,:t) RETURNING id',
 ['w'=>$wa,'n'=>"Audience $m",'t'=>$now->format('Y-m-d H:i:s')]
);
foreach([['ada','Ada Lovelace','Analytical Engines'],['grace','Grace Hopper','Navy']] as [$local,$name,$company]){
 $cid=(int)$c->fetchOne(
  "INSERT INTO contact(workspace_id,email,name,custom_fields,created_at,updated_at)
   VALUES(:w,:e,:n,CAST(:f AS jsonb),:t,:t) RETURNING id",
  ['w'=>$wa,'e'=>"$local-$m@example.test",'n'=>$name,'f'=>json_encode(
    $local === 'ada'
      ? [
          'company'=>$company,
          'first_name'=>'Mallory',
          'email'=>'attacker@example.test',
          'name'=>'Override Name',
        ]
      : ['company'=>$company],
    JSON_THROW_ON_ERROR
  ),'t'=>$now->format('Y-m-d H:i:s')]
 );
 $c->insert('contact_list_member',['workspace_id'=>$wa,'list_id'=>$list,'contact_id'=>$cid,'created_at'=>$now->format('Y-m-d H:i:s')]);
}
echo "USER_A=$ua\nUSER_B=$ub\nWORKSPACE_A=$wa\nWORKSPACE_B=$wb\nSENDER_ID=$sender\nTEMPLATE_ID=$template\nLIST_ID=$list\n";
PHP
)"

value(){ awk -F= -v key="$1" '$1==key{print $2}' <<<"$FIXTURE"; }
USER_A="$(value USER_A)"; USER_B="$(value USER_B)"; WORKSPACE_A="$(value WORKSPACE_A)"
SENDER_ID="$(value SENDER_ID)"; TEMPLATE_ID="$(value TEMPLATE_ID)"; LIST_ID="$(value LIST_ID)"
for x in "$USER_A" "$USER_B" "$WORKSPACE_A" "$SENDER_ID" "$TEMPLATE_ID" "$LIST_ID"; do [[ "$x" =~ ^[1-9][0-9]*$ ]] || fail fixture; done

cat >"$TMP_DIR/create.json" <<JSON
{"name":"Launch $MARKER","senderId":$SENDER_ID,"templateId":$TEMPLATE_ID,"listId":$LIST_ID}
JSON
CREATE="$TMP_DIR/create.out"
[ "$(request "$TOKEN_A" POST /console/campaigns "$TMP_DIR/create.json" "$CREATE")" = 201 ] || { cat "$CREATE"; fail create; }
CID="$(python3 - "$CREATE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d["status"]=="draft" and d["recipientCount"]==0; print(d["id"])
PY
)"
[[ "$CID" =~ ^[1-9][0-9]*$ ]] || fail id
echo "PASS: campaign draft created"

FOREIGN="$TMP_DIR/foreign.out"
[ "$(request "$TOKEN_B" GET /console/campaigns "" "$FOREIGN")" = 200 ] || fail foreign
python3 - "$FOREIGN" "$CID" <<'PY'
import json,sys
assert all(x["id"]!=int(sys.argv[2]) for x in json.load(open(sys.argv[1]))["items"])
PY
echo "PASS: campaign listing is workspace isolated"

cat >"$TMP_DIR/now.json" <<'JSON'
{"scheduledFor":null}
JSON
SCHEDULE="$TMP_DIR/schedule.out"
[ "$(request "$TOKEN_A" POST "/console/campaigns/$CID/schedule" "$TMP_DIR/now.json" "$SCHEDULE")" = 200 ] || { cat "$SCHEDULE"; fail schedule; }
python3 - "$SCHEDULE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["status"]=="ready" and d["recipientCount"]==2 and d["templateVersion"]==1
assert d["snapshotAt"] is not None and d["scheduledFor"] is not None
PY
echo "PASS: send-now scheduling creates immutable snapshot metadata"

ASSERT="$(
docker compose exec -T -e CID="$CID" -e WID="$WORKSPACE_A" api php <<'PHP'
<?php
declare(strict_types=1);
require '/app/vendor/autoload.php';
use App\Campaign\CampaignSnapshotCipher;
use Doctrine\DBAL\DriverManager;
$c=DriverManager::getConnection([
 'driver'=>'pdo_pgsql','host'=>getenv('DB_HOST'),'port'=>getenv('DB_PORT'),
 'dbname'=>getenv('DB_NAME'),'user'=>getenv('DB_USER'),
 'password'=>trim(file_get_contents((string)getenv('DB_PASSWORD_FILE'))),
]);
$r=$c->fetchAssociative('SELECT * FROM campaign WHERE id=:id',['id'=>(int)getenv('CID')]);
$s=json_encode($r,JSON_THROW_ON_ERROR);
foreach(['ada-','grace-','Analytical Engines','Hello {{first_name}}'] as $needle){
 if(str_contains($s,$needle)){echo "LEAK=$needle\n"; exit(3);}
}
$x=(new CampaignSnapshotCipher((string)getenv('PAYLOAD_KEK_FILE')))->decrypt(
 (int)getenv('WID'),(int)getenv('CID'),
 ['ciphertext'=>(string)$r['snapshot_ciphertext'],'nonce'=>(string)$r['snapshot_nonce'],
  'wrappedDek'=>(string)$r['snapshot_wrapped_dek'],'wrapNonce'=>(string)$r['snapshot_wrap_nonce'],
  'algorithm'=>(string)$r['snapshot_algorithm'],'keyVersion'=>(int)$r['snapshot_key_version']]
);
echo "COUNT=",count($x['recipients']),"\n";
echo "SUBJECT=",$x['template']['subject'],"\n";
echo "FIRST=",$x['recipients'][0]['variables']['first_name'],"\n";
echo "EMAIL=",$x['recipients'][0]['email'],"\n";
echo "NAME=",$x['recipients'][0]['name'],"\n";
echo "COMPANY=",$x['recipients'][0]['variables']['company'],"\n";
PHP
)"
grep -Fq 'COUNT=2' <<<"$ASSERT"
grep -Fq 'SUBJECT=Hello {{first_name}}' <<<"$ASSERT"
grep -Fq 'FIRST=Ada' <<<"$ASSERT"
grep -Fq "EMAIL=ada-$MARKER@example.test" <<<"$ASSERT"
grep -Fq 'NAME=Ada Lovelace' <<<"$ASSERT"
grep -Fq 'COMPANY=Analytical Engines' <<<"$ASSERT"
echo "PASS: campaign snapshot is encrypted at rest and reserved contact variables cannot be overridden"

MUTATE="$(
docker compose exec -T -e TID="$TEMPLATE_ID" -e WID="$WORKSPACE_A" -e MARKER="$MARKER" api php <<'PHP'
<?php
declare(strict_types=1);
require '/app/vendor/autoload.php';
use Doctrine\DBAL\DriverManager;
$c=DriverManager::getConnection([
 'driver'=>'pdo_pgsql','host'=>getenv('DB_HOST'),'port'=>getenv('DB_PORT'),
 'dbname'=>getenv('DB_NAME'),'user'=>getenv('DB_USER'),
 'password'=>trim(file_get_contents((string)getenv('DB_PASSWORD_FILE'))),
]);
$n=(new DateTimeImmutable('now',new DateTimeZone('UTC')))->format('Y-m-d H:i:s');
$c->insert('email_template_version',['template_id'=>(int)getenv('TID'),'version'=>2,'subject'=>'MUTATED {{first_name}}','text_body'=>'Changed {{company}}','html_body'=>null,'created_at'=>$n]);
$c->executeStatement("UPDATE contact SET name='Mutated Person',custom_fields='{\"company\":\"Mutated\"}'::jsonb,updated_at=:n WHERE workspace_id=:w AND email LIKE :p",['n'=>$n,'w'=>(int)getenv('WID'),'p'=>'%-'.getenv('MARKER').'@example.test']);
echo "OK\n";
PHP
)"
grep -Fq OK <<<"$MUTATE"

AFTER="$(
docker compose exec -T -e CID="$CID" -e WID="$WORKSPACE_A" api php <<'PHP'
<?php
declare(strict_types=1);
require '/app/vendor/autoload.php';
use App\Campaign\CampaignSnapshotCipher;
use Doctrine\DBAL\DriverManager;
$c=DriverManager::getConnection([
 'driver'=>'pdo_pgsql','host'=>getenv('DB_HOST'),'port'=>getenv('DB_PORT'),
 'dbname'=>getenv('DB_NAME'),'user'=>getenv('DB_USER'),
 'password'=>trim(file_get_contents((string)getenv('DB_PASSWORD_FILE'))),
]);
$r=$c->fetchAssociative('SELECT * FROM campaign WHERE id=:id',['id'=>(int)getenv('CID')]);
$x=(new CampaignSnapshotCipher((string)getenv('PAYLOAD_KEK_FILE')))->decrypt(
 (int)getenv('WID'),(int)getenv('CID'),
 ['ciphertext'=>(string)$r['snapshot_ciphertext'],'nonce'=>(string)$r['snapshot_nonce'],
  'wrappedDek'=>(string)$r['snapshot_wrapped_dek'],'wrapNonce'=>(string)$r['snapshot_wrap_nonce'],
  'algorithm'=>(string)$r['snapshot_algorithm'],'keyVersion'=>(int)$r['snapshot_key_version']]
);
echo "VERSION=",$x['template']['version'],"\nSUBJECT=",$x['template']['subject'],"\nFIRST=",$x['recipients'][0]['variables']['first_name'],"\n";
PHP
)"
grep -Fq 'VERSION=1' <<<"$AFTER"
grep -Fq 'SUBJECT=Hello {{first_name}}' <<<"$AFTER"
grep -Fq 'FIRST=Ada' <<<"$AFTER"
echo "PASS: source mutation cannot change scheduled snapshot"

RES="$TMP_DIR/res.out"
[ "$(request "$TOKEN_A" POST "/console/campaigns/$CID/schedule" "$TMP_DIR/now.json" "$RES")" = 409 ] || fail resnapshot
CANCEL="$TMP_DIR/cancel.out"
[ "$(request "$TOKEN_A" POST "/console/campaigns/$CID/cancel" "" "$CANCEL")" = 200 ] || fail cancel
python3 - "$CANCEL" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))["status"]=="cancelled"
PY
echo "PASS: scheduled campaign cannot be re-snapshotted and can be cancelled"
echo "ALL CAMPAIGN FOUNDATION TESTS PASSED"
