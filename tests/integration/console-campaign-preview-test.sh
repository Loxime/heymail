#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

API_ORIGIN="https://api.heymail.test:8443"
TMP_DIR="$(mktemp -d /tmp/heymail-campaign-preview.XXXXXX)"
MARKER="$(openssl rand -hex 8)"
TOKEN_A="$(openssl rand -hex 32)"
TOKEN_B="$(openssl rand -hex 32)"
EMAIL_A="campaign-preview-a-${MARKER}@example.test"
EMAIL_B="campaign-preview-b-${MARKER}@example.test"
USER_A=""
USER_B=""
CAMPAIGN_ID=""
MESSAGE_ID=""

cleanup() {
  rc=$?
  trap - EXIT
  set +e

  docker compose exec \
    -T \
    -e EMAIL_A="$EMAIL_A" \
    -e EMAIL_B="$EMAIL_B" \
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

$p = new ConsoleUserProvisioner($c);

foreach ([getenv('EMAIL_A'), getenv('EMAIL_B')] as $email) {
    $userId = $c->fetchOne(
        'SELECT id FROM console_user WHERE email = :email',
        ['email' => $email],
    );

    if ($userId === false) {
        continue;
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

        $c->executeStatement(
            'DELETE FROM sender_identity
             WHERE sending_domain_id IN (
                 SELECT id
                 FROM sending_domain
                 WHERE workspace_id = :workspace_id
             )',
            ['workspace_id' => $workspaceId],
        );

        $c->executeStatement(
            'DELETE FROM sending_domain WHERE workspace_id = :workspace_id',
            ['workspace_id' => $workspaceId],
        );
    }

    $p->delete($userId);
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
  local body="$4"
  local output="$5"
  local headers="$6"

  local args=(
    --noproxy '*'
    --silent
    --show-error
    --cacert secrets/gateway_tls_cert.pem
    --resolve api.heymail.test:8443:127.0.0.1
    --dump-header "$headers"
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

echo "=== HeyMail campaign preview + test-send E2E ==="

docker compose up -d --wait database api gateway >/dev/null
docker compose stop mail-worker campaign-worker >/dev/null 2>&1 || true

FIXTURE="$(
  docker compose exec \
    -T \
    -e TOKEN_A="$TOKEN_A" \
    -e TOKEN_B="$TOKEN_B" \
    -e EMAIL_A="$EMAIL_A" \
    -e EMAIL_B="$EMAIL_B" \
    -e MARKER="$MARKER" \
    api \
    php <<'PHP'
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

$now = new DateTimeImmutable('now', new DateTimeZone('UTC'));
$hash = password_hash(bin2hex(random_bytes(24)), PASSWORD_DEFAULT);

if (!is_string($hash)) {
    throw new RuntimeException('Password hash failed.');
}

$p = new ConsoleUserProvisioner($c);

$userA = $p->create(
    (string) getenv('EMAIL_A'),
    'Preview',
    'A',
    $hash,
    $now,
);

$userB = $p->create(
    (string) getenv('EMAIL_B'),
    'Preview',
    'B',
    $hash,
    $now,
);

$workspaceA = (int) $c->fetchOne(
    'SELECT workspace_id FROM workspace_member WHERE user_id = :user_id',
    ['user_id' => $userA],
);

foreach ([
    [$userA, getenv('TOKEN_A')],
    [$userB, getenv('TOKEN_B')],
] as [$userId, $token]) {
    $c->insert('console_session', [
        'token_hash' => hash('sha256', (string) $token),
        'user_id' => $userId,
        'created_at' => $now->format('Y-m-d H:i:s'),
        'last_seen_at' => $now->format('Y-m-d H:i:s'),
        'expires_at' => $now->modify('+1 hour')->format('Y-m-d H:i:s'),
    ]);
}

$domainId = (int) $c->fetchOne(
    <<<'SQL'
INSERT INTO sending_domain (
    workspace_id,
    domain,
    status,
    verification_token,
    created_at,
    verification_checked_at,
    verified_at,
    dkim_selector,
    dkim_public_key,
    dkim_provisioned_at
)
VALUES (
    :workspace_id,
    :domain,
    'verified',
    :token,
    :now,
    :now,
    :now,
    'hm1',
    :public_key,
    :now
)
RETURNING id
SQL,
    [
        'workspace_id' => $workspaceA,
        'domain' => 'preview-' . getenv('MARKER') . '.example.test',
        'token' => hash('sha256', 'preview-' . getenv('MARKER')),
        'now' => $now->format('Y-m-d H:i:s'),
        'public_key' => base64_encode(random_bytes(32)),
    ],
);

$senderId = (int) $c->fetchOne(
    <<<'SQL'
INSERT INTO sender_identity (
    sending_domain_id,
    email,
    created_at
)
VALUES (
    :domain_id,
    :email,
    :created_at
)
RETURNING id
SQL,
    [
        'domain_id' => $domainId,
        'email' => 'hello@preview-' . getenv('MARKER') . '.example.test',
        'created_at' => $now->format('Y-m-d H:i:s'),
    ],
);

$templateId = (int) $c->fetchOne(
    <<<'SQL'
INSERT INTO email_template (
    workspace_id,
    name,
    created_at,
    updated_at
)
VALUES (
    :workspace_id,
    :name,
    :now,
    :now
)
RETURNING id
SQL,
    [
        'workspace_id' => $workspaceA,
        'name' => 'Preview ' . getenv('MARKER'),
        'now' => $now->format('Y-m-d H:i:s'),
    ],
);

$c->insert('email_template_version', [
    'template_id' => $templateId,
    'version' => 1,
    'subject' => 'Hello {{first_name}}',
    'text_body' => 'Company {{company}}',
    'html_body' => '<p>Hello {{first_name}} at {{company}}</p>',
    'created_at' => $now->format('Y-m-d H:i:s'),
]);

$listId = (int) $c->fetchOne(
    <<<'SQL'
INSERT INTO contact_list (
    workspace_id,
    name,
    created_at,
    updated_at
)
VALUES (
    :workspace_id,
    :name,
    :now,
    :now
)
RETURNING id
SQL,
    [
        'workspace_id' => $workspaceA,
        'name' => 'Preview list ' . getenv('MARKER'),
        'now' => $now->format('Y-m-d H:i:s'),
    ],
);

echo "USER_A=$userA\n";
echo "USER_B=$userB\n";
echo "WORKSPACE_A=$workspaceA\n";
echo "SENDER_ID=$senderId\n";
echo "TEMPLATE_ID=$templateId\n";
echo "LIST_ID=$listId\n";
PHP
)"

value() {
  awk -F= -v key="$1" '$1 == key { print $2 }' <<<"$FIXTURE"
}

USER_A="$(value USER_A)"
USER_B="$(value USER_B)"
WORKSPACE_A="$(value WORKSPACE_A)"
SENDER_ID="$(value SENDER_ID)"
TEMPLATE_ID="$(value TEMPLATE_ID)"
LIST_ID="$(value LIST_ID)"

for id in "$USER_A" "$USER_B" "$WORKSPACE_A" "$SENDER_ID" "$TEMPLATE_ID" "$LIST_ID"; do
  [[ "$id" =~ ^[1-9][0-9]*$ ]] || fail "invalid fixture identifier"
done

cat >"$TMP_DIR/create.json" <<JSON
{
  "name": "Preview ${MARKER}",
  "senderId": ${SENDER_ID},
  "templateId": ${TEMPLATE_ID},
  "listId": ${LIST_ID}
}
JSON

CREATE_OUT="$TMP_DIR/create.out"
CREATE_HEADERS="$TMP_DIR/create.headers"

[ "$(
  request \
    "$TOKEN_A" \
    POST \
    /console/campaigns \
    "$TMP_DIR/create.json" \
    "$CREATE_OUT" \
    "$CREATE_HEADERS"
)" = "201" ] || {
  cat "$CREATE_OUT" >&2
  fail "campaign draft creation failed"
}

CAMPAIGN_ID="$(
  python3 - "$CREATE_OUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["status"] == "draft"
print(data["id"])
PY
)"

