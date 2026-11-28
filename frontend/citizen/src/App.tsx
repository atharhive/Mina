import { KIND, LIMITS, SAFETY, displayStatus, keepSynchronised, type DisplayStatus } from "@mina/shared";
import { useEffect, useState, useSyncExternalStore, type FormEvent } from "react";
import { useLive } from "./live";
import { ReportForm } from "./ReportForm";
import { connection, db, engine } from "./store";
import { LANGUAGE_NAMES, STRINGS, initialLang, keepLang, time, title, type Lang, type Strings } from "./text";

const TONE: Record<DisplayStatus, string> = {
  saved: "text-wait", waiting: "text-wait", delivered: "text-ink", acknowledged: "text-safe",
  in_progress: "text-safe", resolved: "text-muted", rejected: "text-alarm",
};

export function App() {
  const state = useSyncExternalStore(connection.watch, connection.state);
  const region = useLive(async () => ((await db.meta.get("region"))?.value as number | undefined) ?? 0, []);
  useEffect(() => (region ? keepSynchronised(engine, [region]) : undefined), [region]);
  const [lang, setLang] = useState(initialLang);
  useEffect(() => { document.documentElement.lang = lang; }, [lang]);
  const t = STRINGS[lang];

  return (
    <div className="mx-auto max-w-xl px-4 pb-10">
      <header className="flex items-baseline justify-between border-b border-ink py-4">
        <h1 className="text-2xl font-bold tracking-tight">MINA</h1>
        <div className="flex items-center gap-3">
          {region ? <button className="text-sm underline" onClick={() => void db.meta.delete("region")}>{t.area(region)}</button> : null}
          <select aria-label="Language · भाषा" value={lang} className="min-h-10 border border-line bg-card px-2 text-sm"
            onChange={(e) => { const chosen = e.target.value as Lang; setLang(chosen); keepLang(chosen); }}>
            {LANGUAGE_NAMES.map(([code, name]) => <option key={code} value={code} lang={code}>{name}</option>)}
          </select>
        </div>
      </header>
      <p role="status" aria-label="Connection" className={`border-b border-line py-2 text-sm font-semibold ${state === "online" ? "text-safe" : "text-wait"}`}>
        {t.link[state]}
      </p>
      <main className="space-y-6 pt-4">
        {region === undefined ? null : region === 0 ? <ChooseArea t={t} /> : <Home region={region} online={state === "online"} t={t} />}
      </main>
      <footer className="mt-10 border-t border-line pt-4 text-sm text-muted">
        <p>{t.disclaimer}</p>
        <p className="mt-2">{t.demo}</p>
      </footer>
    </div>
  );
}

function ChooseArea({ t }: { t: Strings }) {
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
        <span className="font-semibold">{t.areaLabel}</span>
        <input inputMode="numeric" value={value} onChange={(e) => setValue(e.target.value)} className="mt-1 w-full border border-ink bg-card p-3 text-lg" />
        <span className="text-sm text-muted">{t.areaHint(LIMITS.maxRegion)}</span>
      </label>
      <button type="submit" disabled={!valid} className="min-h-12 w-full bg-ink font-semibold text-paper disabled:opacity-40">{t.proceed}</button>
    </form>
  );
}

function Home({ region, online, t }: { region: number; online: boolean; t: Strings }) {
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
          <ReportForm region={region} t={t} onSaved={(n) => { setAsking(false); setNote(n); }} />
          <button className="text-sm underline" onClick={() => setAsking(false)}>{t.cancel}</button>
        </>
      ) : (
        <button onClick={() => { setAsking(true); setNote(""); }} className="min-h-24 w-full bg-alarm text-2xl font-bold text-white">{t.requestHelp}</button>
      )}
      {note && <p role="status" className="text-sm text-wait">{note}</p>}
      <section aria-label={t.mySafety} className="grid grid-cols-2 gap-2">
        <button onClick={() => void safety(SAFETY.safe)} className="min-h-14 border border-safe font-semibold text-safe">{t.safe}</button>
        <button onClick={() => void safety(SAFETY.needs_help)} className="min-h-14 border border-alarm font-semibold text-alarm">{t.needHelp}</button>
        <p className="col-span-2 text-sm text-muted">{t.safetyNote}</p>
      </section>
      <section aria-label={t.alerts}>
        <h2 className="border-b border-ink pb-1 font-semibold">{t.alerts}</h2>
        {alerts.length === 0 ? <p className="py-3 text-muted">{t.noAlerts}</p> : (
          <ul>{alerts.map((a) => (
            <li key={a.seq} className="border-b border-line py-3">
              <p className="break-words font-medium">{a.body}</p>
              <p className="text-sm text-muted">{time(a.ts * 1000, t)}</p>
            </li>
          ))}</ul>
        )}
      </section>
      <section aria-label={t.myReports}>
        <h2 className="border-b border-ink pb-1 font-semibold">{t.myReports}</h2>
        {mine.length === 0 ? <p className="py-3 text-muted">{t.noReports}</p> : (
          <ul>{mine.map((item) => {
            const status = displayStatus(item, events, online);
            return (
              <li key={item.id} className="border-b border-line py-3">
                <p className="font-semibold">{title(item, t)}</p>
                {item.payload.body && <p className="break-words">{item.payload.body}</p>}
                <p className={`font-semibold ${TONE[status]}`}>{t.status[status]}{status === "rejected" && item.error ? `: ${item.error}` : ""}</p>
                <p className="text-sm text-muted">{time(item.createdAt, t)}</p>
              </li>
            );
          })}</ul>
        )}
      </section>
    </>
  );
}
