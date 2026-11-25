#!/usr/bin/env bash
# Differential test of the native read plans against the reference SQL: two servers on copies of
# one synthetic database, one with MINA_FORCE_SQL=1, answer the same random requests.
#
#   tests/diff.sh [requests]        (default 20000; MINA_DIFF_SEED, MINA_TEST_PORT)
#
# Needs ./build.sh, sqlite3 and curl.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${MINA_SERVER:-$ROOT/bin/mina-server}"; ADMIN="${MINA_ADMIN:-$ROOT/bin/mina-admin}"
N="${1:-20000}"; SEED="${MINA_DIFF_SEED:-1}"; PA="${MINA_TEST_PORT:-3917}"; PB=$((PA+1))
TMP="$(mktemp -d)"; PIDS=()
trap 'kill "${PIDS[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP"' EXIT
fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; fail=1; }
cc -O2 -Wall -o "$TMP/diffclient" "$ROOT/tests/diff/diffclient.c" || exit 1
sqlite3 "$TMP/a.db" <"$ROOT/gen/schema.sql" && "$ADMIN" seed --events 20000 --regions 8 --seed "$SEED" | sqlite3 -bail "$TMP/a.db" || exit 1
cp "$TMP/a.db" "$TMP/b.db"
SECRET=0123456789abcdef0123456789abcdef
start() {  # start <name> <port> [env...]
  local name=$1 port=$2; shift 2
  env "$@" MINA_DB="$TMP/$name.db" MINA_SECRET=$SECRET MINA_PORT=$port "$SERVER" >"$TMP/$name.log" 2>&1 & PIDS+=($!)
  for _ in $(seq 100); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$port/v1/health" && return; sleep 0.1; done
  echo "server $name did not start:"; cat "$TMP/$name.log"; exit 1
}
start a $PA
start b $PB MINA_FORCE_SQL=1
grep -q 'native read plans: on' "$TMP/a.log" && ok "first server uses native plans" || bad "native plans on" "$(cat "$TMP/a.log")"
grep -q 'native read plans: off' "$TMP/b.log" && ok "second server uses SQL" || bad "forced SQL" "$(cat "$TMP/b.log")"
T() { MINA_SECRET=$SECRET "$ADMIN" token "$@"; }
if "$TMP/diffclient" $PA $PB "$N" "$SEED" 20000 "$(T --sub 1 --role admin)" "$(T --sub 2 --role responder --regions 1,2,3)" \
     "$(T --sub 3 --role citizen)" >"$TMP/diff.out"; then ok "$(cat "$TMP/diff.out")"; else bad "answers differ" "$(cat "$TMP/diff.out")"; fi
! grep -qE 'native plan failed|another connection wrote' "$TMP/a.log" && ok "no fallback during the run" || bad "fallback" "$(grep -m3 -E 'native|another' "$TMP/a.log")"

# another process writes: the native server must notice and answer from the database
head="$(sqlite3 "$TMP/a.db" 'SELECT max(seq) FROM events')"
sqlite3 "$TMP/a.db" ".timeout 2000" "INSERT INTO events (seq, eid, region, vis, kind, actor, ts, body) VALUES ($((head+1)), randomblob(16), 999, 0, 6, 9, 1, 'from outside')"
got="$(curl -s -m 2 -H "Authorization: Bearer $(T --sub 3 --role citizen)" "http://127.0.0.1:$PA/v1/sync?region=999&after=$head")"
[[ "$got" == *'"from outside"'* ]] && ok "a write by another process is served" || bad "foreign write" "$got"
grep -q 'another connection wrote' "$TMP/a.log" && ok "native plans are switched off after it" || bad "foreign write unnoticed" "$(cat "$TMP/a.log")"
! grep -qE 'runtime error|ERROR: [A-Za-z]*Sanitizer|batch rolled back' "$TMP"/*.log && ok "clean logs" || bad "server log"
[ $fail = 0 ] && echo "diff: ok" || { echo "diff: FAILED"; exit 1; }
