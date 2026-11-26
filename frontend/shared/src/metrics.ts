/** GET /v1/metrics, and the arithmetic a display needs. Counters only grow while a server runs;
 * rates come from the difference of two readings. */
export interface Histogram { bounds: number[]; counts: number[] }
export interface Metrics {
  runtime: Record<
    "uptime_s" | "rings" | "connection_slots" | "connections_open" | "accepted" | "closed" | "idle_dropped" | "requests" | "jobs" | "batches" |
    "batch_jobs_max" | "loop_iterations" | "completions" | "receive_buffers_exhausted" | "queued_bytes" | "bytes_out" |
    "status_2xx" | "status_3xx" | "status_4xx" | "status_5xx", number> & { batch_us: Histogram };
  db: Record<"commits" | "rollbacks" | "wal_frames" | "checkpoints" | "checkpoint_frames" | "checkpoint_us_last" | "checkpoints_inline" | "checkpoint_inline_us_max", number>;
  process: Record<"cpu_user_us" | "cpu_system_us" | "rss_bytes" | "tcp_sockets_namespace" | "tcp_memory_bytes_namespace", number>;
  app: Record<
    "native_on" | "head_seq" | "events_stored" | "duplicates" | "transitions_refused" | "rate_limited" | "auth_refused" | "sessions_issued" |
    "sync_native" | "sync_quiet" | "sync_sql" | "resyncs" | "sync_bytes", number> & { native_ns: Histogram };
}

/** The upper bound of the bucket holding the value at this share (0..1), or null if empty. */
export function percentile(h: Histogram, share: number): number | null {
  const total = h.counts.reduce((a, b) => a + b, 0);
  if (total === 0) return null;
  let seen = 0;
  for (let i = 0; i < h.counts.length; i++) {
    seen += h.counts[i]!;
    if (seen >= share * total) return h.bounds[i]!;
  }
  return h.bounds.at(-1)!;
}

const between = (a: Histogram, b: Histogram): Histogram => ({ bounds: b.bounds, counts: b.counts.map((n, i) => n - (a.counts[i] ?? 0)) });

export interface Rates {
  requestsPerSecond: number; errorsPerSecond: number; commitsPerSecond: number; bytesPerSecond: number; cpuPercent: number;
  jobsPerBatch: number | null; completionsPerLoop: number | null;
  batchP50Us: number | null; batchP99Us: number | null;
  syncs: { total: number; native: number; quiet: number; sql: number };
  syncBytesMean: number | null; nativeP50Ns: number | null; nativeP99Ns: number | null;
}

export function rates(before: Metrics, after: Metrics, seconds: number): Rates {
  if (after.runtime.requests < before.runtime.requests) throw new Error("the server restarted between the readings");
  const run = (k: keyof Omit<Metrics["runtime"], "batch_us">) => after.runtime[k] - before.runtime[k];
  const app = (k: keyof Omit<Metrics["app"], "native_ns">) => after.app[k] - before.app[k];
  const ratio = (a: number, b: number) => (b > 0 ? a / b : null);
  const batch = between(before.runtime.batch_us, after.runtime.batch_us);
  const native = between(before.app.native_ns, after.app.native_ns);
  const syncs = { native: app("sync_native"), quiet: app("sync_quiet"), sql: app("sync_sql"), total: 0 };
  syncs.total = syncs.native + syncs.quiet + syncs.sql;
  const cpu = after.process.cpu_user_us + after.process.cpu_system_us - before.process.cpu_user_us - before.process.cpu_system_us;
  return {
    requestsPerSecond: run("requests") / seconds,
    errorsPerSecond: (run("status_4xx") + run("status_5xx")) / seconds,
    commitsPerSecond: (after.db.commits - before.db.commits) / seconds,
    bytesPerSecond: run("bytes_out") / seconds,
    cpuPercent: (cpu / (seconds * 1e6)) * 100,
    jobsPerBatch: ratio(run("jobs"), run("batches")),
    completionsPerLoop: ratio(run("completions"), run("loop_iterations")),
    batchP50Us: percentile(batch, 0.5),
    batchP99Us: percentile(batch, 0.99),
    syncs,
    // resynchronisation answers carry no events and are not counted as synchronisations
    syncBytesMean: ratio(app("sync_bytes"), syncs.total),
    nativeP50Ns: percentile(native, 0.5),
    nativeP99Ns: percentile(native, 0.99),
  };
}
