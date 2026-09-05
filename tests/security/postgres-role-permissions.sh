#!/usr/bin/env bash

set -euo pipefail

echo "=== HeyMail PostgreSQL role permission tests ==="

docker compose up -d --wait database >/dev/null

echo "Ensuring PostgreSQL roles are provisioned..."
docker compose run --rm database-bootstrap >/dev/null

docker compose run --rm \
  --no-deps \
  --entrypoint /bin/sh \
  database-bootstrap \
  -lc '
set -eu

TABLE="migration_permission_test"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

# ---------------------------------------------------------------------------
# Authentication files
# ---------------------------------------------------------------------------

printf "%s:%s:%s:%s:%s\n" \
    "$PGHOST" \
    "$PGPORT" \
    "$POSTGRES_DB" \
    "heymail_app" \
    "$(cat /run/secrets/postgres_app_password)" \
    > /tmp/app.pgpass

printf "%s:%s:%s:%s:%s\n" \
    "$PGHOST" \
    "$PGPORT" \
    "$POSTGRES_DB" \
    "heymail_migrator" \
    "$(cat /run/secrets/postgres_migrator_password)" \
    > /tmp/migrator.pgpass

chmod 600 \
    /tmp/app.pgpass \
    /tmp/migrator.pgpass

cleanup() {
    export PGPASSFILE=/tmp/migrator.pgpass

    psql \
        -h "$PGHOST" \
        -p "$PGPORT" \
        -U heymail_migrator \
        -d "$POSTGRES_DB" \
        -v ON_ERROR_STOP=1 \
        -c "DROP TABLE IF EXISTS ${TABLE};" \
        >/dev/null 2>&1 || true
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Runtime role MUST NOT create schema objects
# ---------------------------------------------------------------------------

export PGPASSFILE=/tmp/app.pgpass

if psql \
    -h "$PGHOST" \
    -p "$PGPORT" \
    -U heymail_app \
    -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 \
    -c "CREATE TABLE forbidden_runtime_table (id INTEGER);" \
    >/tmp/app-create-result 2>&1
then
    fail "heymail_app can CREATE TABLE"
fi

if ! grep -Eqi "permission denied|not permitted" /tmp/app-create-result; then
    cat /tmp/app-create-result
    fail "CREATE TABLE failed for an unexpected reason"
fi

pass "heymail_app cannot CREATE TABLE"

# ---------------------------------------------------------------------------
# Migrator MUST be able to create schema objects
# ---------------------------------------------------------------------------

export PGPASSFILE=/tmp/migrator.pgpass

psql \
    -h "$PGHOST" \
    -p "$PGPORT" \
    -U heymail_migrator \
    -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 \
    -c "
DROP TABLE IF EXISTS ${TABLE};

CREATE TABLE ${TABLE} (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    value TEXT NOT NULL
);
" >/dev/null

pass "heymail_migrator can CREATE TABLE"

# ---------------------------------------------------------------------------
# Runtime role MUST be able to manipulate application data
# ---------------------------------------------------------------------------

export PGPASSFILE=/tmp/app.pgpass

psql \
    -h "$PGHOST" \
    -p "$PGPORT" \
    -U heymail_app \
    -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 \
    -c "
INSERT INTO ${TABLE} (value)
VALUES ('heymail-runtime-test');
" >/dev/null

VALUE="$(
    psql \
        -h "$PGHOST" \
        -p "$PGPORT" \
        -U heymail_app \
        -d "$POSTGRES_DB" \
        -At \
        -v ON_ERROR_STOP=1 \
        -c "SELECT value FROM ${TABLE} WHERE id = 1;"
)"

[ "$VALUE" = "heymail-runtime-test" ] \
    || fail "heymail_app could not read its inserted data"

pass "heymail_app can INSERT and SELECT"

# ---------------------------------------------------------------------------
# Runtime role MUST NOT alter the schema
# ---------------------------------------------------------------------------

if psql \
    -h "$PGHOST" \
    -p "$PGPORT" \
    -U heymail_app \
    -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 \
    -c "ALTER TABLE ${TABLE} ADD COLUMN forbidden TEXT;" \
    >/tmp/app-alter-result 2>&1
then
    fail "heymail_app can ALTER TABLE"
fi

if ! grep -Eqi "must be owner|permission denied|not permitted" \
    /tmp/app-alter-result
then
    cat /tmp/app-alter-result
    fail "ALTER TABLE failed for an unexpected reason"
fi

pass "heymail_app cannot ALTER TABLE"

# ---------------------------------------------------------------------------
# Schema ownership
# ---------------------------------------------------------------------------

export PGPASSFILE=/tmp/migrator.pgpass

OWNER="$(
    psql \
        -h "$PGHOST" \
        -p "$PGPORT" \
        -U heymail_migrator \
        -d "$POSTGRES_DB" \
        -At \
        -v ON_ERROR_STOP=1 \
        -c "
SELECT tableowner
FROM pg_tables
WHERE schemaname = '\''public'\''
  AND tablename = '\''${TABLE}'\'';
"
)"

[ "$OWNER" = "heymail_migrator" ] \
    || fail "unexpected table owner: $OWNER"

pass "application schema objects are owned by heymail_migrator"

cleanup
trap - EXIT

echo
echo "ALL POSTGRESQL ROLE PERMISSION TESTS PASSED"
'

