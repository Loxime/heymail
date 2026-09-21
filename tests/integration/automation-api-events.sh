#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
    && pwd
)"

cd "$ROOT_DIR"

API_ORIGIN='https://api.heymail.test:8443'
TMP_DIR="$(
  mktemp \
    -d \
    /tmp/heymail-automation-api-event.XXXXXX
)"
TOKEN_A="$(openssl rand -hex 32)"
TOKEN_B="$(openssl rand -hex 32)"
MARKER="$(openssl rand -hex 8)"

USER_A=""
USER_B=""
WORKSPACE_A=""
WORKSPACE_B=""
AUTOMATION_ID=""
API_KEY_A=""
API_SECRET_A=""
API_KEY_B=""
API_SECRET_B=""

cleanup() {
  rc=$?

  trap - EXIT
  set +e

  docker compose exec \
    -T \
    -e USER_A="${USER_A:-}" \
    -e USER_B="${USER_B:-}" \
    -e WORKSPACE_A="${WORKSPACE_A:-}" \
    -e WORKSPACE_B="${WORKSPACE_B:-}" \
    -e API_KEY_A="${API_KEY_A:-}" \
    -e API_KEY_B="${API_KEY_B:-}" \
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
    'password' => trim(
        file_get_contents(
            (string) getenv(
                'DB_PASSWORD_FILE',
            ),
        ),
    ),
]);

$workspaces = [];

foreach (
    [
        getenv('WORKSPACE_A'),
        getenv('WORKSPACE_B'),
    ]
    as $value
) {
    if (
        is_string($value)
        && preg_match(
            '/^[1-9][0-9]*$/D',
            $value,
        ) === 1
    ) {
        $workspaces[] =
            (int) $value;
    }
}

$messageIds = [];

