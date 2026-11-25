#!/usr/bin/env bash
# The synthetic data generator (mina-admin seed): deterministic, and a history the server could
# have produced. Needs bin/mina-admin, bin/mina-server, sqlite3, curl and jq.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADMIN="$ROOT/bin/mina-admin"; SERVER="$ROOT/bin/mina-server"
PORT="${MINA_TEST_PORT:-3917}"
TMP="$(mktemp -d)"; PID=
trap 'if [ -n "$PID" ]; then kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; fi; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; fail=$((fail+1)); }
sql() { sqlite3 "$TMP/a.db" "$1"; }
is() { local got; got="$(sql "$2")"; [ "$got" = "$3" ] && ok "$1" || bad "$1" "want $3, got $got"; }

"$ADMIN" seed --events 20000 --regions 8 --seed 7 >"$TMP/a.sql" 2>"$TMP/err" || bad "seed runs" "$(cat "$TMP/err")"
"$ADMIN" seed --events 20000 --regions 8 --seed 7 >"$TMP/b.sql" 2>/dev/null
"$ADMIN" seed --events 20000 --regions 8 --seed 8 >"$TMP/c.sql" 2>/dev/null
[ -s "$TMP/a.sql" ] && cmp -s "$TMP/a.sql" "$TMP/b.sql" && ok "same seed, same bytes" || bad "determinism"
! cmp -s "$TMP/a.sql" "$TMP/c.sql" && ok "another seed, other data" || bad "seed ignored"
sqlite3 "$TMP/a.db" <"$ROOT/gen/schema.sql" && sqlite3 -bail "$TMP/a.db" <"$TMP/a.sql" && ok "applies to an empty database" || bad "apply"
is "20000 events, numbered 1..20000" 'SELECT count(*), min(seq), max(seq) FROM events' '20000|1|20000'
is "every kind occurs" 'SELECT group_concat(kind) FROM (SELECT DISTINCT kind FROM events ORDER BY kind)' '1,2,3,4,5,6'
is "all 8 regions, nothing else" 'SELECT count(DISTINCT region), min(region), max(region) FROM events' '8|1|8'
is "reports and safety statuses are restricted" 'SELECT count(*) FROM events WHERE vis != (kind IN (1, 5))' 0
is "public updates carry no text or location" 'SELECT count(*) FROM events WHERE kind IN (2, 3, 4) AND (body IS NOT NULL OR lat IS NOT NULL OR lon IS NOT NULL)' 0
is "one incident per report" 'SELECT (SELECT count(*) FROM incidents) - (SELECT count(*) FROM events WHERE kind = 1)' 0
is "reports open their own incident" 'SELECT count(*) FROM events WHERE kind = 1 AND incident IS NOT seq' 0
is "incidents agree with their last event" "SELECT count(*) FROM incidents i LEFT JOIN events e ON e.seq = i.updated_seq WHERE e.incident IS NOT i.id OR e.region != i.region OR e.category != i.category
    OR i.status != (CASE WHEN e.kind = 1 THEN 1 ELSE e.status END) OR EXISTS (SELECT 1 FROM events x WHERE x.incident = i.id AND x.seq > i.updated_seq)" 0
is "only permitted transitions" "WITH h AS (SELECT incident, seq, kind, CASE WHEN kind = 1 THEN 1 ELSE status END AS s FROM events WHERE incident IS NOT NULL),
  t AS (SELECT kind, s, lag(s) OVER (PARTITION BY incident ORDER BY seq) AS p FROM h)
  SELECT count(*) FROM t WHERE NOT ((p IS NULL AND kind = 1) OR (kind = 2 AND p = 1 AND s = 2) OR (kind = 3 AND ((p = 2 AND s = 3) OR (p = 3 AND s = 2))) OR (kind = 4 AND p IN (1, 2, 3) AND s = 4))" 0
for args in "--events 0" "--events x" "--regions 1025" "--bogus 1" "--seed"; do
  "$ADMIN" seed $args >/dev/null 2>&1 && bad "seed accepts $args" || ok "seed rejects $args"
done
SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
MINA_DB="$TMP/a.db" MINA_SECRET="$SECRET" MINA_PORT="$PORT" "$SERVER" >"$TMP/server.log" 2>&1 & PID=$!
for _ in $(seq 100); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$PORT/v1/health" && break; sleep 0.1; done
T="$(MINA_SECRET="$SECRET" "$ADMIN" token --sub 1 --role admin)"
got="$(curl -s -m 2 -H "Authorization: Bearer $T" "http://127.0.0.1:$PORT/v1/sync?region=3&after=19000&limit=256" | jq -c '[.events[][0]]')"
want="$(sql 'SELECT json_group_array(seq) FROM (SELECT seq FROM events WHERE region = 3 AND seq > 19000 ORDER BY seq LIMIT 256)' | jq -c .)"
[ -n "$got" ] && [ "$got" = "$want" ] && ok "the server serves the seeded data" || bad "sync over seed" "$got / $want"

echo "passed=$pass failed=$fail"
[ $fail = 0 ]