[[ "$CAMPAIGN_ID" =~ ^[1-9][0-9]*$ ]] || fail "invalid campaign id"

cat >"$TMP_DIR/preview.json" <<'JSON'
{
  "variables": {
    "first_name": "Ada",
    "company": "Analytical Engines"
  }
}
JSON

PREVIEW_OUT="$TMP_DIR/preview.out"
PREVIEW_HEADERS="$TMP_DIR/preview.headers"

[ "$(
  request \
    "$TOKEN_A" \
    POST \
    "/console/campaigns/${CAMPAIGN_ID}/preview" \
    "$TMP_DIR/preview.json" \
    "$PREVIEW_OUT" \
    "$PREVIEW_HEADERS"
)" = "200" ] || {
  cat "$PREVIEW_OUT" >&2
  fail "campaign preview failed"
}

grep -Eiq '^cache-control: no-store' "$PREVIEW_HEADERS"

python3 - "$PREVIEW_OUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data == {
    "subject": "Hello Ada",
    "text": "Company Analytical Engines",
    "html": "<p>Hello Ada at Analytical Engines</p>",
}
PY

echo "PASS: draft campaign preview renders server-side with no-store"

FOREIGN_OUT="$TMP_DIR/foreign.out"
FOREIGN_HEADERS="$TMP_DIR/foreign.headers"

