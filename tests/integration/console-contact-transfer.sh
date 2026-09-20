#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

API_ORIGIN="https://api.heymail.test:8443"
TMP_DIR="$(mktemp -d /tmp/heymail-contact-transfer.XXXXXX)"
TOKEN_A="$(openssl rand -hex 32)"
TOKEN_B="$(openssl rand -hex 32)"
MARKER="$(openssl rand -hex 8)"
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

$connection = DriverManager::getConnection([
    'driver' => 'pdo_pgsql',
    'host' => getenv('DB_HOST'),
    'port' => getenv('DB_PORT'),
    'dbname' => getenv('DB_NAME'),
    'user' => getenv('DB_USER'),
    'password' => trim(file_get_contents((string) getenv('DB_PASSWORD_FILE'))),
]);

$provisioner = new ConsoleUserProvisioner($connection);

foreach ([getenv('USER_A'), getenv('USER_B')] as $id) {
    if (
        is_string($id)
        && preg_match('/^[1-9][0-9]*$/D', $id) === 1
    ) {
        try {
            $provisioner->delete((int) $id);
        } catch (Throwable) {
        }
    }
}
PHP

  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

request_json() {
  local token="$1"
  local method="$2"
  local path="$3"
  local body="${4:-}"
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

request_csv() {
  local token="$1"
  local path="$2"
  local body="$3"
  local output="$4"

  curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --output "$output" \
    --write-out '%{http_code}' \
    --request POST \
    --header "Cookie: heymail_session=${token}" \
    --header 'Content-Type: text/csv' \
    --data-binary "@$body" \
    "$API_ORIGIN$path"
}

echo "=== HeyMail contact CSV transfer E2E ==="

docker compose up -d --wait database api gateway >/dev/null

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

$connection = DriverManager::getConnection([
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
    throw new RuntimeException('Hash failed.');
}

$provisioner = new ConsoleUserProvisioner($connection);
$marker = (string) getenv('MARKER');

$userA = $provisioner->create(
    "csv-a-$marker@example.test",
    'CSV',
    'A',
    $hash,
    $now,
);
$userB = $provisioner->create(
    "csv-b-$marker@example.test",
    'CSV',
    'B',
    $hash,
    $now,
);

foreach ([[$userA, getenv('TOKEN_A')], [$userB, getenv('TOKEN_B')]] as [$userId, $token]) {
    $connection->insert('console_session', [
        'token_hash' => hash('sha256', (string) $token),
        'user_id' => $userId,
        'created_at' => $now->format('Y-m-d H:i:s'),
        'last_seen_at' => $now->format('Y-m-d H:i:s'),
        'expires_at' => $now->modify('+1 hour')->format('Y-m-d H:i:s'),
    ]);
}

echo "USER_A=$userA\nUSER_B=$userB\n";
PHP
)"

value() {
  awk -F= -v key="$1" '$1 == key { print $2 }' <<<"$FIXTURE"
}

USER_A="$(value USER_A)"
USER_B="$(value USER_B)"

[[ "$USER_A" =~ ^[1-9][0-9]*$ ]] || fail "invalid user A"
[[ "$USER_B" =~ ^[1-9][0-9]*$ ]] || fail "invalid user B"

cat >"$TMP_DIR/list.json" <<'JSON'
{
  "name": "Imported"
}
JSON

LIST_OUT="$TMP_DIR/list.out"

[ "$(
  request_json \
    "$TOKEN_A" \
    POST \
    /console/contact-lists \
    "$TMP_DIR/list.json" \
    "$LIST_OUT"
)" = "201" ] || {
  cat "$LIST_OUT" >&2
  fail "list creation failed"
}

cat >"$TMP_DIR/import.csv" <<CSV
email,name,tags_json,lists_json,custom_fields_json
ada-${MARKER}@example.test,=2+2,"[""vip"",""customer""]","[""Imported""]","{""company"":""Analytical Engines"",""score"":42}"
grace-${MARKER}@example.test,Grace Hopper,"[""customer""]","[""Imported""]","{""company"":""Navy""}"
CSV

IMPORT_OUT="$TMP_DIR/import.out"

[ "$(
  request_csv \
    "$TOKEN_A" \
    /console/contacts/import \
    "$TMP_DIR/import.csv" \
    "$IMPORT_OUT"
)" = "200" ] || {
  cat "$IMPORT_OUT" >&2
  fail "CSV import failed"
}

python3 - "$IMPORT_OUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data == {
    "rows": 2,
    "created": 2,
    "updated": 0,
}
PY

echo "PASS: CSV import is atomic and reports created rows"

TAGS_OUT="$TMP_DIR/tags.out"

[ "$(
  request_json \
    "$TOKEN_A" \
    GET \
    /console/contact-tags \
    "" \
    "$TAGS_OUT"
)" = "200" ] || fail "tag listing failed"

python3 - "$TAGS_OUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    items = json.load(handle)["items"]

counts = {
    item["name"].lower(): item["contactCount"]
    for item in items
}

assert counts["customer"] == 2
assert counts["vip"] == 1
PY

echo "PASS: tag registry exposes workspace-scoped contact counts"

FILTER_OUT="$TMP_DIR/filter.out"

