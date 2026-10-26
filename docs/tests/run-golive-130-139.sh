#!/usr/bin/env bash
# Proves docs/go-live-130-139.sql on a private PostgreSQL 16: replay 001..129, record 129, run the go-live file (a) without 129
# recorded (must refuse), (b) once (must succeed), (c) a second time (must refuse and change nothing); then runs each workstream's
# scratch tests (t130-133, t132-134, t135-137, t138, t129) on a copy of the post-go-live database.
# Needs a local PostgreSQL 16 server and a superuser (default: "su postgres" when run as root). Nothing leaves the machine.
# Usage: docs/tests/run-golive-130-139.sh [database-name]        (default golive; it and its copies are DROPPED and recreated)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$(dirname "$HERE")")"; DB="${1:-golive}"; SB="$ROOT/supabase"
if [ "$(id -u)" = 0 ]; then PSQL() { su postgres -c "psql -X -q -v ON_ERROR_STOP=0 $(printf '%q ' "$@")"; }; else PSQL() { psql -X -q "$@"; }; fi
"$HERE/build-go-live-130-139.sh" >/dev/null || exit 2
cp "$ROOT/docs/go-live-130-139.sql" /tmp/golive130139.sql
for t in t129 t130-133-pre t130-133 t132-134 t135-137 t138; do cp "$HERE/$t.sql" "/tmp/gl_$t.sql"; done; chmod 644 /tmp/golive130139.sql /tmp/gl_*.sql
NAMES="'130_tax_rate_schedule','131_open_price_and_business_date_tax','132_move_order_items','133_order_tips','134_floor_status','135_log_print_reprint_audit','136_bulk_price_change','137_copy_rights_and_access','138_report_pack_3_covers_reprints_tips','139_erase_groups_tips_and_price_changes'"
SIG() { PSQL -At -d "$1" -c "select 'objects md5: ' || md5(coalesce((select string_agg(pg_get_functiondef(p.oid), '' order by p.oid::regprocedure::text) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','app')),'') || coalesce((select string_agg(table_name||column_name, '' order by table_name, column_name) from information_schema.columns where table_schema='public'),'') || coalesce((select string_agg(key, '' order by key) from public.permissions),''))" -c "select 'recorded 130-139: ' || count(*) from supabase_migrations.schema_migrations where name in ($NAMES)"; }
mkdb() { PSQL -d postgres -c "drop database if exists $1" -c "create database $1 ${2:+template $2}" || exit 2; }
mkdb $DB
PSQL -d $DB -f "$SB/verify/stubs.sql" >/dev/null 2>&1
PSQL -d $DB -c "alter database $DB set search_path = public, extensions" \
 -c "alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role" \
 -c "alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role" \
 -c "create schema supabase_migrations" \
 -c "create table supabase_migrations.schema_migrations(version text primary key, statements text[], name text, created_by text, idempotency_key text, rollback text[])" || exit 2
echo "== replaying migrations 001..129"; fail=0
for f in $(cd "$SB/migrations" && LC_ALL=C ls *.sql | LC_ALL=C sort); do
  num=$((10#${f%%[!0-9]*})); [ "$num" -gt 129 ] && continue
  sed -E '/^[[:space:]]*create extension if not exists (pg_net|pg_cron)/Id' "$SB/migrations/$f" > /tmp/mgl.sql; chmod 644 /tmp/mgl.sql
  err="$(PSQL -d $DB -v ON_ERROR_STOP=1 -1 -f /tmp/mgl.sql 2>&1 >/dev/null | grep -m1 -E 'ERROR|FATAL')"
  [ -n "$err" ] && { echo "  FAIL $f: $err"; fail=$((fail+1)); }
done
echo "   failures: $fail"
echo "== go-live without 129 recorded (must refuse, change nothing)"
SIG $DB > /tmp/gl_sig0.txt
PSQL -d $DB -v ON_ERROR_STOP=1 -f /tmp/golive130139.sql 2>&1 | grep -E "ERROR|NOTICE" | head -3
SIG $DB | diff - /tmp/gl_sig0.txt >/dev/null && echo "   unchanged: yes" || echo "   unchanged: NO (BUG)"
PSQL -d $DB -c "insert into supabase_migrations.schema_migrations(version, name) values ('20261025090000', '129_report_pack_2_rpcs')"
echo "== t130-133 needs golden 'before' bills captured on a 129 database: do that on a separate copy, then go-live there too"
mkdb ${DB}_t130_133 $DB
PSQL -d ${DB}_t130_133 -v ON_ERROR_STOP=1 -f /tmp/gl_t130-133-pre.sql 2>&1 | tail -2
PSQL -d ${DB}_t130_133 -v ON_ERROR_STOP=1 -f /tmp/golive130139.sql 2>&1 | grep -E "ERROR" || echo "   go-live ran on the copy"
echo "== go-live, first run (must succeed)"
PSQL -d $DB -v ON_ERROR_STOP=1 -f /tmp/golive130139.sql 2>&1 | grep -E "ERROR|NOTICE"
PSQL -At -d $DB -c "select 'recorded: ' || version || ' ' || name from supabase_migrations.schema_migrations where name ~ '^13[0-9]_' order by version"
SIG $DB > /tmp/gl_sig1.txt; cat /tmp/gl_sig1.txt
echo "== go-live, second run (must refuse, change nothing)"
PSQL -d $DB -v ON_ERROR_STOP=1 -f /tmp/golive130139.sql 2>&1 | grep -E "ERROR|NOTICE"
SIG $DB | diff - /tmp/gl_sig1.txt >/dev/null && echo "   unchanged: yes" || echo "   unchanged: NO (BUG)"
echo "== erase_groups lists the new tables"
PSQL -At -d $DB -c "select 'order_tips in pos_tx before payments: ' || ((g->'pos_tx') @> '\"order_tips\"'::jsonb and (select min(o) from jsonb_array_elements_text(g->'pos_tx') with ordinality x(v,o) where v='order_tips') < (select min(o) from jsonb_array_elements_text(g->'pos_tx') with ordinality x(v,o) where v='payments')), 'price_change_* before products: ' || ((select min(o) from jsonb_array_elements_text(g->'pos_master') with ordinality x(v,o) where v='price_change_batches') < (select min(o) from jsonb_array_elements_text(g->'pos_master') with ordinality x(v,o) where v='products')) from (select app.erase_groups() g) z"
PSQL -At -d $DB -c "select 'order.reprint granted to roles: ' || string_agg(distinct r.name, ',' order by r.name) from public.role_permissions rp join public.roles r on r.id=rp.role_id where rp.permission_key='order.reprint'" -c "select 'order.open_price granted to roles: ' || string_agg(distinct r.name, ',' order by r.name) from public.role_permissions rp join public.roles r on r.id=rp.role_id where rp.permission_key='order.open_price'" -c "select 'order.open_price duplicate grants: ' || count(*) from (select role_id from public.role_permissions where permission_key='order.open_price' group by role_id having count(*)>1) d"
echo "== workstream tests on copies of the post-go-live database"
for t in t130-133 t132-134 t135-137 t138 t129; do
  c="${DB}_${t//-/_}"; [ "$t" = t130-133 ] || mkdb $c $DB
  echo "-- $t"; PSQL -d $c -v ON_ERROR_STOP=0 -f /tmp/gl_$t.sql 2>&1 | grep -E "RESULT|FAIL|passed|failed|ERROR" | cut -c1-240 | head -20
done
