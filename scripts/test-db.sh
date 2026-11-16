#!/usr/bin/env bash
# Runs all migrations + DB tests against a throwaway local database.
# Never touches any non-local database. Requires a local PostgreSQL 15+.
set -euo pipefail
cd "$(dirname "$0")/.."

DB="po_erp_test"
PSQL="psql -X -v ON_ERROR_STOP=1 -q -U postgres -h 127.0.0.1 -d $DB"
ADMIN="psql -X -v ON_ERROR_STOP=1 -q -U postgres -h 127.0.0.1 -d postgres"

$ADMIN -c "drop database if exists $DB" -c "create database $DB"
# Roles are cluster-wide; create idempotently so reruns work.
$ADMIN <<'SQL'
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    -- drop leftovers from a previous run (owned objects live in dropped DB)
    drop role if exists anon; drop role if exists authenticated; drop role if exists service_role;
  end if;
end $$;
SQL

$PSQL -f supabase/tests/00_supabase_shim.sql
for f in supabase/migrations/*.sql; do echo "migrate: $f"; $PSQL -f "$f"; done
for f in supabase/tests/[0-9][0-9]_*.test.sql; do echo "test: $f"; $PSQL -f "$f" 2>&1; done
