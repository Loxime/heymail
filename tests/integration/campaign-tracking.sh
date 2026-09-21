#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

TMP_DIR="$(mktemp -d /tmp/heymail-campaign-tracking.XXXXXX)"
CAMPAIGN_ID=""
DISABLED_CAMPAIGN_ID=""
OUTBOUND_ID=""
DISABLED_OUTBOUND_ID=""
DESTINATION='https://example.test/tracked?source=heymail'

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cleanup() {
  rc=$?
  trap - EXIT
  set +e

  if [[ -n "${CAMPAIGN_ID:-}" ]]; then
    docker compose exec \
      -T \
      -e CAMPAIGN_ID="$CAMPAIGN_ID" \
      -e DISABLED_CAMPAIGN_ID="$DISABLED_CAMPAIGN_ID" \
      -e OUTBOUND_ID="$OUTBOUND_ID" \
      -e DISABLED_OUTBOUND_ID="$DISABLED_OUTBOUND_ID" \
      api \
      php <<'PHP' >/dev/null 2>&1
<?php

declare(strict_types=1);

$pdo = new PDO(
    sprintf(
        'pgsql:host=%s;port=%s;dbname=%s',
        getenv('DB_HOST'),
        getenv('DB_PORT'),
        getenv('DB_NAME'),
    ),
    getenv('DB_USER'),
    trim(
        file_get_contents(
            (string) getenv('DB_PASSWORD_FILE'),
        ),
    ),
    [
        PDO::ATTR_ERRMODE
            => PDO::ERRMODE_EXCEPTION,
    ],
);

foreach (
    [
        getenv('CAMPAIGN_ID'),
        getenv('DISABLED_CAMPAIGN_ID'),
    ]
    as $id
) {
    if (
        is_string($id)
        && preg_match(
            '/^[1-9][0-9]*$/D',
            $id,
        ) === 1
    ) {
        $statement =
            $pdo->prepare(
                'DELETE FROM campaign WHERE id = :id',
            );

        $statement->execute([
            'id' => (int) $id,
        ]);
    }
}

foreach (
    [
        getenv('OUTBOUND_ID'),
        getenv('DISABLED_OUTBOUND_ID'),
    ]
    as $id
) {
    if (
        is_string($id)
        && preg_match(
            '/^[1-9][0-9]*$/D',
            $id,
        ) === 1
    ) {
        $statement =
            $pdo->prepare(
                'DELETE FROM outbound_message WHERE id = :id',
            );

        $statement->execute([
            'id' => (int) $id,
        ]);
    }
}
PHP
  fi

  rm -rf "$TMP_DIR"
  exit "$rc"
}

trap cleanup EXIT

echo '=== HeyMail optional campaign tracking E2E ==='

docker compose up \
  -d \
  --wait \
  database \
  database-bootstrap \
  api \
  gateway \
  >/dev/null

FIXTURE="$(
  docker compose exec \
    -T \
    api \
    php <<'PHP'
<?php

declare(strict_types=1);

$pdo = new PDO(
    sprintf(
        'pgsql:host=%s;port=%s;dbname=%s',
        getenv('DB_HOST'),
        getenv('DB_PORT'),
        getenv('DB_NAME'),
    ),
    getenv('DB_USER'),
    trim(
        file_get_contents(
            (string) getenv('DB_PASSWORD_FILE'),
        ),
    ),
    [
        PDO::ATTR_ERRMODE
            => PDO::ERRMODE_EXCEPTION,
    ],
);

$workspaceId =
    (int) $pdo
        ->query(
            'SELECT id FROM workspace ORDER BY id LIMIT 1',
        )
        ->fetchColumn();

if ($workspaceId < 1) {
    throw new RuntimeException(
        'No workspace fixture.',
    );
}

$now =
    (
        new DateTimeImmutable(
            'now',
            new DateTimeZone('UTC'),
        )
    )->format('Y-m-d H:i:s');

$marker =
    bin2hex(
        random_bytes(8),
    );

