#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
    && pwd
)"

cd "$ROOT_DIR"

API_ORIGIN="https://api.heymail.test:8443"
TMP_DIR="$(
  mktemp -d /tmp/heymail-console-contacts.XXXXXX
)"
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
    'password' => trim(
        file_get_contents(
            (string) getenv('DB_PASSWORD_FILE'),
        ),
    ),
]);

$provisioner = new ConsoleUserProvisioner(
    $connection,
);

foreach ([
    getenv('USER_A'),
    getenv('USER_B'),
] as $id) {
    if (
        is_string($id)
        && preg_match('/^[1-9][0-9]*$/D', $id) === 1
    ) {
        try {
            $provisioner->delete(
                (int) $id,
            );
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

request() {
  local token="$1"
  local method="$2"
  local path="$3"
  local body_file="$4"
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

  if [ -n "$body_file" ]; then
    args+=(
      --header 'Content-Type: application/json'
      --data-binary "@$body_file"
    )
  fi

  curl \
    "${args[@]}" \
    "$API_ORIGIN$path"
}

echo "=== HeyMail workspace contacts E2E ==="

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

$connection = DriverManager::getConnection([
    'driver' => 'pdo_pgsql',
    'host' => getenv('DB_HOST'),
    'port' => getenv('DB_PORT'),
    'dbname' => getenv('DB_NAME'),
    'user' => getenv('DB_USER'),
    'password' => trim(
        file_get_contents(
            (string) getenv('DB_PASSWORD_FILE'),
        ),
    ),
]);

$provisioner = new ConsoleUserProvisioner(
    $connection,
);

$now = new DateTimeImmutable(
    'now',
    new DateTimeZone('UTC'),
);

$hash = password_hash(
    bin2hex(random_bytes(24)),
    PASSWORD_DEFAULT,
);

if (!is_string($hash)) {
    exit(2);
}

$marker = (string) getenv('MARKER');

$userA = $provisioner->create(
    "contacts-a-$marker@example.test",
    'Contacts',
    'A',
    $hash,
    $now,
);

$userB = $provisioner->create(
    "contacts-b-$marker@example.test",
    'Contacts',
    'B',
    $hash,
    $now,
);

$workspaceFor = static function (
    int $userId,
) use ($connection): int {
    return (int) $connection->fetchOne(
        <<<'SQL'
SELECT workspace_id
FROM workspace_member
WHERE user_id = :user_id
SQL,
        [
            'user_id' => $userId,
        ],
    );
};

foreach ([
    [$userA, getenv('TOKEN_A')],
    [$userB, getenv('TOKEN_B')],
] as [$userId, $token]) {
    $connection->insert(
        'console_session',
        [
            'token_hash' => hash(
                'sha256',
                (string) $token,
            ),
            'user_id' => $userId,
            'created_at' => $now->format(
                'Y-m-d H:i:s',
            ),
            'last_seen_at' => $now->format(
                'Y-m-d H:i:s',
            ),
            'expires_at' => $now
                ->modify('+1 hour')
                ->format('Y-m-d H:i:s'),
        ],
    );
}

echo "USER_A=$userA\n";
echo "USER_B=$userB\n";
echo 'WORKSPACE_A=', $workspaceFor($userA), "\n";
echo 'WORKSPACE_B=', $workspaceFor($userB), "\n";
PHP
)"

value() {
  awk \
    -F= \
    -v key="$1" \
    '$1 == key { print $2 }' \
    <<<"$FIXTURE"
}

USER_A="$(value USER_A)"
USER_B="$(value USER_B)"
WORKSPACE_A="$(value WORKSPACE_A)"
WORKSPACE_B="$(value WORKSPACE_B)"

for value in \
  "$USER_A" \
  "$USER_B" \
  "$WORKSPACE_A" \
  "$WORKSPACE_B"
do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid fixture identifier"
done

cat >"$TMP_DIR/favorite.json" <<JSON
{
  "email": "legacy.${MARKER}@example.test",
  "name": "Legacy Favorite"
}
JSON

FAVORITE_OUT="$TMP_DIR/favorite.out"

[ "$(
  request     "$TOKEN_A"     POST     /console/profile/favorites     "$TMP_DIR/favorite.json"     "$FAVORITE_OUT"
)" = "200" ]   || {
    cat "$FAVORITE_OUT" >&2
    fail "legacy favorite creation failed"
  }

FAVORITE_ID="$(
  python3     - "$FAVORITE_OUT" "$MARKER" <<'PYF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    items = json.load(handle)["items"]

email = f"legacy.{sys.argv[2]}@example.test"

matched = [
    item
    for item in items
    if item["email"] == email
]

assert len(matched) == 1
print(matched[0]["id"])
PYF
)"

