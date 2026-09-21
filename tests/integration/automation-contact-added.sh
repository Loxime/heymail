#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
    && pwd
)"

cd "$ROOT_DIR"

TMP_DIR="$(
  mktemp \
    -d \
    /tmp/heymail-automation-contact.XXXXXX
)"

TOKEN="$(
  openssl rand -hex 32
)"

MARKER="$(
  openssl rand -hex 8
)"

USER_ID=""
WORKSPACE_ID=""
IMMEDIATE_ID=""
DELAYED_ID=""

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

$userId = (int) getenv('USER_ID');

if ($userId < 1) {
    exit;
}

$connection = DriverManager::getConnection([
    'driver' => 'pdo_pgsql',
    'host' => getenv('DB_HOST'),
    'port' => getenv('DB_PORT'),
    'dbname' => getenv('DB_NAME'),
    'user' => getenv('DB_USER'),
    'password' => trim(
        file_get_contents(
            (string) getenv(
                'DB_PASSWORD_FILE',
            ),
        ),
    ),
]);

$workspaceId = (int) $connection->fetchOne(
    <<<'SQL'
SELECT workspace_id
FROM workspace_member
WHERE user_id = :user_id
SQL,
    [
        'user_id' => $userId,
    ],
);

if ($workspaceId > 0) {
    $messageIds =
        array_map(
            'intval',
            $connection->fetchFirstColumn(
                <<<'SQL'
SELECT DISTINCT outbound_message_id
FROM automation_job
WHERE workspace_id = :workspace_id
  AND outbound_message_id IS NOT NULL
SQL,
                [
                    'workspace_id'
                        => $workspaceId,
                ],
            ),
        );

    $connection->executeStatement(
        <<<'SQL'
DELETE FROM automation_quota_reservation
WHERE workspace_id = :workspace_id
SQL,
        [
            'workspace_id'
                => $workspaceId,
        ],
    );

    $connection->executeStatement(
        <<<'SQL'
DELETE FROM automation
WHERE workspace_id = :workspace_id
SQL,
        [
            'workspace_id'
                => $workspaceId,
        ],
    );

    foreach ($messageIds as $messageId) {
        $connection->executeStatement(
            <<<'SQL'
DELETE FROM messenger_messages
WHERE queue_name IN ('outbound', 'failed')
  AND body LIKE :message_id
SQL,
            [
                'message_id'
                    => '%"outboundMessageId":'
                        . $messageId
                        . '%',
            ],
        );

        $connection->delete(
            'outbound_message',
            [
                'id' => $messageId,
            ],
        );
    }
}

try {
    (
        new ConsoleUserProvisioner(
            $connection,
        )
    )->delete(
        $userId,
    );
} catch (Throwable) {
}
PHP

  docker compose start \
    mail-worker \
    campaign-worker \
    automation-worker \
    >/dev/null 2>&1 \
    || true

  rm -rf "$TMP_DIR"

  exit "$rc"
}

trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo '=== HeyMail contact-added automations E2E ==='

docker compose up \
  -d \
  --wait \
  database \
  api \
  gateway \
  >/dev/null

docker compose stop \
  mail-worker \
  campaign-worker \
  automation-worker \
  >/dev/null 2>&1 \
  || true

FIXTURE="$(
  docker compose exec \
    -T \
    -e TOKEN="$TOKEN" \
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
            (string) getenv(
                'DB_PASSWORD_FILE',
            ),
        ),
    ),
]);

$now = new DateTimeImmutable(
    'now',
    new DateTimeZone('UTC'),
);

$marker =
    (string) getenv('MARKER');

$hash = password_hash(
    bin2hex(
        random_bytes(24),
    ),
    PASSWORD_DEFAULT,
);

if (!is_string($hash)) {
    throw new RuntimeException(
        'Unable to hash fixture password.',
    );
}

$userId =
    (
        new ConsoleUserProvisioner(
            $connection,
        )
    )->create(
        sprintf(
            'automation-%s@example.test',
            $marker,
        ),
        'Automation',
        'Test',
        $hash,
        $now,
    );

$workspaceId =
    (int) $connection->fetchOne(
        <<<'SQL'
SELECT workspace_id
FROM workspace_member
WHERE user_id = :user_id
SQL,
        [
            'user_id'
                => $userId,
        ],
    );