$createMessage =
    static function (
        PDO $pdo,
        int $workspaceId,
        string $marker,
        string $now,
    ): int {
        $statement =
            $pdo->prepare(
                <<<'SQL'
INSERT INTO outbound_message (
    workspace_id,
    idempotency_key_hash,
    status,
    created_at
)
VALUES (
    :workspace_id,
    :hash,
    'queued',
    :created_at
)
RETURNING id
SQL
            );

        $statement->execute([
            'workspace_id'
                => $workspaceId,
            'hash'
                => hash(
                    'sha256',
                    $marker,
                ),
            'created_at'
                => $now,
        ]);

        return (int) $statement
            ->fetchColumn();
    };

$createCampaign =
    static function (
        PDO $pdo,
        int $workspaceId,
        bool $tracking,
        string $marker,
        string $now,
    ): int {
        $statement =
            $pdo->prepare(
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
    :tracking_enabled,
    0,
    0,
    :created_at,
    :updated_at
)
RETURNING id
SQL
            );

        $statement->execute([
            'workspace_id'
                => $workspaceId,
            'name'
                => $marker,
            'tracking_enabled'
                => $tracking
                    ? 'true'
                    : 'false',
            'created_at'
                => $now,
            'updated_at'
                => $now,
        ]);

        return (int) $statement
            ->fetchColumn();
    };

$outboundId =
    $createMessage(
        $pdo,
        $workspaceId,
        'tracking-enabled-'
            . $marker,
        $now,
    );

$campaignId =
    $createCampaign(
        $pdo,
        $workspaceId,
        true,
        'tracking-enabled-'
            . $marker,
        $now,
    );

$disabledOutboundId =
    $createMessage(
        $pdo,
        $workspaceId,
        'tracking-disabled-'
            . $marker,
        $now,
    );

$disabledCampaignId =
    $createCampaign(
        $pdo,
        $workspaceId,
        false,
        'tracking-disabled-'
            . $marker,
        $now,
    );

$delivery =
    $pdo->prepare(
        <<<'SQL'
INSERT INTO campaign_delivery (
    campaign_id,
    recipient_index,
    outbound_message_id,
    created_at
)
VALUES (
    :campaign_id,
    0,
    :outbound_message_id,
    :created_at
)
SQL
    );

$delivery->execute([
    'campaign_id'
        => $campaignId,
    'outbound_message_id'
        => $outboundId,
    'created_at'
        => $now,
]);

$delivery->execute([
    'campaign_id'
        => $disabledCampaignId,
    'outbound_message_id'
        => $disabledOutboundId,
    'created_at'
        => $now,
]);

echo 'CAMPAIGN_ID=',
    $campaignId,
    "\n";

echo 'OUTBOUND_ID=',
    $outboundId,
    "\n";

echo 'DISABLED_CAMPAIGN_ID=',
    $disabledCampaignId,
    "\n";

echo 'DISABLED_OUTBOUND_ID=',
    $disabledOutboundId,
    "\n";
PHP
)"

value() {
  awk \
    -F= \
    -v key="$1" \
    '$1==key{print substr($0,index($0,"=")+1)}' \
    <<<"$FIXTURE"
}

CAMPAIGN_ID="$(value CAMPAIGN_ID)"
OUTBOUND_ID="$(value OUTBOUND_ID)"
DISABLED_CAMPAIGN_ID="$(value DISABLED_CAMPAIGN_ID)"
DISABLED_OUTBOUND_ID="$(value DISABLED_OUTBOUND_ID)"

for id in \
  "$CAMPAIGN_ID" \
  "$OUTBOUND_ID" \
  "$DISABLED_CAMPAIGN_ID" \
  "$DISABLED_OUTBOUND_ID"
do
  [[ "$id" =~ ^[1-9][0-9]*$ ]] \
    || fail "invalid fixture identifier"
done

TOKENS="$(
  docker compose exec \
    -T \
    -e CAMPAIGN_ID="$CAMPAIGN_ID" \
    -e DISABLED_CAMPAIGN_ID="$DISABLED_CAMPAIGN_ID" \
    -e DESTINATION="$DESTINATION" \
    api \
    php <<'PHP'
<?php

declare(strict_types=1);

require '/app/vendor/autoload.php';

