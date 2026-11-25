/* MINA operator tool. Runs offline with the server's key; the server never issues responder or
 * admin tokens.
 *
 *   MINA_SECRET=... mina-admin token --sub N --role citizen|responder|admin
 *                                    [--regions R,R,...] [--ttl SECONDS]  */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "rt.h"
#include "json.c"
#include "jwt.c"
#include "domain.h"

static int usage(const char *why) {
  fprintf(stderr, "mina-admin: %s\n"
                  "usage: MINA_SECRET=... mina-admin token --sub N --role citizen|responder|admin\n"
                  "                                        [--regions R,R,...] [--ttl SECONDS]\n", why);
  return 2;
}
/* A decimal integer in [lo, hi], nothing else. */
static int number(const char *s, i64 lo, i64 hi, i64 *out) {
  if (*s < '0' || *s > '9') return 0;
  char *end;
  i64 v = strtoll(s, &end, 10);
  if (*end || v < lo || v > hi) return 0;
  *out = v;
  return 1;
}

static int cmd_token(int argc, char **argv) {
  claims_t c = {0};
  i64 ttl = 30 * 86400;
  for (int i = 0; i < argc; i += 2) {
    const char *k = argv[i], *v = i + 1 < argc ? argv[i + 1] : 0;
    if (!v) return usage("missing value");
    if (!strcmp(k, "--sub")) {
      if (!number(v, 1, 999999999999999LL, &c.uid)) return usage("--sub must be 1 .. 999999999999999");
    } else if (!strcmp(k, "--role")) {
      c.role = !strcmp(v, "citizen") ? ROLE_CITIZEN : !strcmp(v, "responder") ? ROLE_RESPONDER : !strcmp(v, "admin") ? ROLE_ADMIN : 0;
      if (!c.role) return usage("unknown role");
    } else if (!strcmp(k, "--regions")) {
      if (jwt_regions((const u8 *)v, (u32)strlen(v), &c)) return usage("--regions must be a list such as 1,7 (at most 16)");
      for (int r = 0; r < c.nregions; r++) if (c.regions[r] > MAX_REGION) return usage("region out of range");
    } else if (!strcmp(k, "--ttl")) {
      if (!number(v, 1, 366 * 86400, &ttl)) return usage("--ttl must be 1 second .. 366 days");
    } else return usage("unknown option");
  }
  if (!c.uid || !c.role) return usage("--sub and --role are required");
  if (c.role == ROLE_RESPONDER && !c.nregions) return usage("a responder needs --regions");
  const char *secret = getenv("MINA_SECRET");
  if (!secret || strlen(secret) < MIN_SECRET_BYTES) return usage("MINA_SECRET (at least 32 bytes) is required");
  hmac_init((const u8 *)secret, strlen(secret));
  u8 t[JWT_MAX];
  u32 n = jwt_sign(&c, (i64)time(0) + ttl, t);
  printf("%.*s\n", (int)n, t);
  return 0;
}

int main(int argc, char **argv) {
  if (argc >= 2 && !strcmp(argv[1], "token")) return cmd_token(argc - 2, argv + 2);
  return usage("unknown command");
}
