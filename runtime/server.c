/* The MINA server is one translation unit: SQLite's amalgamation, the runtime, and the
 * application layer generated from the Lean specification (build/app_gen.c).
 *
 * Environment: MINA_DB (database file, required), MINA_SECRET (token key, required, >= 32 bytes),
 * MINA_HOST (127.0.0.1), MINA_PORT (8080), MINA_IDLE_S (120: seconds a connection may go
 * without completing a request or receiving an answer), MINA_FORCE_SQL (set: answer reads with
 * the reference SQL instead of the native plans). */
#define _GNU_SOURCE
#include "sqlite3.c"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "rt.h"
#include "out.c"
#include "json.c"
#include "jwt.c"
#include "http.c"
#include "db.c"
#include "uring.c"
#include "app_gen.c"

int main(void) {
  const char *path = getenv("MINA_DB"), *secret = getenv("MINA_SECRET");
  const char *host = getenv("MINA_HOST"), *port = getenv("MINA_PORT");
  if (!path || !secret) { fprintf(stderr, "MINA_DB and MINA_SECRET are required\n"); return 1; }
  if (strlen(secret) < MIN_SECRET_BYTES) { fprintf(stderr, "MINA_SECRET must be at least %d bytes\n", MIN_SECRET_BYTES); return 1; }
  if (!host) host = "127.0.0.1";
  if (!port) port = "8080";
  const char *idle = getenv("MINA_IDLE_S");
  if (idle) {
    char *end;
    long v = strtol(idle, &end, 10);
    if (!*idle || *end || v < 1 || v > 86400) { fprintf(stderr, "MINA_IDLE_S must be 1 .. 86400\n"); return 1; }
    idle_limit_s = (u32)v;
  }
  signal(SIGPIPE, SIG_IGN);
  hmac_init((const u8 *)secret, strlen(secret));
  db_open(path);
  app_init();
  transport_init(host, atoi(port), 600000);   /* connection capacity the rings are sized for */
  fprintf(stderr, "listening on %s:%s\n", host, port);
  transport_run();
  return 0;
}
