import { CATEGORY, KIND, STATUS, TRANSITIONS, type StoredEvent, type Submission } from "./protocol";

/** An incident as the event stream tells it. Times are the server's, in seconds. */
export interface Incident {
  id: number; region: number; category: number; status: number;
  body: string | null; lat: number | null; lon: number | null; at: number | null;
  reportedAt: number; updatedAt: number;
  history: { status: number; at: number; seq: number }[];
}

export function incidents(events: readonly StoredEvent[]): Incident[] {
  const found = new Map<number, Incident>();
  for (const e of [...events].sort((a, b) => a.seq - b.seq)) {
    if (e.kind === KIND.sos_created && e.incident !== null) {
      found.set(e.incident, {
        id: e.incident, region: e.region, category: e.category ?? 0, status: STATUS.open, body: e.body, lat: e.lat, lon: e.lon, at: e.at,
        reportedAt: e.ts, updatedAt: e.ts, history: [{ status: STATUS.open, at: e.ts, seq: e.seq }],
      });
    } else if (e.incident !== null && e.status !== null) {
      const incident = found.get(e.incident);
      if (!incident) continue;
      incident.status = e.status;
      incident.updatedAt = e.ts;
      incident.history.push({ status: e.status, at: e.ts, seq: e.seq });
    }
  }
  return [...found.values()].sort(byPriority);
}

const URGENCY: readonly number[] = [CATEGORY.medical, CATEGORY.rescue, CATEGORY.evacuation, CATEGORY.water, CATEGORY.food];

/** What needs attention first: by status (unanswered, acknowledged, in progress, resolved), then
 * by urgency of the category, then the longest waiting. Resolved ones: newest first. */
export function byPriority(a: Incident, b: Incident): number {
  if (a.status !== b.status) return a.status - b.status;
  if (a.status === STATUS.resolved) return b.updatedAt - a.updatedAt || b.id - a.id;
  return URGENCY.indexOf(a.category) - URGENCY.indexOf(b.category) || a.id - b.id;
}

export interface Action { kind: number; target: number; submission(incident: number): Submission }

/** The changes the server permits from a status (Mina.Domain.transitions). */
export function actionsFor(status: number): Action[] {
  return TRANSITIONS.filter((t) => t.source === status).map(({ kind, target }) => ({
    kind, target,
    submission: (incident: number): Submission => (kind === KIND.status_updated ? { kind, incident, status: target } : { kind, incident }),
  }));
}
