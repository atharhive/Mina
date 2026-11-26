/* Mutation fuzzer for everything that reads a client's bytes: HTTP framing, the generated
 * request decoders (routes, query, JSON bodies, tokens) and the parsers on their own. Built with
 * AddressSanitizer and UBSan by tests/fuzz.sh; every input sits in a heap block of exactly its
 * size, so a read past the end is reported.
 *
 *   fuzz <seconds> <seed> */
#define main server_main
#include "../runtime/server.c"
#undef main

static u64 state;
static u64 rnd(void) {
  u64 z = (state += 0x9E3779B97F4A7C15ULL);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  return z ^ (z >> 31);
}
static u32 below(u32 n) { return n ? (u32)(rnd() % n) : 0; }
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "invariant failed: %s (line %d)\n", #x, __LINE__); abort(); } } while (0)

static const char *PIECES[] = {
  "\r\n", "\r\n\r\n", "\r", "\n", " ", ":", "?", "&", "=", "/", "%00", "GET ", "POST ", "HTTP/1.1", "HTTP/1.0",
  "Content-Length: ", "Content-Length: 99999999999", "Transfer-Encoding: chunked\r\n", "Connection: close\r\n",
  "Authorization: Bearer ", "Accept-Encoding: ", "If-None-Match: ", ";q=0", "br, gzip", "-1", "0", "999999999999999999",
  "{", "}", "[", "]", ",", "\"", "\\", "\\u", "\\ud800", "\\udc00", "\\u0000", "null", "true", "1e999", "-", ".",
  "\"eid\":", "\"kind\":", "\"region\":", "\"body\":", "\"lat\":", "\"incident\":", "region=", "after=", "limit=",
  "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xff", "\xe2\x80\x83", "\0"};

#define CAP 40000
/* Change a copy of the input in a few places. */
static u32 mutate(u8 *b, u32 n) {
  for (u32 k = below(8) + 1; k; k--) {
    u32 at = below(n + 1), op = below(8);
    if (op == 0 && n) b[below(n)] ^= (u8)(1u << below(8));
    else if (op == 1 && n) b[below(n)] = (u8)rnd();
    else if (op == 2 && n) { u32 len = below(n - (at % n)) % 64 + 1; at %= n; if (len > n - at) len = n - at; memmove(b + at, b + at + len, n - at - len); n -= len; }
    else if (op == 3) {
      u32 i = below(sizeof PIECES / sizeof *PIECES), len = (u32)strlen(PIECES[i]);
      if (!len) len = 1;
      if (n + len < CAP) { memmove(b + at + len, b + at, n - at); memcpy(b + at, PIECES[i], len); n += len; }
    } else if (op == 4 && n) { at %= n; u32 len = below(n - at) + 1; if (len > 2000) len = 2000; if (n + len < CAP) { memmove(b + at + len, b + at, n - at); n += len; } }
    else if (op == 5) n = at;
    else if (op == 6 && n + 4000 < CAP && below(20) == 0) { u32 len = below(4000); memmove(b + at + len, b + at, n - at); memset(b + at, "a\"{[ 9\\"[below(7)], len); n += len; }
    else if (n) b[below(n)] = "0123456789{}[]\":,\\ \r\n"[below(21)];
  }
  return n;
}
static u8 *exact(const u8 *p, u32 n) {
  u8 *m = malloc(n ? n : 1);
  CHECK(m);
  if (n) memcpy(m, p, n);
  return m;
}
static int inside(const u8 *p, u32 n, const u8 *base, u32 size) { return !n || (p >= base && p + n <= base + size); }

static u8 tokens[3][JWT_MAX + 1];
static u32 token_len[3];
static u64 framed, queued[16], answered[6], json_ok, json_bad, jwt_good, jwt_refused;

