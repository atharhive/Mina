import "fake-indexeddb/auto";
import { describe, expect, it } from "vitest";
import { CATEGORY, KIND, MinaApi, MinaDb, SyncEngine, backoffMs, displayStatus } from "../src";
import { fakeServer, type Call, type Reply } from "./fake";

let databases = 0;
function setup(handler: (call: Call) => Reply, name = `db-${++databases}`) {
  const server = fakeServer(handler);
  const db = new MinaDb(name);
  let now = 1_000_000;
  const engine = new SyncEngine(db, new MinaApi("", server.fetch), { now: () => now, random: () => 0.5 });
  return { server, db, engine, name, advance: (ms: number) => (now += ms) };
}
const session: Reply = { status: 201, body: { token: "T1", sub: "42", exp: 4_000_000_000 } };
const posts = (calls: Call[]) => calls.filter((c) => c.path === "/v1/events");
const sos = { kind: KIND.sos_created, region: 1, category: CATEGORY.medical, body: "leg injury" };

describe("saving on the device", () => {
  it("stores a submission before anything is sent", async () => {
    const t = setup(() => "offline");
    const item = await t.engine.submit(sos);
    expect(item.eid).toMatch(/^[0-9a-f]{32}$/);
    const stored = await t.db.outbox.toArray();
    expect(stored).toHaveLength(1);
    expect(stored[0]).toMatchObject({ state: "queued", attempts: 0, eid: item.eid });
    expect(t.server.calls).toHaveLength(0);
    expect(displayStatus(stored[0]!, [], false)).toBe("saved");
    expect(displayStatus(stored[0]!, [], true)).toBe("waiting");
  });

  it("refuses what the server would refuse, without storing it", async () => {
    const t = setup(() => "offline");
    await expect(t.engine.submit({ kind: KIND.sos_created, region: 1 })).rejects.toThrow(/category/);
    await expect(t.engine.submit({ ...sos, incident: 3 })).rejects.toThrow(/incident/);
    await expect(t.engine.submit({ ...sos, region: 0 })).rejects.toThrow(/region/);
    await expect(t.engine.submit({ ...sos, body: "x".repeat(281) })).rejects.toThrow(/280/);
    expect(await t.db.outbox.count()).toBe(0);
  });

  it("survives a restart of the app", async () => {
    const first = setup(() => "offline");
    const item = await first.engine.submit(sos);
    first.db.close();
    const again = setup((c) => (c.path === "/v1/session" ? session : { status: 201, body: { seq: 7, incident: 7 } }), first.name);
    await again.engine.run(1);
    expect(posts(again.server.calls).map((c) => c.body.eid)).toEqual([item.eid]);
  });
});

describe("sending", () => {
  it("marks a stored submission delivered", async () => {
    const t = setup((c) => (c.path === "/v1/session" ? session : { status: 201, body: { seq: 7, incident: 7 } }));
    await t.engine.submit(sos);
    await t.engine.flush();
    expect(await t.db.outbox.toArray()).toMatchObject([{ state: "delivered", seq: 7, incident: 7 }]);
  });

  it("keeps the order and waits longer after each failure", async () => {
    const t = setup((c) => (c.path === "/v1/session" ? session : "offline"));
    await t.engine.submit(sos);
    await t.engine.submit({ ...sos, body: "second" });
    await t.engine.flush();
    expect(posts(t.server.calls)).toHaveLength(1);                       // the second waits its turn
    await t.engine.flush();
    expect(posts(t.server.calls)).toHaveLength(1);                       // too early to retry
    t.advance(backoffMs(1, () => 0.5));
    await t.engine.flush();
    expect(posts(t.server.calls)).toHaveLength(2);
    expect((await t.db.outbox.orderBy("id").first())?.attempts).toBe(2);
  });

  it("retries with the same event id after a lost answer, and accepts the duplicate", async () => {
    let lose = true;
    const t = setup((c) => {
      if (c.path === "/v1/session") return session;
      if (lose) { lose = false; return "offline"; }                     // stored, answer lost
      return { status: 200, body: { seq: 9, incident: 9, duplicate: true } };
    });
    await t.engine.submit(sos);
    await t.engine.flush();
    t.advance(60_000);
    await t.engine.flush();
    const sent = posts(t.server.calls);
    expect(sent).toHaveLength(2);
    expect(sent[1]!.body).toEqual(sent[0]!.body);
    expect(await t.db.outbox.toArray()).toMatchObject([{ state: "delivered", seq: 9 }]);
  });

  it("sets aside what the server rejects and sends the rest", async () => {
    const t = setup((c) => {
      if (c.path === "/v1/session") return session;
      return c.body.body === "leg injury" ? { status: 400, body: { error: "invalid body" } } : { status: 201, body: { seq: 3, incident: 3 } };
    });
    await t.engine.submit(sos);
    await t.engine.submit({ ...sos, body: "second" });
    await t.engine.flush();
    expect((await t.db.outbox.orderBy("id").toArray()).map((i) => [i.state, i.error])).toEqual([["rejected", "invalid body"], ["delivered", undefined]]);
  });

  it("treats a rate limit and a server error as temporary", async () => {
    for (const status of [429, 500, 503]) {
      const t = setup((c) => (c.path === "/v1/session" ? session : { status, body: { error: "x" } }));
      await t.engine.submit(sos);
      await t.engine.flush();
      expect(await t.db.outbox.toArray()).toMatchObject([{ state: "queued", attempts: 1 }]);
    }
  });

  it("gets a new identity when the token is refused", async () => {
    let issued = 0;
    const t = setup((c) => {
      if (c.path === "/v1/session") return { status: 201, body: { token: `T${++issued}`, sub: `${issued}`, exp: 4_000_000_000 } };
      return c.token === "T1" ? { status: 401, body: { error: "invalid token" } } : { status: 201, body: { seq: 1, incident: 1 } };
    });
    await t.engine.submit(sos);
    await t.engine.flush();
    expect(issued).toBe(2);
    expect(await t.db.outbox.toArray()).toMatchObject([{ state: "delivered" }]);
  });
});

