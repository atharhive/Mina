import { describe, expect, it } from "vitest";
import { percentile, rates, type Metrics } from "../src";

const hist = (counts: number[]) => ({ bounds: counts.map((_, i) => (i + 1) * 10), counts });

describe("percentiles from a histogram", () => {
  it("returns the bound below which that share of the values lies", () => {
    const h = hist([50, 45, 4, 1]);
    expect(percentile(h, 0.5)).toBe(10);
    expect(percentile(h, 0.95)).toBe(20);
    expect(percentile(h, 0.99)).toBe(30);
    expect(percentile(h, 1)).toBe(40);
  });
  it("has no answer without values", () => {
    expect(percentile(hist([0, 0]), 0.5)).toBeNull();
  });
});

const sample = (over: { runtime?: object; db?: object; process?: object; app?: object }): Metrics => ({
  runtime: { requests: 0, jobs: 0, batches: 0, status_2xx: 0, status_3xx: 0, status_4xx: 0, status_5xx: 0, loop_iterations: 0, completions: 0, bytes_out: 0, batch_us: hist([0, 0, 0]), ...over.runtime },
  db: { commits: 0, ...over.db },
  process: { cpu_user_us: 0, cpu_system_us: 0, ...over.process },
  app: { sync_native: 0, sync_quiet: 0, sync_sql: 0, resyncs: 0, sync_bytes: 0, native_ns: hist([0, 0, 0]), ...over.app },
}) as Metrics;

describe("rates between two readings", () => {
  const before = sample({ runtime: { requests: 100, jobs: 100, batches: 50, status_4xx: 2, batch_us: hist([100, 0, 0]) }, db: { commits: 10 }, process: { cpu_user_us: 1_000_000 }, app: { sync_quiet: 5, sync_bytes: 500 } });
  const after = sample({ runtime: { requests: 300, jobs: 300, batches: 100, status_4xx: 4, status_5xx: 2, batch_us: hist([100, 190, 10]) }, db: { commits: 30 }, process: { cpu_user_us: 1_300_000, cpu_system_us: 100_000 }, app: { sync_quiet: 20, sync_native: 5, sync_bytes: 2500 } });
  const r = rates(before, after, 2);
  it("divides the differences by the time between them", () => {
    expect(r.requestsPerSecond).toBe(100);
    expect(r.errorsPerSecond).toBe(2);
    expect(r.commitsPerSecond).toBe(10);
    expect(r.cpuPercent).toBeCloseTo(20);
    expect(r.jobsPerBatch).toBe(4);
  });
  it("takes percentiles of what happened in the interval only", () => {
    expect(r.batchP50Us).toBe(20);
    expect(r.batchP99Us).toBe(30);
  });
  it("splits synchronisations by how they were answered", () => {
    expect(r.syncs).toEqual({ total: 20, native: 5, quiet: 15, sql: 0 });
    expect(r.syncBytesMean).toBe(100);
    expect(r.nativeP50Ns).toBeNull();
  });
  it("reports nothing rather than nonsense after a server restart", () => {
    expect(() => rates(after, before, 2)).toThrow(/restart/);
  });
});
