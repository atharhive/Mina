import { KIND, SAFETY, incidents, keepSynchronised, type Link, type Responder } from "@mina/shared";
import { useEffect, useMemo, useState, useSyncExternalStore, type FormEvent } from "react";
import { Alerts } from "./Alerts";
import { Detail } from "./Detail";
import { useLive } from "./live";
import { SignIn } from "./SignIn";
import { connection, db, engine, signOut } from "./store";
import { CATEGORY_TEXT, STATUS_TEXT, STATUS_TONE, clock, place } from "./text";

/** Incidents put on the page at a time. The list is in priority order, so these are the ones
 * that need attention; thousands of rows would freeze the page on every change. */
const PAGE_ROWS = 200;
const LINK_TEXT: Record<Link, string> = { online: "Online", offline: "Offline — changes wait on this device", unreachable: "Cannot reach the server — changes wait on this device" };

export function App() {
  const identity = useLive(async () => ((await engine.identity()) as Responder | undefined) ?? null, []);
  if (identity === undefined) return null;
  return identity === null ? <SignIn /> : <Watch responder={identity} />;
}

/** An admin's token names no region: they choose which to watch. */
function Watch({ responder }: { responder: Responder }) {
  const chosen = useLive(async () => ((await db.meta.get("watch"))?.value as number[] | undefined) ?? [], []);
  const [text, setText] = useState("");
  const regions = responder.regions.length > 0 ? responder.regions : chosen;
  if (!regions) return null;
  if (regions.length > 0) return <Dashboard responder={responder} regions={regions} />;
  function save(event: FormEvent) {
    event.preventDefault();
    const list = text.split(",").map(Number).filter((n) => Number.isInteger(n) && n >= 1 && n <= 1024).slice(0, 16);
    if (list.length > 0) void db.meta.put({ key: "watch", value: list });
  }
  return (
    <main className="mx-auto max-w-md p-6">
      <form onSubmit={save} className="space-y-3 border border-line bg-panel p-4">
        <label className="block"><span>Areas to watch, for example 1,2</span>
          <input value={text} onChange={(e) => setText(e.target.value)} className="mt-1 w-full border border-line bg-base p-2" /></label>
        <button type="submit" className="bg-ink px-4 py-2 font-semibold text-base">Watch</button>
      </form>
    </main>
  );
}

function Dashboard({ responder, regions }: { responder: Responder; regions: number[] }) {
  const state = useSyncExternalStore(connection.watch, connection.state);
  const key = regions.join(",");
  useEffect(() => keepSynchronised(engine, regions, 3000, 2000), [key]);
  const events = useLive(() => db.events.where("region").anyOf(regions).toArray(), [key]) ?? [];
  const outbox = useLive(() => db.outbox.toArray(), []) ?? [];
  const list = useMemo(() => incidents(events), [events]);
  const safety = events.filter((e) => e.kind === KIND.safety_reported)
    .sort((a, b) => Number(b.status === SAFETY.needs_help) - Number(a.status === SAFETY.needs_help) || b.seq - a.seq).slice(0, 50);
  const [selected, setSelected] = useState<number>();
  const [shown, setShown] = useState(PAGE_ROWS);
  const incident = list.find((i) => i.id === selected);
  const unsent = outbox.filter((i) => i.state === "queued").length;

  function leave() {
    if (unsent === 0 || confirm(`${unsent} changes have not been sent and will be lost. Sign out?`)) void signOut();
  }

  return (
    <div className="mx-auto max-w-7xl px-4 pb-8">
      <header className="flex flex-wrap items-center justify-between gap-2 border-b border-line py-3">
        <h1 className="text-lg font-semibold tracking-tight">MINA Command</h1>
        <p role="status" aria-label="Connection" className={`text-sm font-semibold ${state === "online" ? "text-safe" : "text-wait"}`}>{LINK_TEXT[state]}</p>
        <p className="text-sm text-muted">Responder {responder.sub} · areas {regions.join(", ")}{" "}
          <button onClick={leave} className="ml-3 underline">Sign out</button></p>
      </header>
      <div className="grid gap-6 pt-4 md:grid-cols-[minmax(0,2fr)_minmax(0,3fr)]">
        <div className="space-y-6">
          <section>
            <h2 className="border-b border-line pb-1 font-semibold">
              Incidents <span className="font-normal text-muted">· {list.filter((i) => i.status === 1).length} unanswered</span></h2>
            {list.length === 0 && <p className="py-3 text-muted">No reports received.</p>}
            <ol aria-label="Incidents" className="max-h-[60vh] overflow-y-auto">
              {list.slice(0, shown).map((i) => (
                <li key={i.id} className="row border-b border-line">
                  <button onClick={() => setSelected(i.id)} aria-current={i.id === selected} className={`block w-full px-2 py-2 text-left ${i.id === selected ? "bg-panel" : ""}`}>
                    <span className="flex justify-between gap-2"><span className="font-semibold">{CATEGORY_TEXT[i.category]}</span>
                      <span className={`text-sm font-semibold ${STATUS_TONE[i.status]}`}>{STATUS_TEXT[i.status]}</span></span>
                    <span className="block truncate text-sm">{i.body ?? "No description"}</span>
                    <span className="block text-xs text-muted">Area {i.region} · {clock(i.reportedAt)}</span>
                  </button>
                </li>
              ))}
            </ol>
            {list.length > shown && (
              <button onClick={() => setShown(shown + PAGE_ROWS)} className="mt-2 w-full border border-line py-2 text-sm">
                Show {Math.min(PAGE_ROWS, list.length - shown)} more <span className="text-muted">({list.length - shown} not shown)</span>
              </button>
            )}
          </section>
          <section aria-label="Safety reports">
            <h2 className="border-b border-line pb-1 font-semibold">Safety reports</h2>
            {safety.length === 0 && <p className="py-3 text-muted">None received.</p>}
            <ul className="max-h-[40vh] overflow-y-auto">{safety.map((s) => (
              <li key={s.seq} className="row border-b border-line py-2 text-sm">
                <p className={`font-semibold ${s.status === SAFETY.needs_help ? "text-alarm" : "text-safe"}`}>{s.status === SAFETY.needs_help ? "Needs help" : "Safe"}</p>
                {s.body && <p className="break-words">{s.body}</p>}
                <p className="text-muted">Area {s.region} · {clock(s.ts)} · location {place(s.lat, s.lon)}</p>
              </li>
            ))}</ul>
          </section>
        </div>
        <div className="space-y-6">
          <section aria-label="Incident detail" className="border border-line bg-panel p-4">
            {incident ? <Detail incident={incident} outbox={outbox} regions={regions} /> : <p className="text-muted">Choose an incident from the list.</p>}
          </section>
          <Alerts regions={regions} events={events} outbox={outbox} />
        </div>
      </div>
    </div>
  );
}
