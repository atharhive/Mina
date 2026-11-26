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

export const LIMITS = {
  maxRegion: 1024,
  maxBodyChars: 280,
  maxLatitude: 9000000,
  maxLongitude: 18000000,
  syncMaxLimit: 256,
} as const;
