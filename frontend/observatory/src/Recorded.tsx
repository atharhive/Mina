import { VERIFIED } from "@mina/shared";
import report from "../../../bench/reports/2026-11-26-mina-load.jsonl?raw";
import { one, whole } from "./format";

interface Run { commit: string; mode: string; users: number; hold_s: number; nominal_rps: number; achieved_rps: number; p50_ms: number; p99_ms: number; server_cpu_pct: number; cpu_us_per_request: number; mem_peak_mb: number }
const [about, ...runs] = report.trim().split("\n").map((line) => JSON.parse(line));

export function Recorded() {
  return (
    <section aria-label="Recorded benchmarks" className="space-y-2">
      <h2 className="border-b border-line pb-1 font-semibold">Recorded benchmarks <span className="font-normal text-wait">· not live</span></h2>
      <p className="text-sm text-muted">{(about as { environment: string }).environment}</p>
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-muted">
              {["Users", "Build", "Reads", "Hold", "Requests/s of offered", "p50 ms", "p99 ms", "CPU %", "us per request", "Peak MB"].map((h) => <th key={h} className="border-b border-line py-1 pr-3 font-normal">{h}</th>)}
            </tr>
          </thead>
          <tbody>
            {(runs as Run[]).map((r) => (
              <tr key={`${r.commit}-${r.mode}-${r.users}`} className="border-b border-line">
                {[whole(r.users), r.commit, r.mode, `${r.hold_s} s`, `${whole(r.achieved_rps)} of ${whole(r.nominal_rps)}`, r.p50_ms.toFixed(2), r.p99_ms.toFixed(2),
                  one(r.server_cpu_pct), one(r.cpu_us_per_request), whole(r.mem_peak_mb)].map((v, i) => <td key={i} className="py-1 pr-3">{v}</td>)}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="text-sm text-muted">Builds c75adc8 and 5b30529 differ by one fix to the event insert (docs/OPTIMIZATION_LOG.md).</p>
    </section>
  );
}

export function Proved() {
  return (
    <section aria-label="Proved in Lean" className="space-y-2">
      <h2 className="border-b border-line pb-1 font-semibold">Proved in Lean</h2>
      <p className="text-sm text-muted">Theorems about a model of the event store, checked by the Lean kernel at build time. They are about the model, not the C: the C is tested against SQL.</p>
      <ul className="grid gap-x-6 text-sm md:grid-cols-2">
        {VERIFIED.map((t) => (
          <li key={t.name} className="border-b border-line py-2"><code className="text-trace">{t.name}</code><p>{t.statement}</p></li>
        ))}
      </ul>
    </section>
  );
}
