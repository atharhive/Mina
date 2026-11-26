#!/usr/bin/env bash
# Contract tests against a built server (default bin/mina-server). Starts it on a fresh
# temporary database and checks exact response bytes.
#
#   tests/contract.sh [server-binary]
#
# Env: MINA_TEST_PORT (3917). Needs curl, sqlite3, jq, openssl and bin/mina-admin.
set -uo pipefail
trap '' PIPE    # the server may close a connection the suite is still writing to
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
up=
for _ in $(seq 100); do curl -sf -m 1 -o /dev/null "$BASE/v1/health" && { up=1; break; }; kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
[ -n "$up" ] || { echo "the server did not start:"; cat "$TMP/server.log"; exit 1; }

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
ADMIN="${MINA_ADMIN:-$ROOT/bin/mina-admin}"
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
sqlite3 "$TMP/sync.db" <"$ROOT/gen/schema.sql"
for mode in normal:NORMAL full:FULL; do
  log="$(MINA_DB="$TMP/sync.db" MINA_SECRET="$SECRET" MINA_PORT=$((PORT+3)) MINA_SYNC="${mode%:*}" timeout 1 "$SERVER" 2>&1)"
  grep -q "durability: synchronous=${mode#*:}" <<<"$log" && ok "MINA_SYNC=${mode%:*}" || bad "MINA_SYNC=${mode%:*}" "$log"
  sleep 0.5
done
MINA_DB="$TMP/sync.db" MINA_SECRET="$SECRET" MINA_PORT=$((PORT+3)) MINA_SYNC=off timeout 3 "$SERVER" >/dev/null 2>&1; [ $? = 1 ] && ok "rejects MINA_SYNC=off" || bad "MINA_SYNC=off accepted"

