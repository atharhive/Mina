import Dexie, { type Table } from "dexie";
import type { StoredEvent, Submission } from "./protocol";

/** Something this device wants the server to store. It is written here before any attempt to
 * send it and stays here afterwards as the person's history. */
export interface OutboxItem {
  id?: number;
  eid: string;
  payload: Submission;
  state: "queued" | "delivered" | "rejected";
  attempts: number;
  createdAt: number;
  nextAttemptAt: number;
  seq?: number;
  incident?: number;
  error?: string;
}
export interface Meta { key: string; value: unknown }

export class MinaDb extends Dexie {
  declare outbox: Table<OutboxItem, number>;
  declare events: Table<StoredEvent, number>;
  declare meta: Table<Meta, string>;

  constructor(name = "mina") {
    super(name);
    this.version(1).stores({ outbox: "++id, &eid, state", events: "seq, region, incident", meta: "key" });
  }
}
