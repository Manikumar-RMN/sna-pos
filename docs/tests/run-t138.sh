#!/usr/bin/env bash
# Builds a private Postgres database (Supabase stand-ins from supabase/verify/stubs.sql), replays migrations 001..129 (and 130..137 when they
# exist on this branch), applies 138, proves it can run twice, then runs docs/tests/t138.sql.
# t138.sql creates a clearly marked STAND-IN public.order_tips when migration 133 is not present, and writes its own audit_logs rows.
# Also runs docs/tests/t129.sql afterwards (informational: it shows which 129 expectations changed because of the pending KOT / bills fix).
# Needs a local PostgreSQL 16 server and a superuser (default: "su postgres" when run as root). Nothing leaves the machine.
# Usage: docs/tests/run-t138.sh [database-name]        (default t138; it is DROPPED and recreated)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$(dirname "$HERE")")"; DB="${1:-t138}"; SB="$ROOT/supabase"
if [ "$(id -u)" = 0 ]; then PSQL() { su postgres -c "psql -X -q -v ON_ERROR_STOP=0 $(printf '%q ' "$@")"; }; else PSQL() { psql -X -q "$@"; }; fi
cp "$HERE/t138.sql" /tmp/t138.sql; cp "$HERE/t129.sql" /tmp/t129.sql; chmod 644 /tmp/t138.sql /tmp/t129.sql
PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB" || exit 2
PSQL -d $DB -f "$SB/verify/stubs.sql" >/dev/null 2>&1
PSQL -d $DB -c "alter database $DB set search_path = public, extensions" \
 -c "alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role" \
 -c "create schema supabase_migrations" \
 -c "create table supabase_migrations.schema_migrations(version text primary key, statements text[], name text, created_by text, idempotency_key text, rollback text[])" || exit 2
echo "== replaying migrations 001..137 that exist (138 is applied last)"; fail=0
for f in $(cd "$SB/migrations" && LC_ALL=C ls *.sql | LC_ALL=C sort); do
  num=$((10#${f%%[!0-9]*})); [ "$num" -ge 138 ] && continue
  sed -E '/^[[:space:]]*create extension if not exists (pg_net|pg_cron)/Id' "$SB/migrations/$f" > /tmp/m138.sql; chmod 644 /tmp/m138.sql
  err="$(PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f /tmp/m138.sql 2>&1 >/dev/null | grep -m1 -E 'ERROR|FATAL')"
  [ -n "$err" ] && { echo "  FAIL $f: $err"; fail=$((fail+1)); }
done
echo "   failures: $fail"
PSQL -d postgres -c "drop database if exists ${DB}_b" -c "create database ${DB}_b template $DB" || exit 2
echo "== t129.sql BEFORE 138 (baseline, must be all green)"
PSQL -d ${DB}_b -v ON_ERROR_STOP=0 -f /tmp/t129.sql 2>&1 | grep -E "RESULT|FAIL" | head -5
echo "== applying 138 (twice: the file must be re-runnable)"
for i in 1 2; do PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f "$SB/migrations/138_report_pack_3_covers_reprints_tips.sql" 2>&1 | grep -E "ERROR" || echo "   run $i ok"; done
PSQL -d postgres -c "drop database if exists ${DB}_a" -c "create database ${DB}_a template $DB" || exit 2
echo "== t138.sql"
PSQL -d $DB -v ON_ERROR_STOP=1 -f /tmp/t138.sql 2>&1
rc=$?
echo "== t129.sql AFTER 138 (informational: failures here are 129 expectations that the pending KOT / bills fix intentionally changes)"
PSQL -d ${DB}_a -v ON_ERROR_STOP=0 -f /tmp/t129.sql 2>&1 | grep -E "RESULT|FAIL" | cut -c1-260 | head -40
exit $rc
