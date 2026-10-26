#!/usr/bin/env bash
# Builds a private Postgres database (Supabase stand-ins from supabase/verify/stubs.sql), replays migrations 001..129 plus
# 132 (move_order_items) and 134 (floor_status), then runs docs/tests/t132-134.sql. Migrations 130, 131, 133 are not needed and not applied.
# Needs a local PostgreSQL 16 server and a superuser (default: "su postgres" when run as root). Nothing leaves the machine.
# Usage: docs/tests/run-t132-134.sh [database-name]        (default t132; it is DROPPED and recreated)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$(dirname "$HERE")")"; DB="${1:-t132}"; SB="$ROOT/supabase"
if [ "$(id -u)" = 0 ]; then PSQL() { su postgres -c "psql -X -q -v ON_ERROR_STOP=0 $(printf '%q ' "$@")"; }; else PSQL() { psql -X -q "$@"; }; fi
cp "$HERE/t132-134.sql" /tmp/t132-134.sql; chmod 644 /tmp/t132-134.sql
PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB" || exit 2
PSQL -d $DB -f "$SB/verify/stubs.sql" >/dev/null 2>&1
PSQL -d $DB -c "alter database $DB set search_path = public, extensions" \
 -c "alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role" \
 -c "create schema supabase_migrations" \
 -c "create table supabase_migrations.schema_migrations(version text primary key, statements text[], name text, created_by text, idempotency_key text, rollback text[])" || exit 2
echo "== replaying migrations 001..129, 132, 134"; fail=0
for f in $(cd "$SB/migrations" && LC_ALL=C ls *.sql | LC_ALL=C sort); do
  num=$((10#${f%%[!0-9]*}))
  if [ "$num" -gt 129 ] && [ "$num" != 132 ] && [ "$num" != 134 ]; then continue; fi
  sed -E '/^[[:space:]]*create extension if not exists (pg_net|pg_cron)/Id' "$SB/migrations/$f" > /tmp/m132.sql; chmod 644 /tmp/m132.sql
  err="$(PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f /tmp/m132.sql 2>&1 >/dev/null | grep -m1 -E 'ERROR|FATAL')"
  [ -n "$err" ] && { echo "  FAIL $f: $err"; fail=$((fail+1)); }
done
echo "   failures: $fail"
echo "== the new migrations are re-runnable (create or replace)"
for f in 132_move_order_items.sql 134_floor_status.sql; do
  PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f "$SB/migrations/$f" 2>&1 | grep -E "ERROR" || echo "   $f ran again without error"
done
echo "== t132-134.sql"
PSQL -d $DB -v ON_ERROR_STOP=1 -f /tmp/t132-134.sql 2>&1
