#!/usr/bin/env bash
# Front Office behaviour tests on a throw-away PostgreSQL. Same build as the repo's e2e harness
# (stubs.sql, Supabase roles, default privileges, every migration replayed), driven by psql.
set -u
SB=/home/claude/sna-pos/supabase
S="$(cd "$(dirname "$0")" && pwd)"
PORT=5497
BIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"
[ -x "$BIN/initdb" ] || { echo "No PostgreSQL binaries"; exit 2; }
WORK="$(mktemp -d /var/tmp/fo-test.XXXXXX)"; chmod 755 "$WORK"
run() { if [ "$(id -u)" = 0 ]; then chown postgres "$WORK"; su postgres -c "$*"; else sh -c "$*"; fi; }
cleanup() { run "$BIN/pg_ctl -D $WORK/data -m immediate stop" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT
run "$BIN/initdb -D $WORK/data -A trust" >/dev/null || exit 2
run "$BIN/pg_ctl -D $WORK/data -o '-p $PORT -k /tmp' -l $WORK/log -w start" >/dev/null || exit 2
P="$BIN/psql -h /tmp -p $PORT -U postgres -X -q"

$P -d postgres -c "create database fo" >/dev/null || exit 2
sed -E 's/create role (anon|authenticated|service_role)[^;]*;//g' "$SB/verify/stubs.sql" > "$WORK/stubs.sql"
$P -d fo -f "$WORK/stubs.sql" >/dev/null 2>&1
$P -d fo -c "create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls" >/dev/null 2>&1
$P -d fo -c "alter database fo set search_path = public, extensions" >/dev/null
for k in tables functions sequences; do
  $P -d fo -c "alter default privileges for role postgres in schema public grant all on $k to anon, authenticated, service_role" >/dev/null
done

echo "Replaying migrations"
for f in $(cd "$SB/migrations" && LC_ALL=C ls *.sql | LC_ALL=C sort); do
  sed -E '/^[[:space:]]*create extension if not exists (pg_net|pg_cron)/Id' "$SB/migrations/$f" > "$WORK/m.sql"
  err="$($P -d fo -v ON_ERROR_STOP=1 -1 -f "$WORK/m.sql" 2>&1 >/dev/null | grep -m1 -E 'ERROR|FATAL')"
  [ -n "$err" ] && { echo "  FAIL $f: $err"; exit 1; }
done

# One session: psql variables set by \gset do not survive a reconnect.
cat "$S/fo_tests.sql" "$S/fo_world.sql" "$S/fo_body.sql" "$S/fo_batch_a.sql" "$S/fo_batch_b.sql" "$S/fo_batch_b2.sql" > "$WORK/all.sql"
echo "Running tests"
$P -d fo -f "$WORK/all.sql" > "$WORK/out.log" 2>&1
grep -E "^(psql:|ERROR)" "$WORK/out.log" | grep -v "already exists" | head -10

$P -d fo -At -F'|' -c "select case when passed then 'PASS' else 'FAIL' end, label, coalesce(detail,'') from t.results order by id"
echo "----"
$P -d fo -At -c "select 'total ' || count(*) || ', failed ' || count(*) filter (where not passed) from t.results"
