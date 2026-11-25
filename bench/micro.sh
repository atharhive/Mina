#!/usr/bin/env bash
# Native sync plans against the reference SQL, in process, on one CPU.
#
#   bench/micro.sh [events] [regions]        (default 200000 16; CPU 0, set MICRO_CPU to change)
#
# Needs ./build.sh to have run, sqlite3 and taskset.
set -euo pipefail
cd "$(dirname "$0")/.."
EVENTS=${1:-200000} REGIONS=${2:-16}
SQLITE=$(ls -d vendor/sqlite-amalgamation-*/ | head -1)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# the same compiler flags as the server (build.sh)
cc -O2 -march=native -fno-plt -pthread -Wno-unused-function -o "$TMP/micro_sync" \
  -DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE \
  -DSQLITE_USE_ALLOCA -DSQLITE_DQS=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 \
  -Iruntime -Ibuild -I"$SQLITE" bench/micro_sync.c -lm
sqlite3 "$TMP/m.db" <gen/schema.sql
bin/mina-admin seed --events "$EVENTS" --regions "$REGIONS" --seed 1 | sqlite3 -bail "$TMP/m.db"
echo "events $EVENTS, regions $REGIONS, commit $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
taskset -c "${MICRO_CPU:-0}" "$TMP/micro_sync" "$TMP/m.db" "$REGIONS" 2> >(grep -v '^native read plans' >&2)
