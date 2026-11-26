import { KIND, LIMITS, SAFETY, displayStatus, type DisplayStatus } from "@mina/shared";
import { useEffect, useState, useSyncExternalStore, type FormEvent } from "react";
import { useLive } from "./live";
import { ReportForm } from "./ReportForm";
import { db, engine, keepSynchronised, link, watchLink, type Link } from "./store";
import { STATUS_TEXT, time, title } from "./text";

const LINK_TEXT: Record<Link, string> = {
  online: "Online",
  offline: "Offline — reports are saved on this phone",
  unreachable: "Cannot reach the server — reports are saved on this phone",
};
const TONE: Record<DisplayStatus, string> = {
  saved: "text-wait", waiting: "text-wait", delivered: "text-ink", acknowledged: "text-safe",
  in_progress: "text-safe", resolved: "text-muted", rejected: "text-alarm",
};

export function App() {
  const state = useSyncExternalStore(watchLink, link);
  const region = useLive(async () => ((await db.meta.get("region"))?.value as number | undefined) ?? 0, []);
  useEffect(() => (region ? keepSynchronised(region) : undefined), [region]);

  return (
    <div className="mx-auto max-w-xl px-4 pb-10">
      <header className="flex items-baseline justify-between border-b border-ink py-4">
        <h1 className="text-2xl font-bold tracking-tight">MINA</h1>
        {region ? <button className="text-sm underline" onClick={() => void db.meta.delete("region")}>Area {region} · change</button> : null}
      </header>
      <p role="status" aria-label="Connection" className={`border-b border-line py-2 text-sm font-semibold ${state === "online" ? "text-safe" : "text-wait"}`}>
        {LINK_TEXT[state]}
      </p>
      <main className="space-y-6 pt-4">
        {region === undefined ? null : region === 0 ? <ChooseArea /> : <Home region={region} online={state === "online"} />}
      </main>
      <footer className="mt-10 border-t border-line pt-4 text-sm text-muted">
        MINA is a research system and not a replacement for official emergency services. If you can reach them, call them.
      </footer>
    </div>
  );
}

function ChooseArea() {
  const [value, setValue] = useState("");
  const number = Number(value);
  const valid = Number.isInteger(number) && number >= 1 && number <= LIMITS.maxRegion;
  function save(event: FormEvent) {
    event.preventDefault();
    if (valid) void db.meta.put({ key: "region", value: number });
  }
  return (
    <form onSubmit={save} className="space-y-3">
      <label className="block">
        <span className="font-semibold">Your area number</span>
        <input inputMode="numeric" value={value} onChange={(e) => setValue(e.target.value)} className="mt-1 w-full border border-ink bg-card p-3 text-lg" />
        <span className="text-sm text-muted">Given by your local responders, from 1 to {LIMITS.maxRegion}.</span>
      </label>
      <button type="submit" disabled={!valid} className="min-h-12 w-full bg-ink font-semibold text-paper disabled:opacity-40">Continue</button>
    </form>
  );
}

function Home({ region, online }: { region: number; online: boolean }) {
  const [asking, setAsking] = useState(false);
  const [note, setNote] = useState("");
  const mine = useLive(() => db.outbox.orderBy("id").reverse().limit(50).toArray(), []) ?? [];
  const events = useLive(() => db.events.where("region").equals(region).toArray(), [region]) ?? [];
  const alerts = events.filter((e) => e.kind === KIND.alert_published).sort((a, b) => b.seq - a.seq).slice(0, 20);

  async function safety(status: number) {
    await engine.submit({ kind: KIND.safety_reported, region, status });
    void engine.run(region);
  }

  return (
    <>
      {asking ? (
        <>
          <ReportForm region={region} onSaved={(n) => { setAsking(false); setNote(n); }} />
          <button className="text-sm underline" onClick={() => setAsking(false)}>Cancel</button>
        </>
      ) : (
        <button onClick={() => { setAsking(true); setNote(""); }} className="min-h-24 w-full bg-alarm text-2xl font-bold text-white">Request help</button>
      )}
      {note && <p role="status" className="text-sm text-wait">{note}</p>}
      <section aria-label="My safety" className="grid grid-cols-2 gap-2">
        <button onClick={() => void safety(SAFETY.safe)} className="min-h-14 border border-safe font-semibold text-safe">I am safe</button>
        <button onClick={() => void safety(SAFETY.needs_help)} className="min-h-14 border border-alarm font-semibold text-alarm">I need help</button>
        <p className="col-span-2 text-sm text-muted">Your safety status is shown only to responders of your area.</p>
      </section>
      <section aria-label="Alerts for your area">
        <h2 className="border-b border-ink pb-1 font-semibold">Alerts for your area</h2>
        {alerts.length === 0 ? <p className="py-3 text-muted">No alerts received.</p> : (
          <ul>{alerts.map((a) => (
            <li key={a.seq} className="border-b border-line py-3">
              <p className="break-words font-medium">{a.body}</p>
              <p className="text-sm text-muted">{time(a.ts * 1000)}</p>
            </li>
          ))}</ul>
        )}
      </section>
      <section aria-label="My reports">
        <h2 className="border-b border-ink pb-1 font-semibold">My reports</h2>
        {mine.length === 0 ? <p className="py-3 text-muted">Nothing reported from this phone.</p> : (
          <ul>{mine.map((item) => {
            const status = displayStatus(item, events, online);
            return (
              <li key={item.id} className="border-b border-line py-3">
                <p className="font-semibold">{title(item)}</p>
                {item.payload.body && <p className="break-words">{item.payload.body}</p>}
                <p className={`font-semibold ${TONE[status]}`}>{STATUS_TEXT[status]}{status === "rejected" && item.error ? `: ${item.error}` : ""}</p>
                <p className="text-sm text-muted">{time(item.createdAt)}</p>
              </li>
            );
          })}</ul>
        )}
      </section>
    </>
  );
}
