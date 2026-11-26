import { actionsFor, type Incident, type OutboxItem } from "@mina/shared";
import { engine } from "./store";
import { CATEGORY_TEXT, STATUS_TEXT, STATUS_TONE, actionText, clock, place } from "./text";

export function Detail({ incident, outbox, regions }: { incident: Incident; outbox: OutboxItem[]; regions: number[] }) {
  const mine = outbox.filter((i) => i.payload.incident === incident.id);
  const pending = mine.find((i) => i.state === "queued");
  const refused = mine.at(-1)?.state === "rejected" ? mine.at(-1) : undefined;
  const actions = actionsFor(incident.status);

  async function act(index: number) {
    await engine.submit(actions[index]!.submission(incident.id));
    void engine.run(...regions);
  }

  return (
    <div className="space-y-4">
      <header className="border-b border-line pb-3">
        <h2 className="text-lg font-semibold">{CATEGORY_TEXT[incident.category]} · incident {incident.id}</h2>
        <p className={`font-semibold ${STATUS_TONE[incident.status]}`}>{STATUS_TEXT[incident.status]}</p>
      </header>
      <p className="break-words text-lg">{incident.body ?? <span className="text-muted">No description.</span>}</p>
      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
        <dt className="text-muted">Area</dt><dd>{incident.region}</dd>
        <dt className="text-muted">Location</dt><dd className="tabular-nums">{place(incident.lat, incident.lon)}</dd>
        <dt className="text-muted">Received</dt><dd>{clock(incident.reportedAt)}</dd>
        <dt className="text-muted">Written on the phone</dt><dd>{incident.at === null ? "unknown" : clock(incident.at)}</dd>
      </dl>
      {pending ? (
        <p role="status" className="font-semibold text-wait">Waiting to send: {actionText(pending.payload.kind, pending.payload.status ?? 0)}</p>
      ) : actions.length > 0 && (
        <div className="flex flex-wrap gap-2">
          {actions.map((a, i) => (
            <button key={`${a.kind}-${a.target}`} onClick={() => void act(i)}
              className={`border px-4 py-2 font-semibold ${i === 0 ? "border-ink bg-ink text-base" : "border-line"}`}>
              {actionText(a.kind, a.target)}
            </button>
          ))}
        </div>
      )}
      {refused && <p role="alert" className="text-alarm">Not accepted: {refused.error}. Someone else may have changed it.</p>}
      <section>
        <h3 className="border-b border-line pb-1 text-sm font-semibold text-muted">History</h3>
        <ol>{incident.history.map((h) => (
          <li key={h.seq} className="flex justify-between border-b border-line py-1 text-sm">
            <span>{STATUS_TEXT[h.status]}</span><span className="tabular-nums text-muted">{clock(h.at)}</span>
          </li>
        ))}</ol>
      </section>
    </div>
  );
}
