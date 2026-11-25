/* Token signing and verification (runtime/jwt.c). Run through tests/unit.sh. */
#include <stdio.h>
#include <stdlib.h>
#include "rt.h"
#include "json.c"
#include "jwt.c"

static int failed;
#define CHECK(x) do { if (!(x)) { printf("  FAIL %s:%d %s\n", __FILE__, __LINE__, #x); failed++; } } while (0)

#define NOW 1000000

/* A correctly signed token with an arbitrary header and payload. */
static u32 forge(const char *header, const char *payload, u8 *out) {
  u32 n = b64url_encode((const u8 *)header, (u32)strlen(header), out);
  out[n++] = '.';
  n += b64url_encode((const u8 *)payload, (u32)strlen(payload), out + n);
  u8 mac[32];
  hmac_sha256(out, n, mac);
  out[n++] = '.';
  return n + b64url_encode(mac, 32, out + n);
}
static int verify_payload(const char *payload) {
  u8 t[1024];
  claims_t c;
  u32 n = forge("{\"alg\":\"HS256\"}", payload, t);
  return jwt_verify(t, n, NOW, &c);
}

int main(void) {
  hmac_init((const u8 *)"0123456789abcdef0123456789abcdef", 32);
  u8 t[JWT_MAX];
  claims_t in = {.uid = 123456789012345LL, .role = 2, .nregions = 3, .regions = {1, 7, 65535}}, out;

  u32 n = jwt_sign(&in, NOW + 60, t);
  CHECK(n > 0 && n <= JWT_MAX);
  CHECK(jwt_verify(t, n, NOW, &out) == JWT_OK);
  CHECK(out.uid == in.uid && out.role == 2 && out.nregions == 3);
  CHECK(out.regions[0] == 1 && out.regions[1] == 7 && out.regions[2] == 65535);
  CHECK(jwt_verify(t, n, NOW + 60, &out) == JWT_INVALID);          /* expired */

  u8 bad[JWT_MAX];
  for (u32 i = 0; i < n; i++) {                                     /* any changed byte */
    memcpy(bad, t, n);
    bad[i] = bad[i] == 'A' ? 'B' : 'A';
    if (jwt_verify(bad, n, NOW, &out) == JWT_OK) { CHECK(!"tampered token accepted"); break; }
  }

  claims_t citizen = {.uid = 5, .role = 1};
  n = jwt_sign(&citizen, NOW + 60, t);
  CHECK(jwt_verify(t, n, NOW, &out) == JWT_OK && out.role == 1 && out.nregions == 0 && out.uid == 5);

  claims_t most = {.uid = 999999999999999LL, .role = 255, .nregions = JWT_REGIONS};
  for (int i = 0; i < JWT_REGIONS; i++) most.regions[i] = 65535;
  n = jwt_sign(&most, 999999999999LL, t);                           /* largest token */
  CHECK(n <= JWT_MAX && jwt_verify(t, n, NOW, &out) == JWT_OK && out.nregions == JWT_REGIONS);

  CHECK(verify_payload("{\"sub\":\"5\",\"role\":1,\"exp\":2000000}") == JWT_OK);
  CHECK(verify_payload("{\"sub\":\"5\",\"exp\":2000000}") == JWT_PAYLOAD);              /* no role */
  CHECK(verify_payload("{\"sub\":\"5\",\"role\":0,\"exp\":2000000}") == JWT_PAYLOAD);
  CHECK(verify_payload("{\"sub\":\"5\",\"role\":256,\"exp\":2000000}") == JWT_PAYLOAD);
  CHECK(verify_payload("{\"sub\":\"5\",\"role\":\"1\",\"exp\":2000000}") == JWT_PAYLOAD);
  CHECK(verify_payload("{\"sub\":\"5\",\"role\":1.5,\"exp\":2000000}") == JWT_PAYLOAD);
  CHECK(verify_payload("{\"sub\":\"0\",\"role\":1,\"exp\":2000000}") == JWT_PAYLOAD);
  const char *rg[] = {"\"\"", "\"1,\"", "\",1\"", "\"1,,2\"", "\"a\"", "\"0\"", "\"65536\"", "[1]", "5",
                      "\"1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17\""};
  for (unsigned i = 0; i < sizeof rg / sizeof *rg; i++) {
    char p[256];
    snprintf(p, sizeof p, "{\"sub\":\"5\",\"role\":2,\"rg\":%s,\"exp\":2000000}", rg[i]);
    if (verify_payload(p) != JWT_PAYLOAD) { printf("  FAIL rg %s accepted\n", rg[i]); failed++; }
  }
  u8 u[1024];
  u32 un = forge("{\"alg\":\"none\"}", "{\"sub\":\"5\",\"role\":1,\"exp\":2000000}", u);
  CHECK(jwt_verify(u, un, NOW, &out) == JWT_INVALID);

  printf("jwt: %s\n", failed ? "FAILED" : "ok");
  return failed != 0;
}
