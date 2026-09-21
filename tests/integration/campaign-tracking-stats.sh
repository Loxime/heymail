#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

API_ORIGIN='https://api.heymail.test:8443'
TMP_DIR="$(mktemp -d /tmp/heymail-campaign-tracking-stats.XXXXXX)"
TOKEN_A="$(openssl rand -hex 32)"
TOKEN_B="$(openssl rand -hex 32)"
MARKER="$(openssl rand -hex 8)"
USER_A=''
USER_B=''

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

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

$provisioner = new ConsoleUserProvisioner($connection);

foreach ([getenv('USER_A'), getenv('USER_B')] as $id) {
    if (!is_string($id) || preg_match('/^[1-9][0-9]*$/D', $id) !== 1) {
        continue;
    }

    try {
        $workspaceIds = $connection->fetchFirstColumn(
            'SELECT workspace_id FROM workspace_member WHERE user_id = :user_id',
            ['user_id' => (int) $id],
        );

        foreach ($workspaceIds as $workspaceId) {
            $connection->executeStatement(
                'DELETE FROM campaign WHERE workspace_id = :workspace_id',
                ['workspace_id' => (int) $workspaceId],
            );
            $connection->executeStatement(
                'DELETE FROM outbound_message WHERE workspace_id = :workspace_id',
                ['workspace_id' => (int) $workspaceId],
            );
        }

        $provisioner->delete((int) $id);
    } catch (Throwable) {
    }
}
PHP

  rm -rf "$TMP_DIR"
  exit "$rc"
}

trap cleanup EXIT

request() {
  local token="$1"
  local path="$2"
  local output="$3"

  curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --output "$output" \
    --write-out '%{http_code}' \
    --header "Cookie: heymail_session=${token}" \
    "$API_ORIGIN$path"
}

echo '=== HeyMail campaign tracking stats E2E ==='

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

$now = new DateTimeImmutable('now', new DateTimeZone('UTC'));
$hash = password_hash(bin2hex(random_bytes(24)), PASSWORD_DEFAULT);

if (!is_string($hash)) {
    throw new RuntimeException('Unable to create password hash.');
}

$marker = (string) getenv('MARKER');
$provisioner = new ConsoleUserProvisioner($connection);

$userA = $provisioner->create(
    "tracking-stats-a-$marker@example.test",
    'Tracking',
    'A',
    $hash,
    $now,
);
$userB = $provisioner->create(
    "tracking-stats-b-$marker@example.test",
    'Tracking',
    'B',
    $hash,
    $now,
);

$workspaceA = (int) $connection->fetchOne(
    'SELECT workspace_id FROM workspace_member WHERE user_id = :id',
    ['id' => $userA],
);
$workspaceB = (int) $connection->fetchOne(
    'SELECT workspace_id FROM workspace_member WHERE user_id = :id',
    ['id' => $userB],
);

foreach (
    [
        [$userA, getenv('TOKEN_A')],
        [$userB, getenv('TOKEN_B')],
    ] as [$userId, $token]
) {
    $connection->insert('console_session', [
        'token_hash' => hash('sha256', (string) $token),
        'user_id' => $userId,
        'created_at' => $now->format('Y-m-d H:i:s'),
        'last_seen_at' => $now->format('Y-m-d H:i:s'),
        'expires_at' => $now->modify('+1 hour')->format('Y-m-d H:i:s'),
    ]);
}

$createCampaign = static function (
    int $workspaceId,
    string $name,
) use ($connection, $now): int {
    return (int) $connection->fetchOne(
        <<<'SQL'
INSERT INTO campaign (
    workspace_id,
    name,
    status,
    tracking_enabled,
    recipient_count,
    processed_count,
    created_at,
    updated_at
)
VALUES (
    :workspace_id,
    :name,
    'draft',
    TRUE,
    0,
    0,
    :created_at,
    :updated_at
)
RETURNING id
SQL,
        [
            'workspace_id' => $workspaceId,
            'name' => $name,
            'created_at' => $now->format('Y-m-d H:i:s'),
            'updated_at' => $now->format('Y-m-d H:i:s'),
        ],
    );
};

$campaignA = $createCampaign($workspaceA, "Stats A $marker");
$campaignB = $createCampaign($workspaceB, "Stats B $marker");

