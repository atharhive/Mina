#!/usr/bin/env bash
# No statement the server runs may scan a table or sort. Uses the bundled SQLite, so run
# ./build.sh first (it downloads the amalgamation).
set -euo pipefail
cd "$(dirname "$0")/.."
SQLITE=$(ls -d vendor/sqlite-amalgamation-*/ | head -1)
mkdir -p build
[ build/sqlite3.o -nt "${SQLITE}sqlite3.c" ] || cc -O1 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -c "${SQLITE}sqlite3.c" -o build/sqlite3.o
cc -O1 -Wall -I"$SQLITE" -o build/plans tests/plans.c build/sqlite3.o -lm
# statements may only be prepared from the specification (the health check excepted)
if grep -n 'db_prepare("' spec/Mina/templates/app.c | grep -v 'db_prepare("SELECT 1")'; then echo "  FAIL SQL written in the template is not checked here"; exit 1; fi
build/plans gen/schema.sql gen/queries.sql
