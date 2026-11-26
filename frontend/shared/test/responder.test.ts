import "fake-indexeddb/auto";
import { describe, expect, it } from "vitest";
import { KIND, MinaApi, MinaDb, STATUS, SyncEngine, actionsFor, incidents, readToken, type StoredEvent } from "../src";
import { fakeServer, type Call, type Reply } from "./fake";

const b64 = (v: unknown) => Buffer.from(JSON.stringify(v)).toString("base64url");
const jwt = (claims: Record<string, unknown>) => `${b64({ alg: "HS256" })}.${b64(claims)}.signature`;
const good = jwt({ sub: "9", role: 2, rg: "3,7", exp: 4_000_000_000 });

let databases = 0;
function setup(handler: (call: Call) => Reply) {
  const server = fakeServer(handler);
  const db = new MinaDb(`responder-${++databases}`);
  const engine = new SyncEngine(db, new MinaApi("", server.fetch), { now: () => 1_000_000, random: () => 0.5 }, { identity: "given", page: 256 });
  return { server, db, engine };
}

describe("a responder's token", () => {
  it("is read for its role, regions and expiry", () => {
    expect(readToken(good, 1000)).toEqual({ token: good, sub: "9", role: 2, regions: [3, 7], exp: 4_000_000_000 });
  });
  it("is refused when it is not one, has expired or belongs to a citizen", () => {
    for (const bad of ["", "abc", "a.b.c", jwt({ sub: "1", role: 1, exp: 4_000_000_000 }), jwt({ sub: "1", role: 2, rg: "1", exp: 10 }), jwt({ sub: "1", role: 2, exp: 4_000_000_000 })])
      expect(() => readToken(bad, 1000)).toThrow();
  });
  it("lets an admin in without a region list", () => {
    expect(readToken(jwt({ sub: "1", role: 3, exp: 4_000_000_000 }), 1000).regions).toEqual([]);
  });
});

describe("an engine with a given identity", () => {
  it("never asks the server for a citizen session", async () => {
    const t = setup(() => ({ status: 200, body: { head: 0, next: 0, more: false, events: [] } }));
    await t.engine.pull(3);
    await t.engine.submit({ kind: KIND.sos_acknowledged, incident: 1 });
    await t.engine.flush();
    expect(t.server.calls).toEqual([]);
    expect(await t.db.outbox.toArray()).toMatchObject([{ state: "queued" }]);
  });
  it("sends with the token it was given, in pages of 256", async () => {
    const t = setup((c) => (c.path.startsWith("/v1/sync") ? { status: 200, body: { head: 0, next: 0, more: false, events: [] } } : { status: 201, body: { seq: 4, incident: 1 } }));
    await t.engine.signIn(good);
    await t.engine.submit({ kind: KIND.sos_acknowledged, incident: 1 });
    await t.engine.run(3);
    expect(t.server.calls.map((c) => [c.path, c.token])).toEqual([["/v1/events", good], ["/v1/sync?region=3&after=0&limit=256", good]]);
  });
  it("signs out when the token is refused and keeps what was not sent", async () => {
    const t = setup(() => ({ status: 401, body: { error: "invalid token" } }));
    await t.engine.signIn(good);
    await t.engine.submit({ kind: KIND.sos_acknowledged, incident: 1 });
    await t.engine.flush();
    expect(await t.engine.identity()).toBeUndefined();
    expect(await t.db.outbox.toArray()).toMatchObject([{ state: "queued" }]);
    expect(t.server.calls).toHaveLength(1);
  });
});

const event = (seq: number, kind: number, incident: number | null, status: number | null, extra: Partial<StoredEvent> = {}): StoredEvent =>
  ({ seq, kind, incident, status, region: 3, ts: 1000 + seq, category: 1, body: null, lat: null, lon: null, at: null, ...extra });

