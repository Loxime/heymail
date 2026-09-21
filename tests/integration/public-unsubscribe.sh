#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

API_ORIGIN="https://api.heymail.test:8443"
TMP_DIR="$(mktemp -d /tmp/heymail-unsubscribe.XXXXXX)"
MARKER="$(openssl rand -hex 8)"
TEST_EMAIL="unsubscribe-fixture-$MARKER@example.test"
USER_ID=""

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

if($userId!==false){
 try{
  (new ConsoleUserProvisioner($c))->delete((int)$userId);
 }catch(Throwable){}
}
PHP

  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== HeyMail public unsubscribe E2E ==="

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
  -e TEST_EMAIL="$TEST_EMAIL" \
  -e MARKER="$MARKER" \
  api \
  php <<'PHP'
<?php
declare(strict_types=1);
require '/app/vendor/autoload.php';

use App\Console\ConsoleUserProvisioner;
use App\Suppression\UnsubscribeTokenCodec;
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
 'Public',
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
  'n'=>'Newsletter '.getenv('MARKER'),
  't'=>$now->format('Y-m-d H:i:s'),
 ],
);

$recipient='person-'.getenv('MARKER').'@example.test';

$codec=new UnsubscribeTokenCodec(
 trim(file_get_contents((string)getenv('APP_SECRET_FILE'))),
 'https://api.heymail.test:8443',
);

$token=$codec->encode(
 $workspaceId,
 $listId,
 $recipient,
);

$replayedToken=$codec->encode(
 $workspaceId,
 $listId,
 $recipient,
);

if(!hash_equals($token,$replayedToken)){
 throw new RuntimeException(
  'Unsubscribe token is not deterministic.',
 );
}

echo "USER_ID=$userId\n";
echo "WORKSPACE_ID=$workspaceId\n";
echo "LIST_ID=$listId\n";
echo "RECIPIENT=$recipient\n";
echo "TOKEN=$token\n";
PHP
)"

value(){ awk -F= -v key="$1" '$1==key{print substr($0,index($0,"=")+1)}' <<<"$FIXTURE"; }

USER_ID="$(value USER_ID)"
WORKSPACE_ID="$(value WORKSPACE_ID)"
LIST_ID="$(value LIST_ID)"
RECIPIENT="$(value RECIPIENT)"
TOKEN="$(value TOKEN)"

for x in "$USER_ID" "$WORKSPACE_ID" "$LIST_ID"; do
  [[ "$x" =~ ^[1-9][0-9]*$ ]] || fail "invalid fixture id"
done

[[ "$TOKEN" == u1.* ]] || fail "invalid unsubscribe token"

GET_HEADERS="$TMP_DIR/get.headers"
GET_BODY="$TMP_DIR/get.body"

GET_CODE="$(
 curl --noproxy '*' --silent --show-error \
  --cacert secrets/gateway_tls_cert.pem \
  --resolve api.heymail.test:8443:127.0.0.1 \
  --dump-header "$GET_HEADERS" \
  --output "$GET_BODY" \
  --write-out '%{http_code}' \
  "$API_ORIGIN/unsubscribe/$TOKEN"
)"

[ "$GET_CODE" = 200 ] || fail "unsubscribe GET did not return 200"
grep -Eiq '^cache-control: no-store' "$GET_HEADERS"
grep -Fq '<h1>Unsubscribe</h1>' "$GET_BODY"

COUNT_AFTER_GET="$(
docker compose exec -T -e WID="$WORKSPACE_ID" api php -r '
$pdo=new PDO(
 sprintf("pgsql:host=%s;port=%s;dbname=%s",getenv("DB_HOST"),getenv("DB_PORT"),getenv("DB_NAME")),
 getenv("DB_USER"),trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$stmt=$pdo->prepare("SELECT COUNT(*) FROM email_suppression WHERE workspace_id=:w");
$stmt->execute(["w"=>(int)getenv("WID")]);
echo $stmt->fetchColumn();
' </dev/null
)"

[ "$COUNT_AFTER_GET" = 0 ] || fail "GET unsubscribe mutated state"
echo "PASS: GET confirmation page is non-mutating"

POST_BODY="$TMP_DIR/post.body"
POST_CODE="$(
 curl --noproxy '*' --silent --show-error \
  --cacert secrets/gateway_tls_cert.pem \
  --resolve api.heymail.test:8443:127.0.0.1 \
  --output "$POST_BODY" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data 'List-Unsubscribe=One-Click' \
  "$API_ORIGIN/unsubscribe/$TOKEN"
)"

[ "$POST_CODE" = 200 ] || { cat "$POST_BODY"; fail "one-click POST failed"; }