[ "$(
  request \
    "$TOKEN_B" \
    POST \
    "/console/campaigns/${CAMPAIGN_ID}/preview" \
    "$TMP_DIR/preview.json" \
    "$FOREIGN_OUT" \
    "$FOREIGN_HEADERS"
)" = "404" ] || {
  cat "$FOREIGN_OUT" >&2
  fail "foreign preview did not fail closed"
}

echo "PASS: campaign preview fails closed across workspaces"

TEST_RECIPIENT="campaign-test-${MARKER}@example.test"

cat >"$TMP_DIR/test.json" <<JSON
{
  "email": "${TEST_RECIPIENT}",
  "name": "Campaign Tester",
  "variables": {
    "first_name": "Ada",
    "company": "Analytical Engines"
  }
}
JSON

TEST_OUT="$TMP_DIR/test.out"
TEST_HEADERS="$TMP_DIR/test.headers"

[ "$(
  request \
    "$TOKEN_A" \
    POST \
    "/console/campaigns/${CAMPAIGN_ID}/test" \
    "$TMP_DIR/test.json" \
    "$TEST_OUT" \
    "$TEST_HEADERS"
)" = "202" ] || {
  cat "$TEST_OUT" >&2
  fail "campaign test-send failed"
}

MESSAGE_ID="$(
  python3 - "$TEST_OUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["status"] == "queued"
assert data["replayed"] is False
print(data["messageId"])
PY
)"

[[ "$MESSAGE_ID" =~ ^[1-9][0-9]*$ ]] || fail "invalid test message id"

DB_ASSERT="$(
  docker compose exec \
    -T \
    -e MESSAGE_ID="$MESSAGE_ID" \
    -e WORKSPACE_ID="$WORKSPACE_A" \
    -e TEST_RECIPIENT="$TEST_RECIPIENT" \
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

$messageId = (int) getenv('MESSAGE_ID');

$message = $c->fetchAssociative(
    'SELECT workspace_id, status
     FROM outbound_message
     WHERE id = :id',
    ['id' => $messageId],
);

$payload = $c->fetchAssociative(
    'SELECT ciphertext, nonce, wrapped_dek, wrap_nonce, algorithm, key_version
     FROM outbound_message_payload
     WHERE outbound_message_id = :id',
    ['id' => $messageId],
);

$queued = (int) $c->fetchOne(
    'SELECT COUNT(*)
     FROM messenger_messages
     WHERE queue_name = :queue
       AND body LIKE :needle',
    [
        'queue' => 'outbound',
        'needle' => '%"outboundMessageId":' . $messageId . '%',
    ],
);

if ($message === false || $payload === false) {
    exit(3);
}

$serialized = json_encode(
    $payload,
    JSON_THROW_ON_ERROR,
);

foreach ([
    getenv('TEST_RECIPIENT'),
    'Hello Ada',
    'Analytical Engines',
] as $needle) {
    if (
        is_string($needle)
        && $needle !== ''
        && str_contains($serialized, $needle)
    ) {
        echo "PLAINTEXT_LEAK=$needle\n";
        exit(4);
    }
}

echo 'WORKSPACE=', $message['workspace_id'], "\n";
echo 'STATUS=', $message['status'], "\n";
echo 'QUEUE=', $queued, "\n";
PHP
)"

grep -Fq "WORKSPACE=${WORKSPACE_A}" <<<"$DB_ASSERT"
grep -Fq 'STATUS=queued' <<<"$DB_ASSERT"
grep -Fq 'QUEUE=1' <<<"$DB_ASSERT"

echo "PASS: campaign test-send enters the encrypted outbound queue"

FOREIGN_TEST_OUT="$TMP_DIR/foreign-test.out"
FOREIGN_TEST_HEADERS="$TMP_DIR/foreign-test.headers"

[ "$(
  request \
    "$TOKEN_B" \
    POST \
    "/console/campaigns/${CAMPAIGN_ID}/test" \
    "$TMP_DIR/test.json" \
    "$FOREIGN_TEST_OUT" \
    "$FOREIGN_TEST_HEADERS"
)" = "404" ] || {
  cat "$FOREIGN_TEST_OUT" >&2
  fail "foreign test-send did not fail closed"
}

echo "PASS: campaign test-send fails closed across workspaces"
echo "ALL CAMPAIGN PREVIEW / TEST-SEND TESTS PASSED"