$connection->insert(
    'console_session',
    [
        'token_hash'
            => hash(
                'sha256',
                (string) getenv(
                    'TOKEN',
                ),
            ),
        'user_id'
            => $userId,
        'created_at'
            => $now->format(
                'Y-m-d H:i:s',
            ),
        'last_seen_at'
            => $now->format(
                'Y-m-d H:i:s',
            ),
        'expires_at'
            => $now
                ->modify('+1 hour')
                ->format(
                    'Y-m-d H:i:s',
                ),
    ],
);

$domain =
    sprintf(
        'automation-%s.example.test',
        $marker,
    );

$senderEmail =
    'sender@'
    . $domain;

$domainId =
    (int) $connection->fetchOne(
        <<<'SQL'
INSERT INTO sending_domain (
    workspace_id,
    domain,
    status,
    verification_token,
    created_at,
    verification_checked_at,
    verified_at,
    disabled_at,
    dkim_selector,
    dkim_public_key,
    dkim_provisioned_at
)
VALUES (
    :workspace_id,
    :domain,
    'verified',
    :token,
    :created_at,
    :verified_at,
    :verified_at,
    NULL,
    'auto',
    :public_key,
    :verified_at
)
RETURNING id
SQL,
        [
            'workspace_id'
                => $workspaceId,
            'domain'
                => $domain,
            'token'
                => hash(
                    'sha256',
                    'automation-domain:'
                    . $marker,
                ),
            'created_at'
                => $now->format(
                    'Y-m-d H:i:s',
                ),
            'verified_at'
                => $now->format(
                    'Y-m-d H:i:s',
                ),
            'public_key'
                => base64_encode(
                    random_bytes(32),
                ),
        ],
    );

$senderId =
    (int) $connection->fetchOne(
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
            'domain_id'
                => $domainId,
            'email'
                => $senderEmail,
            'created_at'
                => $now->format(
                    'Y-m-d H:i:s',
                ),
        ],
    );

$templateId =
    (int) $connection->fetchOne(
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
    :created_at,
    :updated_at
)
RETURNING id
SQL,
        [
            'workspace_id'
                => $workspaceId,
            'name'
                => 'Automation Welcome '
                    . $marker,
            'created_at'
                => $now->format(
                    'Y-m-d H:i:s',
                ),
            'updated_at'
                => $now->format(
                    'Y-m-d H:i:s',
                ),
        ],
    );

$connection->insert(
    'email_template_version',
    [
        'template_id'
            => $templateId,
        'version'
            => 1,
        'subject'
            => 'Welcome {{first_name}}',
        'text_body'
            => 'Plan {{plan}}',
        'html_body'
            => '<p>Hello {{first_name}}</p>',
        'created_at'
            => $now->format(
                'Y-m-d H:i:s',
            ),
    ],
);

$immediateId =
    (int) $connection->fetchOne(
        <<<'SQL'
INSERT INTO automation (
    workspace_id,
    name,
    trigger_type,
    delay_seconds,
    sender_identity_id,
    template_id,
    status,
    created_at,
    updated_at
)
VALUES (
    :workspace_id,
    :name,
    'contact_added',
    0,
    :sender_id,
    :template_id,
    'active',
    :created_at,
    :updated_at
)
RETURNING id
SQL,
        [
            'workspace_id'
                => $workspaceId,
            'name'
                => 'Immediate '
                    . $marker,
            'sender_id'
                => $senderId,
            'template_id'
                => $templateId,
            'created_at'
                => $now->format(
                    'Y-m-d H:i:s',
                ),
            'updated_at'
                => $now->format(
                    'Y-m-d H:i:s',
                ),
        ],
    );

$delayedId =
    (int) $connection->fetchOne(
        <<<'SQL'
INSERT INTO automation (
    workspace_id,
    name,
    trigger_type,
    delay_seconds,
    sender_identity_id,
    template_id,
    status,
    created_at,
    updated_at
)
VALUES (
    :workspace_id,
    :name,
    'contact_added',
    259200,
    :sender_id,
    :template_id,
    'active',
    :created_at,
    :updated_at
)
RETURNING id
SQL,
        [
            'workspace_id'
                => $workspaceId,
            'name'
                => 'J+3 '
                    . $marker,
            'sender_id'
                => $senderId,
            'template_id'
                => $templateId,
            'created_at'
                => $now->format(
                    'Y-m-d H:i:s',
                ),
            'updated_at'
                => $now->format(
                    'Y-m-d H:i:s',
                ),
        ],
    );

