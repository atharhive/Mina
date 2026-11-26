/** Wire types over the constants generated from the Lean specification. */
import { EVENT_COLUMNS, KIND_RULES, LIMITS, type Field } from "../../../gen/protocol";
export * from "../../../gen/protocol";

/** One synchronised event, with the region it was requested for. */
export interface StoredEvent {
  seq: number; region: number; kind: number; ts: number; incident: number | null; category: number | null;
  status: number | null; body: string | null; lat: number | null; lon: number | null; at: number | null;
}

export function decodeEvent(row: readonly unknown[], region: number): StoredEvent {
  const event = Object.fromEntries(EVENT_COLUMNS.map((name, i) => [name, row[i] ?? null]));
  return { ...(event as unknown as Omit<StoredEvent, "region">), region };
}

/** The fields of a submission, apart from the event id the client adds. */
export interface Submission {
  kind: number; region?: number; category?: number; status?: number; incident?: number;
  body?: string; lat?: number; lon?: number; at?: number;
}

const integer = (v: unknown, lo: number, hi: number) => Number.isInteger(v) && (v as number) >= lo && (v as number) <= hi;

/** Applies the server's field rules (Mina.Domain), so that a mistake is reported while the
 * person can still fix it, not after hours offline. Returns the submission to store. */
export function checkSubmission(input: Submission): Submission {
  const rule = KIND_RULES[input.kind];
  if (!rule) throw new Error(`unknown kind ${input.kind}`);
  const s: Submission = { ...input };
  if (s.body !== undefined) {
    s.body = s.body.trim();
    if (!s.body) delete s.body;
  }
  const present: Field[] = (["region", "category", "status", "incident", "body", "at"] as const).filter((f) => s[f] !== undefined);
  if (s.lat !== undefined || s.lon !== undefined) present.push("location");
  for (const f of present) if (!rule.required.includes(f) && !rule.optional.includes(f)) throw new Error(`${f} is not part of this kind of report`);
  for (const f of rule.required) if (!present.includes(f)) throw new Error(`${f} is required`);
  if (s.region !== undefined && !integer(s.region, 1, LIMITS.maxRegion)) throw new Error("region is out of range");
  if (s.category !== undefined && !integer(s.category, 1, 5)) throw new Error("category is out of range");
  if (s.status !== undefined && !integer(s.status, rule.statusRange[0], rule.statusRange[1])) throw new Error("status is out of range");
  if (s.incident !== undefined && !integer(s.incident, 1, Number.MAX_SAFE_INTEGER)) throw new Error("incident is not valid");
  if (present.includes("location") && !(integer(s.lat, -LIMITS.maxLatitude, LIMITS.maxLatitude) && integer(s.lon, -LIMITS.maxLongitude, LIMITS.maxLongitude)))
    throw new Error("location is not valid");
  if (s.body !== undefined) {
    if ([...s.body].length > LIMITS.maxBodyChars) throw new Error(`the text is longer than ${LIMITS.maxBodyChars} characters`);
    if (/[\u0000-\u0008\u000b-\u001f]/.test(s.body)) throw new Error("the text contains control characters");
  }
  return s;
}