use App\Tracking\TrackingTokenCodec;

$codec =
    new TrackingTokenCodec(
        trim(
            file_get_contents(
                (string) getenv(
                    'APP_SECRET_FILE',
                ),
            ),
        ),
        'https://api.heymail.test:8443',
    );

echo 'OPEN=',
    basename(
        $codec->openUrl(
            (int) getenv(
                'CAMPAIGN_ID',
            ),
            0,
        ),
    ),
    "\n";

echo 'CLICK=',
    basename(
        $codec->clickUrl(
            (int) getenv(
                'CAMPAIGN_ID',
            ),
            0,
            (string) getenv(
                'DESTINATION',
            ),
        ),
    ),
    "\n";

echo 'DISABLED=',
    basename(
        $codec->openUrl(
            (int) getenv(
                'DISABLED_CAMPAIGN_ID',
            ),
            0,
        ),
    ),
    "\n";
PHP
)"

OPEN_TOKEN="$(
  awk -F= \
    '$1=="OPEN"{print substr($0,index($0,"=")+1)}' \
    <<<"$TOKENS"
)"

CLICK_TOKEN="$(
  awk -F= \
    '$1=="CLICK"{print substr($0,index($0,"=")+1)}' \
    <<<"$TOKENS"
)"

DISABLED_TOKEN="$(
  awk -F= \
    '$1=="DISABLED"{print substr($0,index($0,"=")+1)}' \
    <<<"$TOKENS"
)"

[[ "$OPEN_TOKEN" == t1.* ]] \
  || fail 'invalid open token'

[[ "$CLICK_TOKEN" == t1.* ]] \
  || fail 'invalid click token'

OPEN_HEADERS="$TMP_DIR/open.headers"
OPEN_BODY="$TMP_DIR/open.gif"

curl \
  --noproxy '*' \
  --silent \
  --show-error \
  --cacert secrets/gateway_tls_cert.pem \
  --resolve api.heymail.test:8443:127.0.0.1 \
  --dump-header "$OPEN_HEADERS" \
  --output "$OPEN_BODY" \
  "https://api.heymail.test:8443/track/open/$OPEN_TOKEN"

grep -Eq \
  '^HTTP/[0-9.]+ 200' \
  "$OPEN_HEADERS" \
  || fail 'open pixel did not return 200'

grep -Eqi \
  '^Content-Type: image/gif' \
  "$OPEN_HEADERS" \
  || fail 'open pixel content type is not image/gif'

[[ -s "$OPEN_BODY" ]] \
  || fail 'open pixel body is empty'

echo 'PASS: authenticated open token returns GIF'

CLICK_HEADERS="$TMP_DIR/click.headers"

curl \
  --noproxy '*' \
  --silent \
  --show-error \
  --cacert secrets/gateway_tls_cert.pem \
  --resolve api.heymail.test:8443:127.0.0.1 \
  --dump-header "$CLICK_HEADERS" \
  --output /dev/null \
  "https://api.heymail.test:8443/track/click/$CLICK_TOKEN"

grep -Eq \
  '^HTTP/[0-9.]+ 302' \
  "$CLICK_HEADERS" \
  || fail 'click tracking did not return 302'

grep -Fqi \
  "Location: $DESTINATION" \
  "$CLICK_HEADERS" \
  || fail 'click redirect target mismatch'

echo 'PASS: authenticated click redirects to original HTTPS URL'

curl \
  --noproxy '*' \
  --silent \
  --show-error \
  --cacert secrets/gateway_tls_cert.pem \
  --resolve api.heymail.test:8443:127.0.0.1 \
  --output /dev/null \
  "https://api.heymail.test:8443/track/open/$OPEN_TOKEN"

curl \
  --noproxy '*' \
  --silent \
  --show-error \
  --cacert secrets/gateway_tls_cert.pem \
  --resolve api.heymail.test:8443:127.0.0.1 \
  --output /dev/null \
  "https://api.heymail.test:8443/track/click/$CLICK_TOKEN"

TAMPERED="$(
  python3 - "$OPEN_TOKEN" <<'PY'
import sys

