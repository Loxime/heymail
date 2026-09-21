#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

API_ORIGIN="https://api.heymail.test:8443"
TMP_DIR="$(mktemp -d /tmp/heymail-visual-template.XXXXXX)"
TOKEN="$(openssl rand -hex 32)"
MARKER="$(openssl rand -hex 8)"
USER_ID=""

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
    -e USER_ID="${USER_ID:-}" \
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
            (string) getenv(
                'DB_PASSWORD_FILE',
            ),
        ),
    ),
]);

$id = getenv('USER_ID');

if (
    is_string($id)
    && preg_match(
        '/^[1-9][0-9]*$/D',
        $id,
    ) === 1
) {
    (
        new ConsoleUserProvisioner(
            $connection,
        )
    )->delete(
        (int) $id,
    );
}

PHP

  rm -rf "$TMP_DIR"
  exit "$rc"
}

trap cleanup EXIT

request() {
  local method="$1"
  local path="$2"
  local body="$3"
  local output="$4"

  local args=(
    --noproxy '*'
    --silent
    --show-error
    --cacert secrets/gateway_tls_cert.pem
    --resolve api.heymail.test:8443:127.0.0.1
    --output "$output"
    --write-out '%{http_code}'
    --request "$method"
    --header "Cookie: heymail_session=${TOKEN}"
  )

  if [[ -n "$body" ]]; then
    args+=(
      --header 'Content-Type: application/json'
      --data-binary "@$body"
    )
  fi

  curl \
    "${args[@]}" \
    "$API_ORIGIN$path"
}

echo '=== HeyMail visual email templates E2E ==='

docker compose up \
  -d \
  --wait \
  database \
  api \
  gateway \
  >/dev/null

USER_ID="$(
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

$connection =
    DriverManager::getConnection([
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

$now =
    new DateTimeImmutable(
        'now',
        new DateTimeZone('UTC'),
    );

$hash =
    password_hash(
        bin2hex(
            random_bytes(24),
        ),
        PASSWORD_DEFAULT,
    );

$provisioner =
    new ConsoleUserProvisioner(
        $connection,
    );

$userId =
    $provisioner->create(
        'visual-template-'
            . getenv('MARKER')
            . '@example.test',
        'Visual',
        'Template',
        $hash,
        $now,
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

echo $userId;
PHP
)"

[[ "$USER_ID" =~ ^[1-9][0-9]*$ ]] \
  || fail 'invalid console user fixture'

cat >"$TMP_DIR/create.json" <<'JSON'
{
  "name": "Visual welcome",
  "subject": "Welcome {{first_name}}",
  "text": "Fallback for {{first_name}}",
  "html": null,
  "visual": {
    "version": 1,
    "blocks": [
      {
        "id": "intro",
        "type": "text",
        "text": "<script>alert(1)</script>\nHello {{first_name}}",
        "align": "left"
      },
      {
        "id": "hero",
        "type": "image",
        "url": "https://example.test/welcome.png",
        "alt": "Welcome",
        "align": "center"
      },
      {
        "id": "cta",
        "type": "button",
        "label": "Open {{first_name}}",
        "url": "https://example.test/welcome",
        "align": "center"
      },
      {
        "id": "cols",
        "type": "columns",
        "columns": [
          {
            "text": "Left {{company}}",
            "align": "left"
          },
          {
            "text": "Right",
            "align": "right"
          }
        ]
      }
    ]
  }
}
JSON

CREATE="$TMP_DIR/create.out"

[[ "$(
  request \
    POST \
    /console/templates \
    "$TMP_DIR/create.json" \
    "$CREATE"
)" == '201' ]] \
  || {
    cat "$CREATE"
    fail 'visual template creation failed'
  }

TEMPLATE_ID="$(
  python3 - "$CREATE" <<'PY'
import json
import sys

data = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

assert data["version"] == 1
assert data["visual"]["version"] == 1
assert len(data["visual"]["blocks"]) == 4
assert data["variables"] == [
    "company",
    "first_name",
]
assert "[[HMHTML:first_name]]" in data["html"]
assert "<script>alert(1)</script>" not in data["html"]
assert "&lt;script&gt;alert(1)&lt;/script&gt;" in data["html"]

print(data["id"])
PY
)"

[[ "$TEMPLATE_ID" =~ ^[1-9][0-9]*$ ]] \
  || fail 'invalid visual template id'

echo 'PASS: visual document persists and HTML is generated/escaped'

cat >"$TMP_DIR/render.json" <<'JSON'
{
  "variables": {
    "first_name": "<b>Ada</b>",
    "company": "<i>Analytical</i>"
  }
}
JSON

RENDER="$TMP_DIR/render.out"

[[ "$(
  request \
    POST \
    "/console/templates/$TEMPLATE_ID/render" \
    "$TMP_DIR/render.json" \
    "$RENDER"
)" == '200' ]] \
  || {
    cat "$RENDER"
    fail 'visual template render failed'
  }

python3 - "$RENDER" <<'PY'
import json
import sys

data = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

html = data["html"]

assert "&lt;b&gt;Ada&lt;/b&gt;" in html
assert "&lt;i&gt;Analytical&lt;/i&gt;" in html
assert "<b>Ada</b>" not in html
assert "<i>Analytical</i>" not in html
PY

echo 'PASS: visual variables render HTML-escaped'

cat >"$TMP_DIR/insecure.json" <<'JSON'
{
  "name": "Bad visual",
  "subject": "Bad",
  "text": null,
  "html": null,
  "visual": {
    "version": 1,
    "blocks": [
      {
        "id": "bad",
        "type": "image",
        "url": "http://example.test/image.png",
        "alt": "Bad",
        "align": "left"
      }
    ]
  }
}
JSON

INVALID="$TMP_DIR/insecure.out"

[[ "$(
  request \
    POST \
    /console/templates \
    "$TMP_DIR/insecure.json" \
    "$INVALID"
)" == '422' ]] \
  || {
    cat "$INVALID"
    fail 'insecure visual URL did not fail closed'
  }

echo 'PASS: visual URLs require HTTPS'

DUPLICATE="$TMP_DIR/duplicate.out"

[[ "$(
  request \
    POST \
    "/console/templates/$TEMPLATE_ID/duplicate" \
    '' \
    "$DUPLICATE"
)" == '201' ]] \
  || {
    cat "$DUPLICATE"
    fail 'visual template duplication failed'
  }

python3 - "$CREATE" "$DUPLICATE" <<'PY'
import json
import sys

source = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

duplicate = json.load(
    open(
        sys.argv[2],
        encoding="utf-8",
    )
)

assert duplicate["id"] != source["id"]
assert duplicate["version"] == 1
assert duplicate["visual"] == source["visual"]
assert duplicate["html"] == source["html"]
PY

echo 'PASS: duplication preserves latest visual document'
echo 'ALL VISUAL EMAIL TEMPLATE TESTS PASSED'