static void one_request(const u8 *src, u32 n) {
  u8 *p = exact(src, n);
  req_t rq;
  int k = http_parse(p, n, &rq);
  CHECK(k <= (int)n);
  if (k > 0) {
    framed++;
    u32 size = (u32)k;
    CHECK(inside(rq.path, rq.path_len, p, size) && inside(rq.query, rq.query_len, p, size) && inside(rq.body, rq.body_len, p, size) &&
          inside(rq.auth, rq.auth_len, p, size) && inside(rq.accept_encoding, rq.accept_encoding_len, p, size) &&
          inside(rq.if_none_match, rq.if_none_match_len, p, size));
    if (rq.accept_encoding) accepts(rq.accept_encoding, rq.accept_encoding_len, below(2) ? "br" : "gzip");
    job_t j = {0};
    app_decode(&rq, &j);
    CHECK(j.resp || j.kind);
    if (j.kind) { CHECK(j.kind < 16 && !j.resp); queued[j.kind]++; }
    else { u8 d = (u8)(j.resp->data[9] - '0'); CHECK(d < 6); answered[d]++; }
    if (j.resp) obuf_release(j.resp);
    arena_used = 0;
    memset(citizen_buckets, 0, sizeof(bucket) * 4);
    session_bucket.key = 0;
  }
  free(p);
}

static void one_json(const u8 *src, u32 n) {
  u8 *p = exact(src, n);
  jmember m[4] = {{"eid", 3, 0, 0, 0, 0}, {"body", 4, 0, 0, 0, 0}, {"sub", 3, 0, 0, 0, 0}, {"a", 1, 0, 0, 0, 0}};
  int rc = json_members(p, n, m, 4);
  CHECK(rc >= -1 && rc <= 1);
  if (rc == 0) {
    json_ok++;
    for (int i = 0; i < 4; i++)
      if (m[i].type == JT_STRING || m[i].type == JT_NUMBER) {
        CHECK(inside(m[i].v, m[i].v_len, p, n));
        if (m[i].type == JT_STRING) {
          u8 *copy = exact(m[i].v, m[i].v_len), *out = malloc(m[i].v_len ? m[i].v_len : 1);
          CHECK(json_unescape(copy, m[i].v_len, out) <= m[i].v_len);
          free(copy); free(out);
        }
      }
  } else json_bad++;
  free(p);
}