foreach ($workspaces as $workspaceId) {
    $messageIds = [
        ...$messageIds,
        ...array_map(
            'intval',
            $c->fetchFirstColumn(
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
        ),
    ];

    $c->executeStatement(
        'DELETE FROM automation_api_event WHERE workspace_id = :workspace_id',
        [
            'workspace_id'
                => $workspaceId,
        ],
    );

    $c->executeStatement(
        'DELETE FROM automation WHERE workspace_id = :workspace_id',
        [
            'workspace_id'
                => $workspaceId,
        ],
    );
}

foreach (
    [
        getenv('API_KEY_A'),
        getenv('API_KEY_B'),
    ]
    as $apiKey
) {
    if (
        is_string($apiKey)
        && preg_match(
            '/^hm_[a-f0-9]{32}$/D',
            $apiKey,
        ) === 1
    ) {
        $c->delete(
            'automation_api_event_quota_hour',
            [
                'api_key_fingerprint'
                    => hash(
                        'sha256',
                        $apiKey,
                    ),
            ],
        );
    }
}

foreach (
    array_values(
        array_unique(
            $messageIds,
        ),
    )
    as $messageId
) {
    $c->executeStatement(
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

    $c->delete(
        'outbound_message',
        [
            'id'
                => $messageId,
        ],
    );
}

$p =
    new ConsoleUserProvisioner(
        $c,
    );

foreach (
    [
        getenv('USER_A'),
        getenv('USER_B'),
    ]
    as $userId
) {
    if (
        !is_string($userId)
        || preg_match(
            '/^[1-9][0-9]*$/D',
            $userId,
        ) !== 1
    ) {
        continue;
    }

    try {
        $p->delete(
            (int) $userId,
        );
    } catch (Throwable) {
    }
}
PHP

  docker compose start \
    automation-worker \
    mail-worker \
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

console_request() {
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

api_request() {
  local key="$1"
  local secret="$2"
  local event_name="$3"
  local idempotency="$4"
  local body="$5"
  local output="$6"

  curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --output "$output" \
    --write-out '%{http_code}' \
    --request POST \
    --user "${key}:${secret}" \
    --header 'Content-Type: application/json' \
    --header "Idempotency-Key: ${idempotency}" \
    --data-binary "@$body" \
    "$API_ORIGIN/api/v1/automation-events/$event_name"
}

echo '=== HeyMail automation API events E2E ==='

docker compose up \
  -d \
  --wait \
  database \
  api \
  gateway \
  >/dev/null

docker compose stop \
  automation-worker \
  mail-worker \
  >/dev/null 2>&1 \
  || true

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

$c = DriverManager::getConnection([
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
    (string) getenv(
        'MARKER',
    );

$passwordHash =
    password_hash(
        bin2hex(
            random_bytes(24),
        ),
        PASSWORD_DEFAULT,
    );

if (!is_string($passwordHash)) {
    throw new RuntimeException(
        'fixture password hash',
    );
}

$p =
    new ConsoleUserProvisioner(
        $c,
    );

$userA =
    $p->create(
        "automation-api-a-$marker@example.test",
        'Automation',
        'A',
        $passwordHash,
        $now,
    );

$userB =
    $p->create(
        "automation-api-b-$marker@example.test",
        'Automation',
        'B',
        $passwordHash,
        $now,
    );

$workspaceA =
    (int) $c->fetchOne(
        'SELECT workspace_id FROM workspace_member WHERE user_id=:id',
        [
            'id' => $userA,
        ],
    );

$workspaceB =
    (int) $c->fetchOne(
        'SELECT workspace_id FROM workspace_member WHERE user_id=:id',
        [
            'id' => $userB,
        ],
    );

foreach (
    [
        [
            $userA,
            getenv('TOKEN_A'),
        ],
        [
            $userB,
            getenv('TOKEN_B'),
        ],
    ]
    as [
        $user,
        $token,
    ]
) {
    $c->insert(
        'console_session',
        [
            'token_hash'
                => hash(
                    'sha256',
                    (string) $token,
                ),
            'user_id'
                => $user,
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
}

$domain =
    "automation-api-$marker.example.test";

$domainId =
    (int) $c->fetchOne(
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
    :verification_token,
    :created_at,
    :created_at,
    :created_at,
    'hm1',
    :public_key,
    :created_at
)
RETURNING id
SQL,
        [
            'workspace_id'
                => $workspaceA,
            'domain'
                => $domain,
            'verification_token'
                => hash(
                    'sha256',
                    $marker,
                ),
            'created_at'
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
    (int) $c->fetchOne(
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
                => 'hello@'
                    . $domain,
            'created_at'
                => $now->format(
                    'Y-m-d H:i:s',
                ),
        ],
    );

$templateId =
    (int) $c->fetchOne(
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
                => $workspaceA,
            'name'
                => 'API Event '
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

$c->insert(
    'email_template_version',
    [
        'template_id'
            => $templateId,
        'version'
            => 1,
        'subject'
            => 'Welcome {{first_name}}',
        'text_body'
            => 'Company {{company}}',
        'html_body'
            => '<p>Hello {{first_name}}</p>',
        'created_at'
            => $now->format(
                'Y-m-d H:i:s',
            ),
    ],
);

$apiKeyA =
    'hm_'
    . bin2hex(
        random_bytes(16),
    );

$apiSecretA =
    bin2hex(
        random_bytes(32),
    );

$apiKeyB =
    'hm_'
    . bin2hex(
        random_bytes(16),
    );

$apiSecretB =
    bin2hex(
        random_bytes(32),
    );

foreach (
    [
        [
            $workspaceA,
            $apiKeyA,
            $apiSecretA,
            'Automation event A',
        ],
        [
            $workspaceB,
            $apiKeyB,
            $apiSecretB,
            'Automation event B',
        ],
    ]
    as [
        $workspaceId,
        $apiKey,
        $apiSecret,
        $label,
    ]
) {
    $secretHash =
        password_hash(
            $apiSecret,
            PASSWORD_DEFAULT,
        );

    if (!is_string($secretHash)) {
        throw new RuntimeException(
            'credential hash',
        );
    }

    $c->insert(
        'api_credential',
        [
            'workspace_id'
                => $workspaceId,
            'api_key'
                => $apiKey,
            'key_fingerprint'
                => hash(
                    'sha256',
                    $apiKey,
                ),
            'secret_hash'
                => $secretHash,
            'label'
                => $label,
            'created_at'
                => $now->format(
                    'Y-m-d H:i:s',
                ),
        ],
    );
}

echo "USER_A=$userA\n";
echo "USER_B=$userB\n";
echo "WORKSPACE_A=$workspaceA\n";
echo "WORKSPACE_B=$workspaceB\n";
echo "SENDER_ID=$senderId\n";
echo "TEMPLATE_ID=$templateId\n";
echo "API_KEY_A=$apiKeyA\n";
echo "API_SECRET_A=$apiSecretA\n";
echo "API_KEY_B=$apiKeyB\n";
echo "API_SECRET_B=$apiSecretB\n";
PHP
)"

value() {
  awk \
    -F= \
    -v key="$1" \
    '$1==key{print substr($0,index($0,"=")+1)}' \
    <<<"$FIXTURE"
}

USER_A="$(value USER_A)"
USER_B="$(value USER_B)"
WORKSPACE_A="$(value WORKSPACE_A)"
WORKSPACE_B="$(value WORKSPACE_B)"
SENDER_ID="$(value SENDER_ID)"
TEMPLATE_ID="$(value TEMPLATE_ID)"
API_KEY_A="$(value API_KEY_A)"
API_SECRET_A="$(value API_SECRET_A)"
API_KEY_B="$(value API_KEY_B)"
API_SECRET_B="$(value API_SECRET_B)"

for id in \
  "$USER_A" \
  "$USER_B" \
  "$WORKSPACE_A" \
  "$WORKSPACE_B" \
  "$SENDER_ID" \
  "$TEMPLATE_ID"
do
  [[ "$id" =~ ^[1-9][0-9]*$ ]] \
    || fail 'invalid numeric fixture'
done

[[ "$API_KEY_A" =~ ^hm_[a-f0-9]{32}$ ]] \
  || fail 'invalid API key A'

[[ "$API_KEY_B" =~ ^hm_[a-f0-9]{32}$ ]] \
  || fail 'invalid API key B'

[[ "$API_SECRET_A" =~ ^[a-f0-9]{64}$ ]] \
  || fail 'invalid API secret A'

[[ "$API_SECRET_B" =~ ^[a-f0-9]{64}$ ]] \
  || fail 'invalid API secret B'

CREATE_BODY="$TMP_DIR/create.json"

cat >"$CREATE_BODY" <<JSON
{"name":"Signup welcome $MARKER","triggerType":"api_event","eventName":"customer.signup","delaySeconds":0,"senderId":$SENDER_ID,"templateId":$TEMPLATE_ID}
JSON

CREATE_OUT="$TMP_DIR/create.out"

CREATE_CODE="$(
  console_request \
    "$TOKEN_A" \
    POST \
    /console/automations \
    "$CREATE_BODY" \
    "$CREATE_OUT"
)"

[ "$CREATE_CODE" = '201' ] || {
  cat "$CREATE_OUT"
  fail 'automation creation failed'
}

AUTOMATION_ID="$(
  python3 \
    - "$CREATE_OUT" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    data = json.load(handle)

assert data["triggerType"] == "api_event"
assert data["eventName"] == "customer.signup"
assert data["delaySeconds"] == 0
assert data["status"] == "active"
assert data["jobCount"] == 0

print(data["id"])
PY
)"

[[ "$AUTOMATION_ID" =~ ^[1-9][0-9]*$ ]] \
  || fail 'invalid automation id'

echo 'PASS: console creates active API-event automation'

FOREIGN_OUT="$TMP_DIR/foreign.out"

[ "$(
  console_request \
    "$TOKEN_B" \
    GET \
    /console/automations \
    '' \
    "$FOREIGN_OUT"
)" = '200' ] || fail 'foreign automation list failed'

python3 \
  - "$FOREIGN_OUT" \
  "$AUTOMATION_ID" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    data = json.load(handle)

target = int(sys.argv[2])

assert all(
    item["id"] != target
    for item in data["items"]
)
PY

echo 'PASS: console automation listing is workspace isolated'

EVENT_BODY="$TMP_DIR/event.json"

python3 \
  - "$MARKER" \
  >"$EVENT_BODY" <<'PY'
import json
import sys

marker = sys.argv[1]

print(
    json.dumps(
        {
            "recipient": {
                "email": f"ada-{marker}@example.test",
                "name": "Ada Lovelace",
            },
            "variables": {
                "company": "Analytical Engines",
            },
        },
        separators=(",", ":"),
    )
)
PY

UNAUTH_OUT="$TMP_DIR/unauth.out"

UNAUTH_CODE="$(
  curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --output "$UNAUTH_OUT" \
    --write-out '%{http_code}' \
    --request POST \
    --header 'Content-Type: application/json' \
    --header "Idempotency-Key: unauth-$MARKER" \
    --data-binary "@$EVENT_BODY" \
    "$API_ORIGIN/api/v1/automation-events/customer.signup"
)"

[ "$UNAUTH_CODE" = '401' ] \
  || fail 'unauthenticated automation event was not rejected'

echo 'PASS: automation event requires Basic authentication'

EVENT_KEY="automation-event-$MARKER"
FIRST_OUT="$TMP_DIR/first.out"

FIRST_CODE="$(
  api_request \
    "$API_KEY_A" \
    "$API_SECRET_A" \
    customer.signup \
    "$EVENT_KEY" \
    "$EVENT_BODY" \
    "$FIRST_OUT"
)"

[ "$FIRST_CODE" = '202' ] || {
  cat "$FIRST_OUT"
  fail 'first automation event was not accepted'
}

EVENT_ID="$(
  python3 \
    - "$FIRST_OUT" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    data = json.load(handle)

assert data["eventName"] == "customer.signup"
assert data["matchedAutomations"] == 1
assert data["replayed"] is False

print(data["eventId"])
PY
)"

[[ "$EVENT_ID" =~ ^[1-9][0-9]*$ ]] \
  || fail 'invalid event id'

echo 'PASS: authenticated API event creates one matching automation job'

AT_REST="$(
  docker compose exec \
    -T \
    -e WORKSPACE_A="$WORKSPACE_A" \
    -e EVENT_ID="$EVENT_ID" \
    -e MARKER="$MARKER" \
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

$w=(int)getenv("WORKSPACE_A");
$event=(int)getenv("EVENT_ID");
$marker=(string)getenv("MARKER");

$eventRow=$pdo->query(
 "SELECT * FROM automation_api_event WHERE id=".$event
)->fetch(PDO::FETCH_ASSOC);

$jobs=$pdo->query(
 "SELECT id,status,trigger_key,snapshot_ciphertext
  FROM automation_job
  WHERE workspace_id=".$w."
  ORDER BY id"
)->fetchAll(PDO::FETCH_ASSOC);

echo "EVENT_ROWS=".($eventRow===false?0:1).PHP_EOL;
echo "JOBS=".count($jobs).PHP_EOL;

foreach($jobs as $job){
 echo "JOB=".$job["status"].":".$job["trigger_key"].PHP_EOL;
 $encoded=json_encode($job,JSON_THROW_ON_ERROR);
 foreach([
  "ada-".$marker,
  "Analytical Engines",
  "Welcome {{first_name}}"
 ] as $needle){
  if(str_contains($encoded,$needle)){
   echo "LEAK=".$needle.PHP_EOL;
  }
 }
}
' </dev/null
)"

grep -Fxq 'EVENT_ROWS=1' <<<"$AT_REST" \
  || fail 'automation event registry row missing'

grep -Fxq 'JOBS=1' <<<"$AT_REST" \
  || fail 'automation event did not create exactly one job'

grep -Eq "^JOB=pending:api-event:${EVENT_ID}$" <<<"$AT_REST" \
  || fail 'automation event job trigger key/status mismatch'

if grep -Fq 'LEAK=' <<<"$AT_REST"; then
  echo "$AT_REST"
  fail 'automation API event leaked plaintext snapshot data'
fi

echo 'PASS: API-event request registry stores no payload and job snapshot is encrypted'

REPLAY_OUT="$TMP_DIR/replay.out"

REPLAY_CODE="$(
  api_request \
    "$API_KEY_A" \
    "$API_SECRET_A" \
    customer.signup \
    "$EVENT_KEY" \
    "$EVENT_BODY" \
    "$REPLAY_OUT"
)"