token = sys.argv[1]
last = token[-1]
print(
    token[:-1]
    + (
        "B"
        if last == "A"
        else "A"
    )
)
PY
)"

TAMPER_STATUS="$(
  curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --output /dev/null \
    --write-out '%{http_code}' \
    "https://api.heymail.test:8443/track/open/$TAMPERED"
)"

[[ "$TAMPER_STATUS" == '404' ]] \
  || fail 'tampered token did not fail closed'

DISABLED_STATUS="$(
  curl \
    --noproxy '*' \
    --silent \
    --show-error \
    --cacert secrets/gateway_tls_cert.pem \
    --resolve api.heymail.test:8443:127.0.0.1 \
    --output /dev/null \
    --write-out '%{http_code}' \
    "https://api.heymail.test:8443/track/open/$DISABLED_TOKEN"
)"

[[ "$DISABLED_STATUS" == '404' ]] \
  || fail 'tracking-disabled campaign accepted event'

echo 'PASS: tampered/disabled tracking fail closed'

STATE="$(
  docker compose exec \
    -T \
    -e CAMPAIGN_ID="$CAMPAIGN_ID" \
    -e DISABLED_CAMPAIGN_ID="$DISABLED_CAMPAIGN_ID" \
    -e DESTINATION="$DESTINATION" \
    api \
    php <<'PHP'
<?php

declare(strict_types=1);

$pdo = new PDO(
    sprintf(
        'pgsql:host=%s;port=%s;dbname=%s',
        getenv('DB_HOST'),
        getenv('DB_PORT'),
        getenv('DB_NAME'),
    ),
    getenv('DB_USER'),
    trim(
        file_get_contents(
            (string) getenv(
                'DB_PASSWORD_FILE',
            ),
        ),
    ),
    [
        PDO::ATTR_ERRMODE
            => PDO::ERRMODE_EXCEPTION,
    ],
);

$statement =
    $pdo->prepare(
        <<<'SQL'
SELECT
    event_type,
    target_hash,
    COUNT(*) AS event_count
FROM campaign_tracking_event
WHERE campaign_id = :campaign_id
GROUP BY
    event_type,
    target_hash
ORDER BY event_type
SQL
    );

$statement->execute([
    'campaign_id'
        => (int) getenv(
            'CAMPAIGN_ID',
        ),
]);

foreach (
    $statement->fetchAll(
        PDO::FETCH_ASSOC,
    )
    as $row
) {
    echo $row['event_type'],
        '=',
        $row['event_count'],
        ':',
        $row['target_hash']
            ?? 'NULL',
        "\n";
}

$statement =
    $pdo->prepare(
        <<<'SQL'
SELECT COUNT(*)
FROM campaign_tracking_event
WHERE campaign_id = :campaign_id
SQL
    );

$statement->execute([
    'campaign_id'
        => (int) getenv(
            'DISABLED_CAMPAIGN_ID',
        ),
]);

echo 'DISABLED_EVENTS=',
    (int) $statement
        ->fetchColumn(),
    "\n";

echo 'EXPECTED_CLICK_HASH=',
    hash(
        'sha256',
        (string) getenv(
            'DESTINATION',
        ),
    ),
    "\n";
PHP
)"

printf '%s\n' "$STATE"

grep -Fqx \
  'opened=1:NULL' \
  <<<"$STATE" \
  || fail 'open event is not unique'

EXPECTED_HASH="$(
  awk -F= \
    '$1=="EXPECTED_CLICK_HASH"{print $2}' \
    <<<"$STATE"
)"

grep -Fqx \
  "clicked=1:$EXPECTED_HASH" \
  <<<"$STATE" \
  || fail 'click event/hash is not unique'

grep -Fqx \
  'DISABLED_EVENTS=0' \
  <<<"$STATE" \
  || fail 'disabled campaign persisted event'

if grep -Fq \
  "$DESTINATION" \
  <<<"$STATE"
then
  fail 'plaintext destination leaked into persistence'
fi

echo 'PASS: unique hash-only tracking persistence'
echo 'ALL OPTIONAL CAMPAIGN TRACKING E2E TESTS PASSED'