$createMessage = static function (
    int $workspaceId,
    string $key,
) use ($connection, $now): int {
    return (int) $connection->fetchOne(
        <<<'SQL'
INSERT INTO outbound_message (
    workspace_id,
    idempotency_key_hash,
    status,
    created_at
)
VALUES (
    :workspace_id,
    :idempotency_key_hash,
    'queued',
    :created_at
)
RETURNING id
SQL,
        [
            'workspace_id' => $workspaceId,
            'idempotency_key_hash' => hash('sha256', $key),
            'created_at' => $now->format('Y-m-d H:i:s'),
        ],
    );
};

for ($index = 0; $index < 4; ++$index) {
    $messageId = $createMessage(
        $workspaceA,
        "tracking-stats-a-$marker-$index",
    );

    $connection->insert('campaign_delivery', [
        'campaign_id' => $campaignA,
        'recipient_index' => $index,
        'outbound_message_id' => $messageId,
        'created_at' => $now->format('Y-m-d H:i:s'),
    ]);
}

$messageB = $createMessage(
    $workspaceB,
    "tracking-stats-b-$marker",
);
$connection->insert('campaign_delivery', [
    'campaign_id' => $campaignB,
    'recipient_index' => 0,
    'outbound_message_id' => $messageB,
    'created_at' => $now->format('Y-m-d H:i:s'),
]);

$events = [
    [0, 'opened', null],
    [1, 'opened', null],
    [0, 'clicked', hash('sha256', 'https://example.test/a')],
    [0, 'clicked', hash('sha256', 'https://example.test/b')],
    [2, 'clicked', hash('sha256', 'https://example.test/a')],
];

foreach ($events as [$recipientIndex, $eventType, $targetHash]) {
    $connection->insert('campaign_tracking_event', [
        'campaign_id' => $campaignA,
        'recipient_index' => $recipientIndex,
        'event_type' => $eventType,
        'target_hash' => $targetHash,
        'occurred_at' => $now->format('Y-m-d H:i:s'),
    ]);
}

echo "USER_A=$userA\n";
echo "USER_B=$userB\n";
echo "CAMPAIGN_A=$campaignA\n";
echo "CAMPAIGN_B=$campaignB\n";
PHP
)"

value() {
  awk -F= -v key="$1" '$1==key{print $2}' <<<"$FIXTURE"
}

USER_A="$(value USER_A)"
USER_B="$(value USER_B)"
CAMPAIGN_A="$(value CAMPAIGN_A)"
CAMPAIGN_B="$(value CAMPAIGN_B)"

for value in \
  "$USER_A" \
  "$USER_B" \
  "$CAMPAIGN_A" \
  "$CAMPAIGN_B"
do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] \
    || fail 'invalid fixture'
done

UNAUTH="$TMP_DIR/unauth.json"
[[ "$(request '' "/console/campaigns/$CAMPAIGN_A/tracking-stats" "$UNAUTH")" == '401' ]] \
  || fail 'tracking stats endpoint accepted unauthenticated request'
echo 'PASS: tracking stats require console authentication'

FOREIGN="$TMP_DIR/foreign.json"
[[ "$(request "$TOKEN_B" "/console/campaigns/$CAMPAIGN_A/tracking-stats" "$FOREIGN")" == '404' ]] \
  || {
    cat "$FOREIGN"
    fail 'foreign workspace campaign stats leaked'
  }
echo 'PASS: tracking stats are workspace isolated'

OWN="$TMP_DIR/own.json"
[[ "$(request "$TOKEN_A" "/console/campaigns/$CAMPAIGN_A/tracking-stats" "$OWN")" == '200' ]] \
  || {
    cat "$OWN"
    fail 'owned tracking stats failed'
  }

python3 - "$OWN" "$CAMPAIGN_A" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

expected = {
    "campaignId": int(sys.argv[2]),
    "trackingEnabled": True,
    "trackedRecipients": 4,
    "openedRecipients": 2,
    "clickedRecipients": 2,
    "uniqueClicks": 3,
    "openRate": 0.5,
    "clickRate": 0.5,
}
assert data == expected, data
PY

echo 'PASS: unique open/click aggregates and rates are deterministic'

if grep -Eq '[a-f0-9]{64}|example\.test' "$OWN"; then
  cat "$OWN"
  fail 'target hash or destination leaked from stats API'
fi

echo 'PASS: stats API is aggregate-only with no target leakage'
echo 'ALL CAMPAIGN TRACKING STATS E2E TESTS PASSED'
