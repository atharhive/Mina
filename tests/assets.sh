#!/usr/bin/env bash
# The server serving a built web application from memory. Builds bin/mina-server-test with a
# small fixture application. Needs node, curl, sqlite3, gzip. MINA_BUILD=sanitize for ASan.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${MINA_TEST_PORT:-3917}"; BASE="http://127.0.0.1:$PORT"
TMP="$(mktemp -d)"; PID=
trap 'if [ -n "$PID" ]; then kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; fi; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; fail=$((fail+1)); }

web="$TMP/web"; mkdir -p "$web/assets"
{ echo '<!doctype html><title>fixture</title>'; for i in $(seq 40); do echo "<p>line $i of a page that compresses well</p>"; done; } >"$web/index.html"
head -c 200000 /dev/urandom | base64 >"$web/assets/app-Ab3dEf12.js"      # larger than one socket write
printf 'x' >"$web/assets/tiny-0000.css"                                  # would grow if compressed
echo '// worker' >"$web/sw.js"
printf '{"name":"f"}' >"$web/manifest.webmanifest"
mkdir -p "$web/command/assets"; echo '<title>second app</title>' >"$web/command/index.html"; echo '1' >"$web/command/assets/c-1111.js"
MINA_WEB="$web" MINA_SUFFIX=-test "$ROOT/build.sh" ${MINA_BUILD:-} >"$TMP/build.log" 2>&1 || { echo "build failed:"; tail -20 "$TMP/build.log"; exit 1; }

sqlite3 "$TMP/m.db" <"$ROOT/gen/schema.sql"
MINA_DB="$TMP/m.db" MINA_SECRET=0123456789abcdef0123456789abcdef MINA_PORT=$PORT "$ROOT/bin/mina-server-test" >"$TMP/server.log" 2>&1 & PID=$!
up=; for _ in $(seq 100); do curl -sf -m 1 -o /dev/null "$BASE/v1/health" && { up=1; break; }; sleep 0.1; done
[ -n "$up" ] || { echo "the server did not start:"; cat "$TMP/server.log"; exit 1; }

get() { # get <path> [curl args...]  ->  STATUS, $TMP/body, $TMP/headers
  local path=$1; shift; : >"$TMP/body"
  STATUS="$(curl -s -m 5 --path-as-is -o "$TMP/body" -D "$TMP/headers" -w '%{http_code}' "$@" "$BASE$path")"; }
header() { grep -i "^$1:" "$TMP/headers" | head -1 | cut -d' ' -f2- | tr -d '\r'; }
is() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want '$3', got '$2'"; }

get /; is "GET / is the page" "$STATUS" 200; cmp -s "$TMP/body" "$web/index.html" && ok "with exactly its bytes" || bad "index bytes"
is "html type" "$(header content-type)" "text/html; charset=utf-8"
is "the page is revalidated" "$(header cache-control)" "no-cache"
is "no encoding unless asked" "$(header content-encoding)" ""
is "content security policy" "$(header content-security-policy)" "default-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
is "no type sniffing" "$(header x-content-type-options)" "nosniff"
etag="$(header etag)"; [ -n "$etag" ] && ok "has an entity tag" || bad "entity tag"
get / -H "If-None-Match: $etag"; is "unchanged page is not sent again" "$STATUS" 304; is "304 has no body" "$(wc -c <"$TMP/body")" 0
get / -H 'If-None-Match: W/"0000000000000000"'; is "another tag gets the page" "$STATUS" 200
get /index.html; cmp -s "$TMP/body" "$web/index.html" && ok "GET /index.html" || bad "index.html"

get /assets/app-Ab3dEf12.js; cmp -s "$TMP/body" "$web/assets/app-Ab3dEf12.js" && ok "a large script arrives whole" || bad "script bytes" "$STATUS"
is "script type" "$(header content-type)" "text/javascript; charset=utf-8"
is "hashed files are cached for good" "$(header cache-control)" "public, max-age=31536000, immutable"
get /assets/app-Ab3dEf12.js -H 'Accept-Encoding: gzip, deflate, br'
is "brotli preferred" "$(header content-encoding)" br; is "varies by encoding" "$(header vary)" Accept-Encoding
node -e 'process.stdout.write(require("zlib").brotliDecompressSync(require("fs").readFileSync(process.argv[1])))' "$TMP/body" | cmp -s - "$web/assets/app-Ab3dEf12.js" \
  && ok "brotli decodes to the file" || bad "brotli bytes"
get /assets/app-Ab3dEf12.js -H 'Accept-Encoding: gzip'; is "gzip when that is all" "$(header content-encoding)" gzip
gzip -dc <"$TMP/body" | cmp -s - "$web/assets/app-Ab3dEf12.js" && ok "gzip decodes to the file" || bad "gzip bytes"
get / -H 'Accept-Encoding: br;q=0, gzip;q=0.5'; is "an encoding refused with q=0" "$(header content-encoding)" gzip
get / -H 'Accept-Encoding: identity, x-br, gzipped'; is "only whole encoding names count" "$(header content-encoding)" ""
get /assets/tiny-0000.css -H 'Accept-Encoding: br, gzip'; is "no encoding that makes a file larger" "$(header content-encoding)" ""
get /manifest.webmanifest; is "manifest type" "$(header content-type)" "application/manifest+json"
get /sw.js; is "service worker is revalidated" "$(header cache-control)" "no-cache"
get '/sw.js?v=2'; is "query string is ignored" "$STATUS" 200

get /command/; cmp -s "$TMP/body" "$web/command/index.html" && ok "a second application under its own path" || bad "GET /command/" "$STATUS"
get /command/assets/c-1111.js; is "its hashed files are cached for good" "$(header cache-control)" "public, max-age=31536000, immutable"
get /command/index.html; is "its page by name" "$STATUS" 200
for p in /command /command// /missing /assets /assets/ /assets/../index.html /../etc/passwd /%2e%2e/etc/passwd //index.html /index.html/ /INDEX.HTML; do
  get "$p"; is "no file at $p" "$STATUS" 404
done
get / -X POST; is "POST / is not found" "$STATUS" 404
get /v1/health; is "the API is unaffected" "$STATUS" 200
get /v1/nothing; is "unknown API path stays JSON" "$(cat "$TMP/body")" '{"error":"not found"}'
exec 3<>"/dev/tcp/127.0.0.1/$PORT"
printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /v1/health HTTP/1.1\r\nHost: x\r\n\r\nGET /sw.js HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' >&3
order="$(timeout 3 cat <&3 | grep -aoE '<title>fixture|"status":"ok"|// worker' | tr '\n' ' ')"; exec 3<&- 3>&-
is "pipelined file, API and file answer in order" "$order" '<title>fixture "status":"ok" // worker '
kill -0 "$PID" 2>/dev/null && ! grep -qE 'runtime error|Sanitizer' "$TMP/server.log" && ok "server still running, clean log" || bad "server log"
echo "passed=$pass failed=$fail"; [ $fail = 0 ]
