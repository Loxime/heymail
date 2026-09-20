#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

API_ORIGIN="https://api.heymail.test:8443"
TMP_DIR="$(mktemp -d /tmp/heymail-template-e2e.XXXXXX)"
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
$pdo = new PDO(
    sprintf('pgsql:host=%s;port=%s;dbname=%s', getenv('DB_HOST'), getenv('DB_PORT'), getenv('DB_NAME')),
    getenv('DB_USER'),
    trim(file_get_contents((string) getenv('DB_PASSWORD_FILE'))),
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION],
);
foreach ([getenv('USER_A'), getenv('USER_B')] as $id) {
    if (is_string($id) && preg_match('/^[1-9][0-9]*$/D', $id) === 1) {
        $stmt = $pdo->prepare('DELETE FROM console_user WHERE id = :id');
        $stmt->execute(['id' => $id]);
    }
}
PHP
  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

request() {
  token="$1"; method="$2"; path="$3"; body="${4:-}"; out="$5"
  args=(
    --noproxy '*'
    --silent --show-error
    --cacert secrets/gateway_tls_cert.pem
    --resolve api.heymail.test:8443:127.0.0.1
    --output "$out"
    --write-out '%{http_code}'
    --request "$method"
    --header "Cookie: heymail_session=${token}"
  )
  if [ -n "$body" ]; then
    args+=(--header 'Content-Type: application/json' --data-binary "@$body")
  fi
  curl "${args[@]}" "$API_ORIGIN$path"
}

docker compose up -d --wait database api gateway >/dev/null

FIXTURE="$(
  docker compose exec -T -e TOKEN_A="$TOKEN_A" -e TOKEN_B="$TOKEN_B" -e MARKER="$MARKER" api php <<'PHP'
<?php
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

$now = new DateTimeImmutable('now', new DateTimeZone('UTC'));
$hash = password_hash(bin2hex(random_bytes(24)), PASSWORD_DEFAULT);
$p = new ConsoleUserProvisioner($c);
$m = (string) getenv('MARKER');

$a = $p->create("template-a-$m@example.test", 'Template', 'A', $hash, $now);
$b = $p->create("template-b-$m@example.test", 'Template', 'B', $hash, $now);

foreach ([[$a, getenv('TOKEN_A')], [$b, getenv('TOKEN_B')]] as [$userId, $token]) {
    $c->insert('console_session', [
        'token_hash' => hash('sha256', (string) $token),
        'user_id' => $userId,
        'created_at' => $now->format('Y-m-d H:i:s'),
        'last_seen_at' => $now->format('Y-m-d H:i:s'),
        'expires_at' => $now->modify('+1 hour')->format('Y-m-d H:i:s'),
    ]);
}

echo "USER_A=$a\nUSER_B=$b\n";
PHP
)"

value() { awk -F= -v key="$1" '$1 == key { print $2 }' <<<"$FIXTURE"; }
USER_A="$(value USER_A)"
USER_B="$(value USER_B)"

cat >"$TMP_DIR/create.json" <<'JSON'
{
  "name": "Welcome",
  "subject": "Hello {{first_name}}",
  "text": "Order {{order_id}} for {{first_name}}."
}
JSON

CREATE="$TMP_DIR/create.out"
[ "$(request "$TOKEN_A" POST /console/templates "$TMP_DIR/create.json" "$CREATE")" = "201" ] \
  || { cat "$CREATE" >&2; fail "template creation failed"; }

TEMPLATE_ID="$(
  python3 - "$CREATE" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
assert d["version"] == 1
assert d["variables"] == ["first_name", "order_id"]
print(d["id"])
PY
)"

[[ "$TEMPLATE_ID" =~ ^[1-9][0-9]*$ ]] || fail "invalid template id"

LIST_A="$TMP_DIR/list-a.out"
[ "$(request "$TOKEN_A" GET /console/templates "" "$LIST_A")" = "200" ] || fail "workspace A list failed"

LIST_B="$TMP_DIR/list-b.out"
[ "$(request "$TOKEN_B" GET /console/templates "" "$LIST_B")" = "200" ] || fail "workspace B list failed"

python3 - "$LIST_A" "$LIST_B" "$TEMPLATE_ID" <<'PY'
import json, sys
a=json.load(open(sys.argv[1], encoding="utf-8"))["items"]
b=json.load(open(sys.argv[2], encoding="utf-8"))["items"]
tid=int(sys.argv[3])
assert sum(item["id"] == tid for item in a) == 1
assert all(item["id"] != tid for item in b)
PY

