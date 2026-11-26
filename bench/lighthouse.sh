#!/usr/bin/env bash
# Lighthouse on the applications as the server serves them, with the default mobile settings
# (simulated slow 4G and 4x slower CPU). Prints one JSON line per run.
#
#   bench/lighthouse.sh [runs per page]      (default 3)
#
# Needs ./build.sh web, Google Chrome, sqlite3, jq and the frontend's dependencies. Nothing
# else should be running: the scores depend on the machine's free processor time.
set -euo pipefail
cd "$(dirname "$0")/.."
RUNS=${1:-3} PORT=${MINA_TEST_PORT:-4330}
TMP=$(mktemp -d); PID=
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$TMP"' EXIT
sqlite3 "$TMP/m.db" <gen/schema.sql
MINA_DB="$TMP/m.db" MINA_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" MINA_PORT=$PORT bin/mina-server >"$TMP/server.log" 2>&1 & PID=$!
for _ in $(seq 100); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$PORT/v1/health" && break; sleep 0.1; done
curl -sf -m 2 -o /dev/null "http://127.0.0.1:$PORT/" || { echo "no web application: run ./build.sh web" >&2; exit 1; }
for page in / /command/ /observatory/; do
  for run in $(seq "$RUNS"); do
    frontend/citizen/node_modules/.bin/lighthouse "http://127.0.0.1:$PORT$page" --quiet --output=json --output-path="$TMP/r.json" \
      --only-categories=performance,accessibility,best-practices --chrome-flags="--headless=new --no-first-run" >/dev/null 2>&1
    jq -c --arg page "$page" --argjson run "$run" '{page: $page, run: $run, lighthouse: .lighthouseVersion,
      performance: (.categories.performance.score * 100 | round), accessibility: (.categories.accessibility.score * 100 | round),
      best_practices: (.categories["best-practices"].score * 100 | round),
      fcp_ms: (.audits["first-contentful-paint"].numericValue | round), lcp_ms: (.audits["largest-contentful-paint"].numericValue | round),
      tbt_ms: (.audits["total-blocking-time"].numericValue | round), cls: .audits["cumulative-layout-shift"].numericValue,
      bytes: (.audits["total-byte-weight"].numericValue | round),
      failed: [.audits[] | select(.score != null and .score < 0.9 and (.scoreDisplayMode == "binary")) | .id]}' "$TMP/r.json"
  done
done
