#!/usr/bin/env bash
# Fuzzes the code that reads clients' bytes (tests/fuzz.c) under AddressSanitizer and UBSan.
#
#   tests/fuzz.sh [seconds] [seed]        (default 60 1)
#
# Needs ./build.sh to have run (generated code and the SQLite amalgamation).
set -euo pipefail
cd "$(dirname "$0")/.."
SQLITE=$(ls -d vendor/sqlite-amalgamation-*/ | head -1)
mkdir -p build
cc -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all -pthread -Wno-unused-function \
  -DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE \
  -DSQLITE_USE_ALLOCA -DSQLITE_DQS=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 \
  -Iruntime -Ibuild -Ibuild/assets -I"$SQLITE" -o build/fuzz tests/fuzz.c -lm
ASAN_OPTIONS=detect_leaks=1 build/fuzz "${1:-60}" "${2:-1}" && echo "fuzz: ok"
