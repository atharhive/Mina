#!/usr/bin/env bash
# Contract tests against a built server (default bin/mina-server). Starts it on a fresh
# temporary database and checks exact response bytes.
#
#   tests/contract.sh [server-binary]
#
# Env: MINA_TEST_PORT (3917). Needs curl and sqlite3.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="${1:-$ROOT/bin/mina-server}"
PORT="${MINA_TEST_PORT:-3917}"
BASE="http://127.0.0.1:$PORT"
TMP="$(mktemp -d)"
PID=
trap 'if [ -n "$PID" ]; then kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; fi; rm -rf "$TMP"' EXIT
[ -x "$SERVER" ] || { echo "no server binary at $SERVER (run ./build.sh)"; exit 1; }

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; fail=$((fail+1)); }

echo "-- configuration"
if env -u MINA_DB -u MINA_SECRET timeout 5 "$SERVER" >/dev/null 2>&1; then bad "refuses to start without MINA_DB and MINA_SECRET"
else ok "refuses to start without MINA_DB and MINA_SECRET"; fi

sqlite3 "$TMP/mina.db" 'PRAGMA user_version = 1;'
MINA_DB="$TMP/mina.db" MINA_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
  MINA_HOST=127.0.0.1 MINA_PORT="$PORT" "$SERVER" >"$TMP/server.log" 2>&1 & PID=$!
for _ in $(seq 100); do curl -sf -m 1 -o /dev/null "$BASE/v1/health" && break; sleep 0.1; done

# req <method> <path>  ->  STATUS, BODY, CTYPE
req() {
  : >"$TMP/body"; : >"$TMP/headers"
  STATUS="$(curl -s -m 2 -o "$TMP/body" -D "$TMP/headers" -w '%{http_code}' -X "$1" "$BASE$2")"
  BODY="$(cat "$TMP/body")"
  CTYPE="$(grep -i '^content-type:' "$TMP/headers" | head -1 | cut -d' ' -f2- | tr -d '\r')"
}
expect() { if [ "$STATUS" = "$2" ] && [ "$BODY" = "$3" ]; then ok "$1 -> $STATUS"; else bad "$1" "want $2 $3, got $STATUS $BODY"; fi; }

echo "-- health and routing"
req GET /v1/health
if [ "$STATUS" = 200 ] && [[ "$BODY" =~ ^\{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":[0-9]+\}$ ]]; then ok "GET /v1/health -> 200 $BODY"; else bad "GET /v1/health" "got $STATUS $BODY"; fi
[ "$CTYPE" = application/json ] && ok "content type" || bad "content type" "got '$CTYPE'"
req GET '/v1/health?probe=1';  [ "$STATUS" = 200 ] && ok "query string is ignored" || bad "query string" "got $STATUS"
req GET /;                     expect "GET /" 404 '{"error":"not found"}'
req GET /v1;                   expect "GET /v1" 404 '{"error":"not found"}'
req GET /v1/healthz;           expect "GET /v1/healthz" 404 '{"error":"not found"}'
req GET /v1/health/x;          expect "GET /v1/health/x" 404 '{"error":"not found"}'
req POST /v1/health;           expect "POST /v1/health" 404 '{"error":"not found"}'
req DELETE /v1/health;         expect "DELETE /v1/health" 404 '{"error":"not found"}'

echo "-- framing"
exec 3<>"/dev/tcp/127.0.0.1/$PORT"
printf 'GET /v1/health HTTP/1.1\r\nHost: x\r\n\r\nGET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' >&3
reply="$(timeout 3 cat <&3)"; exec 3<&- 3>&-
[ "$(grep -o 'HTTP/1.1 [0-9]*' <<<"$reply" | tr '\n' ' ')" = "HTTP/1.1 200 HTTP/1.1 404 " ] && ok "pipelined requests answered in order" || bad "pipelining" "$reply"
exec 3<>"/dev/tcp/127.0.0.1/$PORT"
printf 'garbage\r\n\r\n' >&3
reply="$(timeout 3 cat <&3)"; exec 3<&- 3>&-
grep -q '^HTTP/1.1 400' <<<"$reply" && ok "malformed request -> 400 and close" || bad "malformed request" "$reply"

echo "-- wakeups: sequential new connections must all be accepted"
hung=0
for _ in $(seq 200); do curl -sf -m 1 -o /dev/null "$BASE/v1/health" || hung=$((hung+1)); [ $hung -ge 3 ] && break; done
[ $hung = 0 ] && ok "200 sequential connections" || bad "sequential connections" "$hung requests got no answer within 1 s"

echo "passed=$pass failed=$fail"
[ $fail = 0 ] || { echo "-- server log"; tail -20 "$TMP/server.log"; exit 1; }
