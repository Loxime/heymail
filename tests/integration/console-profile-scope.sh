#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." \
        && pwd
)"
cd "$ROOT_DIR"

USER_ID=""
BODY=""
TOKEN="$(
    openssl rand -hex 32
)"
MARKER="$(
    openssl rand -hex 8
)"
EMAIL="profile-scope-${MARKER}@example.test"

cleanup() {
    RESULT=$?
    trap - EXIT
    set +e

    if [[ "${USER_ID:-}" =~ ^[1-9][0-9]*$ ]]; then
        docker compose exec \
            -T \
            -e USER_ID="$USER_ID" \
            api \
            php <<'PHP' >/dev/null 2>&1
<?php

declare(strict_types=1);

$id = getenv('USER_ID');

if (
    !is_string($id)
    || preg_match('/^[1-9][0-9]*$/D', $id) !== 1
) {
    exit(0);
}

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
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ],
);

$stmt = $pdo->prepare(
    'DELETE FROM console_user WHERE id = :id',
);

$stmt->execute([
    'id' => $id,
]);
PHP
    fi

    if [ -n "${BODY:-}" ]; then
        rm -f "$BODY"
    fi

    exit "$RESULT"
}

trap cleanup EXIT

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
        -e TEST_EMAIL="$EMAIL" \
        -e TEST_TOKEN="$TOKEN" \
        api \
        php <<'PHP'
<?php

declare(strict_types=1);

$email = getenv('TEST_EMAIL');
$token = getenv('TEST_TOKEN');

if (
    !is_string($email)
    || !is_string($token)
    || preg_match('/^[a-f0-9]{64}$/D', $token) !== 1
) {
    exit(2);
}

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
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ],
);

$now = new DateTimeImmutable(
    'now',
    new DateTimeZone('UTC'),
);

$stmt = $pdo->prepare(
    <<<'SQL'
INSERT INTO console_user (
    email,
    first_name,
    last_name,
    password_hash,
    created_at,
    updated_at
)
VALUES (
    :email,
    'Scope',
    'Gate',
    :password_hash,
    :created_at,
    :updated_at
)
RETURNING id
SQL
);

$stmt->execute([
    'email' => $email,
    'password_hash' => password_hash(
        bin2hex(random_bytes(24)),
        PASSWORD_DEFAULT,
    ),
    'created_at' => $now->format('Y-m-d H:i:s'),
    'updated_at' => $now->format('Y-m-d H:i:s'),
]);

$id = $stmt->fetchColumn();

if (
    !is_int($id)
    && !is_string($id)
) {
    exit(3);
}

$session = $pdo->prepare(
    <<<'SQL'
INSERT INTO console_session (
    token_hash,
    user_id,
    created_at,
    last_seen_at,
    expires_at
)
VALUES (
    :token_hash,
    :user_id,
    :created_at,
    :last_seen_at,
    :expires_at
)
SQL
);

$session->execute([
    'token_hash' => hash(
        'sha256',
        $token,
    ),
    'user_id' => $id,
    'created_at' => $now->format('Y-m-d H:i:s'),
    'last_seen_at' => $now->format('Y-m-d H:i:s'),
    'expires_at' => $now
        ->modify('+1 hour')
        ->format('Y-m-d H:i:s'),
]);

echo $id;
PHP
)"

[[ "$USER_ID" =~ ^[1-9][0-9]*$ ]] \
    || {
        echo "FAIL: test console user creation failed" >&2
        exit 1
    }

BODY="$(
    mktemp \
        /tmp/heymail-profile-scope.XXXXXX
)"

STATUS="$(
    curl \
        --noproxy '*' \
        --silent \
        --show-error \
        --cacert secrets/gateway_tls_cert.pem \
        --resolve api.heymail.test:8443:127.0.0.1 \
        --output "$BODY" \
        --write-out '%{http_code}' \
        --header "Cookie: heymail_session=${TOKEN}" \
        https://api.heymail.test:8443/console/profile
)"

[ "$STATUS" = "200" ] \
    || {
        cat "$BODY" >&2
        echo "FAIL: profile returned HTTP $STATUS" >&2
        exit 1
    }

python3 \
    - "$BODY" "$EMAIL" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8",
) as handle:
    data = json.load(handle)

print(
    "stats="
    + json.dumps(
        data["stats"],
        sort_keys=True,
        separators=(",", ":"),
    )
)

assert data["user"]["email"] == sys.argv[2]
assert isinstance(
    data["stats"]["messagesSent"],
    int,
)
assert (
    data["stats"]["messagesSentScope"]
    == "instance"
)

print(
    "messagesSent="
    f'{data["stats"]["messagesSent"]}'
)
print(
    "messagesSentScope="
    f'{data["stats"]["messagesSentScope"]}'
)
PY

echo "PASS: PROFILE STATS ARE EXPLICITLY INSTANCE-SCOPED"