describe("the incident list", () => {
  it("follows each report through its updates, whatever order they are stored in", () => {
    const list = incidents([
      event(5, KIND.status_updated, 1, STATUS.in_progress),
      event(1, KIND.sos_created, 1, null, { body: "roof", lat: 10, lon: 20, at: 990 }),
      event(3, KIND.sos_acknowledged, 1, STATUS.acknowledged),
      event(2, KIND.alert_published, null, null),
      event(4, KIND.safety_reported, null, 2),
    ]);
    expect(list).toHaveLength(1);
    expect(list[0]).toMatchObject({ id: 1, status: STATUS.in_progress, body: "roof", lat: 10, lon: 20, reportedAt: 1001, updatedAt: 1005 });
    expect(list[0]!.history.map((h) => h.status)).toEqual([STATUS.open, STATUS.acknowledged, STATUS.in_progress]);
  });
  it("puts what needs attention first: unanswered, then by urgency, then the longest waiting", () => {
    const report = (id: number, category: number) => event(id, KIND.sos_created, id, null, { category });
    const list = incidents([
      report(1, 4), report(2, 1), report(3, 2), report(4, 1), report(5, 1), report(6, 1),
      event(7, KIND.sos_acknowledged, 5, STATUS.acknowledged),
      event(8, KIND.incident_resolved, 6, STATUS.resolved),
    ]);
    // open: medical 2 and 4 (older first), rescue 3, food 1; then acknowledged 5; then resolved 6
    expect(list.map((i) => i.id)).toEqual([2, 4, 3, 1, 5, 6]);
  });
  it("offers only the permitted changes", () => {
    expect(actionsFor(STATUS.open).map((a) => a.target)).toEqual([STATUS.acknowledged, STATUS.resolved]);
    expect(actionsFor(STATUS.acknowledged).map((a) => a.target)).toEqual([STATUS.in_progress, STATUS.resolved]);
    expect(actionsFor(STATUS.in_progress).map((a) => a.target)).toEqual([STATUS.acknowledged, STATUS.resolved]);
    expect(actionsFor(STATUS.resolved)).toEqual([]);
    expect(actionsFor(STATUS.in_progress)[0]!.submission(12)).toEqual({ kind: KIND.status_updated, incident: 12, status: STATUS.acknowledged });
    expect(actionsFor(STATUS.open)[0]!.submission(12)).toEqual({ kind: KIND.sos_acknowledged, incident: 12 });
  });
});

describe("several areas", () => {
  it("synchronises every area asked for, also when asked during a run", async () => {
    const t = setup(() => ({ status: 200, body: { head: 0, next: 0, more: false, events: [] } }));
    await t.engine.signIn(good);
    const first = t.engine.run(3);
    await Promise.all([first, t.engine.run(7), t.engine.run(3, 9)]);
    const asked = new Set(t.server.calls.map((c) => new URL(c.path, "http://x").searchParams.get("region")));
    expect([...asked].sort()).toEqual(["3", "7", "9"]);
  });
});

describe("a long backlog", () => {
  it("is fetched to its end in one run, still sending in between", async () => {
    const pages = 50;
    const t = setup((c) => {
      if (c.path === "/v1/events") return { status: 201, body: { seq: 999, incident: 1 } };
      const after = Number(new URL(c.path, "http://x").searchParams.get("after"));
      return { status: 200, body: { head: pages, next: after + 1, more: after + 1 < pages, events: [] } };
    });
    await t.engine.signIn(good);
    const running = t.engine.run(3);
    await t.engine.submit({ kind: KIND.sos_acknowledged, incident: 1 });
    await running;
    expect(await t.engine.cursor(3)).toBe(pages);
    const sent = t.server.calls.findIndex((c) => c.path === "/v1/events");
    expect(sent).toBeGreaterThanOrEqual(0);
    expect(sent).toBeLessThan(t.server.calls.length - 1);                // not held until the end
  });
  it("stops when the server stops answering", async () => {
    let calls = 0;
    const t = setup(() => (++calls > 3 ? "offline" : { status: 200, body: { head: 99, next: calls, more: true, events: [] } }));
    await t.engine.signIn(good);
    await t.engine.run(3);
    expect(calls).toBe(4);
  });
});