[ "$(
  request_json \
    "$TOKEN_A" \
    GET \
    "/console/contacts?q=ada&tag=vip" \
    "" \
    "$FILTER_OUT"
)" = "200" ] || fail "segment read failed"

python3 - "$FILTER_OUT" "$MARKER" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    items = json.load(handle)["items"]

assert len(items) == 1
assert items[0]["email"] == f"ada-{sys.argv[2]}@example.test"
assert items[0]["customFields"] == {
    "company": "Analytical Engines",
    "score": 42,
}
PY

echo "PASS: imported contacts participate in segmentation"

EXPORT_BODY="$TMP_DIR/export.csv"
EXPORT_HEADERS="$TMP_DIR/export.headers"

EXPORT_CODE="$(
  curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --dump-header "$EXPORT_HEADERS" \
    --output "$EXPORT_BODY" \
    --write-out '%{http_code}' \
    --header "Cookie: heymail_session=${TOKEN_A}" \
    "$API_ORIGIN/console/contacts/export?tag=vip"
)"

[ "$EXPORT_CODE" = "200" ] || {
  cat "$EXPORT_BODY" >&2
  fail "CSV export failed"
}

grep -Eiq '^content-type: text/csv' "$EXPORT_HEADERS"
grep -Eiq '^cache-control: no-store' "$EXPORT_HEADERS"
grep -Eiq '^x-content-type-options: nosniff' "$EXPORT_HEADERS"

python3 - "$EXPORT_BODY" "$MARKER" <<'PY'
import csv
import json
import sys

with open(
    sys.argv[1],
    newline="",
    encoding="utf-8",
) as handle:
    rows = list(csv.DictReader(handle))

assert len(rows) == 1
row = rows[0]
assert row["email"] == f"ada-{sys.argv[2]}@example.test"
assert row["name"] == "'=2+2"
assert json.loads(row["tags_json"]) == ["customer", "vip"]
assert json.loads(row["lists_json"]) == ["Imported"]
assert json.loads(row["custom_fields_json"]) == {
    "company": "Analytical Engines",
    "score": 42,
}
PY

echo "PASS: CSV export preserves the filtered segment and structured fields"

ROUNDTRIP_OUT="$TMP_DIR/roundtrip.out"

[ "$(
  request_csv \
    "$TOKEN_A" \
    /console/contacts/import \
    "$EXPORT_BODY" \
    "$ROUNDTRIP_OUT"
)" = "200" ] || {
  cat "$ROUNDTRIP_OUT" >&2
  fail "CSV round-trip re-import failed"
}

python3 - "$ROUNDTRIP_OUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data == {
    "rows": 1,
    "created": 0,
    "updated": 1,
}
PY

ROUNDTRIP_CONTACT="$TMP_DIR/roundtrip-contact.out"

[ "$(
  request_json \
    "$TOKEN_A" \
    GET \
    "/console/contacts?q=ada-${MARKER}" \
    "" \
    "$ROUNDTRIP_CONTACT"
)" = "200" ] || fail "round-trip contact read failed"

python3 - "$ROUNDTRIP_CONTACT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    items = json.load(handle)["items"]

assert len(items) == 1
assert items[0]["name"] == "=2+2"
PY

echo "PASS: CSV formula hardening is reversible on HeyMail re-import"

cat >"$TMP_DIR/hostile.csv" <<CSV
email,name,tags_json,lists_json,custom_fields_json
valid-${MARKER}@example.test,Valid,"[]","[""Imported""]","{}"
invalid-${MARKER}@example.test,Invalid,"[]","[""Missing list""]","{}"
CSV

HOSTILE_OUT="$TMP_DIR/hostile.out"

[ "$(
  request_csv \
    "$TOKEN_A" \
    /console/contacts/import \
    "$TMP_DIR/hostile.csv" \
    "$HOSTILE_OUT"
)" = "422" ] || {
  cat "$HOSTILE_OUT" >&2
  fail "unknown list import did not fail closed"
}

AFTER_HOSTILE="$TMP_DIR/after-hostile.out"

[ "$(
  request_json \
    "$TOKEN_A" \
    GET \
    "/console/contacts?q=valid-${MARKER}" \
    "" \
    "$AFTER_HOSTILE"
)" = "200" ] || fail "post-hostile read failed"

python3 - "$AFTER_HOSTILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    items = json.load(handle)["items"]

assert items == []
PY

echo "PASS: failed CSV import rolls back every row"

FOREIGN_EXPORT="$TMP_DIR/foreign-export.csv"

[ "$(
  curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --output "$FOREIGN_EXPORT" \
    --write-out '%{http_code}' \
    --header "Cookie: heymail_session=${TOKEN_B}" \
    "$API_ORIGIN/console/contacts/export"
)" = "200" ] || fail "foreign export failed"

python3 - "$FOREIGN_EXPORT" "$MARKER" <<'PY'
import csv
import sys

with open(
    sys.argv[1],
    newline="",
    encoding="utf-8",
) as handle:
    rows = list(csv.DictReader(handle))

marker = sys.argv[2]
assert all(
    marker not in row["email"]
    for row in rows
)
PY

echo "PASS: CSV export remains workspace isolated"

echo "ALL CONTACT CSV TRANSFER TESTS PASSED"