echo "-- health and routing"
req GET /v1/health
if [ "$STATUS" = 200 ] && [[ "$BODY" =~ ^\{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":[0-9]+\}$ ]]; then ok "GET /v1/health -> 200 $BODY"; else bad "GET /v1/health" "got $STATUS $BODY"; fi
[ "$CTYPE" = application/json ] && ok "content type" || bad "content type" "got '$CTYPE'"
req GET '/v1/health?probe=1';  [ "$STATUS" = 200 ] && ok "query string is ignored" || bad "query string" "got $STATUS"
req GET /nothing;              expect "GET /nothing" 404 '{"error":"not found"}'
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
BURST="$(token --sub 102 --role citizen)"
for i in $(seq 20); do curl -s -m 5 -o "$TMP/dup$i" -w '%{http_code}' -H "Authorization: Bearer $BURST" --data-binary "$D" "$BASE/v1/events" >"$TMP/code$i" & pids+=($!); done
wait "${pids[@]}"
codes="$(for i in $(seq 20); do cat "$TMP/code$i"; echo; done | sort | uniq -c | tr -s ' \n' ' ')"
seqs="$(for i in $(seq 20); do jq -r .seq "$TMP/dup$i"; done | sort -u | tr '\n' ' ')"
[ "$codes" = " 19 200 1 201 " ] && [ "$seqs" = "6 " ] && [ "$(sql 'SELECT count(*) FROM events WHERE seq > 5')" = 1 ] \
  && ok "20 concurrent copies commit one event" || bad "concurrent retries" "codes '$codes' seqs '$seqs'"

echo "-- incident transitions"
RESP9="$(token --sub 209 --role responder --regions 9)"
n=1000
act() { n=$((n+1)); LAST='{"eid":"'"$(eid $n)"'","kind":'"$2"',"incident":'"$3${4:+,\"status\":$4}"'}'; ev "$1" "$LAST"; }   # act <token> <kind> <incident> [status]
act "$CIT" 2 1;          expect "citizens cannot acknowledge" 403 '{"error":"not permitted"}'
act "$RESP9" 2 1;        expect "incidents outside the region are not disclosed" 404 '{"error":"no such incident"}'
act "$RESP" 2 999;       expect "unknown incident" 404 '{"error":"no such incident"}'
act "$RESP" 2 2;         expect "a safety report is not an incident" 404 '{"error":"no such incident"}'
act "$RESP" 3 1 3;       expect "no progress before acknowledgement" 409 '{"error":"invalid transition"}'
act "$RESP" 2 1;         expect "acknowledge" 201 '{"seq":7,"incident":1}'; ACK="$LAST"
ev "$RESP" "$ACK";       expect "acknowledge retried" 200 '{"seq":7,"incident":1,"duplicate":true}'
act "$RESP" 2 1;         expect "second acknowledgement" 409 '{"error":"invalid transition"}'
[ "$(sql 'SELECT vis,kind,region,category,status,actor,body IS NULL AND lat IS NULL AND lon IS NULL FROM events WHERE seq=7')" = "0|2|1|1|2|200|1" ] \
  && ok "the public update carries no text or location" || bad "public update row" "$(sql 'SELECT * FROM events WHERE seq=7')"
[ "$(sql 'SELECT status,updated_seq FROM incidents WHERE id=1')" = "2|7" ] && ok "incident state follows" || bad "incident state"
act "$RESP" 3 1 3;       expect "in progress" 201 '{"seq":8,"incident":1}'
act "$RESP" 3 1 2;       expect "stood down to acknowledged" 201 '{"seq":9,"incident":1}'
ev "$RESP" "$ACK";       expect "an old retry stays a duplicate" 200 '{"seq":7,"incident":1,"duplicate":true}'
act "$RESP" 4 1;         expect "resolve" 201 '{"seq":10,"incident":1}'
act "$RESP" 4 1;         expect "resolved is final" 409 '{"error":"invalid transition"}'
act "$RESP" 3 1 3;       expect "no update after resolution" 409 '{"error":"invalid transition"}'
rej '{"eid":"'"$E"'","kind":3,"incident":1,"status":4}' 'invalid status' "$RESP"
rej '{"eid":"'"$E"'","kind":3,"incident":1}' 'missing or unexpected field' "$RESP"
rej '{"eid":"'"$E"'","kind":2,"incident":1,"body":"x"}' 'missing or unexpected field' "$RESP"
rej '{"eid":"'"$E"'","kind":2,"incident":1,"region":1}' 'missing or unexpected field' "$RESP"
rej '{"eid":"'"$E"'","kind":4,"incident":0}' 'invalid incident' "$RESP"

# every (state, action) pair against a table written independently of the server's
declare -A ALLOWED=([1:ack]=1 [1:resolve]=1 [2:set3]=1 [2:resolve]=1 [3:set2]=1 [3:resolve]=1)
wrong=; MATRIX="$(token --sub 103 --role citizen)"
for from in 1 2 3 4; do
  for action in ack set2 set3 resolve; do
    n=$((n+1)); ev "$MATRIX" '{"eid":"'"$(eid $n)"'","kind":1,"region":2,"category":3}'; inc="$(jq -r .incident <<<"$BODY")"
    case $from in 2) act "$RESP" 2 "$inc" ;; 3) act "$RESP" 2 "$inc"; act "$RESP" 3 "$inc" 3 ;; 4) act "$RESP" 4 "$inc" ;; esac
    case $action in ack) act "$RESP" 2 "$inc" ;; set2) act "$RESP" 3 "$inc" 2 ;; set3) act "$RESP" 3 "$inc" 3 ;; resolve) act "$RESP" 4 "$inc" ;; esac
    want=409; [ -n "${ALLOWED[$from:$action]:-}" ] && want=201
    [ "$STATUS" = $want ] || wrong+=" $from:$action=$STATUS"
  done
done
[ -z "$wrong" ] && ok "all 16 state and action pairs" || bad "transition matrix" "$wrong"

n=$((n+1)); ev "$CIT" '{"eid":"'"$(eid $n)"'","kind":1,"region":1,"category":4}'; inc="$(jq -r .incident <<<"$BODY")"
pids=()
for i in $(seq 10); do curl -s -m 5 -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $RESP" --data-binary '{"eid":"'"$(eid $((5000+i)))"'","kind":2,"incident":'"$inc"'}' "$BASE/v1/events" >"$TMP/code$i" & pids+=($!); done
wait "${pids[@]}"
codes="$(cat "$TMP"/code{1..10} | sort | uniq -c | tr -s ' \n' ' ')"
[ "$codes" = " 1 201 9 409 " ] && ok "racing acknowledgements: one wins" || bad "racing acknowledgements" "$codes"

