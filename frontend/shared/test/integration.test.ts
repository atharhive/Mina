/** The engine against the real server: report while it is down, bring it up, follow the report
 * to resolution. Needs ./build.sh and sqlite3. */
import "fake-indexeddb/auto";
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { CATEGORY, KIND, MinaApi, MinaDb, STATUS, SyncEngine, displayStatus } from "../src";

const root = new URL("../../../", import.meta.url).pathname;
const secret = "0123456789abcdef0123456789abcdef";
const port = 3981;
let dir = "";
let server: ChildProcess | undefined;

async function start() {
  server = spawn(join(root, "bin/mina-server"), { env: { MINA_DB: join(dir, "m.db"), MINA_SECRET: secret, MINA_PORT: String(port) }, stdio: "ignore" });
  for (let i = 0; i < 100; i++) {
    try { if ((await fetch(`http://127.0.0.1:${port}/v1/health`)).ok) return; } catch { /* not yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("server did not start");
}
async function stop() {
  const gone = new Promise((r) => server!.once("exit", r));
  server!.kill();
  await gone;
}
const sql = (q: string) => execFileSync("sqlite3", [join(dir, "m.db"), q], { encoding: "utf8" }).trim();

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), "mina-it-"));
  execFileSync("sqlite3", [join(dir, "m.db")], { input: readFileSync(join(root, "gen/schema.sql")) });
});
afterAll(() => { server?.kill(); rmSync(dir, { recursive: true, force: true }); });

describe("against the real server", () => {
  it("delivers a report made while offline exactly once and follows it to resolution", async () => {
    let now = Date.now();
    const clock = { now: () => now, random: () => 0.5 };
    const api = new MinaApi(`http://127.0.0.1:${port}`, fetch);
    const db = new MinaDb("integration");
    const citizen = new SyncEngine(db, api, clock);

    await citizen.submit({ kind: KIND.sos_created, region: 3, category: CATEGORY.rescue, body: "on the roof", lat: 2812345, lon: 7712345, at: Math.floor(now / 1000) });
    await citizen.run(3);                                   // nothing is listening
    let item = (await db.outbox.toArray())[0]!;
    expect(item.state).toBe("queued");

    await start();
    now += 120_000;
    await citizen.run(3);
    await citizen.run(3);
    item = (await db.outbox.toArray())[0]!;
    expect(item).toMatchObject({ state: "delivered", seq: 1, incident: 1 });
    expect(sql("SELECT count(*) FROM events")).toBe("1");

    const token = execFileSync(join(root, "bin/mina-admin"), ["token", "--sub", "9", "--role", "responder", "--regions", "3"], { env: { MINA_SECRET: secret }, encoding: "utf8" }).trim();
    const responder = async (kind: number) => {
      const reply = await api.submit(token, { eid: String(kind).padStart(32, "0"), kind, incident: 1 });
      expect(reply.ok).toBe(true);
    };
    await responder(KIND.sos_acknowledged);
    await citizen.run(3);
    expect(displayStatus(item, await db.events.toArray(), true)).toBe("acknowledged");
    await responder(KIND.incident_resolved);
    await citizen.run(3);
    const events = await db.events.orderBy("seq").toArray();
    expect(displayStatus(item, events, true)).toBe("resolved");
    expect(events.map((e) => [e.kind, e.status, e.body, e.region])).toEqual([[2, STATUS.acknowledged, null, 3], [4, STATUS.resolved, null, 3]]);

    // an older copy of the database is restored: a report made after the copy is gone from the server
    execFileSync(join(root, "tools/backup.sh"), [join(dir, "m.db"), join(dir, "backup.db")]);
    await citizen.submit({ kind: KIND.safety_reported, region: 3, status: 2 });
    await citizen.run(3);
    expect(sql("SELECT count(*) FROM events WHERE kind = 5")).toBe("1");
    await stop();
    execFileSync(join(root, "tools/restore.sh"), [join(dir, "backup.db"), join(dir, "m.db")]);
    expect(sql("SELECT count(*) FROM events WHERE kind = 5")).toBe("0");
    await start();
    now += 120_000;
    await citizen.run(3);
    await citizen.run(3);
    expect(sql("SELECT count(*) FROM events WHERE kind = 5")).toBe("1");              // sent again, once
    expect(sql("SELECT count(*) FROM events WHERE kind = 1")).toBe("1");              // the older one was kept
    const mine = await db.outbox.orderBy("id").toArray();
    expect(mine.map((i) => i.state)).toEqual(["delivered", "delivered"]);
    expect(displayStatus(mine[0]!, await db.events.toArray(), true)).toBe("resolved");
  });
});
