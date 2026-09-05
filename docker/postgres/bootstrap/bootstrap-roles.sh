#!/bin/sh

set -eu

echo "[HeyMail] PostgreSQL role bootstrap"

umask 077

# ---------------------------------------------------------------------------
# Administrator authentication
#
# We intentionally avoid PGPASSWORD so that the administrator password is
# not exposed as a process environment variable.
# The pgpass file exists only in the container tmpfs.
# ---------------------------------------------------------------------------

printf '%s:%s:%s:%s:%s\n' \
    "$PGHOST" \
    "$PGPORT" \
    "$POSTGRES_DB" \
    "$POSTGRES_USER" \
    "$(cat /run/secrets/postgres_password)" \
    > /tmp/heymail-pgpass

export PGPASSFILE=/tmp/heymail-pgpass

# ---------------------------------------------------------------------------
# Provision roles
#
# psql reads the role passwords directly from Docker secret files.
# They are therefore not included in the command line.
# ---------------------------------------------------------------------------

psql \
    --host "$PGHOST" \
    --port "$PGPORT" \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    --set=ON_ERROR_STOP=1 <<'SQL'

\set app_password `cat /run/secrets/postgres_app_password`
\set migrator_password `cat /run/secrets/postgres_migrator_password`

-- -------------------------------------------------------------------------
-- Application runtime role
-- -------------------------------------------------------------------------

SELECT format(
    'CREATE ROLE heymail_app LOGIN PASSWORD %L',
    :'app_password'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'heymail_app'
)
\gexec

SELECT format(
    'ALTER ROLE heymail_app PASSWORD %L',
    :'app_password'
)
\gexec

ALTER ROLE heymail_app
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOINHERIT
    NOREPLICATION
    NOBYPASSRLS
    CONNECTION LIMIT 20;

-- -------------------------------------------------------------------------
-- Migration role
-- -------------------------------------------------------------------------

SELECT format(
    'CREATE ROLE heymail_migrator LOGIN PASSWORD %L',
    :'migrator_password'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'heymail_migrator'
)
\gexec

SELECT format(
    'ALTER ROLE heymail_migrator PASSWORD %L',
    :'migrator_password'
)
\gexec

ALTER ROLE heymail_migrator
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOINHERIT
    NOREPLICATION
    NOBYPASSRLS
    CONNECTION LIMIT 5;

-- -------------------------------------------------------------------------
-- Database / schema hardening
-- -------------------------------------------------------------------------

REVOKE ALL
ON DATABASE :"DBNAME"
FROM PUBLIC;

GRANT CONNECT
ON DATABASE :"DBNAME"
TO heymail_app, heymail_migrator;

REVOKE CREATE
ON SCHEMA public
FROM PUBLIC;

REVOKE ALL
ON SCHEMA public
FROM heymail_app, heymail_migrator;

GRANT USAGE
ON SCHEMA public
TO heymail_app;

GRANT USAGE, CREATE
ON SCHEMA public
TO heymail_migrator;

-- Existing objects, useful when this bootstrap is re-run.

GRANT SELECT, INSERT, UPDATE, DELETE
ON ALL TABLES
IN SCHEMA public
TO heymail_app;

GRANT USAGE, SELECT, UPDATE
ON ALL SEQUENCES
IN SCHEMA public
TO heymail_app;

-- Future Doctrine objects created by the migration role.

ALTER DEFAULT PRIVILEGES
FOR ROLE heymail_migrator
IN SCHEMA public
GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLES
TO heymail_app;

ALTER DEFAULT PRIVILEGES
FOR ROLE heymail_migrator
IN SCHEMA public
GRANT USAGE, SELECT, UPDATE
ON SEQUENCES
TO heymail_app;

SQL

rm -f /tmp/heymail-pgpass

echo "[HeyMail] PostgreSQL roles successfully provisioned"