echo 'USER_ID=',
    $userId,
    PHP_EOL;

echo 'WORKSPACE_ID=',
    $workspaceId,
    PHP_EOL;

echo 'IMMEDIATE_ID=',
    $immediateId,
    PHP_EOL;

echo 'DELAYED_ID=',
    $delayedId,
    PHP_EOL;
PHP
)"

value() {
  awk \
    -F= \
    -v key="$1" \
    '$1==key{print $2}' \
    <<<"$FIXTURE"
}

USER_ID="$(value USER_ID)"
WORKSPACE_ID="$(value WORKSPACE_ID)"
IMMEDIATE_ID="$(value IMMEDIATE_ID)"
DELAYED_ID="$(value DELAYED_ID)"

for id in \
  "$USER_ID" \
  "$WORKSPACE_ID" \
  "$IMMEDIATE_ID" \
  "$DELAYED_ID"
do
  [[ "$id" =~ ^[1-9][0-9]*$ ]] \
    || fail 'invalid fixture identifier'
done

CONTACT_ONE_EMAIL="ada-${MARKER}@example.test"
CONTACT_ONE_BODY="$TMP_DIR/contact-one.json"

python3 \
  - "$CONTACT_ONE_EMAIL" \
  > "$CONTACT_ONE_BODY" <<'PY'
import json
import sys

print(
    json.dumps(
        {
            "email": sys.argv[1],
            "name": "Ada Lovelace",
            "customFields": {
                "plan": "pro",
            },
            "tags": [],
            "listIds": [],
        },
        separators=(",", ":"),
    )
)
PY

CONTACT_ONE_OUT="$TMP_DIR/contact-one.out"

CONTACT_ONE_CODE="$(
  curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --output "$CONTACT_ONE_OUT" \
    --write-out '%{http_code}' \
    --request POST \
    --header 'Content-Type: application/json' \
    --header "Cookie: heymail_session=${TOKEN}" \
    --data-binary "@$CONTACT_ONE_BODY" \
    'https://api.heymail.test:8443/console/contacts'
)"

[ "$CONTACT_ONE_CODE" = '201' ] || {
  cat "$CONTACT_ONE_OUT"
  fail 'first contact creation failed'
}

FIRST_STATE="$(
  docker compose exec \
    -T \
    -e WORKSPACE_ID="$WORKSPACE_ID" \
    -e EMAIL="$CONTACT_ONE_EMAIL" \
    api \
    php -r '
$pdo=new PDO(
 sprintf(
  "pgsql:host=%s;port=%s;dbname=%s",
  getenv("DB_HOST"),
  getenv("DB_PORT"),
  getenv("DB_NAME")
 ),
 getenv("DB_USER"),
 trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$w=(int)getenv("WORKSPACE_ID");
$email=(string)getenv("EMAIL");
$rows=$pdo->query(
 "SELECT
    a.delay_seconds,
    j.status,
    EXTRACT(EPOCH FROM (j.due_at-j.created_at))::int AS delay,
    j.snapshot_ciphertext
  FROM automation_job j
  INNER JOIN automation a ON a.id=j.automation_id
  WHERE j.workspace_id=".$w."
  ORDER BY a.delay_seconds"
)->fetchAll(PDO::FETCH_ASSOC);
echo "JOBS=".count($rows).PHP_EOL;
foreach($rows as $row){
 echo "ROW=".$row["delay_seconds"].":".$row["status"].":".$row["delay"].PHP_EOL;
 if(str_contains((string)$row["snapshot_ciphertext"],$email)){
  echo "PLAINTEXT=yes".PHP_EOL;
 }
}
' </dev/null
)"

grep -Fxq 'JOBS=2' <<<"$FIRST_STATE" \
  || fail 'contact did not create two automation jobs'

