#!/usr/bin/env bash
# Builds the server and the operator tool:
#   1. Lean checks the specification (spec/) and generates the application layer. The build
#      stops if a checked-in file in gen/ differs from what the specification generates.
#   2. The C compiler builds one translation unit: SQLite (pinned, checksummed), the runtime,
#      and the generated code.
#
#   ./build.sh            optimised binaries (no web application: GET / answers 404)
#   ./build.sh web        the same, with the web applications compiled into the server
#                         (needs node and pnpm). MINA_WEB=<dir> embeds another directory.
#   ./build.sh sanitize   bin/mina-server-san and bin/mina-admin-san, with ASan and UBSan
#
# Needs: elan/lake (or LAKE=/path/to/lake), a C compiler, curl, unzip, sha256sum.
set -euo pipefail
cd "$(dirname "$0")"
LAKE="${LAKE:-$(command -v lake || echo "$HOME/.elan/bin/lake")}"
[ -x "$LAKE" ] || { echo "lake not found: install elan (see README.md) or set LAKE" >&2; exit 1; }
SQLITE=sqlite-amalgamation-3540100
SQLITE_SHA256=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9

mkdir -p vendor bin build
if [ ! -f "vendor/$SQLITE/sqlite3.c" ]; then
  curl -fsSL --retry 3 -o "vendor/$SQLITE.zip" "https://sqlite.org/2026/$SQLITE.zip"
  echo "$SQLITE_SHA256  vendor/$SQLITE.zip" | sha256sum -c -
  unzip -q -o "vendor/$SQLITE.zip" -d vendor
fi

echo "== lean: check the specification and derive the application layer"
(cd spec && "$LAKE" build && "$LAKE" exe derive ../build)
for f in app_gen.c domain.h protocol.ts queries.sql schema.sql; do
  if ! cmp -s "build/$f" "gen/$f"; then
    echo "gen/$f is not what spec/ generates; run: (cd spec && lake exe derive ../gen)" >&2
    diff -u "gen/$f" "build/$f" | head -40
    exit 1
  fi
done

WEB=
case "${1:-}" in
  "")       SUF=;     OPT=(-O2 -march=native -fno-plt) ;;
  web)      SUF=;     OPT=(-O2 -march=native -fno-plt); WEB=build/web
            echo "== web: build the citizen (/) and responder (/command/) applications"
            (cd frontend && pnpm install --frozen-lockfile --silent \
              && pnpm --silent --dir citizen build >/dev/null && pnpm --silent --dir command build >/dev/null)
            rm -rf build/web && mkdir -p build/web
            cp -r frontend/citizen/dist/. build/web/ && cp -r frontend/command/dist build/web/command ;;
  sanitize) SUF=-san; OPT=(-O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all) ;;
  *) echo "usage: ./build.sh [web|sanitize]" >&2; exit 2 ;;
esac
WEB="${MINA_WEB:-$WEB}"
SUF="${MINA_SUFFIX:-$SUF}"
mkdir -p "build/assets$SUF"
if [ -n "$WEB" ]; then
  node tools/embed-assets.mjs "$WEB" >"build/assets$SUF/assets_gen.h"
else
  printf 'static const asset ASSETS[1];\n#define ASSET_COUNT 0\n' >"build/assets$SUF/assets_gen.h"
fi

echo "== cc"
cc "${OPT[@]}" -pthread -o "bin/mina-server$SUF" \
  -DSQLITE_THREADSAFE=2 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE \
  -DSQLITE_USE_ALLOCA -DSQLITE_DQS=0 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 \
  -Iruntime -Ibuild -I"build/assets$SUF" -I"vendor/$SQLITE" runtime/server.c -lm
cc "${OPT[@]}" -Iruntime -Ibuild -Itools -o "bin/mina-admin$SUF" tools/mina-admin.c
echo "built bin/mina-server$SUF bin/mina-admin$SUF"
