import type { OutboxItem } from "./db";
import { KIND, STATUS, type StoredEvent } from "./protocol";

/** What the person is told. Nothing before "delivered" suggests that anyone has received it. */
export type DisplayStatus = "saved" | "waiting" | "delivered" | "acknowledged" | "in_progress" | "resolved" | "rejected";

const UPDATES: readonly number[] = [KIND.sos_acknowledged, KIND.status_updated, KIND.incident_resolved];

export function displayStatus(item: OutboxItem, events: readonly StoredEvent[], online: boolean): DisplayStatus {
  if (item.state === "rejected") return "rejected";
  if (item.state === "queued") return online ? "waiting" : "saved";
  let latest: StoredEvent | undefined;
  for (const e of events)
    if (item.incident !== undefined && e.incident === item.incident && UPDATES.includes(e.kind) && (!latest || e.seq > latest.seq)) latest = e;
  if (latest?.status === STATUS.resolved) return "resolved";
  if (latest?.status === STATUS.in_progress) return "in_progress";
  if (latest?.status === STATUS.acknowledged) return "acknowledged";
  return "delivered";
}