echo "-- regional sync"
sync() { req GET "/v1/sync?$2" "$1"; }    # sync <token> <query>
# What the database holds for a region, as the sync response should list it.
want_events() { sql "SELECT json_group_array(json_array(seq,kind,ts,incident,category,status,body,lat,lon,at)) FROM (SELECT * FROM events WHERE region=$1 AND vis<=$2 AND seq>$3 ORDER BY seq LIMIT $4)" | jq -c .; }
head="$(sql 'SELECT max(seq) FROM events')"
sync '' region=1;                 expect "sync needs a token" 401 '{"error":"missing bearer token"}'
for q in '' region= region=0 region=1025 region=x 'region=1&after=-1' 'region=1&after=x' 'region=1&limit=0' 'region=1&limit=257' 'region=1&after=1234567890123456789' 'region=1&after=-' 'region=-'; do
  sync "$CIT" "$q"; expect "rejects sync?$q" 400 '{"error":"invalid query"}'
done
req GET /v1/sync "$CIT"; expect "rejects sync without a query" 400 '{"error":"invalid query"}'
sync "$CIT" region=1
[ "$STATUS" = 200 ] && [ "$(jq -c .events <<<"$BODY")" = "$(want_events 1 0 0 64)" ] && ok "citizens receive the public stream" || bad "public stream" "$BODY"
jq -e 'all(.events[]; .[1] != 1 and .[1] != 5) and all(.events[] | select(.[1] != 6); .[6] == null and .[7] == null and .[8] == null)' >/dev/null <<<"$BODY" \
  && ok "no reports, safety statuses, text or locations in it" || bad "redaction" "$BODY"
jq -e --argjson h "$head" '.head == $h and .more == false and .next == .events[-1][0]' >/dev/null <<<"$BODY" && ok "head, next and more" || bad "cursor fields" "$BODY"
sync "$RESP" region=1
[ "$(jq -c .events <<<"$BODY")" = "$(want_events 1 1 0 64)" ] && ok "responders receive every event of their region" || bad "responder stream" "$BODY"
sync "$ADM" region=1; [ "$(jq -c .events <<<"$BODY")" = "$(want_events 1 1 0 64)" ] && ok "admins too" || bad "admin stream"
sync "$RESP" region=3; expect "responders stay in their regions" 403 '{"error":"region not authorized"}'
sync "$CIT" "region=1&after=$head";        expect "up to date" 200 '{"head":'"$head"',"generation":0,"events":[],"next":'"$head"',"more":false}'
sync "$CIT" "region=999&after=3";          expect "quiet region keeps its cursor" 200 '{"head":'"$head"',"generation":0,"events":[],"next":3,"more":false}'
sync "$CIT" "region=1&after=$((head+1))";  expect "cursor beyond the head" 409 '{"error":"resync"}'

n=$((n+1)); ev "$ADM" '{"eid":"'"$(eid $n)"'","kind":6,"region":777,"body":"say \"go\"\n→ north \\ ridge","at":7}'; s="$(jq .seq <<<"$BODY")"
t="$(sql "SELECT ts FROM events WHERE seq=$s")"
sync "$CIT" region=777; expect "exact response bytes" 200 '{"head":'"$s"',"generation":0,"events":[['"$s"',6,'"$t"',null,null,null,"say \"go\"\n→ north \\ ridge",null,null,7]],"next":'"$s"',"more":false}'

