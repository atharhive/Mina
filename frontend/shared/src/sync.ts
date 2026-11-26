import type { MinaApi, Session } from "./api";
import { backoffMs } from "./backoff";
import type { MinaDb, OutboxItem } from "./db";
import { KIND_RULES, checkSubmission, type Submission } from "./protocol";

export interface Clock { now(): number; random(): number }
const PAGE = 64;
const MAX_PAGES = 20;          // per pull; the next run continues from the cursor

const eventId = () => Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("");

export class SyncEngine {
  private flushing: Promise<void> | undefined;
  private running: Promise<void> | undefined;
  private again = false;

  constructor(private readonly db: MinaDb, private readonly api: MinaApi,
    private readonly clock: Clock = { now: Date.now, random: Math.random }) {}

  /** Save a report on this device. Resolves once it is stored; sending happens separately. */
  async submit(submission: Submission): Promise<OutboxItem> {
    const payload = checkSubmission(submission);
    if (payload.at === undefined && KIND_RULES[payload.kind]!.optional.includes("at")) payload.at = Math.floor(this.clock.now() / 1000);
    const item: OutboxItem = { eid: eventId(), payload, state: "queued", attempts: 0, createdAt: this.clock.now(), nextAttemptAt: 0 };
    item.id = await this.db.outbox.add(item);
    return item;
  }

  /** Send what is waiting, then fetch what is new for the region. Only one run is active at a
   * time; a call during a run makes it go round once more. */
  run(region: number): Promise<void> {
    if (this.running) {
      this.again = true;
      return this.running;
    }
    this.running = (async () => {
      do {
        this.again = false;
        await this.flush();
        await this.pull(region);
      } while (this.again);
    })().finally(() => (this.running = undefined));
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
   * transaction, so the cursor moves only when the events are saved. */
  async pull(region: number): Promise<void> {
    let restarted = false;
    for (let page = 0; page < MAX_PAGES; page++) {
      const token = await this.token();
      if (!token) return;
      const reply = await this.api.sync(token, region, await this.cursor(region), PAGE);
      if (reply.ok) {
        const { events, next, more } = reply.value;
        await this.db.transaction("rw", this.db.events, this.db.meta, async () => {
          await this.db.events.bulkPut(events);
          await this.db.meta.put({ key: `cursor:${region}`, value: next });
        });
        if (!more) return;
      } else if (reply.failure === "resync" && !restarted) {
        restarted = true;
        await this.db.transaction("rw", this.db.events, this.db.meta, async () => {
          await this.db.events.where("region").equals(region).delete();
          await this.db.meta.delete(`cursor:${region}`);
        });
      } else {
        if (reply.failure === "auth") await this.db.meta.delete("session");
        return;
      }
    }
  }

  private async token(): Promise<string | undefined> {
    const kept = (await this.db.meta.get("session"))?.value as Session | undefined;
    if (kept && kept.exp - 60 > this.clock.now() / 1000) return kept.token;
    const reply = await this.api.session();
    if (!reply.ok) return undefined;
    await this.db.meta.put({ key: "session", value: reply.value });
    return reply.value.token;
  }
}
