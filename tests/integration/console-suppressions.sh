#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

API_ORIGIN="https://api.heymail.test:8443"
TMP_DIR="$(mktemp -d /tmp/heymail-suppressions.XXXXXX)"
MARKER="$(openssl rand -hex 8)"
TOKEN_A="$(openssl rand -hex 32)"
TOKEN_B="$(openssl rand -hex 32)"
USER_A=""
USER_B=""

cleanup() {
  rc=$?
  trap - EXIT
  set +e

  docker compose exec \
    -T \
    -e USER_A="${USER_A:-}" \
    -e USER_B="${USER_B:-}" \
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

$p=new ConsoleUserProvisioner($c);

foreach([getenv('USER_A'),getenv('USER_B')] as $id){
 if(!is_string($id)||preg_match('/^[1-9][0-9]*$/D',$id)!==1){
  continue;
 }
 try{$p->delete((int)$id);}catch(Throwable){}
}
PHP

  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

request(){
  local token="$1"
  local method="$2"
  local path="$3"
  local body="$4"
  local output="$5"

  local args=(
    --noproxy '*'
    --silent
    --show-error
    --cacert secrets/gateway_tls_cert.pem
    --resolve api.heymail.test:8443:127.0.0.1
    --output "$output"
    --write-out '%{http_code}'
    --request "$method"
    --header "Cookie: heymail_session=${token}"
  )

  if [ -n "$body" ]; then
    args+=(
      --header 'Content-Type: application/json'
      --data-binary "@$body"
    )
  fi

  curl "${args[@]}" "$API_ORIGIN$path"
}

echo "=== HeyMail console suppressions E2E ==="

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
  -e TOKEN_A="$TOKEN_A" \
  -e TOKEN_B="$TOKEN_B" \
  -e MARKER="$MARKER" \
  api \
  php <<'PHP'
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

$now=new DateTimeImmutable('now',new DateTimeZone('UTC'));
$hash=password_hash(bin2hex(random_bytes(24)),PASSWORD_DEFAULT);
if(!is_string($hash)){throw new RuntimeException('hash');}

$p=new ConsoleUserProvisioner($c);
$m=(string)getenv('MARKER');

$ua=$p->create("supp-a-$m@example.test",'Supp','A',$hash,$now);
$ub=$p->create("supp-b-$m@example.test",'Supp','B',$hash,$now);

$wa=(int)$c->fetchOne(
 'SELECT workspace_id FROM workspace_member WHERE user_id=:id',
 ['id'=>$ua],
);

foreach([[$ua,getenv('TOKEN_A')],[$ub,getenv('TOKEN_B')]] as [$u,$t]){
 $c->insert('console_session',[
  'token_hash'=>hash('sha256',(string)$t),
  'user_id'=>$u,
  'created_at'=>$now->format('Y-m-d H:i:s'),
  'last_seen_at'=>$now->format('Y-m-d H:i:s'),
  'expires_at'=>$now->modify('+1 hour')->format('Y-m-d H:i:s'),
 ]);
}

$list=(int)$c->fetchOne(
 'INSERT INTO contact_list(workspace_id,name,created_at,updated_at)
  VALUES(:w,:n,:t,:t) RETURNING id',
 [
  'w'=>$wa,
  'n'=>"Suppression $m",
  't'=>$now->format('Y-m-d H:i:s'),
 ],
);

echo "USER_A=$ua\nUSER_B=$ub\nLIST_ID=$list\n";
PHP
)"

value(){ awk -F= -v key="$1" '$1==key{print $2}' <<<"$FIXTURE"; }

USER_A="$(value USER_A)"
USER_B="$(value USER_B)"
LIST_ID="$(value LIST_ID)"

for x in "$USER_A" "$USER_B" "$LIST_ID"; do
  [[ "$x" =~ ^[1-9][0-9]*$ ]] || fail "invalid fixture id"
done

