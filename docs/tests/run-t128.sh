#!/usr/bin/env bash
# Builds a private Postgres database (Supabase stand-ins from supabase/verify/stubs.sql), replays migrations 001..127,
# proves the go-live file (refuses without 127, applies, refuses a second run), then runs docs/tests/t128.sql.
# Needs a local PostgreSQL 16 server and a superuser (default: sudo-less "su postgres" when run as root). Nothing leaves the machine.
# Usage: docs/tests/run-t128.sh [database-name]        (default t128; it is DROPPED and recreated)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$(dirname "$HERE")")"; DB="${1:-t128}"; SB="$ROOT/supabase"
if [ "$(id -u)" = 0 ]; then PSQL() { su postgres -c "psql -X -q -v ON_ERROR_STOP=0 $(printf '%q ' "$@")"; }; else PSQL() { psql -X -q "$@"; }; fi
cp "$ROOT/docs/go-live-128.sql" /tmp/golive128.sql; cp "$HERE/t128.sql" /tmp/t128.sql; chmod 644 /tmp/golive128.sql /tmp/t128.sql
PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB" || exit 2
PSQL -d $DB -f "$SB/verify/stubs.sql" >/dev/null 2>&1
PSQL -d $DB -c "alter database $DB set search_path = public, extensions" \
 -c "alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role" \
 -c "create schema supabase_migrations" \
 -c "create table supabase_migrations.schema_migrations(version text primary key, statements text[], name text, created_by text, idempotency_key text, rollback text[])" || exit 2
echo "== replaying migrations 001..127"; fail=0
for f in $(cd "$SB/migrations" && LC_ALL=C ls *.sql | LC_ALL=C sort); do
  num=$((10#${f%%[!0-9]*})); [ "$num" -gt 127 ] && continue
  sed -E '/^[[:space:]]*create extension if not exists (pg_net|pg_cron)/Id' "$SB/migrations/$f" > /tmp/m128.sql; chmod 644 /tmp/m128.sql
  err="$(PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f /tmp/m128.sql 2>&1 >/dev/null | grep -m1 -E 'ERROR|FATAL')"
  [ -n "$err" ] && { echo "  FAIL $f: $err"; fail=$((fail+1)); }
done
echo "   failures: $fail"
echo "== go-live without 127 recorded (must refuse)"
PSQL -d $DB -v ON_ERROR_STOP=1 -f /tmp/golive128.sql 2>&1 | grep -E "ERROR|NOTICE" | head -3
PSQL -At -d $DB -c "select 'functions installed after refusal: ' || count(*) from pg_proc where proname = 'report_popular_items'"
echo "== record 127, run go-live (must succeed)"
PSQL -d $DB -c "insert into supabase_migrations.schema_migrations(version, name) values ('20261022120000', '127_login_staff_no_lock_leak')"
PSQL -d $DB -v ON_ERROR_STOP=1 -f /tmp/golive128.sql 2>&1 | grep -E "ERROR|NOTICE"
PSQL -At -d $DB -c "select 'recorded: ' || version || ' ' || name from supabase_migrations.schema_migrations where name like '128%'" -c "select 'functions: ' || count(*) from pg_proc where proname in ('report_popular_items','report_unsold_items','report_waiter_sales','report_discounts')"
echo "== second run of go-live (must refuse, change nothing)"
PSQL -At -d $DB -c "select 'before: ' || md5(string_agg(pg_get_functiondef(oid), '' order by proname)) from pg_proc where proname like 'report\_%' and pronamespace = 'public'::regnamespace and proname in ('report_popular_items','report_unsold_items','report_waiter_sales','report_discounts')"
PSQL -d $DB -v ON_ERROR_STOP=1 -f /tmp/golive128.sql 2>&1 | grep -E "ERROR|NOTICE"
PSQL -At -d $DB -c "select 'after:  ' || md5(string_agg(pg_get_functiondef(oid), '' order by proname)) from pg_proc where proname in ('report_popular_items','report_unsold_items','report_waiter_sales','report_discounts')" -c "select 'rows recorded for 128: ' || count(*) from supabase_migrations.schema_migrations where name like '128%'"
echo "== the migration file itself is re-runnable (create or replace)"
PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f "$SB/migrations/128_report_pack_rpcs.sql" 2>&1 | grep -E "ERROR" || echo "   ran again without error"
echo "== t128.sql"
PSQL -d $DB -v ON_ERROR_STOP=1 -f /tmp/t128.sql 2>&1
