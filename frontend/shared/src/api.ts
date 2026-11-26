import type { Metrics } from "./metrics";
import { decodeEvent, type StoredEvent, type Submission } from "./protocol";

/** Why a request did not succeed, in terms of what to do next. */
export type Failure =
  | "offline"      // no answer: try again later
  | "temporary"    // the server asks to try later (429, 5xx) or answered unexpectedly
  | "auth"         // the token is not accepted
  | "resync"       // the cursor is ahead of the server: start the region over
  | "used"         // the event id is already stored under another identity
  | "rejected";    // the request itself is refused: do not repeat it
export type Result<T> = { ok: true; value: T } | { ok: false; failure: Failure; message: string };

export interface Session { token: string; sub: string; exp: number }
export interface Stored { seq: number; incident: number | null; duplicate: boolean }
export interface Page { head: number; next: number; more: boolean; events: StoredEvent[] }

const TIMEOUT_MS = 15_000;

export class MinaApi {
  constructor(private readonly base = "", private readonly fetchFn: typeof fetch = fetch) {}

  session(): Promise<Result<Session>> {
    return this.call("/v1/session", { method: "POST" }, 201, (b) => (typeof b.token === "string" ? (b as Session) : null));
  }

  submit(token: string, submission: Submission & { eid?: string }): Promise<Result<Stored>> {
    const init = { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(submission) };
    return this.call("/v1/events", init, [201, 200], (b) =>
      Number.isInteger(b.seq) ? { seq: b.seq, incident: b.incident ?? null, duplicate: b.duplicate === true } : null);
  }

  metrics(token: string): Promise<Result<Metrics>> {
    return this.call("/v1/metrics", { headers: { authorization: `Bearer ${token}` } }, 200, (b) => (b.runtime && b.db && b.process && b.app ? (b as Metrics) : null));
  }

  sync(token: string, region: number, after: number, limit: number): Promise<Result<Page>> {
    return this.call(`/v1/sync?region=${region}&after=${after}&limit=${limit}`, { headers: { authorization: `Bearer ${token}` } }, 200, (b) =>
      Array.isArray(b.events) && Number.isInteger(b.next)
        ? { head: b.head, next: b.next, more: b.more === true, events: b.events.map((e: unknown[]) => decodeEvent(e, region)) }
        : null);
  }

  private async call<T>(path: string, init: RequestInit, success: number | number[], read: (body: any) => T | null): Promise<Result<T>> {
    let status: number;
    let body: any;
    try {
      const send = this.fetchFn;
      const response = await send(this.base + path, { ...init, signal: AbortSignal.timeout(TIMEOUT_MS) });
      status = response.status;
      body = await response.json();
    } catch (error) {
      return { ok: false, failure: "offline", message: String(error) };
    }
    if ([success].flat().includes(status)) {
      const value = read(body ?? {});
      return value === null ? { ok: false, failure: "temporary", message: "unexpected answer" } : { ok: true, value };
    }
    const message = typeof body?.error === "string" ? body.error : `status ${status}`;
    const failure: Failure =
      status === 401 ? "auth"
      : status === 409 && message === "resync" ? "resync"
      : status === 409 && message === "event id already used" ? "used"
      : status >= 400 && status < 500 && status !== 429 ? "rejected"
      : "temporary";
    return { ok: false, failure, message };
  }
}
