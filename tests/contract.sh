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

# req <method> <path> [token] [json body]  ->  STATUS, BODY, CTYPE
req() {
  : >"$TMP/body"; : >"$TMP/headers"
  local extra=()
  [ -n "${3:-}" ] && extra+=(-H "Authorization: Bearer $3")
  [ -n "${4:-}" ] && extra+=(-H 'Content-Type: application/json' --data-binary "$4")
  STATUS="$(curl -s -m 2 -o "$TMP/body" -D "$TMP/headers" -w '%{http_code}' -X "$1" "${extra[@]}" "$BASE$2")"
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

echo "-- event submission"
token() { MINA_SECRET="$SECRET" "$ADMIN" token "$@"; }
CIT="$(token --sub 100 --role citizen)"; CIT2="$(token --sub 101 --role citizen)"
RESP="$(token --sub 200 --role responder --regions 1,2)"; ADM="$(token --sub 300 --role admin)"
sql() { sqlite3 "$TMP/mina.db" "$1"; }
eid() { printf '%032x' "$1"; }
ev() { req POST /v1/events "$1" "$2"; }   # ev <token> <json>
SOS='{"eid":"'"$(eid 1)"'","kind":1,"region":1,"category":1,"body":"  leg injury\nsecond floor  ","lat":1234567,"lon":-7654321,"at":1790000000}'

ev '' "$SOS";           expect "no token" 401 '{"error":"missing bearer token"}'
ev "${CIT%?}" "$SOS";   expect "damaged token" 401 '{"error":"invalid token"}'
ev "$CIT" "$SOS";       expect "citizen reports an emergency" 201 '{"seq":1,"incident":1}'
ev "$CIT" "$SOS";       expect "retry returns the original" 200 '{"seq":1,"incident":1,"duplicate":true}'
ev "$CIT2" "$SOS";      expect "another identity cannot reuse an event id" 409 '{"error":"event id already used"}'
row="$(sql "SELECT seq,hex(eid),region,vis,kind,incident,category,status IS NULL,actor,at,lat,lon,hex(body) FROM events")"
want="1|$(eid 1 | tr a-f A-F)|1|1|1|1|1|1|100|1790000000|1234567|-7654321|$(printf 'leg injury\nsecond floor' | od -An -tx1 | tr -d ' \n' | tr a-f A-F)"
[ "$row" = "$want" ] && ok "stored once, trimmed and responder-only" || bad "stored row" "got $row want $want"
[ "$(sql 'SELECT id,owner,region,category,status,updated_seq FROM incidents')" = "1|100|1|1|1|1" ] && ok "incident opened" || bad "incident row" "$(sql 'SELECT * FROM incidents')"

ev "$CIT" '{"eid":"'"$(eid 2)"'","kind":5,"region":3,"status":2}';  expect "safety status" 201 '{"seq":2,"incident":null}'
ev "$CIT" '{"eid":"'"$(eid 2)"'","kind":5,"region":3,"status":2}';  expect "safety retry" 200 '{"seq":2,"incident":null,"duplicate":true}'
[ "$(sql 'SELECT vis,kind,status,body IS NULL,lat IS NULL FROM events WHERE seq=2')" = "1|5|2|1|1" ] && ok "safety status is responder-only" || bad "safety row"
ALERT='{"eid":"'"$(eid 3)"'","kind":6,"region":2,"body":"Flood warning: move to higher ground"}'
ev "$CIT" "$ALERT";     expect "citizens cannot publish alerts" 403 '{"error":"not permitted"}'
ev "$RESP" "$ALERT";    expect "responder publishes an alert" 201 '{"seq":3,"incident":null}'
[ "$(sql 'SELECT vis,kind,region,actor FROM events WHERE seq=3')" = "0|6|2|200" ] && ok "alert is public" || bad "alert row"
ev "$RESP" '{"eid":"'"$(eid 4)"'","kind":6,"region":3,"body":"x"}'; expect "responder outside their region" 403 '{"error":"region not authorized"}'
ev "$ADM" '{"eid":"'"$(eid 5)"'","kind":6,"region":1024,"body":"x"}'; expect "admin publishes anywhere" 201 '{"seq":4,"incident":null}'

echo "-- event validation"
E="$(eid 50)"
rej() { ev "${3:-$CIT}" "$1"; expect "rejects $2" 400 "{\"error\":\"$2\"}"; }
rej 'nope' 'invalid json'
rej '[1]' 'invalid json'
rej '{"kind":1,"region":1,"category":1}' 'invalid event id'
rej '{"eid":"abc","kind":1,"region":1,"category":1}' 'invalid event id'
rej '{"eid":"'"${E%?}"'G","kind":1,"region":1,"category":1}' 'invalid event id'
rej '{"eid":"'"$E"'","region":1,"category":1}' 'invalid kind'
rej '{"eid":"'"$E"'","kind":0}' 'invalid kind'
rej '{"eid":"'"$E"'","kind":99}' 'invalid kind'
rej '{"eid":"'"$E"'","kind":"1"}' 'invalid kind'
rej '{"eid":"'"$E"'","kind":1,"category":1}' 'missing or unexpected field'
rej '{"eid":"'"$E"'","kind":1,"region":1}' 'missing or unexpected field'
rej '{"eid":"'"$E"'","kind":1,"region":1,"category":1,"status":1}' 'missing or unexpected field'
rej '{"eid":"'"$E"'","kind":1,"region":1,"category":1,"incident":1}' 'missing or unexpected field'
rej '{"eid":"'"$E"'","kind":1,"region":0,"category":1}' 'invalid region'
rej '{"eid":"'"$E"'","kind":1,"region":1025,"category":1}' 'invalid region'
rej '{"eid":"'"$E"'","kind":1,"region":1.5,"category":1}' 'invalid region'
rej '{"eid":"'"$E"'","kind":1,"region":1,"category":6}' 'invalid category'
rej '{"eid":"'"$E"'","kind":5,"region":1,"status":3}' 'invalid status'
rej '{"eid":"'"$E"'","kind":1,"region":1,"category":1,"lat":1}' 'invalid location'
rej '{"eid":"'"$E"'","kind":1,"region":1,"category":1,"lat":9000001,"lon":0}' 'invalid location'
rej '{"eid":"'"$E"'","kind":1,"region":1,"category":1,"at":-1}' 'invalid time'
rej '{"eid":"'"$E"'","kind":1,"region":1,"category":1,"body":7}' 'invalid body'
rej '{"eid":"'"$E"'","kind":1,"region":1,"category":1,"body":"a\u0000b"}' 'invalid body'
rej '{"eid":"'"$E"'","kind":1,"region":1,"category":1,"body":"'"$(printf 'é%.0s' $(seq 281))"'"}' 'invalid body'
rej '{"eid":"'"$E"'","kind":6,"region":1,"body":" \n "}' 'invalid body' "$RESP"
rej '{"eid":"'"$E"'","kind":6,"region":1}' 'missing or unexpected field' "$RESP"
ev "$CIT" '{"eid":"'"$(eid 6)"'","kind":1,"region":1,"category":5,"body":"'"$(printf 'é%.0s' $(seq 280))"'"}'
expect "280 characters of two bytes each are accepted" 201 '{"seq":5,"incident":5}'
[ "$(sql 'SELECT count(*) FROM events')" = 5 ] && ok "rejected submissions store nothing" || bad "row count" "$(sql 'SELECT count(*) FROM events')"

echo "-- concurrent retries"
D='{"eid":"'"$(eid 7)"'","kind":1,"region":2,"category":2}'
pids=()
for i in $(seq 20); do curl -s -m 5 -o "$TMP/dup$i" -w '%{http_code}' -H "Authorization: Bearer $CIT" --data-binary "$D" "$BASE/v1/events" >"$TMP/code$i" & pids+=($!); done
wait "${pids[@]}"
codes="$(for i in $(seq 20); do cat "$TMP/code$i"; echo; done | sort | uniq -c | tr -s ' \n' ' ')"
seqs="$(for i in $(seq 20); do jq -r .seq "$TMP/dup$i"; done | sort -u | tr '\n' ' ')"
[ "$codes" = " 19 200 1 201 " ] && [ "$seqs" = "6 " ] && [ "$(sql 'SELECT count(*) FROM events WHERE seq > 5')" = 1 ] \
  && ok "20 concurrent copies commit one event" || bad "concurrent retries" "codes '$codes' seqs '$seqs'"

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
