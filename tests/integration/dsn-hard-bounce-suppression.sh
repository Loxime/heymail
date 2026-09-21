#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

TMP_DIR="$(mktemp -d /tmp/heymail-dsn-suppression.XXXXXX)"
EVENT_DIR="$TMP_DIR/events"
mkdir -p "$EVENT_DIR"

MARKER="$(openssl rand -hex 8)"
TEST_EMAIL="dsn-suppression-$MARKER@example.test"
USER_ID=""
OUTBOUND_ID=""
RECIPIENT=""
SOURCE_EVENT_ID=""

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

if($userId===false){
 exit;
}

$userId=(int)$userId;

$workspaceId=(int)$c->fetchOne(
 'SELECT workspace_id
  FROM workspace_member
  WHERE user_id=:user_id',
 ['user_id'=>$userId],
);

$messageIds=$c->fetchFirstColumn(
 'SELECT id
  FROM outbound_message
  WHERE workspace_id=:workspace_id',
 ['workspace_id'=>$workspaceId],
);

foreach($messageIds as $messageId){
 $c->delete(
  'outbound_message',
  ['id'=>(int)$messageId],
 );
}

try{
 (new ConsoleUserProvisioner($c))->delete($userId);
}catch(Throwable){}
PHP

  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT

fail(){
  echo "FAIL: $*" >&2
  exit 1
}

echo "=== HeyMail DSN hard-bounce suppression E2E ==="

docker compose up \
  -d \
  --wait \
  database \
  api \
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
use App\Mail\OutboundEmailPayload;
use App\Mail\OutboundEmailPayloadCipher;
use Doctrine\DBAL\DriverManager;

$c=DriverManager::getConnection([
 'driver'=>'pdo_pgsql',
 'host'=>getenv('DB_HOST'),
 'port'=>getenv('DB_PORT'),
 'dbname'=>getenv('DB_NAME'),
 'user'=>getenv('DB_USER'),
 'password'=>trim(file_get_contents((string)getenv('DB_PASSWORD_FILE'))),
]);

$now=new DateTimeImmutable(
 'now',
 new DateTimeZone('UTC'),
);

$passwordHash=password_hash(
 bin2hex(random_bytes(24)),
 PASSWORD_DEFAULT,
);

if(!is_string($passwordHash)){
 throw new RuntimeException('Password hash failed.');
}

$userId=(new ConsoleUserProvisioner($c))->create(
 (string)getenv('TEST_EMAIL'),
 'DSN',
 'Suppression',
 $passwordHash,
 $now,
);

$workspaceId=(int)$c->fetchOne(
 'SELECT workspace_id
  FROM workspace_member
  WHERE user_id=:user_id',
 ['user_id'=>$userId],
);

$recipient='dsn-hard-bounce-'
 . getenv('MARKER')
 . '@example.test';

$idempotencyKey='dsn-suppression-'
 . getenv('MARKER');

$idempotencyHash=hash(
 'sha256',
 $idempotencyKey,
);

$outboundId=(int)$c->fetchOne(
 <<<'SQL'
INSERT INTO outbound_message (
 workspace_id,
 idempotency_key_hash,
 status,
 created_at,
 ready_for_submission_at,
 submitting_at,
 submitted_at
)
VALUES (
 :workspace_id,
 :idempotency_key_hash,
 'submitted',
 :now,
 :now,
 :now,
 :now
)
RETURNING id
SQL,
 [
  'workspace_id'=>$workspaceId,
  'idempotency_key_hash'=>$idempotencyHash,
  'now'=>$now->format('Y-m-d H:i:s'),
 ],
);

$payload=OutboundEmailPayload::fromArray([
 'from'=>[
  'email'=>'sender@example.test',
 ],
 'to'=>[
  [
   'email'=>$recipient,
  ],
 ],
 'subject'=>'DSN suppression fixture',
 'text'=>'Authenticated DSN suppression fixture',
]);

$context=hash(
 'sha256',
 sprintf(
  'heymail:outbound-payload:v2:%d:%s',
  $workspaceId,
  $idempotencyHash,
 ),
);

