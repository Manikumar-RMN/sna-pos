#!/usr/bin/env bash
# Builds a private Postgres database (Supabase stand-ins from supabase/verify/stubs.sql), replays migrations 001..148, applies migration 149
# directly (TWICE: it must be re-runnable), then runs docs/tests/t149.sql (floor_status billed_bills / billed_at, the blue "bill printed" colour).
# The go-live file, the 148-recorded guard and the regression runs of the older tests are in run-golive-149.sh.
# Needs a local PostgreSQL 16 server and a superuser (default: "su postgres" when run as root). Nothing leaves the machine.
# Usage: docs/tests/run-t149.sh [database-name]        (default t149; it is DROPPED and recreated)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$(dirname "$HERE")")"; DB="${1:-t149}"; SB="$ROOT/supabase"
W="/tmp/w-$DB"; mkdir -p "$W"; chmod 755 "$W"
if [ "$(id -u)" = 0 ]; then PSQL() { su postgres -c "psql -X -q -v ON_ERROR_STOP=0 $(printf '%q ' "$@")"; }; else PSQL() { psql -X -q "$@"; }; fi
cp "$HERE/t149.sql" "$W/t.sql"; chmod 644 "$W"/*.sql
PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB" || exit 2
PSQL -d $DB -f "$SB/verify/stubs.sql" >/dev/null 2>&1
PSQL -d $DB -c "alter database $DB set search_path = public, extensions" \
 -c "alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role" \
 -c "create schema supabase_migrations" \
 -c "create table supabase_migrations.schema_migrations(version text primary key, statements text[], name text, created_by text, idempotency_key text, rollback text[])" || exit 2
echo "== replaying migrations 001..148"; fail=0
for f in $(cd "$SB/migrations" && LC_ALL=C ls *.sql | LC_ALL=C sort); do
  num=$((10#${f%%[!0-9]*})); [ "$num" -ge 149 ] && continue
  sed -E '/^[[:space:]]*create extension if not exists (pg_net|pg_cron)/Id' "$SB/migrations/$f" > "$W/m.sql"; chmod 644 "$W/m.sql"
  err="$(PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f "$W/m.sql" 2>&1 >/dev/null | grep -m1 -E 'ERROR|FATAL')"
  [ -n "$err" ] && { echo "  FAIL $f: $err"; fail=$((fail+1)); }
done
echo "   failures: $fail"
echo "== applying 149 (twice: the file must be re-runnable)"
for i in 1 2; do PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f "$SB/migrations/149_floor_status_billed.sql" 2>&1 | grep -E "ERROR" || echo "   run $i ok"; done
echo "== t149.sql"
OUT="$W/out.txt"
PSQL -d $DB -v ON_ERROR_STOP=0 -f "$W/t.sql" > "$OUT" 2>&1
cat "$OUT"
# a statement that fails outside t.err() leaves no result row, so a clean run has NO psql error line at all
NERR=$(grep -c '^psql:.*ERROR' "$OUT")
echo "SQL errors outside t.err (must be 0): $NERR"
if grep -q '^RESULT: .* 0 failed' "$OUT" && [ "$NERR" = 0 ]; then echo "t149 OK"; else echo "t149 NOT OK"; exit 1; fi