STATE="$(
docker compose exec \
  -T \
  -e WID="$WORKSPACE_ID" \
  -e LID="$LIST_ID" \
  -e RECIPIENT="$RECIPIENT" \
  api \
  php <<'PHP'
<?php
declare(strict_types=1);
require '/app/vendor/autoload.php';
use Doctrine\DBAL\DriverManager;
$c=DriverManager::getConnection([
 'driver'=>'pdo_pgsql','host'=>getenv('DB_HOST'),'port'=>getenv('DB_PORT'),
 'dbname'=>getenv('DB_NAME'),'user'=>getenv('DB_USER'),
 'password'=>trim(file_get_contents((string)getenv('DB_PASSWORD_FILE'))),
]);
$row=$c->fetchAssociative(
 'SELECT scope,reason,contact_list_id
  FROM email_suppression
  WHERE workspace_id=:w AND email_hash=:h',
 [
  'w'=>(int)getenv('WID'),
  'h'=>hash('sha256',strtolower((string)getenv('RECIPIENT'))),
 ],
);
if($row===false){echo "NONE\n";exit;}
echo $row['scope'],':',$row['reason'],':',$row['contact_list_id'],"\n";
PHP
)"

[ "$STATE" = "list:unsubscribe:$LIST_ID" ] \
  || fail "one-click did not create list unsubscribe"
echo "PASS: RFC one-click POST creates list-level unsubscribe"

REPLAY_CODE="$(
 curl --noproxy '*' --silent --show-error \
  --cacert secrets/gateway_tls_cert.pem \
  --resolve api.heymail.test:8443:127.0.0.1 \
  --output /dev/null \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data 'List-Unsubscribe=One-Click' \
  "$API_ORIGIN/unsubscribe/$TOKEN"
)"
[ "$REPLAY_CODE" = 200 ] || fail "one-click replay failed"

COUNT="$(
docker compose exec -T -e WID="$WORKSPACE_ID" api php -r '
$pdo=new PDO(
 sprintf("pgsql:host=%s;port=%s;dbname=%s",getenv("DB_HOST"),getenv("DB_PORT"),getenv("DB_NAME")),
 getenv("DB_USER"),trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$stmt=$pdo->prepare("SELECT COUNT(*) FROM email_suppression WHERE workspace_id=:w");
$stmt->execute(["w"=>(int)getenv("WID")]);
echo $stmt->fetchColumn();
' </dev/null
)"
[ "$COUNT" = 1 ] || fail "one-click replay duplicated suppression"
echo "PASS: one-click unsubscribe is idempotent"

GLOBAL_CODE="$(
 curl --noproxy '*' --silent --show-error \
  --cacert secrets/gateway_tls_cert.pem \
  --resolve api.heymail.test:8443:127.0.0.1 \
  --output /dev/null \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data 'scope=global' \
  "$API_ORIGIN/unsubscribe/$TOKEN"
)"
[ "$GLOBAL_CODE" = 200 ] || fail "global unsubscribe failed"

GLOBAL="$(
docker compose exec \
  -T \
  -e WID="$WORKSPACE_ID" \
  -e RECIPIENT="$RECIPIENT" \
  api \
  php -r '
$pdo=new PDO(
 sprintf("pgsql:host=%s;port=%s;dbname=%s",getenv("DB_HOST"),getenv("DB_PORT"),getenv("DB_NAME")),
 getenv("DB_USER"),trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$stmt=$pdo->prepare(
 "SELECT COUNT(*) FROM email_suppression
  WHERE workspace_id=:w AND scope='\''global'\'' AND reason='\''unsubscribe'\''
    AND email_hash=:h"
);
$stmt->execute([
 "w"=>(int)getenv("WID"),
 "h"=>hash("sha256",strtolower((string)getenv("RECIPIENT"))),
]);
echo $stmt->fetchColumn();
' </dev/null
)"
[ "$GLOBAL" = 1 ] || fail "global unsubscribe not persisted"
echo "PASS: confirmation page can create global unsubscribe"

TAMPERED="${TOKEN%?}A"
[ "$TAMPERED" != "$TOKEN" ] || TAMPERED="${TOKEN%?}B"

TAMPER_CODE="$(
 curl --noproxy '*' --silent --show-error \
  --cacert secrets/gateway_tls_cert.pem \
  --resolve api.heymail.test:8443:127.0.0.1 \
  --output /dev/null \
  --write-out '%{http_code}' \
  "$API_ORIGIN/unsubscribe/$TAMPERED"
)"
[ "$TAMPER_CODE" = 404 ] || fail "tampered token did not fail closed"
echo "PASS: tampered unsubscribe token fails closed"

echo "ALL PUBLIC UNSUBSCRIBE TESTS PASSED"
