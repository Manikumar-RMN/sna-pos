#!/usr/bin/env bash
# Proves docs/go-live-140.sql on a private PostgreSQL 16:
#   A. replay 001..139, run the go-live file (a) without 139 recorded (must refuse, change nothing), record 139, run t140-pre.sql
#      ("before" results), run it (b) once (must succeed) and (c) a second time (must refuse, change nothing), then docs/tests/t140.sql;
#      also proves the migration file itself is re-runnable.
#   B. regression: on a copy of a clean 001..139 database with the go-live applied, run t132-134, t135-137, t138 and t129.
#   C. regression: t130-133 (needs golden "before" bills captured on a 129 database): 001..129 + t130-133-pre, then 130..139, then the 140 go-live, then t130-133.
# Needs a local PostgreSQL 16 server and a superuser (default: "su postgres" when run as root). Nothing leaves the machine.
# Usage: docs/tests/run-golive-140.sh [database-name]        (default golive140; it and its copies are DROPPED and recreated)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$(dirname "$HERE")")"; DB="${1:-golive140}"; SB="$ROOT/supabase"
if [ "$(id -u)" = 0 ]; then PSQL() { su postgres -c "psql -X -q -v ON_ERROR_STOP=0 $(printf '%q ' "$@")"; }; else PSQL() { psql -X -q "$@"; }; fi
"$HERE/build-go-live-140.sh" >/dev/null || exit 2
W=/tmp/gl140; mkdir -p $W; chmod 755 $W
cp "$ROOT/docs/go-live-140.sql" $W/golive140.sql
for t in t129 t130-133-pre t130-133 t132-134 t135-137 t138 t140-pre t140; do cp "$HERE/$t.sql" "$W/$t.sql"; done; chmod 644 $W/*.sql
NAME140="'140_bulk_price_range_offline_open_price_summary_extras'"
SIG() { PSQL -At -d "$1" -c "select 'objects md5: ' || md5(coalesce((select string_agg(pg_get_functiondef(p.oid), '' order by p.oid::regprocedure::text) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','app')),'') || coalesce((select string_agg(table_name||column_name, '' order by table_name, column_name) from information_schema.columns where table_schema='public'),'') || coalesce((select string_agg(key, '' order by key) from public.permissions),''))" -c "select 'recorded 140: ' || count(*) from supabase_migrations.schema_migrations where name = $NAME140"; }
mkdb() { PSQL -d postgres -c "drop database if exists $1" -c "create database $1 ${2:+template $2}" || exit 2; }
newdb() { # $1 = name
  mkdb $1
  PSQL -d $1 -f "$SB/verify/stubs.sql" >/dev/null 2>&1
  PSQL -d $1 -c "alter database $1 set search_path = public, extensions" \
   -c "alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role" \
   -c "alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role" \
   -c "alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role" \
   -c "create schema supabase_migrations" \
   -c "create table supabase_migrations.schema_migrations(version text primary key, statements text[], name text, created_by text, idempotency_key text, rollback text[])" || exit 2
}
replay() { # $1 = db, $2 = max number, $3 = min number
  local fail=0 f num
  for f in $(cd "$SB/migrations" && LC_ALL=C ls *.sql | LC_ALL=C sort); do
    num=$((10#${f%%[!0-9]*})); [ "$num" -gt "$2" ] && continue; [ "$num" -lt "${3:-0}" ] && continue
    sed -E '/^[[:space:]]*create extension if not exists (pg_net|pg_cron)/Id' "$SB/migrations/$f" > $W/m.sql; chmod 644 $W/m.sql
    err="$(PSQL -d $1 -v ON_ERROR_STOP=1 -1 -f $W/m.sql 2>&1 >/dev/null | grep -m1 -E 'ERROR|FATAL')"
    [ -n "$err" ] && { echo "  FAIL $f: $err"; fail=$((fail+1)); }
  done
  echo "   failures: $fail"
}
rec139() { PSQL -d "$1" -c "insert into supabase_migrations.schema_migrations(version, name) values ('20261026090000', '139_erase_groups_tips_and_price_changes')"; }

echo "== A. replaying migrations 001..139"; newdb $DB; replay $DB 139
echo "== go-live 140 without 139 recorded (must refuse, change nothing)"
SIG $DB > $W/sig0.txt
PSQL -d $DB -v ON_ERROR_STOP=1 -f $W/golive140.sql 2>&1 | grep -E "ERROR|NOTICE" | head -3
SIG $DB | diff - $W/sig0.txt >/dev/null && echo "   unchanged: yes" || echo "   unchanged: NO (BUG)"
rec139 $DB
mkdb ${DB}_clean $DB
echo "== t140-pre.sql (before-140 results)"
PSQL -d $DB -v ON_ERROR_STOP=1 -f $W/t140-pre.sql 2>&1 | tail -2
SIG $DB > $W/sig1.txt
echo "== go-live 140, first run (must succeed)"
PSQL -d $DB -v ON_ERROR_STOP=1 -f $W/golive140.sql 2>&1 | grep -E "ERROR|NOTICE"
PSQL -At -d $DB -c "select 'recorded: ' || version || ' ' || name from supabase_migrations.schema_migrations where name ~ '^14[0-9]_'"
SIG $DB > $W/sig2.txt; cat $W/sig2.txt
SIG $DB | diff - $W/sig1.txt >/dev/null && echo "   (signature changed by the go-live: NO - BUG)" || echo "   signature changed by the go-live: yes (expected)"
echo "== go-live 140, second run (must refuse, change nothing)"
PSQL -d $DB -v ON_ERROR_STOP=1 -f $W/golive140.sql 2>&1 | grep -E "ERROR|NOTICE"
SIG $DB | diff - $W/sig2.txt >/dev/null && echo "   unchanged: yes" || echo "   unchanged: NO (BUG)"
echo "== the migration file itself is re-runnable (create or replace)"
PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f "$SB/migrations/140_bulk_price_range_offline_open_price_summary_extras.sql" 2>&1 | grep -E "ERROR" || echo "   ran again without error"
echo "== t140.sql"
PSQL -d $DB -v ON_ERROR_STOP=0 -f $W/t140.sql 2>&1 | grep -E "FAIL|RESULT|ERROR" -A3 | cut -c1-300

echo "== B. regression tests on a clean copy with the go-live applied"
mkdb ${DB}_post ${DB}_clean
PSQL -d ${DB}_post -v ON_ERROR_STOP=1 -f $W/golive140.sql 2>&1 | grep -E "ERROR" || echo "   go-live ran on the copy"
for t in t132-134 t135-137 t138 t129; do
  c="${DB}_${t//-/_}"; mkdb $c ${DB}_post
  echo "-- $t"; PSQL -d $c -v ON_ERROR_STOP=0 -f $W/$t.sql 2>&1 | grep -E "RESULT|FAIL|passed|failed|ERROR" | cut -c1-240 | head -20
done

echo "== C. t130-133 (golden bills captured on 129, then 130..139, then the 140 go-live)"
C=${DB}_t130_133; newdb $C; replay $C 129
PSQL -d $C -v ON_ERROR_STOP=1 -f $W/t130-133-pre.sql 2>&1 | tail -2
replay $C 139 130
PSQL -d $C -c "insert into supabase_migrations.schema_migrations(version, name) values ('20261025090000', '129_report_pack_2_rpcs')" >/dev/null
rec139 $C
PSQL -d $C -v ON_ERROR_STOP=1 -f $W/golive140.sql 2>&1 | grep -E "ERROR" || echo "   go-live 140 ran on the copy"
echo "-- t130-133"; PSQL -d $C -v ON_ERROR_STOP=0 -f $W/t130-133.sql 2>&1 | grep -E "RESULT|FAIL|passed|failed|ERROR" | cut -c1-240 | head -20
