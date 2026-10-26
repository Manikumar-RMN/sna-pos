#!/usr/bin/env bash
# Proves docs/go-live-149.sql on a private PostgreSQL 16 (the file is rebuilt first from supabase/migrations/149_floor_status_billed.sql):
#   A. replay 001..148, run the go-live file (a) without 148 recorded (must refuse, change nothing), record 148, run it (b) once (must succeed and record
#      149) and (c) a second time (must refuse, change nothing); the DO block is all-or-nothing (a broken file rolls back); the migration file is re-runnable;
#      then docs/tests/t149.sql.
#   B. regression: on copies of the clean 001..148 database with the go-live applied, run t132-134, t135-137, t138 and t129.
#   C. regression: t141-148 (its "before" results come from a 140 database): 001..140 + t141-148-pre, then the 141-148 go-live, then the 149 go-live, then t141-148.
# Needs a local PostgreSQL 16 server and a superuser (default: "su postgres" when run as root). Nothing leaves the machine.
# Usage: docs/tests/run-golive-149.sh [database-name]        (default golive149; it and its copies are DROPPED and recreated)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$(dirname "$HERE")")"; DB="${1:-golive149}"; SB="$ROOT/supabase"
if [ "$(id -u)" = 0 ]; then PSQL() { su postgres -c "psql -X -q -v ON_ERROR_STOP=0 $(printf '%q ' "$@")"; }; else PSQL() { psql -X -q "$@"; }; fi
"$HERE/build-go-live-149.sh" >/dev/null || exit 2
"$HERE/build-go-live-141-148.sh" >/dev/null || exit 2
W=/tmp/gl149; mkdir -p $W; chmod 755 $W
cp "$ROOT/docs/go-live-149.sql" $W/golive149.sql
cp "$ROOT/docs/go-live-141-148.sql" $W/golive141.sql
for t in t129 t132-134 t135-137 t138 t141-148-pre t141-148 t149; do cp "$HERE/$t.sql" "$W/$t.sql"; done; chmod 644 $W/*.sql
SIG() { PSQL -At -d "$1" -c "select 'objects md5: ' || md5(coalesce((select string_agg(pg_get_functiondef(p.oid), '' order by p.oid::regprocedure::text) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','app')),'') || coalesce((select string_agg(table_name||column_name, '' order by table_name, column_name) from information_schema.columns where table_schema='public'),'') || coalesce((select string_agg(key, '' order by key) from public.permissions),'') || coalesce((select string_agg(role_id::text||permission_key, '' order by role_id::text, permission_key) from public.role_permissions),''))" -c "select 'recorded 149: ' || count(*) from supabase_migrations.schema_migrations where name = '149_floor_status_billed'"; }
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
replay() { # $1 = db, $2 = max number
  local fail=0 f num
  for f in $(cd "$SB/migrations" && LC_ALL=C ls *.sql | LC_ALL=C sort); do
    num=$((10#${f%%[!0-9]*})); [ "$num" -gt "$2" ] && continue
    sed -E '/^[[:space:]]*create extension if not exists (pg_net|pg_cron)/Id' "$SB/migrations/$f" > $W/m.sql; chmod 644 $W/m.sql
    err="$(PSQL -d $1 -v ON_ERROR_STOP=1 -1 -f $W/m.sql 2>&1 >/dev/null | grep -m1 -E 'ERROR|FATAL')"
    [ -n "$err" ] && { echo "  FAIL $f: $err"; fail=$((fail+1)); }
  done
  echo "   failures: $fail"
}
rec() { PSQL -d "$1" -c "insert into supabase_migrations.schema_migrations(version, name) values ('$2', '$3')"; }
rec140() { rec "$1" 20261026100000 140_bulk_price_range_offline_open_price_summary_extras; }
rec148() { rec "$1" 20261026110000 148_erase_groups_and_grants; }
golive() { PSQL -d "$1" -v ON_ERROR_STOP=1 -f $W/golive149.sql 2>&1 | grep -E "ERROR|NOTICE"; }

echo "== A. replaying migrations 001..148"; newdb $DB; replay $DB 148
echo "== go-live 149 without 148 recorded (must refuse, change nothing)"
SIG $DB > $W/sig0.txt
golive $DB | head -3
SIG $DB | diff - $W/sig0.txt >/dev/null && echo "   unchanged: yes" || echo "   unchanged: NO (BUG)"
rec148 $DB
mkdb ${DB}_clean $DB
SIG $DB > $W/sig1.txt
echo "== go-live 149, first run (must succeed)"
golive $DB
PSQL -At -d $DB -c "select 'recorded: ' || version || ' ' || name from supabase_migrations.schema_migrations where name ~ '^149_'"
SIG $DB > $W/sig2.txt; cat $W/sig2.txt
SIG $DB | diff - $W/sig1.txt >/dev/null && echo "   (signature changed by the go-live: NO - BUG)" || echo "   signature changed by the go-live: yes (expected)"
echo "== go-live 149, second run (must refuse, change nothing)"
golive $DB
SIG $DB | diff - $W/sig2.txt >/dev/null && echo "   unchanged: yes" || echo "   unchanged: NO (BUG)"
echo "== all-or-nothing: the same file with a failing statement after the migration text rolls everything back (and records nothing)"
mkdb ${DB}_aon ${DB}_clean
python3 -c "
s=open('$W/golive149.sql').read()
i=s.index('\$mig149\$;')
s=s[:i]+'select 1/0;\n'+s[i:]
open('$W/golive149_broken.sql','w').write(s)"
chmod 644 $W/golive149_broken.sql
SIG ${DB}_aon > $W/sig_aon0.txt
PSQL -d ${DB}_aon -v ON_ERROR_STOP=1 -f $W/golive149_broken.sql 2>&1 | grep -E "ERROR" | head -2
SIG ${DB}_aon | diff - $W/sig_aon0.txt >/dev/null && echo "   nothing changed after the failure: yes" || echo "   nothing changed after the failure: NO (BUG)"
echo "== the migration file itself is re-runnable"
PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f "$SB/migrations/149_floor_status_billed.sql" 2>&1 | grep -E "ERROR" || echo "   ran again without error"
echo "== t149.sql"
PSQL -d $DB -v ON_ERROR_STOP=0 -f $W/t149.sql > $W/t149.out 2>&1
grep -E "FAIL|RESULT" -A3 $W/t149.out | cut -c1-300
echo "   SQL errors outside t.err (must be 0): $(grep -c '^psql:.*ERROR' $W/t149.out)"

echo "== B. regression tests on a clean copy with the go-live applied"
mkdb ${DB}_post ${DB}_clean
golive ${DB}_post | grep -E "ERROR" || echo "   go-live ran on the copy"
for t in t132-134 t135-137 t138 t129; do
  c="${DB}_${t//-/_}"; mkdb $c ${DB}_post
  echo "-- $t"; PSQL -d $c -v ON_ERROR_STOP=0 -f $W/$t.sql 2>&1 | grep -E "RESULT|FAIL|passed|failed|ERROR" | cut -c1-240 | head -20
done

echo "== C. t141-148 (before-141 results captured on 140, then the 141-148 go-live, then the 149 go-live)"
C=${DB}_t141; newdb $C; replay $C 140
rec140 $C >/dev/null
PSQL -d $C -v ON_ERROR_STOP=1 -f $W/t141-148-pre.sql 2>&1 | grep -v NOTICE | tail -2
PSQL -d $C -v ON_ERROR_STOP=1 -f $W/golive141.sql 2>&1 | grep -E "ERROR" || echo "   go-live 141-148 ran on the copy"
sleep 10   # the go-live versions are timestamps (141-148 use base+1..8 seconds): keep 149 apart
golive $C | grep -E "ERROR" || echo "   go-live 149 ran on the copy"
echo "-- t141-148"; PSQL -d $C -v ON_ERROR_STOP=0 -f $W/t141-148.sql 2>&1 | grep -E "RESULT|FAIL|passed|failed|ERROR" | cut -c1-240 | head -20
