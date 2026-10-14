#!/usr/bin/env bash
# Proves that supabase/migrations rebuild the database described by supabase/schema/03_live_baseline.sql.
#
# It starts a throw-away PostgreSQL, replays every migration in order into one database, loads the baseline into
# another, and compares the two object by object (tables' columns, constraints, indexes, triggers, policies, views,
# functions, grants, row level security). Nothing outside a temp folder is touched; no Supabase project is used.
#
# Needs: PostgreSQL server binaries (initdb, pg_ctl, psql) of version 16 or newer.
# Usage: supabase/verify/verify_rebuild.sh [last-migration-number]     (default 117 = the last one applied live)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; SB="$(dirname "$HERE")"
LAST="${1:-117}"; PORT=5496
BIN="$(ls -d /usr/lib/postgresql/*/bin /opt/homebrew/opt/postgresql@*/bin /usr/local/opt/postgresql@*/bin 2>/dev/null | sort -V | tail -1)"
[ -x "$BIN/initdb" ] || { echo "No PostgreSQL server binaries found (looked for initdb)."; exit 2; }
WORK="$(mktemp -d /var/tmp/sna-verify.XXXXXX)"; chmod 755 "$WORK"
run() { if [ "$(id -u)" = 0 ]; then chown postgres "$WORK"; su postgres -c "$*"; else sh -c "$*"; fi; }
cleanup() { run "$BIN/pg_ctl -D $WORK/data -m immediate stop" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT
run "$BIN/initdb -D $WORK/data -A trust" >/dev/null || exit 2
run "$BIN/pg_ctl -D $WORK/data -o '-p $PORT -k /tmp' -l $WORK/log -w start" >/dev/null || exit 2
P="$BIN/psql -h /tmp -p $PORT -U postgres -X -q"
$P -d postgres -c "create database mig" -c "create database base" || exit 2
for db in mig base; do $P -d $db -f "$HERE/stubs.sql" >/dev/null 2>&1; $P -d $db -c "alter database $db set search_path = public, extensions"; done
# What Supabase gives every new object in public (this is why the migrations never grant to these roles themselves).
$P -d mig -c "alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role" \
          -c "alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role" \
          -c "alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role"

echo "Replaying migrations 001..$LAST"
fail=0; n=0
for f in $(cd "$SB/migrations" && LC_ALL=C ls *.sql | LC_ALL=C sort); do
  num=$((10#${f%%[!0-9]*})); [ "$num" -gt "$LAST" ] && continue
  n=$((n+1))
  # pg_net / pg_cron are Supabase extensions; the stand-in functions in stubs.sql cover what the migrations call.
  sed -E '/^[[:space:]]*create extension if not exists (pg_net|pg_cron)/Id' "$SB/migrations/$f" > "$WORK/m.sql"
  err="$($P -d mig -v ON_ERROR_STOP=1 -1 -f "$WORK/m.sql" 2>&1 >/dev/null | grep -m1 -E 'ERROR|FATAL')"
  [ -n "$err" ] && { echo "  FAIL $f: $err"; fail=$((fail+1)); }
done
echo "  $n migrations replayed, $fail failed"

sed 's/ MAINTAIN,//; s/, MAINTAIN//; /GRANT MAINTAIN/d' "$SB/schema/03_live_baseline.sql" > "$WORK/base.sql"   # MAINTAIN exists only from PostgreSQL 17
$P -d base -f "$WORK/base.sql" >/dev/null 2>&1
fp() { $P -d "$1" -At -f "$HERE/fingerprint.sql" \
        | sed -E '/^(fngrant|tblgrant)\|/{s/service_role(:[A-Za-z]+)?,?//g; s/,$//}' \
        | sed -E '/^con\|/{s/[() ]//g}' | sort; }   # service_role grants come from Supabase defaults; CHECK text differs only in parentheses between PostgreSQL versions
fp mig > "$WORK/mig.fp"; fp base > "$WORK/base.fp"
echo "Comparing $(wc -l < "$WORK/mig.fp") rebuilt objects with $(wc -l < "$WORK/base.fp") in the baseline"
if diff "$WORK/base.fp" "$WORK/mig.fp" > "$WORK/fp.diff"; then echo "RESULT: identical. The migrations rebuild the baseline."; else
  echo "RESULT: DIFFERENT"; grep '^[<>]' "$WORK/fp.diff" | cut -c1-220 | head -40; echo "(< = only in baseline, > = only in migrations)"; fail=$((fail+1)); fi
exit $((fail>0))