[ "$REPLAY_CODE" = '200' ] || {
  cat "$REPLAY_OUT"
  fail 'automation event replay did not return 200'
}

python3 \
  - "$REPLAY_OUT" \
  "$EVENT_ID" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    data = json.load(handle)

assert data["eventId"] == int(sys.argv[2])
assert data["matchedAutomations"] == 1
assert data["replayed"] is True
PY

REPLAY_COUNT="$(
  docker compose exec \
    -T \
    -e WORKSPACE_A="$WORKSPACE_A" \
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
$w=(int)getenv("WORKSPACE_A");
echo $pdo->query(
 "SELECT COUNT(*) FROM automation_job WHERE workspace_id=".$w
)->fetchColumn();
' </dev/null
)"

[ "$REPLAY_COUNT" = '1' ] \
  || fail 'idempotent replay duplicated automation job'

echo 'PASS: identical idempotent replay is stable and creates no duplicate job'

CONFLICT_BODY="$TMP_DIR/conflict.json"

python3 \
  - "$MARKER" \
  >"$CONFLICT_BODY" <<'PY'
import json
import sys

marker = sys.argv[1]

print(
    json.dumps(
        {
            "recipient": {
                "email": f"grace-{marker}@example.test",
                "name": "Grace Hopper",
            },
            "variables": {
                "company": "Navy",
            },
        },
        separators=(",", ":"),
    )
)
PY

