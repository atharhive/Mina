/** The citizen app against the real server: report while offline, reopen offline, reconnect,
 * delivered once, then acknowledged by a responder. Needs ./build.sh and sqlite3. */
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "@playwright/test";
import { preview, type PreviewServer } from "vite";

const root = new URL("../../../", import.meta.url).pathname;
const secret = "0123456789abcdef0123456789abcdef";
const api = "http://127.0.0.1:3982";
let dir = "";
let server: ChildProcess;
let web: PreviewServer;

const sql = (q: string) => execFileSync("sqlite3", [join(dir, "m.db"), q], { encoding: "utf8" }).trim();
const responderToken = () => execFileSync(join(root, "bin/mina-admin"), ["token", "--sub", "9", "--role", "responder", "--regions", "7"],
  { env: { MINA_SECRET: secret }, encoding: "utf8" }).trim();
async function respond(body: Record<string, unknown>) {
  const reply = await fetch(`${api}/v1/events`, { method: "POST", headers: { authorization: `Bearer ${responderToken()}` }, body: JSON.stringify(body) });
  expect(reply.status).toBe(201);
}

test.beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), "mina-e2e-"));
  execFileSync("sqlite3", [join(dir, "m.db")], { input: readFileSync(join(root, "gen/schema.sql")) });
  server = spawn(join(root, "bin/mina-server"), { env: { MINA_DB: join(dir, "m.db"), MINA_SECRET: secret, MINA_PORT: "3982" }, stdio: "ignore" });
  web = await preview({ root: join(root, "frontend/citizen"), preview: { port: 4317, host: "127.0.0.1", strictPort: true, proxy: { "/v1": api } } });
  await expect.poll(async () => fetch(`${api}/v1/health`).then((r) => r.ok, () => false)).toBe(true);
});
test.afterAll(async () => {
  await web?.close();
  server?.kill();
  rmSync(dir, { recursive: true, force: true });
});

test("a report made offline survives a reload, is delivered once and acknowledged", async ({ page, context }) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/");
  await page.getByLabel("Your area number").fill("7");
  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page.getByRole("status", { name: "Connection" })).toHaveText(/Online/);
  await page.evaluate(() => navigator.serviceWorker.ready);

  await context.setOffline(true);
  await expect(page.getByRole("status", { name: "Connection" })).toHaveText(/Offline/);
  await page.getByRole("button", { name: "Request help" }).click();
  await page.getByRole("radio", { name: "Rescue" }).check();
  await page.getByLabel("What is happening?").fill("Water is at the first floor");
  await page.getByRole("button", { name: "Save and send" }).click();

  const mine = page.getByRole("region", { name: "My reports" });
  await expect(mine).toContainText("Saved on this phone");
  await expect(mine).toContainText("Water is at the first floor");
  await expect(mine).not.toContainText("Delivered");                      // nothing has been sent
  expect(sql("SELECT count(*) FROM events")).toBe("0");

  await page.reload();                                                     // still offline
  await expect(page.getByRole("region", { name: "My reports" })).toContainText("Saved on this phone");

  await context.setOffline(false);
  await expect(mine).toContainText("Delivered to server", { timeout: 30_000 });
  expect(sql("SELECT count(*) FROM events WHERE kind = 1 AND region = 7 AND category = 2 AND body = 'Water is at the first floor'")).toBe("1");

  await respond({ eid: "b".repeat(32), kind: 2, incident: 1 });
  await expect(mine).toContainText("Acknowledged by a responder", { timeout: 30_000 });
  await respond({ eid: "c".repeat(32), kind: 6, region: 7, body: "Boats are coming from the north bridge" });
  await expect(page.getByRole("region", { name: "Alerts for your area" })).toContainText("Boats are coming", { timeout: 30_000 });

  await page.getByRole("button", { name: "I am safe" }).click();
  await expect(mine).toContainText("Safety: I am safe");
  await expect.poll(() => sql("SELECT count(*) FROM events WHERE kind = 5 AND status = 1"), { timeout: 30_000 }).toBe("1");
  await respond({ eid: "d".repeat(32), kind: 4, incident: 1 });
  await expect(mine).toContainText("Resolved", { timeout: 30_000 });
  expect(sql("SELECT count(*) FROM events WHERE kind = 1")).toBe("1");
  expect(errors).toEqual([]);
});

test("says plainly that it is not an emergency service", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByText("not a replacement for official emergency services")).toBeVisible();
});
