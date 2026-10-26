#!/usr/bin/env bash
# Builds a private Postgres database (Supabase stand-ins from supabase/verify/stubs.sql), replays every migration
# 001..137 that exists in this checkout (135 log_print, 136 bulk price, 137 copy rights are the ones under test),
# then runs docs/tests/t135-137.sql. Needs a local PostgreSQL 16 server and a superuser (default: "su postgres" when run as root).
# Nothing leaves the machine. Usage: docs/tests/run-t135-137.sh [database-name]   (default t135137; DROPPED and recreated)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$(dirname "$HERE")")"; DB="${1:-t135137}"; SB="$ROOT/supabase"
if [ "$(id -u)" = 0 ]; then PSQL() { su postgres -c "psql -X -q -v ON_ERROR_STOP=0 $(printf '%q ' "$@")"; }; else PSQL() { psql -X -q "$@"; }; fi
cp "$HERE/t135-137.sql" /tmp/t135137.sql; chmod 644 /tmp/t135137.sql
PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB" || exit 2
PSQL -d $DB -f "$SB/verify/stubs.sql" >/dev/null 2>&1
PSQL -d $DB -c "alter database $DB set search_path = public, extensions" \
 -c "alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role" \
 -c "create schema supabase_migrations" \
 -c "create table supabase_migrations.schema_migrations(version text primary key, statements text[], name text, created_by text, idempotency_key text, rollback text[])" || exit 2
echo "== replaying migrations 001..137"; fail=0
for f in $(cd "$SB/migrations" && LC_ALL=C ls *.sql | LC_ALL=C sort); do
  num=$((10#${f%%[!0-9]*})); [ "$num" -gt 137 ] && continue
  sed -E '/^[[:space:]]*create extension if not exists (pg_net|pg_cron)/Id' "$SB/migrations/$f" > /tmp/m135137.sql; chmod 644 /tmp/m135137.sql
  err="$(PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f /tmp/m135137.sql 2>&1 >/dev/null | grep -m1 -E 'ERROR|FATAL')"
  [ -n "$err" ] && { echo "  FAIL $f: $err"; fail=$((fail+1)); }
done
echo "   failures: $fail"
echo "== 135 and 137 are re-runnable (create or replace)"
for f in 135_log_print_reprint_audit 137_copy_rights_and_access; do
  PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f "$SB/migrations/$f.sql" 2>&1 | grep -E "ERROR" || echo "   $f ran again without error"
done
echo "== t135-137.sql"
PSQL -d $DB -v ON_ERROR_STOP=1 -f /tmp/t135137.sql 2>&1
