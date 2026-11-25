#!/usr/bin/env bash
# Contract tests against a built server (default bin/mina-server). Starts it on a fresh
# temporary database and checks exact response bytes.
#
#   tests/contract.sh [server-binary]
#
# Env: MINA_TEST_PORT (3917). Needs curl, sqlite3, jq, openssl and bin/mina-admin.
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

SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
sqlite3 "$TMP/empty.db" 'PRAGMA user_version = 1;'
MINA_DB="$TMP/empty.db" MINA_SECRET="$SECRET" MINA_PORT="$PORT" timeout 5 "$SERVER" >/dev/null 2>&1; rc=$?
[ $rc != 0 ] && [ $rc != 124 ] && ok "refuses a database without the MINA schema" || bad "database without schema" "exit $rc"

sqlite3 "$TMP/mina.db" <"$ROOT/gen/schema.sql" || { echo "cannot apply gen/schema.sql"; exit 1; }
MINA_DB="$TMP/mina.db" MINA_SECRET="$SECRET" \
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

echo "-- operator tool"
ADMIN="$ROOT/bin/mina-admin"
unb64() { local s="${1//-/+}"; s="${s//_//}"; while (( ${#s} % 4 )); do s+="="; done; base64 -d <<<"$s"; }
TOKEN="$(MINA_SECRET="$SECRET" "$ADMIN" token --sub 42 --role responder --regions 1,7 --ttl 600 2>/dev/null)"
IFS=. read -r th tp ts <<<"$TOKEN"
want="$(printf '%s' "$th.$tp" | openssl dgst -sha256 -hmac "$SECRET" -binary | base64 | tr '+/' '-_' | tr -d '=\n')"
[ -n "$ts" ] && [ "$ts" = "$want" ] && ok "token signature matches openssl" || bad "token signature" "got '$ts' want '$want'"
claims="$(unb64 "$tp" 2>/dev/null)"
jq -e --argjson now "$(date +%s)" '.sub == "42" and .role == 2 and .rg == "1,7" and .exp > $now and .exp <= $now + 601' >/dev/null 2>&1 <<<"$claims" \
  && ok "token claims" || bad "token claims" "$claims"
for args in "--sub 1 --role king" "--sub 0 --role citizen" "--role citizen" "--sub 1 --role responder --regions 0" "--sub 1 --role responder --regions 1025" "--sub 1 --role citizen --ttl -5"; do
  if MINA_SECRET="$SECRET" "$ADMIN" token $args >/dev/null 2>&1; then bad "mina-admin accepts: $args"; else ok "mina-admin rejects: $args"; fi
done
if env -u MINA_SECRET "$ADMIN" token --sub 1 --role citizen >/dev/null 2>&1; then bad "mina-admin without MINA_SECRET"; else ok "mina-admin requires MINA_SECRET"; fi
if MINA_DB="$TMP/mina.db" MINA_SECRET=short MINA_PORT=$((PORT+1)) timeout 3 "$SERVER" >/dev/null 2>&1; [ $? = 1 ]; then ok "server rejects a secret under 32 bytes"; else bad "short secret accepted"; fi

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

echo "-- sessions"
req POST /v1/session
[ "$STATUS" = 201 ] && jq -e '(keys == ["exp","sub","token"]) and (.sub | test("^[1-9][0-9]{0,14}$"))' >/dev/null 2>&1 <<<"$BODY" \
  && ok "POST /v1/session -> 201" || bad "POST /v1/session" "got $STATUS $BODY"
first="$(jq -r .sub 2>/dev/null <<<"$BODY")"
IFS=. read -r th tp ts <<<"$(jq -r .token 2>/dev/null <<<"$BODY")"
[ -n "$ts" ] && [ "$ts" = "$(printf '%s' "$th.$tp" | openssl dgst -sha256 -hmac "$SECRET" -binary | base64 | tr '+/' '-_' | tr -d '=\n')" ] \
  && ok "session token is signed with the server key" || bad "session signature" "$BODY"
jq -e --argjson b "$BODY" '.role == 1 and .sub == $b.sub and .exp == $b.exp and (has("rg") | not)' >/dev/null 2>&1 <<<"$(unb64 "$tp" 2>/dev/null)" \
  && ok "session token is a citizen token" || bad "session claims" "$(unb64 "$tp" 2>/dev/null)"
req POST /v1/session; [ "$(jq -r .sub 2>/dev/null <<<"$BODY")" != "$first" ] && ok "every session gets a new identity" || bad "session identity" "$BODY"
req GET /v1/session; expect "GET /v1/session" 404 '{"error":"not found"}'

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
