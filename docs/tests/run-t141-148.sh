#!/usr/bin/env bash
# Builds a private Postgres database (Supabase stand-ins from supabase/verify/stubs.sql), replays migrations 001..140, runs t141-148-pre.sql
# (fixtures + "before" results), applies every supabase/migrations/14[1-8]_*.sql that exists, in order (every file is applied TWICE: they must be re-runnable), then runs docs/tests/t141-148.sql.
# Needs a local PostgreSQL 16 server and a superuser (default: "su postgres" when run as root). Nothing leaves the machine.
# Usage: docs/tests/run-t141-148.sh [database-name]        (default t141148; it is DROPPED and recreated)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$(dirname "$HERE")")"; DB="${1:-t141148}"; SB="$ROOT/supabase"
W="/tmp/w-$DB"; mkdir -p "$W"; chmod 755 "$W"
if [ "$(id -u)" = 0 ]; then PSQL() { su postgres -c "psql -X -q -v ON_ERROR_STOP=0 $(printf '%q ' "$@")"; }; else PSQL() { psql -X -q "$@"; }; fi
cp "$HERE/t141-148-pre.sql" "$W/pre.sql"; cp "$HERE/t141-148.sql" "$W/t.sql"; chmod 644 "$W"/*.sql
PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB" || exit 2
PSQL -d $DB -f "$SB/verify/stubs.sql" >/dev/null 2>&1
PSQL -d $DB -c "alter database $DB set search_path = public, extensions" \
 -c "alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role" \
 -c "create schema supabase_migrations" \
 -c "create table supabase_migrations.schema_migrations(version text primary key, statements text[], name text, created_by text, idempotency_key text, rollback text[])" || exit 2
echo "== replaying migrations 001..140"; fail=0
for f in $(cd "$SB/migrations" && LC_ALL=C ls *.sql | LC_ALL=C sort); do
  num=$((10#${f%%[!0-9]*})); [ "$num" -ge 141 ] && continue
  sed -E '/^[[:space:]]*create extension if not exists (pg_net|pg_cron)/Id' "$SB/migrations/$f" > "$W/m.sql"; chmod 644 "$W/m.sql"
  err="$(PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f "$W/m.sql" 2>&1 >/dev/null | grep -m1 -E 'ERROR|FATAL')"
  [ -n "$err" ] && { echo "  FAIL $f: $err"; fail=$((fail+1)); }
done
echo "   failures: $fail"
echo "== t141-148-pre.sql (fixtures and results before 141)"
PSQL -d $DB -v ON_ERROR_STOP=1 -f "$W/pre.sql" 2>&1 | grep -v NOTICE
echo "== applying 141..148"
for f in $(cd "$SB/migrations" && LC_ALL=C ls 14[1-8]_*.sql 2>/dev/null | LC_ALL=C sort); do
  num=$((10#${f%%[!0-9]*}))
  runs=2
  for i in $(seq 1 $runs); do
    sed -E '/^[[:space:]]*create extension if not exists (pg_net|pg_cron)/Id' "$SB/migrations/$f" > "$W/m.sql"; chmod 644 "$W/m.sql"
    PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f "$W/m.sql" 2>&1 | grep -E "ERROR" || echo "   $f run $i ok"
  done
done
echo "== t141-148.sql"
OUT="$W/out.txt"
PSQL -d $DB -v ON_ERROR_STOP=0 -f "$W/t.sql" > "$OUT" 2>&1
cat "$OUT"
# a statement that fails outside t.err() leaves no result row, so a clean run has NO psql error line at all
NERR=$(grep -c '^psql:.*ERROR' "$OUT")
echo "SQL errors outside t.err (must be 0): $NERR"
if grep -q '^RESULT: .* 0 failed' "$OUT" && [ "$NERR" = 0 ]; then echo "t141-148 OK"; else echo "t141-148 NOT OK"; exit 1; fi
