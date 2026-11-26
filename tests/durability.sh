#!/usr/bin/env bash
# What MINA_SYNC does to the disk: in full mode every acknowledged write is preceded by a sync of
# the log; in normal mode commits do not sync. Counts the system calls with strace.
# Needs ./build.sh, strace, sqlite3, curl.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${MINA_TEST_PORT:-3917}"
TMP="$(mktemp -d -p "$ROOT/build")"; PID=          # on the project's disk, not a memory file system
trap 'if [ -n "$PID" ]; then kill $PID 2>/dev/null; wait $PID 2>/dev/null; fi; rm -rf -- "${TMP:?}"' EXIT
SECRET=0123456789abcdef0123456789abcdef
TOKEN="$(MINA_SECRET=$SECRET "$ROOT/bin/mina-admin" token --sub 1 --role admin)"
WRITES=100; fail=0
for mode in full normal; do
  sqlite3 "$TMP/$mode.db" <"$ROOT/gen/schema.sql"
  MINA_DB="$TMP/$mode.db" MINA_SECRET=$SECRET MINA_PORT=$PORT MINA_SYNC=$mode \
    strace -f -qq -e trace=fsync,fdatasync -o "$TMP/$mode.trace" "$ROOT/bin/mina-server" >"$TMP/$mode.log" 2>&1 & PID=$!
  up=; for _ in $(seq 100); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$PORT/v1/health" && { up=1; break; }; sleep 0.1; done
  [ -n "$up" ] || { echo "the server did not start:"; cat "$TMP/$mode.log"; exit 1; }
  before=$(grep -cE '(fsync|fdatasync)\(' "$TMP/$mode.trace")
  stored=0
  for i in $(seq $WRITES); do
    [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
        --data-binary '{"eid":"'"$(printf '%032x' $i)"'","kind":5,"region":1,"status":1}' "http://127.0.0.1:$PORT/v1/events")" = 201 ] && stored=$((stored+1))
  done
  syncs=$(( $(grep -cE '(fsync|fdatasync)\(' "$TMP/$mode.trace") - before ))
  kill "$(pgrep -P $PID)" 2>/dev/null; wait $PID 2>/dev/null; PID=; sleep 1
  echo "  $mode: $stored writes acknowledged, $syncs syncs"
  [ $stored = $WRITES ] || { echo "  FAIL writes"; fail=1; }
  if [ $mode = full ]; then [ $syncs -ge $WRITES ] && echo "  ok   full syncs at least once for every commit" || { echo "  FAIL full mode"; fail=1; }
  else [ $syncs -lt $((WRITES/10)) ] && echo "  ok   normal does not sync at commit" || { echo "  FAIL normal mode"; fail=1; }; fi
done
[ $fail = 0 ] && echo "durability: ok" || { echo "durability: FAILED"; exit 1; }