for i in $(seq 70); do n=$((n+1)); ev "$ADM" '{"eid":"'"$(eid $n)"'","kind":6,"region":600,"body":"alert '"$i"'"}'; done
sync "$CIT" region=600
jq -e '(.events | length) == 64 and .more' >/dev/null <<<"$BODY" && ok "default page is 64 events" || bad "default limit" "$(jq '.events|length' <<<"$BODY")"
for role in "$CIT:0" "$RESP:1"; do
  after=0; all='[]'; pages=0
  while :; do
    sync "${role%:*}" "region=1&after=$after&limit=3"; pages=$((pages+1))
    all="$(jq -c --argjson a "$all" '$a + .events' <<<"$BODY")"; next="$(jq .next <<<"$BODY")"
    [ "$next" -ge "$after" ] || { all=backwards; break; }
    after=$next
    [ "$(jq .more <<<"$BODY")" = true ] && [ $pages -lt 100 ] || break
  done
  [ "$all" = "$(want_events 1 "${role##*:}" 0 1000)" ] && ok "pages of 3 deliver every event once, in order (vis <= ${role##*:}, $pages pages)" || bad "pagination" "$all"
done

echo "-- incident retrieval"
n=$((n+1)); ev "$CIT" '{"eid":"'"$(eid $n)"'","kind":1,"region":2,"category":5,"body":"no water","lat":10,"lon":-20,"at":99}'
inc="$(jq .incident <<<"$BODY")"; t="$(sql "SELECT ts FROM events WHERE seq=$inc")"
SUMMARY='"id":'"$inc"',"region":2,"category":5,"status":1,"updated_seq":'"$inc"
req GET "/v1/incidents/$inc";          expect "incident needs a token" 401 '{"error":"missing bearer token"}'
req GET "/v1/incidents/$inc" "$CIT";   expect "the reporter sees the summary" 200 "{$SUMMARY}"
req GET "/v1/incidents/$inc" "$RESP";  expect "a responder sees the report" 200 "{$SUMMARY"',"report":{"ts":'"$t"',"at":99,"body":"no water","lat":10,"lon":-20}}'
req GET "/v1/incidents/$inc" "$ADM";   [ "$STATUS" = 200 ] && jq -e .report >/dev/null <<<"$BODY" && ok "an admin sees the report" || bad "admin view" "$BODY"
act "$RESP" 2 "$inc"; u="$(jq .seq <<<"$BODY")"
req GET "/v1/incidents/$inc" "$CIT";   expect "status follows updates" 200 '{"id":'"$inc"',"region":2,"category":5,"status":2,"updated_seq":'"$u"'}'
for who in "$CIT2:another citizen" "$RESP9:a responder of another region"; do
  req GET "/v1/incidents/$inc" "${who%:*}"; expect "hidden from ${who##*:}" 404 '{"error":"no such incident"}'
done
for id in 0 999999 2 abc -1 1234567890123456789 "$inc.5"; do
  req GET "/v1/incidents/$id" "$ADM"; expect "no incident $id" 404 '{"error":"no such incident"}'
done
req GET /v1/incidents "$ADM"; expect "no incident listing" 404 '{"error":"not found"}'

echo "-- rate limits"
report() { n=$((n+1)); ev "$1" '{"eid":"'"$(eid $n)"'","kind":5,"region":50,"status":1}'; }
FLOOD="$(token --sub 900 --role citizen)"; accepted=0; limited=0; other=
for i in $(seq 40); do report "$FLOOD"; case $STATUS in 201) accepted=$((accepted+1)) ;; 429) limited=$((limited+1)) ;; *) other=$STATUS ;; esac; done
[ -z "$other" ] && [ $accepted -ge 30 ] && [ $accepted -le 33 ] && [ $limited = $((40-accepted)) ] \
  && ok "a citizen may send a burst of 30, then is limited ($accepted accepted)" || bad "citizen limit" "accepted $accepted limited $limited other $other"
for i in 1 2 3; do report "$FLOOD"; [ $STATUS = 429 ] && break; done      # a second may pass and refill one
expect "limited answer" 429 '{"error":"too many requests"}'
[ "$(sql 'SELECT count(*) FROM events WHERE actor=900 AND seq > 0')" -le $((accepted+1)) ] && ok "limited submissions store nothing" || bad "limited rows"
report "$(token --sub 901 --role citizen)"; [ $STATUS = 201 ] && ok "another citizen is unaffected" || bad "isolation" "$STATUS"
sleep 2.1; report "$FLOOD"; [ $STATUS = 201 ] && ok "the budget refills" || bad "refill" "$STATUS"
other=
for i in $(seq 40); do n=$((n+1)); ev "$RESP" '{"eid":"'"$(eid $n)"'","kind":6,"region":1,"body":"x"}'; [ $STATUS = 201 ] || other=$STATUS; done
[ -z "$other" ] && ok "responders are not limited" || bad "responder limited" "$other"
exec 3<>"/dev/tcp/127.0.0.1/$PORT"
{ for i in $(seq 600); do printf 'POST /v1/session HTTP/1.1\r\nHost: x\r\n\r\n'; done; printf 'GET /v1/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'; } >&3
reply="$(timeout 5 cat <&3)"; exec 3<&- 3>&-
made="$(grep -o 'HTTP/1.1 201' <<<"$reply" | wc -l)"; refused="$(grep -o 'HTTP/1.1 429' <<<"$reply" | wc -l)"
[ $((made+refused)) = 600 ] && [ "$made" -ge 100 ] && [ "$made" -le 450 ] && ok "new sessions are limited server-wide ($made of 600)" || bad "session limit" "made $made refused $refused"