/* A correctly signed token around an arbitrary payload reaches the claim checks. */
static void one_token(const u8 *payload, u32 n) {
  static u8 t[CAP * 2];
  static const char header[] = "{\"alg\":\"HS256\"}";
  u32 len = b64url_encode((const u8 *)header, sizeof header - 1, t);
  t[len++] = '.';
  len += b64url_encode(payload, n, t + len);
  u8 mac[32];
  hmac_sha256(t, len, mac);
  t[len++] = '.';
  len += b64url_encode(mac, 32, t + len);
  if (below(4) == 0) len = mutate(t, len);                      /* or a damaged one */
  u8 *p = exact(t, len);
  claims_t c;
  int rc = jwt_verify(p, len, 1000, &c);
  if (rc == JWT_OK) { jwt_good++; CHECK(c.nregions <= JWT_REGIONS && c.uid > 0 && c.role); } else jwt_refused++;
  free(p);
}

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  double seconds = atof(argv[1]);
  state = strtoull(argv[2], 0, 10);
  hmac_init((const u8 *)"0123456789abcdef0123456789abcdef", 32);
  now_s = time(0);
  for (int i = 0; i < 3; i++) {
    claims_t c = {.uid = 7 + i, .role = (u8)(i + 1), .nregions = (u8)(i == 1 ? 2 : 0), .regions = {1, 2}};
    token_len[i] = jwt_sign(&c, now_s + 86400, tokens[i]);
    tokens[i][token_len[i]] = 0;
  }
  /* seeds: one request for every route, with real tokens, and bodies and payloads */
  static char seeds[16][1500];
  int ns = 0;
  const char *bodies[] = {
    "{\"eid\":\"0123456789abcdef0123456789abcdef\",\"kind\":1,\"region\":1,\"category\":2,\"body\":\"roof \\u00e9 \\\"x\\\"\",\"lat\":-5,\"lon\":7,\"at\":9}",
    "{\"eid\":\"0123456789abcdef0123456789abcdef\",\"kind\":3,\"incident\":1,\"status\":3}",
    "{\"eid\":\"0123456789abcdef0123456789abcdef\",\"kind\":6,\"region\":2,\"body\":\"\\ud83c\\udf0a flood\"}"};
  for (int i = 0; i < 3; i++)
    snprintf(seeds[ns++], 1500, "POST /v1/events HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer %s\r\nContent-Length: %zu\r\n\r\n%s", tokens[i == 0 ? 0 : 1], strlen(bodies[i]), bodies[i]);
  const char *gets[] = {"/v1/sync?region=1&after=0&limit=64", "/v1/sync?region=2&after=99", "/v1/incidents/12", "/v1/metrics", "/v1/health", "/", "/command/", "/assets/x.js"};
  for (int i = 0; i < 8; i++)
    snprintf(seeds[ns++], 1500, "GET %s HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer %s\r\nAccept-Encoding: br;q=0.5, gzip\r\nIf-None-Match: W/\"abc\"\r\n\r\n", gets[i], tokens[i == 3 ? 2 : i % 2]);
  snprintf(seeds[ns++], 1500, "POST /v1/session HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
  const char *claims[] = {"{\"sub\":\"5\",\"role\":2,\"rg\":\"1,2,3\",\"exp\":2000000}", "{\"sub\":\"5\",\"role\":1,\"exp\":1.5e12}"};

  static u8 buf[CAP * 2];
  u64 runs = 0, start = clock_ns();
  while ((runs & 1023) || (double)(clock_ns() - start) < seconds * 1e9) {
    int s = (int)below((u32)ns);
    u32 n = (u32)strlen(seeds[s]);
    memcpy(buf, seeds[s], n);
    if (below(2)) {                                        /* change the body only, keep the length right */
      char *body = strstr((char *)buf, "\r\n\r\n");
      if (body && body[4]) {
        static u8 b[CAP * 2];
        u32 bn = n - (u32)(body + 4 - (char *)buf);
        memcpy(b, body + 4, bn);
        bn = mutate(b, bn);
        char *cl = strstr((char *)buf, "Content-Length: ");
        if (cl) {
          static u8 whole[CAP * 2];
          u32 head = (u32)(cl - (char *)buf);
          memcpy(whole, buf, head);
          u32 w = head + (u32)sprintf((char *)whole + head, "Content-Length: %u\r\n\r\n", bn);
          memcpy(whole + w, b, bn);
          one_request(whole, w + bn);
        }
        one_json(b, bn);
      }
    } else one_request(buf, mutate(buf, n));
    const char *c = claims[below(2)];
    u32 cn = (u32)strlen(c);
    memcpy(buf, c, cn);
    cn = mutate(buf, cn);
    one_json(buf, cn);
    one_token(buf, cn);
    runs++;
  }
  printf("fuzz: %llu rounds, seed %s: framed %llu, queued events %llu syncs %llu incidents %llu metrics %llu, answered 2xx %llu 4xx %llu 5xx %llu, json %llu ok %llu refused, tokens %llu accepted %llu refused\n",
         runs, argv[2], framed, queued[K_EVENT], queued[K_SYNC], queued[K_INCIDENT], queued[K_METRICS], answered[2], answered[4], answered[5], json_ok, json_bad, jwt_good, jwt_refused);
  /* every kind of outcome must have been reached, or the run proves little */
  return framed && queued[K_EVENT] && queued[K_SYNC] && queued[K_INCIDENT] && queued[K_METRICS] && answered[2] && answered[4] && json_ok && json_bad && jwt_good && jwt_refused ? 0 : 1;
}