grep -Fxq 'ROW=0:pending:0' <<<"$FIRST_STATE" \
  || fail 'immediate automation due time is invalid'

grep -Fxq 'ROW=259200:pending:259200' <<<"$FIRST_STATE" \
  || fail 'J+3 automation due time is invalid'

if grep -Fxq 'PLAINTEXT=yes' <<<"$FIRST_STATE"
then
  fail 'encrypted automation snapshot leaked recipient plaintext'
fi

echo 'PASS: contact addition atomically creates encrypted immediate + J+3 jobs'

docker compose run \
  --rm \
  --no-deps \
  -T \
  automation-worker \
  php bin/console app:automation:worker \
  --once \
  --no-interaction \
  </dev/null \
  >/dev/null

AFTER_FIRST_WORKER="$(
  docker compose exec \
    -T \
    -e WORKSPACE_ID="$WORKSPACE_ID" \
    api \
    php -r '
$pdo=new PDO(
 sprintf(
  "pgsql:host=%s;port=%s;dbname=%s",
  getenv("DB_HOST"),
  getenv("DB_PORT"),
  getenv("DB_NAME")
 ),
 getenv("DB_USER"),
 trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$w=(int)getenv("WORKSPACE_ID");
$jobs=$pdo->query(
 "SELECT
    a.delay_seconds,
    j.status,
    j.id,
    j.outbound_message_id
  FROM automation_job j
  INNER JOIN automation a ON a.id=j.automation_id
  WHERE j.workspace_id=".$w."
  ORDER BY a.delay_seconds"
)->fetchAll(PDO::FETCH_ASSOC);
foreach($jobs as $row){
 echo "JOB=".$row["delay_seconds"].":".$row["status"].":".$row["id"].":".($row["outbound_message_id"]??"").PHP_EOL;
}
echo "MESSAGES=".$pdo->query(
 "SELECT COUNT(*) FROM outbound_message WHERE workspace_id=".$w
)->fetchColumn().PHP_EOL;
echo "QUOTA=".$pdo->query(
 "SELECT COUNT(*) FROM automation_quota_reservation WHERE workspace_id=".$w
)->fetchColumn().PHP_EOL;
' </dev/null
)"

grep -Eq '^JOB=0:completed:[1-9][0-9]*:[1-9][0-9]*$' \
  <<<"$AFTER_FIRST_WORKER" \
  || fail 'immediate automation did not complete'

grep -Eq '^JOB=259200:pending:[1-9][0-9]*:$' \
  <<<"$AFTER_FIRST_WORKER" \
  || fail 'J+3 automation ran too early'

grep -Fxq 'MESSAGES=1' <<<"$AFTER_FIRST_WORKER" \
  || fail 'immediate automation did not create exactly one outbound message'

grep -Fxq 'QUOTA=1' <<<"$AFTER_FIRST_WORKER" \
  || fail 'immediate automation quota reservation mismatch'

echo 'PASS: worker sends only due automation jobs'

IMMEDIATE_JOB_ID="$(
  sed -nE \
    's/^JOB=0:completed:([1-9][0-9]*):[1-9][0-9]*$/\1/p' \
    <<<"$AFTER_FIRST_WORKER"
)"

[[ "$IMMEDIATE_JOB_ID" =~ ^[1-9][0-9]*$ ]] \
  || fail 'unable to resolve immediate job id'

docker compose exec \
  -T \
  -e JOB_ID="$IMMEDIATE_JOB_ID" \
  api \
  php -r '