echo "-- metrics"
m() { req GET /v1/metrics "$ADM"; cp "$TMP/body" "$TMP/$1.json"; }
diff_of() { echo $(( $(jq "$1" "$TMP/b.json") - $(jq "$1" "$TMP/a.json") )); }
grew() { local got; got="$(diff_of "$2" 2>/dev/null)"; [ "$got" = "$3" ] && ok "$1" || bad "$1" "$2 changed by '$got', want $3"; }
req GET /v1/metrics;            expect "metrics need a token" 401 '{"error":"missing bearer token"}'
req GET /v1/metrics "$CIT";     expect "citizens may not read metrics" 403 '{"error":"not permitted"}'
req GET /v1/metrics "$RESP";    expect "nor responders" 403 '{"error":"not permitted"}'
MET="$(token --sub 104 --role citizen)"
m a; [ "$STATUS" = 200 ] && jq -e '.runtime and .db and .process and .app' "$TMP/a.json" >/dev/null 2>&1 && ok "an admin reads them" || bad "metrics" "$STATUS $BODY"
head="$(sql 'SELECT max(seq) FROM events')"
for i in 1 2 3; do sync "$CIT" "region=1&after=$head"; done          # up to date
sync "$CIT" "region=1&after=0&limit=2"; size="$(wc -c <"$TMP/body")" # has events
D='{"eid":"'"$(eid 9001)"'","kind":5,"region":60,"status":1}'
ev "$MET" "$D"; ev "$MET" "$D"                                      # stored, then a retry
ev "${MET%?}" "$D"                                                   # refused token
req GET /nothing
m b
grew "requests are counted" .runtime.requests 9
grew "answers by class: success" .runtime.status_2xx 7
grew "answers by class: client error" .runtime.status_4xx 2
grew "stored events" .app.events_stored 1
grew "duplicate retries" .app.duplicates 1
grew "refused tokens" .app.auth_refused 1
grew "one transaction per batch that touched the database" .db.commits 7
[ $(( $(diff_of .app.sync_native) + $(diff_of .app.sync_quiet) + $(diff_of .app.sync_sql) )) = 4 ] && ok "every sync is counted once" || bad "sync counts" "$(jq -c .app "$TMP/b.json")"
if [ "$(jq .app.native_on "$TMP/b.json")" = 1 ]; then grew "up-to-date answers skip the B-tree" .app.sync_quiet 3; grew "the others use the native plan" .app.sync_native 1
else grew "with SQL forced, SQL answers" .app.sync_sql 4; fi
[ "$(diff_of .app.sync_bytes)" -ge "$size" ] && ok "sync payload bytes" || bad "sync bytes" "$(diff_of .app.sync_bytes) < $size"
jq -e '.runtime.connections_open >= 1 and .runtime.rings >= 1 and .runtime.uptime_s >= 0 and .process.rss_bytes > 1000000 and .process.cpu_user_us + .process.cpu_system_us > 0 and .app.head_seq > 0 and .db.wal_frames >= 0' "$TMP/b.json" >/dev/null 2>&1 \
  && ok "gauges are plausible" || bad "gauges" "$(cat "$TMP/b.json")"
jq -e '(.runtime.batch_us.bounds | length) == (.runtime.batch_us.counts | length) and (.runtime.batch_us.counts | add) == .runtime.jobs and (.app.native_ns.counts | add) == .app.sync_native' "$TMP/b.json" >/dev/null 2>&1 \
  && ok "histograms add up" || bad "histograms" "$(jq -c '.runtime.batch_us, .runtime.jobs' "$TMP/b.json")"
sleep 0.3; exec 3<>"/dev/tcp/127.0.0.1/$PORT"; sleep 0.3; m b; held="$(jq .runtime.connections_open "$TMP/b.json")"; exec 3<&- 3>&-; sleep 0.3; m a; after="$(jq .runtime.connections_open "$TMP/a.json")"
[ $((held - after)) = 1 ] && ok "open connections rise and fall" || bad "open connections" "$held then $after"

