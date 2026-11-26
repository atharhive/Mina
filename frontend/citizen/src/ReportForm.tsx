import { KIND, LIMITS, type Submission } from "@mina/shared";
import { useState, type FormEvent } from "react";
import { CATEGORIES } from "./text";
import { engine } from "./store";

/** Three decimals of a degree, about 100 m: enough to find someone, no finer. */
function approximateLocation(): Promise<{ lat: number; lon: number } | undefined> {
  return new Promise((resolve) => {
    if (!navigator.geolocation) return resolve(undefined);
    const round = (deg: number) => Math.round(deg * 1000) * 100;
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ lat: round(p.coords.latitude), lon: round(p.coords.longitude) }),
      () => resolve(undefined), { timeout: 8000, maximumAge: 60_000 });
  });
}

export function ReportForm({ region, onSaved }: { region: number; onSaved: (note: string) => void }) {
  const [category, setCategory] = useState<number>();
  const [body, setBody] = useState("");
  const [share, setShare] = useState(false);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState("");

  async function save(event: FormEvent) {
    event.preventDefault();
    if (category === undefined) return setProblem("Choose what kind of help you need.");
    setBusy(true);
    try {
      const place = share ? await approximateLocation() : undefined;
      const report: Submission = { kind: KIND.sos_created, region, category, body, ...place };
      await engine.submit(report);
      onSaved(share && !place ? "Saved without a location: this phone could not determine it." : "");
      void engine.run(region);
    } catch (error) {
      setProblem(error instanceof Error ? error.message : "Could not save the report.");
      setBusy(false);
    }
  }

  return (
    <form onSubmit={save} className="space-y-4 border border-ink bg-card p-4">
      <fieldset>
        <legend className="mb-2 font-semibold">What do you need?</legend>
        <div className="grid grid-cols-2 gap-2">
          {CATEGORIES.map(([code, label]) => (
            <label key={code} className="flex min-h-12 items-center gap-2 border border-line px-3 has-checked:border-ink has-checked:bg-paper">
              <input type="radio" name="category" checked={category === code} onChange={() => { setCategory(code); setProblem(""); }} className="size-5 accent-ink" />
              {label}
            </label>
          ))}
        </div>
      </fieldset>
      <label className="block">
        <span className="font-semibold">What is happening?</span>
        <textarea value={body} onChange={(e) => setBody(e.target.value)} maxLength={LIMITS.maxBodyChars} rows={3}
          className="mt-1 w-full border border-line bg-paper p-2" />
        <span className="text-sm text-muted">{[...body].length} / {LIMITS.maxBodyChars}</span>
      </label>
      <label className="flex min-h-12 items-center gap-3">
        <input type="checkbox" checked={share} onChange={(e) => setShare(e.target.checked)} className="size-5 accent-ink" />
        <span>Add my approximate location (about 100&nbsp;m)</span>
      </label>
      {problem && <p role="alert" className="font-semibold text-alarm">{problem}</p>}
      <button type="submit" disabled={busy} className="min-h-14 w-full bg-alarm text-lg font-semibold text-white disabled:opacity-60">
        {busy ? "Saving…" : "Save and send"}
      </button>
    </form>
  );
}