$pdo=new PDO(
 sprintf(
  "pgsql:host=%s;port=%s;dbname=%s",
  getenv("DB_HOST"),
  getenv("DB_PORT"),
  getenv("DB_NAME")
 ),
 getenv("DB_USER"),
 trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$stmt=$pdo->prepare(
 "UPDATE automation_job
  SET status='\''dispatching'\'',
      outbound_message_id=NULL,
      completed_at=NULL,
      updated_at=CURRENT_TIMESTAMP
  WHERE id=:id"
);
$stmt->execute(["id"=>(int)getenv("JOB_ID")]);
if($stmt->rowCount()!==1){throw new RuntimeException("replay fixture");}
' </dev/null

docker compose run \
  --rm \
  --no-deps \
  -T \
  automation-worker \
  php bin/console app:automation:worker \
  --once \
  --no-interaction \
  </dev/null \
  >/dev/null

REPLAY_STATE="$(
  docker compose exec \
    -T \
    -e WORKSPACE_ID="$WORKSPACE_ID" \
    -e JOB_ID="$IMMEDIATE_JOB_ID" \
    api \
    php -r '
$pdo=new PDO(
 sprintf(
  "pgsql:host=%s;port=%s;dbname=%s",
  getenv("DB_HOST"),
  getenv("DB_PORT"),
  getenv("DB_NAME")
 ),
 getenv("DB_USER"),
 trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$w=(int)getenv("WORKSPACE_ID");
$j=(int)getenv("JOB_ID");
echo "JOB=".$pdo->query(
 "SELECT status FROM automation_job WHERE id=".$j
)->fetchColumn().PHP_EOL;
echo "MESSAGES=".$pdo->query(
 "SELECT COUNT(*) FROM outbound_message WHERE workspace_id=".$w
)->fetchColumn().PHP_EOL;
echo "QUOTA=".$pdo->query(
 "SELECT COUNT(*) FROM automation_quota_reservation WHERE workspace_id=".$w
)->fetchColumn().PHP_EOL;
' </dev/null
)"

grep -Fxq 'JOB=completed' <<<"$REPLAY_STATE" \
  || fail 'dispatching replay did not complete'

grep -Fxq 'MESSAGES=1' <<<"$REPLAY_STATE" \
  || fail 'dispatching replay duplicated outbound message'

grep -Fxq 'QUOTA=1' <<<"$REPLAY_STATE" \
  || fail 'dispatching replay duplicated quota reservation'

echo 'PASS: dispatching replay is idempotent after crash boundary'

docker compose exec \
  -T \
  -e DELAYED_ID="$DELAYED_ID" \
  api \
  php -r '
$pdo=new PDO(
 sprintf(
  "pgsql:host=%s;port=%s;dbname=%s",
  getenv("DB_HOST"),
  getenv("DB_PORT"),
  getenv("DB_NAME")
 ),
 getenv("DB_USER"),
 trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$stmt=$pdo->prepare(
 "UPDATE automation
  SET status='\''paused'\'',
      updated_at=CURRENT_TIMESTAMP
  WHERE id=:id"
);
$stmt->execute(["id"=>(int)getenv("DELAYED_ID")]);
if($stmt->rowCount()!==1){throw new RuntimeException("pause delayed");}
' </dev/null

CONTACT_TWO_EMAIL="suppressed-${MARKER}@example.test"
CONTACT_TWO_BODY="$TMP_DIR/contact-two.json"

python3 \
  - "$CONTACT_TWO_EMAIL" \
  > "$CONTACT_TWO_BODY" <<'PY'
import json
import sys

print(
    json.dumps(
        {
            "email": sys.argv[1],
            "name": "Grace Hopper",
            "customFields": {
                "plan": "team",
            },
            "tags": [],
            "listIds": [],
        },
        separators=(",", ":"),
    )
)
PY

CONTACT_TWO_OUT="$TMP_DIR/contact-two.out"

CONTACT_TWO_CODE="$(
  curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --output "$CONTACT_TWO_OUT" \
    --write-out '%{http_code}' \
    --request POST \
    --header 'Content-Type: application/json' \
    --header "Cookie: heymail_session=${TOKEN}" \
    --data-binary "@$CONTACT_TWO_BODY" \
    'https://api.heymail.test:8443/console/contacts'
)"

[ "$CONTACT_TWO_CODE" = '201' ] || {
  cat "$CONTACT_TWO_OUT"
  fail 'suppression fixture contact creation failed'
}

docker compose exec \
  -T \
  -e WORKSPACE_ID="$WORKSPACE_ID" \
  -e EMAIL="$CONTACT_TWO_EMAIL" \
  api \
  php <<'PHP' >/dev/null
<?php

declare(strict_types=1);

require '/app/vendor/autoload.php';

use App\Suppression\EmailSuppressionService;
use Doctrine\DBAL\DriverManager;

$connection = DriverManager::getConnection([
    'driver' => 'pdo_pgsql',
    'host' => getenv('DB_HOST'),
    'port' => getenv('DB_PORT'),
    'dbname' => getenv('DB_NAME'),
    'user' => getenv('DB_USER'),
    'password' => trim(
        file_get_contents(
            (string) getenv(
                'DB_PASSWORD_FILE',
            ),
        ),
    ),
]);

(
    new EmailSuppressionService(
        $connection,
    )
)->suppressGlobal(
    (int) getenv(
        'WORKSPACE_ID',
    ),
    (string) getenv(
        'EMAIL',
    ),
    'manual',
);
PHP

docker compose run \
  --rm \
  --no-deps \
  -T \
  automation-worker \
  php bin/console app:automation:worker \
  --once \
  --no-interaction \
  </dev/null \
  >/dev/null

SUPPRESSION_STATE="$(
  docker compose exec \
    -T \
    -e WORKSPACE_ID="$WORKSPACE_ID" \
    -e EMAIL="$CONTACT_TWO_EMAIL" \
    api \
    php -r '
$pdo=new PDO(
 sprintf(
  "pgsql:host=%s;port=%s;dbname=%s",
  getenv("DB_HOST"),
  getenv("DB_PORT"),
  getenv("DB_NAME")
 ),
 getenv("DB_USER"),
 trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$w=(int)getenv("WORKSPACE_ID");
$email=(string)getenv("EMAIL");
$stmt=$pdo->prepare(
 "SELECT j.status,j.skip_reason
  FROM automation_job j
  INNER JOIN contact c
    ON j.trigger_key=CAST(:prefix AS text)||c.id::text
  WHERE j.workspace_id=:w
    AND c.workspace_id=:w
    AND c.email=:email
  ORDER BY j.id DESC
  LIMIT 1"
);
$stmt->execute([
 "w"=>$w,
 "email"=>$email,
 "prefix"=>"contact-added:",
]);
$r=$stmt->fetch(PDO::FETCH_ASSOC);
echo "JOB=".$r["status"].":".$r["skip_reason"].PHP_EOL;
echo "MESSAGES=".$pdo->query(
 "SELECT COUNT(*) FROM outbound_message WHERE workspace_id=".$w
)->fetchColumn().PHP_EOL;
echo "QUOTA=".$pdo->query(
 "SELECT COUNT(*) FROM automation_quota_reservation WHERE workspace_id=".$w
)->fetchColumn().PHP_EOL;
' </dev/null
)"

grep -Fxq 'JOB=skipped:suppressed' <<<"$SUPPRESSION_STATE" \
  || fail 'suppressed automation job was not skipped'

grep -Fxq 'MESSAGES=1' <<<"$SUPPRESSION_STATE" \
  || fail 'suppressed automation created outbound mail'

grep -Fxq 'QUOTA=1' <<<"$SUPPRESSION_STATE" \
  || fail 'suppressed automation consumed quota'

echo 'PASS: suppression is rechecked before quota and dispatch'

CONTACT_THREE_EMAIL="import-${MARKER}@example.test"
CSV="$TMP_DIR/import.csv"

python3 \
  - "$CONTACT_TWO_EMAIL" \
  "$CONTACT_THREE_EMAIL" \
  > "$CSV" <<'PY'
import csv
import json
import sys

writer = csv.writer(sys.stdout)
writer.writerow(
    [
        "email",
        "name",
        "tags_json",
        "lists_json",
        "custom_fields_json",
    ]
)
writer.writerow(
    [
        sys.argv[1],
        "Grace Updated",
        "[]",
        "[]",
        json.dumps({"plan": "updated"}),
    ]
)
writer.writerow(
    [
        sys.argv[2],
        "Katherine Johnson",
        "[]",
        "[]",
        json.dumps({"plan": "pro"}),
    ]
)
PY

IMPORT_OUT="$TMP_DIR/import.out"

IMPORT_CODE="$(
  curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --output "$IMPORT_OUT" \
    --write-out '%{http_code}' \
    --request POST \
    --header 'Content-Type: text/csv' \
    --header "Cookie: heymail_session=${TOKEN}" \
    --data-binary "@$CSV" \
    'https://api.heymail.test:8443/console/contacts/import'
)"