CONFLICT_OUT="$TMP_DIR/conflict.out"

CONFLICT_CODE="$(
  api_request \
    "$API_KEY_A" \
    "$API_SECRET_A" \
    customer.signup \
    "$EVENT_KEY" \
    "$CONFLICT_BODY" \
    "$CONFLICT_OUT"
)"

[ "$CONFLICT_CODE" = '409' ] \
  || {
    cat "$CONFLICT_OUT"
    fail 'conflicting automation event replay did not return 409'
  }

echo 'PASS: same idempotency key with different event payload returns 409'

FOREIGN_EVENT_OUT="$TMP_DIR/foreign-event.out"

FOREIGN_EVENT_CODE="$(
  api_request \
    "$API_KEY_B" \
    "$API_SECRET_B" \
    customer.signup \
    "foreign-$MARKER" \
    "$EVENT_BODY" \
    "$FOREIGN_EVENT_OUT"
)"

[ "$FOREIGN_EVENT_CODE" = '202' ] || {
  cat "$FOREIGN_EVENT_OUT"
  fail 'foreign workspace event request failed'
}

python3 \
  - "$FOREIGN_EVENT_OUT" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    data = json.load(handle)

assert data["matchedAutomations"] == 0
assert data["replayed"] is False
PY

echo 'PASS: API events cannot match automations from another workspace'

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

