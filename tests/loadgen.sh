#!/usr/bin/env bash
# The load generator's source addresses: a count of loopback addresses, or a list of local
# addresses (needed to open more than about 64,000 connections from one remote machine).
# Also: separate user numbering for several load generators. Needs bin/mina-server, cc,
# sqlite3, curl and ss. Loopback only.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${1:-$ROOT/bin/mina-server}"
PORT="${MINA_TEST_PORT:-3918}"
TMP="$(mktemp -d)"; PID=
trap 'if [ -n "$PID" ]; then kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; fi; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; fail=$((fail+1)); }

cc -O2 -pthread -Wno-unused-function -DWORKLOAD='"workload_health.h"' -I"$ROOT/bench" -o "$TMP/loadgen" "$ROOT/bench/loadgen.c" || exit 1
sqlite3 "$TMP/a.db" <"$ROOT/gen/schema.sql"
MINA_DB="$TMP/a.db" MINA_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" MINA_PORT="$PORT" "$SERVER" >"$TMP/server.log" 2>&1 & PID=$!
for _ in $(seq 50); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$PORT/v1/health" && break; sleep 0.1; done

# run <source_ips>: 20 users for 7 s; leaves the distinct source addresses seen in $TMP/seen
run() {
  "$TMP/loadgen" 127.0.0.1 "$PORT" 20 1 6 0 2 "$1" >"$TMP/load.json" 2>"$TMP/load.err" & local lg=$!
  sleep 3
  ss -Htn state established "( dport = :$PORT )" | awk '{sub(/:[0-9]+$/, "", $3); print $3}' | sort -u | paste -sd, >"$TMP/seen"
  wait "$lg"
}

run '127.0.0.5,127.0.0.9'
[ "$(cat "$TMP/seen")" = 127.0.0.5,127.0.0.9 ] && ok "binds the listed addresses" || bad "binds the listed addresses" "saw: $(cat "$TMP/seen")"
grep -q '"open_conns_min_in_hold":20,' "$TMP/load.json" && grep -q '"errors_in_hold":0,' "$TMP/load.json" &&
  ok "all users connected, no errors" || bad "all users connected, no errors" "$(cat "$TMP/load.json" "$TMP/load.err")"

run 3
[ "$(cat "$TMP/seen")" = 127.0.0.2,127.0.0.3,127.0.0.4 ] && ok "a count still means loopback addresses from 127.0.0.2" || bad "a count" "saw: $(cat "$TMP/seen")"

for arg in '127.0.0.5,nonsense' '127.0.0.5,' 'x'; do
  timeout 15 "$TMP/loadgen" 127.0.0.1 "$PORT" 1 0 1 0 1 "$arg" >/dev/null 2>&1
  rc=$?; [ $rc = 2 ] && ok "rejects '$arg'" || bad "rejects '$arg'" "exit $rc"
done

# the MINA workload on several machines: each one numbers its users from its own base
SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
kill "$PID"; wait "$PID" 2>/dev/null; sleep 3
sqlite3 "$TMP/b.db" <"$ROOT/gen/schema.sql"
MINA_DB="$TMP/b.db" MINA_SECRET="$SECRET" MINA_PORT="$PORT" "$SERVER" >"$TMP/server.log" 2>&1 & PID=$!
for _ in $(seq 50); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$PORT/v1/health" && break; sleep 0.1; done
cc -O2 -pthread -Wno-unused-function -DWORKLOAD='"workload_mina.h"' -I"$ROOT/bench" -I"$ROOT/runtime" -I"$ROOT/gen" \
  -o "$TMP/loadgen-mina" "$ROOT/bench/loadgen.c" "$ROOT/bench/sign.c" || exit 1
# two generators started together, every citizen request a report
for base in 1000000 2000000; do
  MINA_UID_BASE=$base "$TMP/loadgen-mina" 127.0.0.1 "$PORT" 40 1 14 0 2 0 "$SECRET:0:4:0:90" >"$TMP/mina-$base.json" 2>>"$TMP/load.err" &
done
wait $(jobs -p | grep -vx "$PID")
bases=$(sqlite3 "$TMP/b.db" 'SELECT group_concat(b) FROM (SELECT DISTINCT actor / 1000000 AS b FROM events ORDER BY b)')
[ "$bases" = 1,2 ] && ok "each generator has its own users" || bad "each generator has its own users" "actors / 1000000: $bases"
[ "$(grep -l '"unexpected":0[,}]' "$TMP"/mina-*.json | wc -l)" = 2 ] && ok "no unexpected answer on either" ||
  bad "unexpected answers" "$(head -3 "$TMP/load.err")"

echo "$pass passed, $fail failed"
[ $fail = 0 ]