$encrypted=(new OutboundEmailPayloadCipher(
 (string)getenv('PAYLOAD_KEK_FILE'),
))->encrypt(
 $context,
 $payload,
);

$c->insert(
 'outbound_message_payload',
 [
  'outbound_message_id'=>$outboundId,
  'ciphertext'=>$encrypted->ciphertext,
  'nonce'=>$encrypted->nonce,
  'wrapped_dek'=>$encrypted->wrappedDek,
  'wrap_nonce'=>$encrypted->wrapNonce,
  'algorithm'=>$encrypted->algorithm,
  'key_version'=>$encrypted->keyVersion,
 ],
);

$recipientHash=hash(
 'sha256',
 strtolower($recipient),
);

$type='bounced';
$smtpStatus='5.1.1';
$detail='mailbox does not exist';

$sourceEventId=hash(
 'sha256',
 implode(
  "\0",
  [
   'heymail-dsn-v1',
   (string)$outboundId,
   $recipientHash,
   $type,
   $smtpStatus,
   $detail,
  ],
 ),
);

echo "USER_ID=$userId\n";
echo "WORKSPACE_ID=$workspaceId\n";
echo "OUTBOUND_ID=$outboundId\n";
echo "RECIPIENT=$recipient\n";
echo "RECIPIENT_HASH=$recipientHash\n";
echo "SOURCE_EVENT_ID=$sourceEventId\n";
echo "SMTP_STATUS=$smtpStatus\n";
echo "DETAIL=$detail\n";
PHP
)"

value(){
  awk -F= -v key="$1" '$1==key{print substr($0,index($0,"=")+1)}' <<<"$FIXTURE"
}

USER_ID="$(value USER_ID)"
WORKSPACE_ID="$(value WORKSPACE_ID)"
OUTBOUND_ID="$(value OUTBOUND_ID)"
RECIPIENT="$(value RECIPIENT)"
RECIPIENT_HASH="$(value RECIPIENT_HASH)"
SOURCE_EVENT_ID="$(value SOURCE_EVENT_ID)"
SMTP_STATUS="$(value SMTP_STATUS)"
DETAIL="$(value DETAIL)"

for x in "$USER_ID" "$WORKSPACE_ID" "$OUTBOUND_ID"; do
  [[ "$x" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid fixture identifier"
done

[[ "$RECIPIENT_HASH" =~ ^[a-f0-9]{64}$ ]] \
  || fail "invalid recipient hash"

[[ "$SOURCE_EVENT_ID" =~ ^[a-f0-9]{64}$ ]] \
  || fail "invalid source event id"

write_event(){
python3 \
  - "$EVENT_DIR/$SOURCE_EVENT_ID.json" \
  "$OUTBOUND_ID" \
  "$RECIPIENT_HASH" \
  "$SMTP_STATUS" \
  "$DETAIL" \
  "$SOURCE_EVENT_ID" <<'PY'
import json
import sys

path, message_id, recipient_hash, smtp_status, detail, source_id = sys.argv[1:]

with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "detail": detail,
            "messageId": int(message_id),
            "recipientHash": recipient_hash,
            "smtpStatus": smtp_status,
            "sourceEventId": source_id,
            "type": "bounced",
        },
        handle,
        separators=(",", ":"),
    )
PY
}

run_worker(){
  docker compose run \
    --rm \
    --no-deps \
    -T \
    -v "$EVENT_DIR:/events" \
    api \
    php bin/console app:consume-dsn-spool \
    --directory=/events \
    --once \
    --no-interaction \
    </dev/null
}

write_event

WORKER_OUT="$(run_worker)"
printf '%s\n' "$WORKER_OUT"

[ ! -e "$EVENT_DIR/$SOURCE_EVENT_ID.json" ] \
  || fail "DSN file was not acknowledged"

STATE="$(
docker compose exec \
  -T \
  -e OUTBOUND_ID="$OUTBOUND_ID" \
  -e WORKSPACE_ID="$WORKSPACE_ID" \
  -e RECIPIENT="$RECIPIENT" \
  -e SOURCE_EVENT_ID="$SOURCE_EVENT_ID" \
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