[[ "$FAVORITE_ID" =~ ^[1-9][0-9]*$ ]]   || fail "invalid favorite identifier"

LEGACY_CONTACT_OUT="$TMP_DIR/legacy-contact.out"

[ "$(
  request     "$TOKEN_A"     GET     "/console/contacts?q=legacy.${MARKER}"     ""     "$LEGACY_CONTACT_OUT"
)" = "200" ]   || fail "legacy favorite contact bridge read failed"

LEGACY_CONTACT_ID="$(
  python3     - "$LEGACY_CONTACT_OUT" "$MARKER" <<'PYF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    items = json.load(handle)["items"]

email = f"legacy.{sys.argv[2]}@example.test"

matched = [
    item
    for item in items
    if item["email"] == email
]

assert len(matched) == 1
assert matched[0]["name"] == "Legacy Favorite"
assert matched[0]["customFields"] == {}
assert matched[0]["tags"] == []
assert matched[0]["listIds"] == []

print(matched[0]["id"])
PYF
)"

[[ "$LEGACY_CONTACT_ID" =~ ^[1-9][0-9]*$ ]]   || fail "invalid bridged contact identifier"

DELETE_FAVORITE_OUT="$TMP_DIR/delete-favorite.out"

[ "$(
  request     "$TOKEN_A"     DELETE     "/console/profile/favorites/${FAVORITE_ID}"     ""     "$DELETE_FAVORITE_OUT"
)" = "204" ]   || fail "legacy favorite deletion failed"

LEGACY_AFTER_DELETE="$TMP_DIR/legacy-after-delete.out"

[ "$(
  request     "$TOKEN_A"     GET     "/console/contacts?q=legacy.${MARKER}"     ""     "$LEGACY_AFTER_DELETE"
)" = "200" ]   || fail "bridged contact disappeared after favorite deletion"

python3   - "$LEGACY_AFTER_DELETE" "$LEGACY_CONTACT_ID" <<'PYF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    items = json.load(handle)["items"]

contact_id = int(sys.argv[2])

assert [
    item["id"]
    for item in items
] == [contact_id]
PYF

echo "PASS: legacy favorites bridge into workspace contacts without deleting contacts on unfavorite"

cat >"$TMP_DIR/list.json" <<'JSON'
{
  "name": "Customers"
}
JSON

LIST_A_OUT="$TMP_DIR/list-a.out"

[ "$(
  request \
    "$TOKEN_A" \
    POST \
    /console/contact-lists \
    "$TMP_DIR/list.json" \
    "$LIST_A_OUT"
)" = "201" ] \
  || {
    cat "$LIST_A_OUT" >&2
    fail "workspace A list creation failed"
  }

LIST_A_ID="$(
  python3 \
    - "$LIST_A_OUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["name"] == "Customers"
assert data["contactCount"] == 0
print(data["id"])
PY
)"

[[ "$LIST_A_ID" =~ ^[1-9][0-9]*$ ]] \
  || fail "invalid list identifier"