echo "-- bounded queues"
BIG="$(printf '\\"%.0s' $(seq 280))"
for i in $(seq 200); do n=$((n+1)); ev "$ADM" '{"eid":"'"$(eid $n)"'","kind":6,"region":650,"body":"'"$BIG"'"}'; done
sync "$CIT" 'region=650&limit=256'; size="$(wc -c <"$TMP/body")"
peak() { awk '/VmHWM/ {print $2}' "/proc/$PID/status"; }
before="$(peak)"
one="$(printf 'GET /v1/sync?region=650&limit=256 HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer %s' "$CIT")"   # no blank line yet
exec 3<>"/dev/tcp/127.0.0.1/$PORT"
{ for i in $(seq 199); do printf '%s\r\n\r\n' "$one"; done; printf '%s\r\nConnection: close\r\n\r\n' "$one"; } >&3
sleep 1.5; grown=$(( $(peak) - before ))
if grep -q __asan_init "$SERVER"; then echo "  skip bounded memory: resident size under AddressSanitizer says nothing about the queue"
elif [ "$grown" -lt 8192 ]; then ok "a client that is not reading costs bounded memory (server grew $grown KiB for $((200*size/1024)) KiB of answers)"
else bad "unbounded output queue" "peak memory grew $grown KiB"; fi
start=$(date +%s%N)
got="$(timeout 10 cat <&3 | grep -o 'HTTP/1.1 200' | wc -l)"; exec 3<&- 3>&-
[ "$got" = 200 ] && ok "it gets all 200 answers once it reads ($(( ($(date +%s%N) - start) / 1000000 )) ms)" || bad "backpressure" "$got of 200 answers"
exec 3<>"/dev/tcp/127.0.0.1/$PORT"
{ for i in $(seq 400); do printf '%s\r\n\r\n' "$one"; done; } >&3 2>/dev/null
timeout 5 cat <&3 >/dev/null 2>&1; [ $? != 124 ] && ok "a client that keeps sending without reading is disconnected" || bad "input bound"
exec 3<&- 3>&-
req GET /v1/health; [ "$STATUS" = 200 ] && ok "server is healthy afterwards" || bad "health after flood" "$STATUS"

echo "-- idle connections"
IPORT=$((PORT+2))
sqlite3 "$TMP/idle.db" <"$ROOT/gen/schema.sql"
MINA_DB="$TMP/idle.db" MINA_SECRET="$SECRET" MINA_PORT=$IPORT MINA_IDLE_S=2 "$SERVER" >"$TMP/idle.log" 2>&1 & IPID=$!
for _ in $(seq 100); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$IPORT/v1/health" && break; sleep 0.1; done
ms() { echo $(( $(date +%s%N) / 1000000 )); }
# closes <description>: the server must close fd 3 between 1 and 6 seconds from now
closes() { local t=$(ms); timeout 8 cat <&3 >/dev/null 2>&1; local rc=$? d=$(( $(ms) - t )); exec 3<&- 3>&-
  [ $rc != 124 ] && [ $d -ge 900 ] && [ $d -le 6000 ] && ok "$1 (after $d ms)" || bad "$1" "exit $rc after $d ms"; }
exec 3<>"/dev/tcp/127.0.0.1/$IPORT"; closes "a silent connection is closed"
exec 3<>"/dev/tcp/127.0.0.1/$IPORT"; printf 'GET /v1/health HTTP/1.1\r\n' >&3
( for i in $(seq 7); do sleep 1; printf 'X-Slow: %s\r\n' $i >&3 || break; done ) 2>/dev/null & trickle=$!
closes "a request that trickles in is not waited for"; kill $trickle 2>/dev/null; wait $trickle 2>/dev/null
exec 3<>"/dev/tcp/127.0.0.1/$IPORT"
for i in $(seq 5); do printf 'GET /v1/health HTTP/1.1\r\nHost: x\r\n\r\n' >&3; sleep 1; done
printf 'GET /v1/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' >&3
got="$(timeout 3 cat <&3 | grep -o 'HTTP/1.1 200' | wc -l)"; exec 3<&- 3>&-
[ "$got" = 6 ] && ok "a connection in use stays open" || bad "active connection closed" "$got of 6"
kill $IPID; wait $IPID 2>/dev/null
MINA_DB="$TMP/idle.db" MINA_SECRET="$SECRET" MINA_PORT=$IPORT MINA_IDLE_S=0 timeout 3 "$SERVER" >/dev/null 2>&1; [ $? = 1 ] && ok "rejects MINA_IDLE_S=0" || bad "MINA_IDLE_S=0 accepted"

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

echo "-- after the run"
kill -0 "$PID" 2>/dev/null && ok "the server is still running" || bad "the server died"
! grep -qE 'runtime error|ERROR: [A-Za-z]*Sanitizer|batch rolled back' "$TMP"/*.log && ok "no sanitizer report or failed batch in the logs" \
  || bad "server log" "$(grep -hE -m3 'runtime error|Sanitizer|batch rolled back' "$TMP"/*.log)"
echo "passed=$pass failed=$fail"
[ $fail = 0 ] || { echo "-- server log"; tail -20 "$TMP/server.log"; exit 1; }