$eventRow=$c->fetchAssociative(
 <<<'SQL'
SELECT
 recipient_domain
FROM outbound_message_event
WHERE outbound_message_id=:message_id
  AND event_type='bounced'
  AND source_event_id=:source_event_id
SQL,
 [
  'message_id'=>(int)getenv('OUTBOUND_ID'),
  'source_event_id'=>getenv('SOURCE_EVENT_ID'),
 ],
);

$eventCount=$eventRow===false ? 0 : 1;

$row=$c->fetchAssociative(
 <<<'SQL'
SELECT
 scope,
 reason,
 source_outbound_message_id,
 source_event_id
FROM email_suppression
WHERE workspace_id=:workspace_id
  AND email_hash=:email_hash
SQL,
 [
  'workspace_id'=>(int)getenv('WORKSPACE_ID'),
  'email_hash'=>hash(
   'sha256',
   strtolower((string)getenv('RECIPIENT')),
  ),
 ],
);

echo "EVENT_COUNT=$eventCount\n";
echo 'EVENT_DOMAIN=',
 $eventRow===false
  ? 'NONE'
  : $eventRow['recipient_domain'],
 "\n";

if($row===false){
 echo "SUPPRESSION=NONE\n";
 exit;
}

echo 'SUPPRESSION=',
 $row['scope'],
 ':',
 $row['reason'],
 ':',
 $row['source_outbound_message_id'],
 ':',
 $row['source_event_id'],
 "\n";
PHP
)"

printf '%s\n' "$STATE"

grep -Fqx 'EVENT_COUNT=1' <<<"$STATE" \
  || fail "authenticated DSN bounce was not persisted exactly once"

grep -Fqx 'EVENT_DOMAIN=example.test' <<<"$STATE" \
  || fail "authenticated DSN bounce did not persist recipient domain"

grep -Fqx \
  "SUPPRESSION=global:hard_bounce:$OUTBOUND_ID:$SOURCE_EVENT_ID" \
  <<<"$STATE" \
  || fail "DSN hard bounce did not create expected global suppression"

echo "PASS: authenticated DSN hard bounce persists recipient domain and creates workspace-global suppression"

write_event

REPLAY_OUT="$(run_worker)"
printf '%s\n' "$REPLAY_OUT"

[ ! -e "$EVENT_DIR/$SOURCE_EVENT_ID.json" ] \
  || fail "duplicate DSN file was not acknowledged"

REPLAY="$(
docker compose exec \
  -T \
  -e OUTBOUND_ID="$OUTBOUND_ID" \
  -e WORKSPACE_ID="$WORKSPACE_ID" \
  -e RECIPIENT="$RECIPIENT" \
  -e SOURCE_EVENT_ID="$SOURCE_EVENT_ID" \
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

echo 'EVENTS=',(int)$c->fetchOne(
 <<<'SQL'
SELECT COUNT(*)
FROM outbound_message_event
WHERE outbound_message_id=:message_id
  AND event_type='bounced'
  AND source_event_id=:source_event_id
SQL,
 [
  'message_id'=>(int)getenv('OUTBOUND_ID'),
  'source_event_id'=>getenv('SOURCE_EVENT_ID'),
 ],
),"\n";

echo 'SUPPRESSIONS=',(int)$c->fetchOne(
 'SELECT COUNT(*)
  FROM email_suppression
  WHERE workspace_id=:workspace_id
    AND email_hash=:email_hash',
 [
  'workspace_id'=>(int)getenv('WORKSPACE_ID'),
  'email_hash'=>hash(
   'sha256',
   strtolower((string)getenv('RECIPIENT')),
  ),
 ],
),"\n";
PHP
)"

printf '%s\n' "$REPLAY"

grep -Fqx 'EVENTS=1' <<<"$REPLAY" \
  || fail "duplicate DSN created duplicate bounce event"

grep -Fqx 'SUPPRESSIONS=1' <<<"$REPLAY" \
  || fail "duplicate DSN created duplicate suppression"

echo "PASS: DSN suppression path is idempotent on replay"
echo "ALL DSN HARD-BOUNCE SUPPRESSION TESTS PASSED"
