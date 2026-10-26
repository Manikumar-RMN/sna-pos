#!/usr/bin/env bash
# Builds a private Postgres database (Supabase stand-ins from supabase/verify/stubs.sql), replays migrations 001..129,
# captures "before" golden bill results (docs/tests/t130-133-pre.sql), applies migrations 130, 131 and 133 (each as one
# transaction), then runs docs/tests/t130-133.sql (golden comparison + tax schedule + open price + tips).
# Needs a local PostgreSQL 16 server and a superuser (default: "su postgres" when run as root). Nothing leaves the machine.
# Usage: docs/tests/run-t130-133.sh [database-name]        (default t130133; it is DROPPED and recreated)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$(dirname "$HERE")")"; DB="${1:-t130133}"; SB="$ROOT/supabase"
if [ "$(id -u)" = 0 ]; then PSQL() { su postgres -c "psql -X -q -v ON_ERROR_STOP=0 $(printf '%q ' "$@")"; }; else PSQL() { psql -X -q "$@"; }; fi
cp "$HERE/t130-133-pre.sql" /tmp/t130pre.sql; cp "$HERE/t130-133.sql" /tmp/t130133.sql; chmod 644 /tmp/t130pre.sql /tmp/t130133.sql
PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB" || exit 2
PSQL -d $DB -f "$SB/verify/stubs.sql" >/dev/null 2>&1
PSQL -d $DB -c "alter database $DB set search_path = public, extensions" \
 -c "alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role" \
 -c "create schema supabase_migrations" \
 -c "create table supabase_migrations.schema_migrations(version text primary key, statements text[], name text, created_by text, idempotency_key text, rollback text[])" || exit 2
apply() { # $1 = max migration number, $2 = min number
  local fail=0 f num
  for f in $(cd "$SB/migrations" && LC_ALL=C ls *.sql | LC_ALL=C sort); do
    num=$((10#${f%%[!0-9]*})); [ "$num" -gt "$1" ] && continue; [ "$num" -lt "$2" ] && continue
    case "$num" in 13[0-3]) case "$f" in 130_*|131_*|133_*) ;; *) continue;; esac;; esac
    sed -E '/^[[:space:]]*create extension if not exists (pg_net|pg_cron)/Id' "$SB/migrations/$f" > /tmp/m130.sql; chmod 644 /tmp/m130.sql
    err="$(PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f /tmp/m130.sql 2>&1 >/dev/null | grep -m1 -E 'ERROR|FATAL')"
    [ -n "$err" ] && { echo "  FAIL $f: $err"; fail=$((fail+1)); }
  done
  echo "   failures: $fail"
}
echo "== replaying migrations 001..129"; apply 129 0
echo "== capturing golden 'before' results"
PSQL -d $DB -v ON_ERROR_STOP=1 -f /tmp/t130pre.sql 2>&1
echo "== applying migrations 130..133"; apply 133 130
echo "== migrations 130, 131, 133 re-run (must be re-runnable)"
for f in "$SB"/migrations/130_*.sql "$SB"/migrations/131_*.sql "$SB"/migrations/133_*.sql; do
  PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f "$f" 2>&1 | grep -E "ERROR" || echo "   $(basename "$f") ran again without error"
done
echo "== t130-133.sql"
PSQL -d $DB -v ON_ERROR_STOP=1 -f /tmp/t130133.sql 2>&1