[ "$IMPORT_CODE" = '200' ] || {
  cat "$IMPORT_OUT"
  fail 'contact import failed'
}

python3 \
  - "$IMPORT_OUT" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    data = json.load(handle)

assert data["rows"] == 2
assert data["created"] == 1
assert data["updated"] == 1
PY

IMPORT_JOBS="$(
  docker compose exec \
    -T \
    -e WORKSPACE_ID="$WORKSPACE_ID" \
    api \
    php -r '
$pdo=new PDO(
 sprintf(
  "pgsql:host=%s;port=%s;dbname=%s",
  getenv("DB_HOST"),
  getenv("DB_PORT"),
  getenv("DB_NAME")
 ),
 getenv("DB_USER"),
 trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$w=(int)getenv("WORKSPACE_ID");
echo "JOBS=".$pdo->query(
 "SELECT COUNT(*) FROM automation_job WHERE workspace_id=".$w
)->fetchColumn().PHP_EOL;
echo "PENDING_DUE=".$pdo->query(
 "SELECT COUNT(*) FROM automation_job
  WHERE workspace_id=".$w."
    AND status='\''pending'\''
    AND due_at<=CURRENT_TIMESTAMP"
)->fetchColumn().PHP_EOL;
' </dev/null
)"

grep -Fxq 'JOBS=4' <<<"$IMPORT_JOBS" \
  || fail 'import triggered existing contacts or missed new contact'

