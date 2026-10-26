#!/usr/bin/env bash
# Builds a private Postgres database (Supabase stand-ins from supabase/verify/stubs.sql), replays migrations 001..139, runs t140-pre.sql
# (fixtures + "before" results), applies migration 140 directly (twice: it must be re-runnable), then runs docs/tests/t140.sql.
# The go-live file, the 139-recorded guard and the regression runs of the older tests are in run-golive-140.sh.
# Needs a local PostgreSQL 16 server and a superuser (default: "su postgres" when run as root). Nothing leaves the machine.
# Usage: docs/tests/run-t140.sh [database-name]        (default t140; it is DROPPED and recreated)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$(dirname "$HERE")")"; DB="${1:-t140}"; SB="$ROOT/supabase"
if [ "$(id -u)" = 0 ]; then PSQL() { su postgres -c "psql -X -q -v ON_ERROR_STOP=0 $(printf '%q ' "$@")"; }; else PSQL() { psql -X -q "$@"; }; fi
cp "$HERE/t140-pre.sql" /tmp/t140-pre.sql; cp "$HERE/t140.sql" /tmp/t140.sql; chmod 644 /tmp/t140-pre.sql /tmp/t140.sql
PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB" || exit 2
PSQL -d $DB -f "$SB/verify/stubs.sql" >/dev/null 2>&1
PSQL -d $DB -c "alter database $DB set search_path = public, extensions" \
 -c "alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role" \
 -c "create schema supabase_migrations" \
 -c "create table supabase_migrations.schema_migrations(version text primary key, statements text[], name text, created_by text, idempotency_key text, rollback text[])" || exit 2
echo "== replaying migrations 001..139"; fail=0
for f in $(cd "$SB/migrations" && LC_ALL=C ls *.sql | LC_ALL=C sort); do
  num=$((10#${f%%[!0-9]*})); [ "$num" -ge 140 ] && continue
  sed -E '/^[[:space:]]*create extension if not exists (pg_net|pg_cron)/Id' "$SB/migrations/$f" > /tmp/m140.sql; chmod 644 /tmp/m140.sql
  err="$(PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f /tmp/m140.sql 2>&1 >/dev/null | grep -m1 -E 'ERROR|FATAL')"
  [ -n "$err" ] && { echo "  FAIL $f: $err"; fail=$((fail+1)); }
done
echo "   failures: $fail"
echo "== t140-pre.sql (fixtures and results before 140)"
PSQL -d $DB -v ON_ERROR_STOP=1 -f /tmp/t140-pre.sql 2>&1 | grep -v NOTICE
echo "== applying 140 (twice: the file must be re-runnable)"
for i in 1 2; do PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f "$SB/migrations/140_bulk_price_range_offline_open_price_summary_extras.sql" 2>&1 | grep -E "ERROR" || echo "   run $i ok"; done
echo "== t140.sql"
PSQL -d $DB -v ON_ERROR_STOP=1 -f /tmp/t140.sql 2>&1
