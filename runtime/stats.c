#include "rt.h"

/* Counters the server keeps about itself. Plain increments on the request thread; the
 * checkpoint thread's three are written atomically. metrics.c writes them as JSON. */

/* A histogram with four buckets per power of two: exact below 8, then within 25 %. */
#define HIST 76
typedef struct { u64 counts[HIST]; } histogram;

static inline u32 hist_bucket(u64 v) {
  if (v < 8) return (u32)v;
  int e = 63 - __builtin_clzll(v);
  u32 i = 8 + (u32)(e - 3) * 4 + (u32)((v >> (e - 2)) & 3);
  return i < HIST ? i : HIST - 1;
}
/* Values in bucket i are below this; the last bucket also holds everything larger. */
static inline u64 hist_bound(u32 i) {
  return i < 8 ? i + 1 : (u64)(4 + (i - 8) % 4 + 1) << ((i - 8) / 4 + 1);
}
static inline void hist_add(histogram *h, u64 v, u64 weight) { h->counts[hist_bucket(v)] += weight; }

static struct {
  /* transport */
  u64 accepted, closed, requests, jobs, batches, batch_jobs_max, iterations, completions, bytes_out, no_buffers, idle_dropped;
  u64 status[6];                     /* answers by first digit of the status */
  u32 open;
  histogram batch_us;                /* time to serve a batch, counted once for each job in it */
  /* database */
  u64 commits, rollbacks, checkpoints_inline;
  u64 checkpoints, checkpoint_frames, checkpoint_us_last;     /* the checkpoint thread */
} stats;

static i64 server_started;

static inline u64 clock_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (u64)t.tv_sec * 1000000000ull + (u64)t.tv_nsec;
}