grep -Fxq 'PENDING_DUE=1' <<<"$IMPORT_JOBS" \
  || fail 'new imported contact did not create one due automation job'

echo 'PASS: CSV import triggers only newly-created contacts'

docker compose run \
  --rm \
  --no-deps \
  -T \
  automation-worker \
  php bin/console app:automation:worker \
  --once \
  --no-interaction \
  </dev/null \
  >/dev/null

FINAL="$(
  docker compose exec \
    -T \
    -e WORKSPACE_ID="$WORKSPACE_ID" \
    api \
    php -r '
$pdo=new PDO(
 sprintf(
  "pgsql:host=%s;port=%s;dbname=%s",
  getenv("DB_HOST"),
  getenv("DB_PORT"),
  getenv("DB_NAME")
 ),
 getenv("DB_USER"),
 trim(file_get_contents(getenv("DB_PASSWORD_FILE"))),
 [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]
);
$w=(int)getenv("WORKSPACE_ID");
echo "COMPLETED=".$pdo->query(
 "SELECT COUNT(*) FROM automation_job
  WHERE workspace_id=".$w."
    AND status='\''completed'\''"
)->fetchColumn().PHP_EOL;
echo "SKIPPED=".$pdo->query(
 "SELECT COUNT(*) FROM automation_job
  WHERE workspace_id=".$w."
    AND status='\''skipped'\''"
)->fetchColumn().PHP_EOL;
echo "FUTURE=".$pdo->query(
 "SELECT COUNT(*) FROM automation_job
  WHERE workspace_id=".$w."
    AND status='\''pending'\''
    AND due_at>CURRENT_TIMESTAMP"
)->fetchColumn().PHP_EOL;
echo "MESSAGES=".$pdo->query(
 "SELECT COUNT(*) FROM outbound_message WHERE workspace_id=".$w
)->fetchColumn().PHP_EOL;
echo "QUOTA=".$pdo->query(
 "SELECT COUNT(*) FROM automation_quota_reservation WHERE workspace_id=".$w
)->fetchColumn().PHP_EOL;
' </dev/null
)"

grep -Fxq 'COMPLETED=2' <<<"$FINAL" \
  || fail 'automation completion count mismatch'

grep -Fxq 'SKIPPED=1' <<<"$FINAL" \
  || fail 'automation skipped count mismatch'

grep -Fxq 'FUTURE=1' <<<"$FINAL" \
  || fail 'J+3 job no longer pending'

grep -Fxq 'MESSAGES=2' <<<"$FINAL" \
  || fail 'automation outbound message count mismatch'

grep -Fxq 'QUOTA=2' <<<"$FINAL" \
  || fail 'automation quota count mismatch'

echo 'PASS: automation engine preserves delay, suppression, quota and idempotence'
echo 'ALL CONTACT-ADDED AUTOMATION TESTS PASSED'
