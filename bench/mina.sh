#!/usr/bin/env bash
# One load step of the MINA workload (bench/workload_mina.h) against a freshly seeded database.
#
#   bench/mina.sh <users> <ramp_s> <hold_s> <rampdown_s> [native|sql]
#
# The server runs as in bench/run.sh: alone on one CPU inside a 2 GB memory cgroup, over
# loopback. Env: EVENTS (200000) and REGIONS (64) for the seed, RESULTS (results/mina-load,
# on a real disk: the database is written there). Prints one JSON line and appends it to
# $RESULTS/steps.jsonl. Needs ./build.sh to have run.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 4 ] || { sed -n '2,9p' "$0"; exit 2; }
USERS=$1 RAMP=$2 HOLD=$3 DOWN=$4 MODE=${5:-native}
EVENTS=${EVENTS:-200000} REGIONS=${REGIONS:-64} RESULTS=${RESULTS:-results/mina-load}
case $MODE in native) FORCE= ;; sql) FORCE=1 ;; *) echo "mode: native or sql" >&2; exit 2 ;; esac
mkdir -p "$RESULTS"
cc -O2 -pthread -Wno-unused-function -DWORKLOAD='"workload_mina.h"' -Ibench -Iruntime -Igen -o bin/loadgen-mina bench/loadgen.c bench/sign.c
DB="$RESULTS/mina.db"
rm -f "$DB" "$DB-wal" "$DB-shm"
sqlite3 "$DB" <gen/schema.sql
bin/mina-admin seed --events "$EVENTS" --regions "$REGIONS" --seed 1 | sqlite3 -bail "$DB"
sync
SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
LOG="$RESULTS/server-$USERS-$MODE.log"
line=$(MINA_DB="$DB" MINA_SECRET="$SECRET" MINA_PORT=3000 MINA_FORCE_SQL="$FORCE" SERVER_LOG="$LOG" \
  WORKLOAD_ARG="$SECRET:$EVENTS:$REGIONS" bench/run.sh bin/loadgen-mina "$USERS" "$RAMP" "$HOLD" "$DOWN" -- bin/mina-server)
want="native read plans: $([ "$MODE" = native ] && echo on || echo off)"
grep -q "$want" "$LOG" || { echo "server did not report '$want'" >&2; exit 1; }
if grep -qE 'native plan failed|another connection|batch rolled back|checkpointed in the request thread' "$LOG"; then
  echo "server log has warnings:" >&2; grep -m5 -E 'native|another|rolled|wal:' "$LOG" >&2
fi
events=$(sqlite3 "$DB" 'SELECT count(*) FROM events')
jq -c --arg mode "$MODE" --arg commit "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" --argjson ev "$EVENTS" --argjson end "$events" \
  '. + {mode: $mode, commit: $commit, events_at_start: $ev, events_at_end: $end}' <<<"$line" | tee -a "$RESULTS/steps.jsonl"
