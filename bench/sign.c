/* Token signing for the MINA workload, with the server's own code. */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "rt.h"
#include "json.c"
#include "jwt.c"
#include "domain.h"

void sign_key(const char *secret) { hmac_init((const u8 *)secret, strlen(secret)); }

/* A citizen token, or with region > 0 a responder token for that region. */
void sign_token(long long sub, int region, char *out) {
  claims_t c = {.uid = sub, .role = region ? ROLE_RESPONDER : ROLE_CITIZEN};
  if (region) { c.nregions = 1; c.regions[0] = (u16)region; }
  out[jwt_sign(&c, (i64)time(0) + 86400, (u8 *)out)] = 0;
}