PROCESSED="$(
  docker compose exec \
    -T \
    -e WORKSPACE_A="$WORKSPACE_A" \
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
$w=(int)getenv("WORKSPACE_A");

$r=$pdo->query(
 "SELECT status,outbound_message_id
  FROM automation_job
  WHERE workspace_id=".$w."
  ORDER BY id
  LIMIT 1"
)->fetch(PDO::FETCH_ASSOC);

echo "STATUS=".$r["status"].PHP_EOL;
echo "OUTBOUND=".$r["outbound_message_id"].PHP_EOL;
echo "MESSAGES=".$pdo->query(
 "SELECT COUNT(*) FROM outbound_message WHERE workspace_id=".$w
)->fetchColumn().PHP_EOL;
' </dev/null
)"

grep -Fxq 'STATUS=completed' <<<"$PROCESSED" \
  || fail 'API-event automation job did not complete'

grep -Eq '^OUTBOUND=[1-9][0-9]*$' <<<"$PROCESSED" \
  || fail 'API-event automation job lacks outbound message'

grep -Fxq 'MESSAGES=1' <<<"$PROCESSED" \
  || fail 'API-event automation created unexpected outbound count'

echo 'PASS: API-event job reuses the #17A outbound submission engine'

PAUSE_OUT="$TMP_DIR/pause.out"

