import { percentile, type Rates } from "@mina/shared";
import { Trace } from "./Trace";
import type { Readings } from "./useReadings";
import { below, bytes, one, share, whole } from "./format";

function Figure({ label, value, id }: { label: string; value: string; id?: string }) {
  return (
    <div className="border border-line bg-panel p-3">
      <dt className="text-xs text-muted">{label}</dt>
      <dd data-testid={id} className="text-xl">{value}</dd>
    </div>
  );
}
function Group({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div>
      <h3 className="mb-2 border-b border-line pb-1 text-sm font-semibold text-muted">{title}</h3>
      <dl className="grid grid-cols-2 gap-2 sm:grid-cols-4">{children}</dl>
    </div>
  );
}

export function Live({ readings }: { readings: Readings }) {
  const last = readings.history.at(-1);
  if (!last) return <p className="text-muted">Waiting for the first reading.</p>;
  const m = last.metrics;
  const r: Rates | null = last.rates;
  const series = (pick: (r: Rates) => number | null) => readings.history.flatMap((x) => (x.rates ? [pick(x.rates) ?? 0] : []));
  const rate = (v: number | undefined) => (v === undefined ? "—" : whole(v));
  return (
    <div className="space-y-5">
      <Group title="Load">
        <Figure id="connections" label="Open connections" value={whole(m.runtime.connections_open)} />
        <Figure id="requests-per-second" label="Requests per second" value={rate(r?.requestsPerSecond)} />
        <Figure label="CPU, share of one core" value={r ? `${one(r.cpuPercent)} %` : "—"} />
        <Figure label="Resident memory" value={bytes(m.process.rss_bytes)} />
        <Figure label="Batch time, median (server side)" value={below(r?.batchP50Us ?? null, "us")} />
        <Figure label="Batch time, 99th percentile" value={below(r?.batchP99Us ?? null, "us")} />
        <Figure label="4xx and 5xx per second" value={r ? one(r.errorsPerSecond) : "—"} />
        <Figure label="Sent per second" value={r ? bytes(r.bytesPerSecond) : "—"} />
      </Group>
      <div className="grid gap-2 md:grid-cols-2">
        <Trace title="Requests per second" values={series((x) => x.requestsPerSecond)} format={whole} />
        <Trace title="CPU %" values={series((x) => x.cpuPercent)} format={one} />
        <Trace title="Batch time p99, us" values={series((x) => x.batchP99Us)} format={whole} />
        <Trace title="Open connections" values={readings.history.map((x) => x.metrics.runtime.connections_open)} format={whole} />
      </div>
      <Group title={`Synchronisation (native plans ${m.app.native_on ? "on" : "off"})`}>
        <Figure label="Syncs in the last interval" value={r ? whole(r.syncs.total) : "—"} />
        <Figure id="sync-quiet-share" label="Answered without reading (up to date)" value={r ? share(r.syncs.quiet, r.syncs.total) : "—"} />
        <Figure label="Answered by the native plan" value={r ? share(r.syncs.native, r.syncs.total) : "—"} />
        <Figure label="Answered by SQL" value={r ? share(r.syncs.sql, r.syncs.total) : "—"} />
        <Figure label="Native plan time, median" value={below(r?.nativeP50Ns ?? percentile(m.app.native_ns, 0.5), "ns")} />
        <Figure label="Native plan time, p99" value={below(r?.nativeP99Ns ?? percentile(m.app.native_ns, 0.99), "ns")} />
        <Figure label="Mean answer size" value={r?.syncBytesMean == null ? "—" : bytes(r.syncBytesMean)} />
        <Figure label="Newest event" value={whole(m.app.head_seq)} />
      </Group>
      <Group title="Database">
        <Figure label="Transactions per second" value={r ? one(r.commitsPerSecond) : "—"} />
        <Figure label="Rolled back, total" value={whole(m.db.rollbacks)} />
        <Figure label="Log frames not yet restarted" value={whole(m.db.wal_frames)} />
        <Figure label="Checkpoints (background / request thread)" value={`${whole(m.db.checkpoints)} / ${whole(m.db.checkpoints_inline)}`} />
        <Figure label="Last checkpoint" value={m.db.checkpoints ? `${whole(m.db.checkpoint_frames)} frames, ${one(m.db.checkpoint_us_last / 1000)} ms` : "—"} />
        <Figure label="Events stored, total" value={whole(m.app.events_stored)} />
        <Figure label="Retries recognised" value={whole(m.app.duplicates)} />
        <Figure label="Transitions refused" value={whole(m.app.transitions_refused)} />
      </Group>
      <Group title="Transport (io_uring)">
        <Figure label="Requests served per batch" value={r?.jobsPerBatch == null ? "—" : one(r.jobsPerBatch)} />
        <Figure label="Completions per loop pass" value={r?.completionsPerLoop == null ? "—" : one(r.completionsPerLoop)} />
        <Figure label="Receive buffers ran out, total" value={whole(m.runtime.receive_buffers_exhausted)} />
        <Figure label="Answers waiting to be sent" value={bytes(m.runtime.queued_bytes)} />
        <Figure label="Connection slots" value={`${whole(m.runtime.connection_slots)} in ${m.runtime.rings} rings`} />
        <Figure label="Idle connections dropped" value={whole(m.runtime.idle_dropped)} />
        <Figure label="Rate limited / tokens refused" value={`${whole(m.app.rate_limited)} / ${whole(m.app.auth_refused)}`} />
        <Figure label="TCP socket memory, whole namespace" value={bytes(m.process.tcp_memory_bytes_namespace)} />
      </Group>
    </div>
  );
}
