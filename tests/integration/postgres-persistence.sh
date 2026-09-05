#!/usr/bin/env bash

set -euo pipefail

readonly TABLE="bootstrap_persistence_test"

echo "=== HeyMail PostgreSQL persistence test ==="

cleanup() {
    docker compose up -d --wait database >/dev/null 2>&1 || true

    docker compose exec -T database sh -lc "
        export PGPASSWORD=\"\$(cat /run/secrets/postgres_password)\"

        psql \
            -h 127.0.0.1 \
            -U \"\$POSTGRES_USER\" \
            -d \"\$POSTGRES_DB\" \
            -v ON_ERROR_STOP=1 \
            -c 'DROP TABLE IF EXISTS ${TABLE};'
    " >/dev/null 2>&1 || true
}

trap cleanup EXIT

docker compose up -d --wait database

echo "Creating persistence fixture..."

docker compose exec -T database sh -lc "
    export PGPASSWORD=\"\$(cat /run/secrets/postgres_password)\"

    psql \
        -h 127.0.0.1 \
        -U \"\$POSTGRES_USER\" \
        -d \"\$POSTGRES_DB\" \
        -v ON_ERROR_STOP=1 \
        -c '
            DROP TABLE IF EXISTS ${TABLE};

            CREATE TABLE ${TABLE} (
                id INTEGER PRIMARY KEY
            );

            INSERT INTO ${TABLE} (id)
            VALUES (42);
        '
"

echo "Destroying database container..."

docker compose rm -sf database

docker volume inspect heymail_postgres_data >/dev/null \
    || {
        echo "FAIL: PostgreSQL persistent volume disappeared"
        exit 1
    }

echo "PASS: persistent volume survived container deletion"

echo "Recreating database container..."

docker compose up -d --wait database

RESULT="$(
    docker compose exec -T database sh -lc "
        export PGPASSWORD=\"\$(cat /run/secrets/postgres_password)\"

        psql \
            -h 127.0.0.1 \
            -U \"\$POSTGRES_USER\" \
            -d \"\$POSTGRES_DB\" \
            -At \
            -v ON_ERROR_STOP=1 \
            -c 'SELECT id FROM ${TABLE};'
    "
)"

[[ "$RESULT" == "42" ]] \
    || {
        echo "FAIL: expected persisted value 42, got '$RESULT'"
        exit 1
    }

echo "PASS: persisted value 42 recovered after container recreation"

docker compose exec -T database sh -lc "
    export PGPASSWORD=\"\$(cat /run/secrets/postgres_password)\"

    psql \
        -h 127.0.0.1 \
        -U \"\$POSTGRES_USER\" \
        -d \"\$POSTGRES_DB\" \
        -v ON_ERROR_STOP=1 \
        -c 'DROP TABLE ${TABLE};'
"

trap - EXIT

echo
echo "ALL POSTGRESQL PERSISTENCE TESTS PASSED"
