/** The responder interface served by the real server: sign in, see reports in priority order,
 * move one to resolved, publish an alert, work through a dropped connection. Needs
 * ./build.sh web and sqlite3. */
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "@playwright/test";

const root = new URL("../../../", import.meta.url).pathname;
const secret = "0123456789abcdef0123456789abcdef";
const base = "http://127.0.0.1:4318";
let dir = "";
let server: ChildProcess;

const sql = (q: string) => execFileSync("sqlite3", [join(dir, "m.db"), q], { encoding: "utf8" }).trim();
const token = (...args: string[]) => execFileSync(join(root, "bin/mina-admin"), ["token", ...args], { env: { MINA_SECRET: secret }, encoding: "utf8" }).trim();
let events = 0;
async function report(body: Record<string, unknown>) {
  const citizen = await (await fetch(`${base}/v1/session`, { method: "POST" })).json();
  const reply = await fetch(`${base}/v1/events`, { method: "POST", headers: { authorization: `Bearer ${citizen.token}` },
    body: JSON.stringify({ eid: String(++events).padStart(32, "0"), ...body }) });
  expect(reply.status).toBe(201);
}

test.beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), "mina-cmd-"));
  execFileSync("sqlite3", [join(dir, "m.db")], { input: readFileSync(join(root, "gen/schema.sql")) });
  server = spawn(join(root, "bin/mina-server"), { env: { MINA_DB: join(dir, "m.db"), MINA_SECRET: secret, MINA_PORT: "4318" }, stdio: "ignore" });
  await expect.poll(async () => fetch(`${base}/v1/health`).then((r) => r.ok, () => false)).toBe(true);
  expect((await fetch(`${base}/command/`)).status, "the server has no web application: run ./build.sh web").toBe(200);
  await report({ kind: 1, region: 7, category: 4, body: "Out of food for two days" });
  await report({ kind: 1, region: 7, category: 1, body: "Man collapsed near the pump house", lat: 2812300, lon: 7712300 });
  await report({ kind: 5, region: 7, status: 2, body: "Trapped on the roof" });
  await report({ kind: 1, region: 8, category: 2, body: "In another area" });
});
test.afterAll(() => { server?.kill(); rmSync(dir, { recursive: true, force: true }); });

test("a responder handles incidents of their region", async ({ page, context }) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => { if (m.text().includes("Content Security Policy")) errors.push(m.text()); });
  await page.goto("/command/");
  await page.getByLabel("Access token").fill(token("--sub", "1", "--role", "citizen"));
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page.getByRole("alert")).toContainText("not a responder or admin token");
  await page.getByLabel("Access token").fill(token("--sub", "50", "--role", "responder", "--regions", "7"));
  await page.getByRole("button", { name: "Sign in" }).click();

  const list = page.getByRole("list", { name: "Incidents" });
  await expect(list.getByRole("listitem")).toHaveCount(2);                      // not region 8
  await expect(list.getByRole("listitem").nth(0)).toContainText("Medical");     // most urgent first
  await expect(list.getByRole("listitem").nth(1)).toContainText("Food");
  await expect(page.getByRole("region", { name: "Safety reports" })).toContainText("Trapped on the roof");

  await list.getByRole("button", { name: /Medical/ }).click();
  const detail = page.getByRole("region", { name: "Incident detail" });
  await expect(detail).toContainText("Man collapsed near the pump house");
  await expect(detail).toContainText("28.123, 77.123");
  await expect(detail.getByRole("button", { name: "Start work" })).toHaveCount(0);   // not permitted yet
  await detail.getByRole("button", { name: "Acknowledge" }).click();
  await expect(detail).toContainText("Acknowledged", { timeout: 30_000 });
  await detail.getByRole("button", { name: "Start work" }).click();
  await expect(detail.getByRole("button", { name: "Stand down" })).toBeVisible({ timeout: 30_000 });

  await context.setOffline(true);                                               // the link drops
  await detail.getByRole("button", { name: "Resolve" }).click();
  await expect(detail).toContainText("Waiting to send");
  expect(sql("SELECT status FROM incidents WHERE id = 2")).toBe("3");
  await context.setOffline(false);
  await expect(detail).toContainText("Resolved", { timeout: 30_000 });
  await expect(detail.getByRole("button")).toHaveCount(0);
  expect(sql("SELECT status FROM incidents WHERE id = 2")).toBe("4");

  await page.getByLabel("Alert for region 7").fill("Shelter open at the school");
  await page.getByRole("button", { name: "Publish alert" }).click();
  await expect.poll(() => sql("SELECT body FROM events WHERE kind = 6"), { timeout: 30_000 }).toBe("Shelter open at the school");

  await report({ kind: 1, region: 7, category: 2, body: "Family on a balcony" });     // arrives while watching
  await expect(list).toContainText("Family on a balcony", { timeout: 30_000 });

  // the link drops and the page is reopened: the dashboard and what it holds are still there
  await page.evaluate(() => navigator.serviceWorker.ready);
  await context.setOffline(true);
  await page.reload();
  await expect(page.getByRole("list", { name: "Incidents" })).toContainText("Family on a balcony");
  await expect(page.getByRole("status", { name: "Connection" })).toContainText("Offline");
  // the citizen app, installed on the same server, still opens offline too: neither cache removed the other
  await context.setOffline(false);
  await page.goto("/");
  await page.evaluate(() => navigator.serviceWorker.ready);
  await expect.poll(() => page.evaluate(async () => (await caches.keys()).map((k) => k.replace(/-[0-9a-f]+$/, "")).sort().join()))
    .toBe("mina-citizen,mina-command");
  await context.setOffline(true);
  await page.reload();
  await expect(page.getByLabel("Your area number")).toBeVisible();
  await page.goto("/command/");
  await expect(page.getByRole("list", { name: "Incidents" })).toContainText("Family on a balcony");
  await context.setOffline(false);

  await page.getByRole("button", { name: "Sign out" }).click();
  await expect(page.getByLabel("Access token")).toBeVisible();
  // nothing about other people stays on the device
  await expect.poll(() => page.evaluate(() => new Promise<number>((resolve, reject) => {
    const open = indexedDB.open("mina-command");
    open.onerror = () => reject(open.error);
    open.onsuccess = () => {
      const db = open.result, stores = [...db.objectStoreNames];
      if (stores.length === 0) { db.close(); return resolve(0); }
      const tx = db.transaction(stores);
      let total = 0;
      for (const name of stores) { const count = tx.objectStore(name).count(); count.onsuccess = () => (total += count.result); }
      tx.oncomplete = () => { db.close(); resolve(total); };
    };
  }))).toBe(0);
  expect(errors).toEqual([]);
});