[ "$(
  console_request \
    "$TOKEN_A" \
    POST \
    "/console/automations/$AUTOMATION_ID/pause" \
    '' \
    "$PAUSE_OUT"
)" = '200' ] || {
  cat "$PAUSE_OUT"
  fail 'automation pause failed'
}

python3 \
  - "$PAUSE_OUT" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    data = json.load(handle)

assert data["status"] == "paused"
assert data["jobCount"] == 1
PY

PAUSED_EVENT_OUT="$TMP_DIR/paused-event.out"

[ "$(
  api_request \
    "$API_KEY_A" \
    "$API_SECRET_A" \
    customer.signup \
    "paused-$MARKER" \
    "$EVENT_BODY" \
    "$PAUSED_EVENT_OUT"
)" = '202' ] || {
  cat "$PAUSED_EVENT_OUT"
  fail 'paused event request failed'
}

python3 \
  - "$PAUSED_EVENT_OUT" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    data = json.load(handle)

assert data["matchedAutomations"] == 0
PY

echo 'PASS: paused automation does not consume new API events'

RESUME_OUT="$TMP_DIR/resume.out"

[ "$(
  console_request \
    "$TOKEN_A" \
    POST \
    "/console/automations/$AUTOMATION_ID/resume" \
    '' \
    "$RESUME_OUT"
)" = '200' ] || {
  cat "$RESUME_OUT"
  fail 'automation resume failed'
}

python3 \
  - "$RESUME_OUT" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    data = json.load(handle)

assert data["status"] == "active"
PY

RESUMED_EVENT_OUT="$TMP_DIR/resumed-event.out"

[ "$(
  api_request \
    "$API_KEY_A" \
    "$API_SECRET_A" \
    customer.signup \
    "resumed-$MARKER" \
    "$EVENT_BODY" \
    "$RESUMED_EVENT_OUT"
)" = '202' ] || {
  cat "$RESUMED_EVENT_OUT"
  fail 'resumed event request failed'
}

python3 \
  - "$RESUMED_EVENT_OUT" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    data = json.load(handle)

assert data["matchedAutomations"] == 1
PY

echo 'PASS: resumed automation matches future API events'

DELETE_OUT="$TMP_DIR/delete.out"

DELETE_CODE="$(
  console_request \
    "$TOKEN_A" \
    DELETE \
    "/console/automations/$AUTOMATION_ID" \
    '' \
    "$DELETE_OUT"
)"

[ "$DELETE_CODE" = '409' ] || {
  cat "$DELETE_OUT"
  fail 'automation with history was unexpectedly deletable'
}

echo 'PASS: automation history is protected from destructive deletion'

RESERVED_BODY="$TMP_DIR/reserved.json"

cat >"$RESERVED_BODY" <<JSON
{"recipient":{"email":"reserved-$MARKER@example.test","name":"Reserved"},"variables":{"email":"override@example.test"}}
JSON

RESERVED_OUT="$TMP_DIR/reserved.out"

RESERVED_CODE="$(
  api_request \
    "$API_KEY_A" \
    "$API_SECRET_A" \
    customer.signup \
    "reserved-$MARKER" \
    "$RESERVED_BODY" \
    "$RESERVED_OUT"
)"

[ "$RESERVED_CODE" = '422' ] || {
  cat "$RESERVED_OUT"
  fail 'reserved variable override was not rejected'
}

echo 'PASS: API-event recipient variables cannot override reserved fields'

echo 'ALL AUTOMATION API EVENT TESTS PASSED'
