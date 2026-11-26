import type { MinaApi, Session } from "./api";
import { readToken, type Responder } from "./identity";
import { backoffMs } from "./backoff";
import type { MinaDb, OutboxItem } from "./db";
import { KIND_RULES, checkSubmission, type Submission } from "./protocol";

export interface Clock { now(): number; random(): number }
/** "own": a citizen device asks the server for an identity when it needs one. "given": a
 * responder signs in with an issued token, and is signed out if the server refuses it. */
export interface Options { identity?: "own" | "given"; page?: number }
const MAX_PAGES = 20;          // per pull, so that queued reports are not held back by a long backlog

const eventId = () => Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("");

export class SyncEngine {
  private flushing: Promise<void> | undefined;
  private running: Promise<void> | undefined;
  private readonly wanted = new Set<number>();
  /** Set once a run has started over, so that it happens at most once per run. */
  private startedOver = false;

  constructor(private readonly db: MinaDb, private readonly api: MinaApi,
    private readonly clock: Clock = { now: Date.now, random: Math.random }, private readonly options: Options = {}) {}

  /** Keep an issued token on this device. Throws if it cannot be used. */
  async signIn(token: string): Promise<Responder> {
    const responder = readToken(token, this.clock.now() / 1000);
    await this.db.meta.put({ key: "session", value: responder });
    return responder;
  }

  async identity(): Promise<Session | undefined> {
    return (await this.db.meta.get("session"))?.value as Session | undefined;
  }

  /** Save a report on this device. Resolves once it is stored; sending happens separately. */
  async submit(submission: Submission): Promise<OutboxItem> {
    const payload = checkSubmission(submission);
    if (payload.at === undefined && KIND_RULES[payload.kind]!.optional.includes("at")) payload.at = Math.floor(this.clock.now() / 1000);
    const item: OutboxItem = { eid: eventId(), payload, state: "queued", attempts: 0, createdAt: this.clock.now(), nextAttemptAt: 0 };
    item.id = await this.db.outbox.add(item);
    return item;
  }

  /** Send what is waiting, then fetch what is new for the regions. Only one run is active at a
   * time; what is asked during a run is done before it ends. */
  run(...regions: number[]): Promise<void> {
    for (const region of regions) this.wanted.add(region);
    this.running ??= (async () => {
      this.startedOver = false;
      try {
        while (this.wanted.size > 0) {
          const now = [...this.wanted];
          this.wanted.clear();
          await this.flush();
          // a region with more waiting goes round again, after another chance to send
          for (const region of now) if (await this.pull(region)) this.wanted.add(region);
        }
      } finally {
        this.running = undefined;
      }
    })();
    return this.running;
  }

  /** Make every queued report due now: connectivity has returned or the app was reopened. */
  async retryNow(): Promise<void> {
    await this.db.outbox.where("state").equals("queued").modify({ nextAttemptAt: 0 });
  }

  /** Send queued reports oldest first. One that cannot be sent yet holds back those after it. */
  flush(): Promise<void> {
    this.flushing ??= this.flushOnce().finally(() => (this.flushing = undefined));
    return this.flushing;
  }

  private async flushOnce(): Promise<void> {
    let renewed = false;
    for (;;) {
      const item = await this.db.outbox.where("state").equals("queued").first();     // lowest id
      if (!item || item.nextAttemptAt > this.clock.now()) return;
      const token = await this.token();
      if (!token) return this.postpone(item);
      const reply = await this.api.submit(token, { eid: item.eid, ...item.payload });
      if (reply.ok) {
        const { seq, incident } = reply.value;
        await this.db.outbox.update(item.id!, { state: "delivered", seq, ...(incident === null ? {} : { incident }) });
      } else if (reply.failure === "used") {
        // Stored earlier under a previous identity of this device (the answer was lost).
        await this.db.outbox.update(item.id!, { state: "delivered" });
      } else if (reply.failure === "rejected") {
        await this.db.outbox.update(item.id!, { state: "rejected", error: reply.message });
      } else if (reply.failure === "auth" && !renewed) {
        renewed = true;
        await this.db.meta.delete("session");
      } else return this.postpone(item);
    }
  }

  private async postpone(item: OutboxItem): Promise<void> {
    const attempts = item.attempts + 1;
    await this.db.outbox.update(item.id!, { attempts, nextAttemptAt: this.clock.now() + backoffMs(attempts, () => this.clock.random()) });
  }

  async cursor(region: number): Promise<number> {
    return ((await this.db.meta.get(`cursor:${region}`))?.value as number | undefined) ?? 0;
  }

  /** Fetch the events after the stored cursor. Events and cursor are written in one local
   * transaction, so the cursor moves only when the events are saved. True if the server has
   * more to give. */
  async pull(region: number): Promise<boolean> {
    let replaced = false;
    for (let page = 0; page < MAX_PAGES; page++) {
      const token = await this.token();
      if (!token) return false;
      const reply = await this.api.sync(token, region, await this.cursor(region), this.options.page ?? 64);
      if (reply.ok) {
        const { events, next, more, generation } = reply.value;
        const known = (await this.db.meta.get("generation"))?.value as number | undefined;
        if (known !== undefined && known !== generation) {
          // the server's database was replaced: this page answers an out-of-date cursor
          if (this.startedOver) return false;
          await this.startOver(generation);
          replaced = true;
          continue;
        }
        if (known === undefined) await this.db.meta.put({ key: "generation", value: generation });
        await this.db.transaction("rw", this.db.events, this.db.meta, async () => {
          await this.db.events.bulkPut(events);
          await this.db.meta.put({ key: `cursor:${region}`, value: next });
        });
        if (!more) return replaced;             // true: come back, after sending what was queued again
      } else if (reply.failure === "resync" && !this.startedOver) {
        await this.startOver();                 // the server has less than this device has seen
        replaced = true;
      } else {
        if (reply.failure === "auth") await this.db.meta.delete("session");
        return false;
      }
    }
    return true;
  }

  /** The server may have lost what it once confirmed. Forget what was read, and queue again
   * everything it had accepted: the event ids are unchanged, so what it still has is answered as
   * a duplicate and nothing is stored twice. */
  private async startOver(generation?: number): Promise<void> {
    this.startedOver = true;
    await this.db.transaction("rw", this.db.outbox, this.db.events, this.db.meta, async () => {
      await this.db.events.clear();
      await this.db.meta.where("key").startsWith("cursor:").delete();
      if (generation !== undefined) await this.db.meta.put({ key: "generation", value: generation });
      await this.db.outbox.where("state").equals("delivered").modify({ state: "queued", attempts: 0, nextAttemptAt: 0 });
    });
  }

  private async token(): Promise<string | undefined> {
    const kept = await this.identity();
    if (kept && kept.exp - 60 > this.clock.now() / 1000) return kept.token;
    if (this.options.identity === "given") return undefined;
    const reply = await this.api.session();
    if (!reply.ok) return undefined;
    await this.db.meta.put({ key: "session", value: reply.value });
    return reply.value.token;
  }
}