GLOBAL_EMAIL="global-$MARKER@example.test"
LIST_EMAIL="list-$MARKER@example.test"

cat >"$TMP_DIR/global.json" <<JSON
{"email":"$GLOBAL_EMAIL"}
JSON

GLOBAL_OUT="$TMP_DIR/global.out"
[ "$(
  request \
    "$TOKEN_A" \
    POST \
    /console/suppressions \
    "$TMP_DIR/global.json" \
    "$GLOBAL_OUT"
)" = 201 ] || {
  cat "$GLOBAL_OUT"
  fail "global suppression create"
}

GLOBAL_ID="$(
python3 - "$GLOBAL_OUT" "$GLOBAL_EMAIL" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["email"]==sys.argv[2]
assert d["scope"]=="global"
assert d["reason"]=="manual"
assert d["listId"] is None
print(d["id"])
PY
)"

cat >"$TMP_DIR/list.json" <<JSON
{"email":"$LIST_EMAIL","listId":$LIST_ID}
JSON

LIST_OUT="$TMP_DIR/list.out"
[ "$(
  request \
    "$TOKEN_A" \
    POST \
    /console/suppressions \
    "$TMP_DIR/list.json" \
    "$LIST_OUT"
)" = 201 ] || {
  cat "$LIST_OUT"
  fail "list suppression create"
}

LIST_SUPPRESSION_ID="$(
python3 - "$LIST_OUT" "$LIST_EMAIL" "$LIST_ID" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["email"]==sys.argv[2]
assert d["scope"]=="list"
assert d["reason"]=="manual"
assert d["listId"]==int(sys.argv[3])
print(d["id"])
PY
)"

echo "PASS: global and list-level suppressions created"

LIST_A="$TMP_DIR/list-a.out"
[ "$(
  request \
    "$TOKEN_A" \
    GET \
    /console/suppressions \
    "" \
    "$LIST_A"
)" = 200 ] || fail "workspace A list"

python3 - "$LIST_A" "$GLOBAL_ID" "$LIST_SUPPRESSION_ID" <<'PY'
import json,sys
ids={x["id"] for x in json.load(open(sys.argv[1]))["items"]}
assert int(sys.argv[2]) in ids
assert int(sys.argv[3]) in ids
PY

LIST_B="$TMP_DIR/list-b.out"
[ "$(
  request \
    "$TOKEN_B" \
    GET \
    /console/suppressions \
    "" \
    "$LIST_B"
)" = 200 ] || fail "workspace B list"

python3 - "$LIST_B" "$GLOBAL_ID" "$LIST_SUPPRESSION_ID" <<'PY'
import json,sys
ids={x["id"] for x in json.load(open(sys.argv[1]))["items"]}
assert int(sys.argv[2]) not in ids
assert int(sys.argv[3]) not in ids
PY

echo "PASS: suppression reads are workspace isolated"

FOREIGN_DELETE="$TMP_DIR/foreign-delete.out"
[ "$(
  request \
    "$TOKEN_B" \
    DELETE \
    "/console/suppressions/$GLOBAL_ID" \
    "" \
    "$FOREIGN_DELETE"
)" = 404 ] || fail "foreign delete must fail closed"

echo "PASS: suppression deletion fails closed across workspaces"

[ "$(
  request \
    "$TOKEN_A" \
    DELETE \
    "/console/suppressions/$GLOBAL_ID" \
    "" \
    "$TMP_DIR/delete-global.out"
)" = 204 ] || fail "delete global suppression"

[ "$(
  request \
    "$TOKEN_A" \
    DELETE \
    "/console/suppressions/$LIST_SUPPRESSION_ID" \
    "" \
    "$TMP_DIR/delete-list.out"
)" = 204 ] || fail "delete list suppression"

echo "PASS: workspace can remove its suppressions"
echo "ALL CONSOLE SUPPRESSION TESTS PASSED"
