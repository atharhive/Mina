import { KIND, LIMITS, type OutboxItem, type StoredEvent } from "@mina/shared";
import { useState, type FormEvent } from "react";
import { engine } from "./store";
import { clock } from "./text";

export function Alerts({ regions, events, outbox }: { regions: number[]; events: StoredEvent[]; outbox: OutboxItem[] }) {
  const [chosen, setChosen] = useState<number>();
  const [text, setText] = useState("");
  const [problem, setProblem] = useState("");
  const region = chosen !== undefined && regions.includes(chosen) ? chosen : regions[0]!;
  const waiting = outbox.filter((i) => i.payload.kind === KIND.alert_published && i.state !== "delivered");
  const sent = events.filter((e) => e.kind === KIND.alert_published).sort((a, b) => b.seq - a.seq).slice(0, 10);

  async function publish(event: FormEvent) {
    event.preventDefault();
    try {
      await engine.submit({ kind: KIND.alert_published, region, body: text });
      setText("");
      void engine.run(...regions);
    } catch (error) {
      setProblem(error instanceof Error ? error.message : "Could not save the alert.");
    }
  }

  return (
    <section aria-label="Alerts" className="space-y-2">
      <h2 className="border-b border-line pb-1 font-semibold">Alerts</h2>
      <form onSubmit={publish} className="space-y-2">
        {regions.length > 1 && (
          <label className="block text-sm">Area{" "}
            <select value={region} onChange={(e) => setChosen(Number(e.target.value))} className="border border-line bg-base p-1">
              {regions.map((r) => <option key={r} value={r}>{r}</option>)}
            </select>
          </label>
        )}
        <label className="block">
          <span className="text-sm">Alert for region {region}</span>
          <textarea value={text} maxLength={LIMITS.maxBodyChars} rows={2} onChange={(e) => { setText(e.target.value); setProblem(""); }}
            className="mt-1 w-full border border-line bg-base p-2" />
        </label>
        {problem && <p role="alert" className="text-alarm">{problem}</p>}
        <button type="submit" disabled={!text.trim()} className="border border-ink px-4 py-2 font-semibold disabled:opacity-40">Publish alert</button>
      </form>
      <ul>
        {waiting.map((i) => (
          <li key={i.eid} className="border-b border-line py-2 text-sm">
            <p className="break-words">{i.payload.body}</p>
            <p className={i.state === "rejected" ? "text-alarm" : "text-wait"}>{i.state === "rejected" ? `Not accepted: ${i.error}` : "Waiting to send"}</p>
          </li>
        ))}
        {sent.map((a) => (
          <li key={a.seq} className="border-b border-line py-2 text-sm">
            <p className="break-words">{a.body}</p>
            <p className="text-muted">Area {a.region} · {clock(a.ts)}</p>
          </li>
        ))}
      </ul>
    </section>
  );
}