const page = (events: unknown[][], next: number, more: boolean, head = next): Reply => ({ status: 200, body: { head, events, next, more } });
const ev = (seq: number, kind = 6, incident: number | null = null, status: number | null = null) =>
  [seq, kind, 1790000000, incident, null, status, kind === 6 ? "alert" : null, null, null, null];

describe("receiving", () => {
  it("applies pages and moves the cursor with them", async () => {
    const t = setup((c) => {
      if (c.path === "/v1/session") return session;
      return c.path.includes("after=0&") ? page([ev(1), ev(2)], 2, true, 3) : page([ev(3)], 3, false);
    });
    await t.engine.pull(4);
    expect((await t.db.events.orderBy("seq").toArray()).map((e) => e.seq)).toEqual([1, 2, 3]);
    expect(await t.engine.cursor(4)).toBe(3);
    expect(t.server.calls.filter((c) => c.path.startsWith("/v1/sync")).map((c) => c.path)).toEqual(
      ["/v1/sync?region=4&after=0&limit=64", "/v1/sync?region=4&after=2&limit=64"]);
  });

  it("does not move the cursor if the events cannot be saved", async () => {
    const t = setup((c) => (c.path === "/v1/session" ? session : page([ev(1)], 1, false)));
    t.db.events.hook("creating", () => { throw new Error("disk full"); });
    await expect(t.engine.pull(4)).rejects.toThrow();
    expect(await t.engine.cursor(4)).toBe(0);
    expect(await t.db.events.count()).toBe(0);
  });

  it("starts over when the server asks for a resynchronisation", async () => {
    let restored = false;
    const t = setup((c) => {
      if (c.path === "/v1/session") return session;
      if (!restored) return page([ev(5)], 5, false);
      return c.path.includes("after=5&") ? { status: 409, body: { error: "resync" } } : page([ev(2)], 2, false);
    });
    await t.engine.pull(4);
    restored = true;
    await t.engine.pull(4);
    expect((await t.db.events.toArray()).map((e) => e.seq)).toEqual([2]);
    expect(await t.engine.cursor(4)).toBe(2);
  });

  it("shows a report as acknowledged, then resolved, from the public updates", async () => {
    const item = { eid: "a".repeat(32), state: "delivered" as const, seq: 7, incident: 7, attempts: 1, createdAt: 0, nextAttemptAt: 0, payload: sos };
    const update = (seq: number, kind: number, status: number) => ({ seq, kind, ts: 0, incident: 7, category: 1, status, body: null, lat: null, lon: null, at: null, region: 1 });
    expect(displayStatus(item, [], true)).toBe("delivered");
    expect(displayStatus(item, [update(8, 2, 2)], true)).toBe("acknowledged");
    expect(displayStatus(item, [update(8, 2, 2), update(9, 3, 3)], true)).toBe("in_progress");
    expect(displayStatus(item, [update(10, 4, 4), update(8, 2, 2)], false)).toBe("resolved");
  });
});

describe("backoff", () => {
  it("doubles, is capped at a minute, and is spread by jitter", () => {
    expect(backoffMs(1, () => 0)).toBe(1000);
    expect(backoffMs(1, () => 1)).toBe(2000);
    expect(backoffMs(3, () => 0)).toBe(4000);
    expect(backoffMs(30, () => 1)).toBe(60_000);
    expect(backoffMs(30, () => 0)).toBe(30_000);
  });
});
