/* In-process cost of GET /v1/sync: the native plans against the reference SQL, on the same
 * database, inside one read transaction. Every request is also answered both ways first and
 * the bytes compared. Times cover the application's read (and response serialization), not the
 * network, HTTP parsing, token check or transaction begin and commit.
 *
 * Build and run: bench/micro.sh */
#define main server_main
#include "../runtime/server.c"
#undef main

#define PARAMS 4096
#define ROUNDS 100000

static i64 stamp_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000000000LL + t.tv_nsec;
}
static obuf *answer(sync_t *q, int native) {
  job_t j = {.kind = K_SYNC, .data = q};
  native_on = native;
  exec_sync(&j);
  if (native_on != native) { fprintf(stderr, "fatal: the native plan fell back to SQL\n"); exit(1); }
  return j.resp;
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: micro_sync <database> <regions>\n"); return 2; }
  i64 regions = atoll(argv[2]);
  db_open(argv[1]);
  app_init();
  if (!native_on) { fprintf(stderr, "fatal: native plans are off\n"); return 1; }
  static const struct { const char *name; int restricted, limit; i64 back; } CASES[] = {
    /* back: how far behind the head the cursor is; -1 anywhere in the older part */
    {"public stream, 64 events", 0, 64, -1},   {"responder merge, 64 events", 1, 64, -1},
    {"public stream, 256 events", 0, 256, -1}, {"public stream, a few new events", 0, 64, 40},
    {"up to date (empty answer)", 0, 64, 0},   {"responder up to date (empty)", 1, 64, 0}};
  printf("%-34s %10s %10s %8s %12s\n", "case", "native us", "sql us", "ratio", "bytes/answer");
  db_batch_begin();
  C_events = cursor_new(ROOT_events, 0);
  for (int v = 0; v < 2; v++) C_region[v] = cursor_new(ROOT_region, KI_region);
  for (unsigned k = 0; k < sizeof CASES / sizeof *CASES; k++) {
    static sync_t q[PARAMS];
    u64 state = 12345 + k, bytes = 0;
    for (int i = 0; i < PARAMS; i++) {
      state = state * 6364136223846793005ULL + 1442695040888963407ULL;
      i64 region = (i64)(state >> 33) % regions + 1;
      i64 after = CASES[k].back < 0 ? (i64)(state >> 13) % (global_head / 2 + 1) : global_head - CASES[k].back;
      q[i] = (sync_t){.region = region, .after = after < 0 ? 0 : after, .limit = CASES[k].limit, .restricted = (u8)CASES[k].restricted};
      obuf *a = answer(&q[i], 1), *b = answer(&q[i], 0);
      if (a->len != b->len || memcmp(a->data, b->data, a->len)) { fprintf(stderr, "fatal: %s: answers differ\n", CASES[k].name); return 1; }
      bytes += a->len;
      obuf_release(a);
      obuf_release(b);
    }
    double us[2];
    for (int native = 1; native >= 0; native--) {
      i64 t0 = stamp_ns();
      for (int i = 0; i < ROUNDS; i++) obuf_release(answer(&q[i % PARAMS], native));
      us[native] = (double)(stamp_ns() - t0) / ROUNDS / 1000.0;
    }
    printf("%-34s %10.2f %10.2f %7.1fx %12llu\n", CASES[k].name, us[1], us[0], us[0] / us[1], bytes / PARAMS);
  }
  return 0;
}
