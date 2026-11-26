// GENERATED from spec/Mina (Mina.Codegen.TypeScript). Do not edit.

export const ROLE = {
  citizen: 1,
  responder: 2,
  admin: 3,
} as const;
export const KIND = {
  sos_created: 1,
  sos_acknowledged: 2,
  status_updated: 3,
  incident_resolved: 4,
  safety_reported: 5,
  alert_published: 6,
} as const;
export const STATUS = {
  open: 1,
  acknowledged: 2,
  in_progress: 3,
  resolved: 4,
} as const;
export const CATEGORY = {
  medical: 1,
  rescue: 2,
  evacuation: 3,
  food: 4,
  water: 5,
} as const;
export const SAFETY = {
  safe: 1,
  needs_help: 2,
} as const;

export type Field = "region" | "category" | "status" | "body" | "location" | "incident" | "at";
export interface KindRule { roles: readonly number[]; required: readonly Field[]; optional: readonly Field[]; statusRange: readonly [number, number] }
export const KIND_RULES: Readonly<Record<number, KindRule>> = {
  1: { roles: [1, 2, 3], required: ["region", "category"], optional: ["body", "location", "at"], statusRange: [0, 0] },
  2: { roles: [2, 3], required: ["incident"], optional: ["at"], statusRange: [0, 0] },
  3: { roles: [2, 3], required: ["incident", "status"], optional: ["at"], statusRange: [2, 3] },
  4: { roles: [2, 3], required: ["incident"], optional: ["at"], statusRange: [0, 0] },
  5: { roles: [1, 2, 3], required: ["region", "status"], optional: ["body", "location", "at"], statusRange: [1, 2] },
  6: { roles: [2, 3], required: ["region", "body"], optional: ["at"], statusRange: [0, 0] },
};

/** Every permitted change of an incident (Mina.Domain.transitions). */
export const TRANSITIONS: ReadonlyArray<{ kind: number; source: number; target: number }> = [
  { kind: 2, source: 1, target: 2 },
  { kind: 3, source: 2, target: 3 },
  { kind: 3, source: 3, target: 2 },
  { kind: 4, source: 1, target: 4 },
  { kind: 4, source: 2, target: 4 },
  { kind: 4, source: 3, target: 4 },
];

/** A synchronised event is an array with these members, in this order. */
export const EVENT_COLUMNS = ["seq", "kind", "ts", "incident", "category", "status", "body", "lat", "lon", "at"] as const;

/** Theorems about the model (Mina.Verified; docs/PROOFS.md). */
export const VERIFIED: ReadonlyArray<{ name: string; statement: string }> = [
  { name: "syncPlan_eq", statement: "The native index scan returns exactly what the reference query returns." },
  { name: "syncAllPlan_eq", statement: "Merging the two streams of a region returns exactly the responder query." },
  { name: "head_empty", statement: "A cursor at or past a stream's newest event has an empty answer." },
  { name: "head_preserved", statement: "Updating the remembered newest number at each insert keeps it exact." },
  { name: "apply_idem", statement: "Submitting an event twice is submitting it once." },
  { name: "cursor_mono", statement: "A synchronisation cursor never goes back." },
  { name: "pages_compose", statement: "Two pages read in turn equal one longer page." },
  { name: "no_skip", statement: "No event up to the returned cursor is missed, even as events are appended." },
  { name: "resolved_is_final", statement: "A resolved incident cannot change again." },
  { name: "updates_are_public", statement: "Public incident updates cannot carry a report's text or location." },
  { name: "citizens_cannot_update", statement: "Citizens cannot change an incident's status." },
];

export const LIMITS = {
  maxRegion: 1024,
  maxBodyChars: 280,
  maxLatitude: 9000000,
  maxLongitude: 18000000,
  syncMaxLimit: 256,
} as const;