cat >"$TMP_DIR/contact-a.json" <<JSON
{
  "email": "ADA.${MARKER}@Example.Test",
  "name": "Ada Lovelace",
  "customFields": {
    "company": "Analytical Engines",
    "score": 42
  },
  "tags": [
    "VIP",
    "Customer"
  ],
  "listIds": [
    ${LIST_A_ID}
  ]
}
JSON

CONTACT_A_OUT="$TMP_DIR/contact-a.out"

[ "$(
  request \
    "$TOKEN_A" \
    POST \
    /console/contacts \
    "$TMP_DIR/contact-a.json" \
    "$CONTACT_A_OUT"
)" = "201" ] \
  || {
    cat "$CONTACT_A_OUT" >&2
    fail "workspace A contact creation failed"
  }

CONTACT_A_ID="$(
  python3 \
    - "$CONTACT_A_OUT" "$LIST_A_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["email"] == data["email"].lower()
assert data["name"] == "Ada Lovelace"
assert data["customFields"] == {
    "company": "Analytical Engines",
    "score": 42,
}
assert data["tags"] == ["Customer", "VIP"]
assert data["listIds"] == [int(sys.argv[2])]
print(data["id"])
PY
)"

[[ "$CONTACT_A_ID" =~ ^[1-9][0-9]*$ ]] \
  || fail "invalid contact identifier"

echo "PASS: workspace A created contact with tags, list and custom fields"

SEARCH_OUT="$TMP_DIR/search.out"

[ "$(
  request \
    "$TOKEN_A" \
    GET \
    "/console/contacts?q=ada&tag=vip&list=${LIST_A_ID}" \
    "" \
    "$SEARCH_OUT"
)" = "200" ] \
  || fail "contact search failed"

python3 \
  - "$SEARCH_OUT" "$CONTACT_A_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    items = json.load(handle)["items"]

contact_id = int(sys.argv[2])

assert [item["id"] for item in items] == [contact_id]
PY

echo "PASS: search, tag and list filters intersect correctly"

LIST_B_VIEW="$TMP_DIR/list-b-view.out"

[ "$(
  request \
    "$TOKEN_B" \
    GET \
    /console/contacts \
    "" \
    "$LIST_B_VIEW"
)" = "200" ] \
  || fail "workspace B contact list failed"

python3 \
  - "$LIST_B_VIEW" "$CONTACT_A_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    items = json.load(handle)["items"]

contact_id = int(sys.argv[2])

assert all(
    item["id"] != contact_id
    for item in items
)
PY

cat >"$TMP_DIR/foreign-patch.json" <<'JSON'
{
  "name": "Foreign write"
}
JSON

FOREIGN_PATCH="$TMP_DIR/foreign-patch.out"

[ "$(
  request \
    "$TOKEN_B" \
    PATCH \
    "/console/contacts/${CONTACT_A_ID}" \
    "$TMP_DIR/foreign-patch.json" \
    "$FOREIGN_PATCH"
)" = "404" ] \
  || fail "foreign workspace mutated contact"

echo "PASS: contact reads and writes fail closed across workspaces"

cat >"$TMP_DIR/contact-b.json" <<JSON
{
  "email": "ada.${MARKER}@example.test",
  "name": "Workspace B Ada"
}
JSON

CONTACT_B_OUT="$TMP_DIR/contact-b.out"

[ "$(
  request \
    "$TOKEN_B" \
    POST \
    /console/contacts \
    "$TMP_DIR/contact-b.json" \
    "$CONTACT_B_OUT"
)" = "201" ] \
  || {
    cat "$CONTACT_B_OUT" >&2
    fail "same email in independent workspace was rejected"
  }

echo "PASS: contact email uniqueness is workspace-scoped"

cat >"$TMP_DIR/update-a.json" <<JSON
{
  "name": "Ada Byron",
  "customFields": {
    "company": "Analytical Engines",
    "active": true
  },
  "tags": [
    "Customer"
  ],
  "listIds": [
    ${LIST_A_ID}
  ]
}
JSON

