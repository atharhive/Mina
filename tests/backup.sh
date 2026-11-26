#!/usr/bin/env bash
# Backup while the server is writing, and restore: the restored database is consistent, a stale
# write-ahead log is not applied to it, sequence numbers are never reused, and a client that had
# read past the backup misses nothing new. Needs ./build.sh, sqlite3, curl, jq.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${MINA_TEST_PORT:-3917}"; BASE="http://127.0.0.1:$PORT"
TMP="$(mktemp -d)"; PID=; WRITER=
trap '[ -n "$WRITER" ] && kill $WRITER 2>/dev/null; [ -n "$PID" ] && kill -9 $PID 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; fail=$((fail+1)); }
SECRET=0123456789abcdef0123456789abcdef
ADM="$(MINA_SECRET=$SECRET "$ROOT/bin/mina-admin" token --sub 1 --role admin)"
start() {
  MINA_DB="$TMP/live.db" MINA_SECRET=$SECRET MINA_PORT=$PORT "$ROOT/bin/mina-server" >>"$TMP/server.log" 2>&1 & PID=$!
  for _ in $(seq 100); do curl -sf -m 1 -o /dev/null "$BASE/v1/health" && return; sleep 0.1; done
  echo "the server did not start:"; tail -5 "$TMP/server.log"; exit 1
}
n=0
submit() { n=$((n+1)); curl -s -m 2 -H "Authorization: Bearer $ADM" --data-binary '{"eid":"'"$(printf '%032x' $n)"'","kind":1,"region":1,"category":1,"body":"report '"$n"'"}' "$BASE/v1/events"; }
sql() { sqlite3 "$1" "$2"; }
consistent() { # consistent <db> <description>
  local r
  r="$(sql "$1" "PRAGMA integrity_check")"; [ "$r" = ok ] && ok "$2: intact" || bad "$2: integrity" "$r"
  r="$(sql "$1" "SELECT (SELECT count(*) FROM events WHERE kind = 1) - (SELECT count(*) FROM incidents)")"; [ "$r" = 0 ] && ok "$2: one incident per report" || bad "$2: incidents" "$r"; }

sqlite3 "$TMP/live.db" <"$ROOT/gen/schema.sql"
start
for _ in $(seq 300); do submit >/dev/null; done
( for _ in $(seq 2000); do submit >/dev/null || break; n=$((n+1)); done ) & WRITER=$!
sleep 0.3
"$ROOT/tools/backup.sh" "$TMP/live.db" "$TMP/backup.db" >"$TMP/backup.out" 2>&1 && ok "a backup is taken while the server writes" || bad "backup" "$(cat "$TMP/backup.out")"
kill $WRITER 2>/dev/null; wait $WRITER 2>/dev/null; WRITER=
! grep -q 'another connection wrote' "$TMP/server.log" && ok "taking it leaves the native read plans on" || bad "backup counted as a write"
consistent "$TMP/backup.db" backup
saved="$(sql "$TMP/backup.db" 'SELECT max(seq) FROM events')"
[ "$saved" -ge 300 ] && [ "$(sql "$TMP/backup.db" 'SELECT count(*) = max(seq) FROM events')" = 1 ] && ok "the backup is a complete prefix ($saved events)" || bad "backup prefix" "$saved"
"$ROOT/tools/backup.sh" "$TMP/live.db" "$TMP/backup.db" >/dev/null 2>&1 && bad "backup overwrites an existing file" || ok "an existing file is not overwritten"
generation() { curl -s -m 2 -H "Authorization: Bearer $ADM" "$BASE/v1/sync?region=1&limit=1" | jq .generation; }
before="$(generation)"; [ "$before" = 0 ] && ok "a new database is generation 0" || bad "generation" "$before"

n=100000; for _ in $(seq 50); do submit >/dev/null; done                       # accepted after the backup
seen="$(sql "$TMP/live.db" 'SELECT max(seq) FROM events')"                   # a client has read up to here
"$ROOT/tools/restore.sh" "$TMP/backup.db" "$TMP/live.db" >"$TMP/r0" 2>&1 && bad "restore under a running server" || ok "refuses to restore while the server runs"
kill -9 $PID; wait $PID 2>/dev/null; PID=                                    # leaves a write-ahead log behind
[ -s "$TMP/live.db-wal" ] && ok "a stale write-ahead log is present" || bad "expected a write-ahead log"
"$ROOT/tools/restore.sh" "$TMP/backup.db" "$TMP/live.db" >"$TMP/r1" 2>&1 && ok "restore" || bad "restore" "$(cat "$TMP/r1")"
consistent "$TMP/live.db" restored
[ "$(sql "$TMP/live.db" "SELECT count(*) FROM events WHERE seq <= $saved")" = "$saved" ] && [ "$(sql "$TMP/live.db" "SELECT count(*) FROM events WHERE kind = 1 AND body = 'report 100001'")" = 0 ] \
  && ok "holds what the backup held, nothing newer" || bad "restored contents"
ls "$TMP"/live.db.before-restore* >/dev/null 2>&1 && ok "the replaced database is kept aside" || bad "old database not kept"
start
r="$(n=200000; submit)"; new="$(jq .seq <<<"$r")"
[ "$new" -gt "$seen" ] && ok "new events are numbered after anything issued before ($new > $seen)" || bad "sequence reuse" "$r after $seen"
page="$(curl -s -m 2 -H "Authorization: Bearer $ADM" "$BASE/v1/sync?region=1&after=$seen&limit=256")"
[ "$(jq -c '[.events[] | select(.[1] == 1) | .[0]]' <<<"$page")" = "[$new]" ] && ok "a client that had read further receives the new event" || bad "sync after restore" "$page"
after="$(generation)"; [ -n "$after" ] && [ "$after" != null ] && [ "$after" != 0 ] && ok "the restored database announces a new generation ($after)" || bad "generation after restore" "$after"
kill $PID; wait $PID 2>/dev/null; PID=
"$ROOT/tools/restore.sh" "$TMP/backup.db" "$TMP/live.db" >/dev/null 2>&1; start
again="$(generation)"; [ "$again" != "$after" ] && [ "$again" != 0 ] && ok "restoring the same backup again is another generation" || bad "second restore" "$again after $after"
grep -qE 'fatal|runtime error' "$TMP/server.log" && bad "server log" "$(grep -m3 -E 'fatal|runtime' "$TMP/server.log")" || ok "clean server log"
echo "passed=$pass failed=$fail"; [ $fail = 0 ]