cat >"$TMP_DIR/v2.json" <<'JSON'
{
  "subject": "Updated {{first_name}}",
  "html": "<h1>Hello {{first_name}}</h1>"
}
JSON

V2="$TMP_DIR/v2.out"
[ "$(request "$TOKEN_A" POST "/console/templates/$TEMPLATE_ID/versions" "$TMP_DIR/v2.json" "$V2")" = "200" ] \
  || { cat "$V2" >&2; fail "version creation failed"; }

python3 - "$V2" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
assert d["version"] == 2
assert d["variables"] == ["first_name"]
PY

FOREIGN="$TMP_DIR/foreign.out"
[ "$(request "$TOKEN_B" POST "/console/templates/$TEMPLATE_ID/versions" "$TMP_DIR/v2.json" "$FOREIGN")" = "404" ] \
  || fail "foreign workspace mutated template"

HISTORY="$TMP_DIR/history.out"
[ "$(request "$TOKEN_A" GET "/console/templates/$TEMPLATE_ID/history" "" "$HISTORY")" = "200" ] \
  || fail "history failed"

python3 - "$HISTORY" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
assert [item["version"] for item in d["items"]] == [2, 1]
PY

echo "PASS: workspace templates are isolated and versions are immutable"

cat >"$TMP_DIR/render-missing.json" <<'JSON'
{
  "variables": {}
}
JSON

RENDER_MISSING="$TMP_DIR/render-missing.out"
[ "$(request "$TOKEN_A" POST "/console/templates/$TEMPLATE_ID/render" "$TMP_DIR/render-missing.json" "$RENDER_MISSING")" = "422" ] \
  || { cat "$RENDER_MISSING" >&2; fail "missing template variable did not fail closed"; }

cat >"$TMP_DIR/render.json" <<'JSON'
{
  "variables": {
    "first_name": "Ada"
  }
}
JSON

RENDER="$TMP_DIR/render.out"
[ "$(request "$TOKEN_A" POST "/console/templates/$TEMPLATE_ID/render" "$TMP_DIR/render.json" "$RENDER")" = "200" ] \
  || { cat "$RENDER" >&2; fail "template render failed"; }

python3 - "$RENDER" "$TEMPLATE_ID" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
assert d["templateId"] == int(sys.argv[2])
assert d["version"] == 2
assert d["subject"] == "Updated Ada"
assert d["text"] is None
assert d["html"] == "<h1>Hello Ada</h1>"
PY

FOREIGN_RENDER="$TMP_DIR/foreign-render.out"
[ "$(request "$TOKEN_B" POST "/console/templates/$TEMPLATE_ID/render" "$TMP_DIR/render.json" "$FOREIGN_RENDER")" = "404" ] \
  || fail "foreign workspace rendered template"

echo "PASS: template rendering resolves variables and remains workspace isolated"

DUPLICATE="$TMP_DIR/duplicate.out"
[ "$(request "$TOKEN_A" POST "/console/templates/$TEMPLATE_ID/duplicate" "" "$DUPLICATE")" = "201" ] \
  || { cat "$DUPLICATE" >&2; fail "template duplication failed"; }

DUPLICATE_ID="$(
  python3 - "$DUPLICATE" "$TEMPLATE_ID" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
assert d["id"] != int(sys.argv[2])
assert d["version"] == 1
assert d["subject"] == "Updated {{first_name}}"
assert d["text"] is None
assert d["html"] == "<h1>Hello {{first_name}}</h1>"
assert d["variables"] == ["first_name"]
assert "copy" in d["name"].lower()
print(d["id"])
PY
)"

[[ "$DUPLICATE_ID" =~ ^[1-9][0-9]*$ ]] || fail "duplicate template id invalid"

DUP_HISTORY="$TMP_DIR/duplicate-history.out"
[ "$(request "$TOKEN_A" GET "/console/templates/$DUPLICATE_ID/history" "" "$DUP_HISTORY")" = "200" ] \
  || fail "duplicate history failed"

python3 - "$DUP_HISTORY" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
assert [item["version"] for item in d["items"]] == [1]
PY

FOREIGN_DUP="$TMP_DIR/foreign-duplicate.out"
[ "$(request "$TOKEN_B" POST "/console/templates/$TEMPLATE_ID/duplicate" "" "$FOREIGN_DUP")" = "404" ] \
  || fail "foreign workspace duplicated template"

echo "PASS: duplication copies only the latest version into a new version-1 template"
echo "ALL CONSOLE EMAIL TEMPLATE TESTS PASSED"