UPDATE_A_OUT="$TMP_DIR/update-a.out"

[ "$(
  request \
    "$TOKEN_A" \
    PATCH \
    "/console/contacts/${CONTACT_A_ID}" \
    "$TMP_DIR/update-a.json" \
    "$UPDATE_A_OUT"
)" = "200" ] \
  || {
    cat "$UPDATE_A_OUT" >&2
    fail "contact update failed"
  }

python3 \
  - "$UPDATE_A_OUT" "$LIST_A_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["name"] == "Ada Byron"
assert data["customFields"] == {
    "company": "Analytical Engines",
    "active": True,
}
assert data["tags"] == ["Customer"]
assert data["listIds"] == [int(sys.argv[2])]
PY

echo "PASS: contact CRUD preserves bounded custom fields and exact tags"

cat >"$TMP_DIR/members.json" <<JSON
{
  "contactIds": [
    ${CONTACT_A_ID}
  ]
}
JSON

MEMBERS_OUT="$TMP_DIR/members.out"

[ "$(
  request \
    "$TOKEN_A" \
    POST \
    "/console/contact-lists/${LIST_A_ID}/members" \
    "$TMP_DIR/members.json" \
    "$MEMBERS_OUT"
)" = "200" ] \
  || fail "list membership replacement failed"

python3 \
  - "$MEMBERS_OUT" "$LIST_A_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data == {
    "id": int(sys.argv[2]),
    "contactCount": 1,
}
PY

LISTS_OUT="$TMP_DIR/lists.out"

[ "$(
  request \
    "$TOKEN_A" \
    GET \
    /console/contact-lists \
    "" \
    "$LISTS_OUT"
)" = "200" ] \
  || fail "contact lists read failed"

python3 \
  - "$LISTS_OUT" "$LIST_A_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    items = json.load(handle)["items"]

list_id = int(sys.argv[2])
matched = [
    item
    for item in items
    if item["id"] == list_id
]

assert len(matched) == 1
assert matched[0]["contactCount"] == 1
PY

echo "PASS: contact list membership is workspace-scoped and replaceable"

DELETE_LIST_OUT="$TMP_DIR/delete-list.out"

[ "$(
  request \
    "$TOKEN_A" \
    DELETE \
    "/console/contact-lists/${LIST_A_ID}" \
    "" \
    "$DELETE_LIST_OUT"
)" = "204" ] \
  || fail "contact list deletion failed"

AFTER_LIST_DELETE="$TMP_DIR/after-list-delete.out"

[ "$(
  request \
    "$TOKEN_A" \
    GET \
    "/console/contacts?q=ada" \
    "" \
    "$AFTER_LIST_DELETE"
)" = "200" ] \
  || fail "contact read after list deletion failed"

python3 \
  - "$AFTER_LIST_DELETE" "$CONTACT_A_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    items = json.load(handle)["items"]

contact_id = int(sys.argv[2])
matched = [
    item
    for item in items
    if item["id"] == contact_id
]

assert len(matched) == 1
assert matched[0]["listIds"] == []
PY

echo "PASS: deleting a list preserves its contacts"

FOREIGN_DELETE="$TMP_DIR/foreign-delete.out"

[ "$(
  request \
    "$TOKEN_B" \
    DELETE \
    "/console/contacts/${CONTACT_A_ID}" \
    "" \
    "$FOREIGN_DELETE"
)" = "404" ] \
  || fail "foreign workspace deleted contact"

DELETE_A="$TMP_DIR/delete-a.out"

[ "$(
  request \
    "$TOKEN_A" \
    DELETE \
    "/console/contacts/${CONTACT_A_ID}" \
    "" \
    "$DELETE_A"
)" = "204" ] \
  || fail "contact deletion failed"

echo "PASS: contact deletion is isolated"

echo "ALL WORKSPACE CONTACT TESTS PASSED"
