#include "rt.h"

/* The server's own measurements as JSON members. Read only when asked for: the process and
 * kernel figures cost a few system calls. */

static void metric(out_t *o, const char *name, u64 value, int more) {
  u32 n = (u32)strlen(name);
  out_need(o, n + 26);
  out_lit(o, "\"", 1);
  out_lit(o, name, n);
  out_lit(o, "\":", 2);
  out_i64(o, (i64)value);
  if (more) out_lit(o, ",", 1);
}
static void metric_text(out_t *o, const char *s) {
  u32 n = (u32)strlen(s);
  out_need(o, n);
  out_lit(o, s, n);
}
static void metric_histogram(out_t *o, const char *name, const histogram *h, int more) {
  metric_text(o, "\"");
  metric_text(o, name);
  metric_text(o, "\":{\"bounds\":[");
  for (u32 i = 0; i < HIST; i++) { out_need(o, 22); if (i) out_lit(o, ",", 1); out_i64(o, (i64)hist_bound(i)); }
  metric_text(o, "],\"counts\":[");
  for (u32 i = 0; i < HIST; i++) { out_need(o, 22); if (i) out_lit(o, ",", 1); out_i64(o, (i64)h->counts[i]); }
  metric_text(o, more ? "]}," : "]}");
}

/* "runtime", "db" and "process" members, each followed by a comma. */
static void metrics_runtime(out_t *o) {
  metric_text(o, "\"runtime\":{");
  metric(o, "uptime_s", (u64)now_s - (u64)server_started, 1);
  metric(o, "rings", (u64)nrings, 1);
  metric(o, "connection_slots", nrings ? (u64)nrings * rings[0].nslots : 0, 1);
  metric(o, "connections_open", stats.open, 1);
  metric(o, "accepted", stats.accepted, 1);
  metric(o, "closed", stats.closed, 1);
  metric(o, "idle_dropped", stats.idle_dropped, 1);
  metric(o, "requests", stats.requests, 1);
  metric(o, "jobs", stats.jobs, 1);
  metric(o, "batches", stats.batches, 1);
  metric(o, "batch_jobs_max", stats.batch_jobs_max, 1);
  metric(o, "loop_iterations", stats.iterations, 1);
  metric(o, "completions", stats.completions, 1);
  metric(o, "receive_buffers_exhausted", stats.no_buffers, 1);
  metric(o, "queued_bytes", out_total, 1);
  metric(o, "bytes_out", stats.bytes_out, 1);
  metric(o, "status_2xx", stats.status[2], 1);
  metric(o, "status_3xx", stats.status[3], 1);
  metric(o, "status_4xx", stats.status[4], 1);
  metric(o, "status_5xx", stats.status[5], 1);
  metric_histogram(o, "batch_us", &stats.batch_us, 0);
  metric_text(o, "},\"db\":{");
  metric(o, "commits", stats.commits, 1);
  metric(o, "rollbacks", stats.rollbacks, 1);
  metric(o, "wal_frames", (u64)wal_frames, 1);
  metric(o, "checkpoints", __atomic_load_n(&stats.checkpoints, __ATOMIC_RELAXED), 1);
  metric(o, "checkpoint_frames", __atomic_load_n(&stats.checkpoint_frames, __ATOMIC_RELAXED), 1);
  metric(o, "checkpoint_us_last", __atomic_load_n(&stats.checkpoint_us_last, __ATOMIC_RELAXED), 1);
  metric(o, "checkpoints_inline", stats.checkpoints_inline, 0);
  metric_text(o, "},\"process\":{");
  struct rusage u;
  getrusage(RUSAGE_SELF, &u);
  metric(o, "cpu_user_us", (u64)u.ru_utime.tv_sec * 1000000 + (u64)u.ru_utime.tv_usec, 1);
  metric(o, "cpu_system_us", (u64)u.ru_stime.tv_sec * 1000000 + (u64)u.ru_stime.tv_usec, 1);
  unsigned long long size = 0, resident = 0;
  FILE *f = fopen("/proc/self/statm", "r");
  if (f) { if (fscanf(f, "%llu %llu", &size, &resident) != 2) resident = 0; fclose(f); }
  metric(o, "rss_bytes", resident * (u64)sysconf(_SC_PAGESIZE), 1);
  /* TCP socket memory of the whole network namespace, not of this process alone */
  unsigned long long inuse = 0, pages = 0;
  if ((f = fopen("/proc/net/sockstat", "r"))) {
    char line[256];
    while (fgets(line, sizeof line, f)) sscanf(line, "TCP: inuse %llu orphan %*u tw %*u alloc %*u mem %llu", &inuse, &pages);
    fclose(f);
  }
  metric(o, "tcp_sockets_namespace", inuse, 1);
  metric(o, "tcp_memory_bytes_namespace", pages * (u64)sysconf(_SC_PAGESIZE), 0);
  metric_text(o, "},");
}
