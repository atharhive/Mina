/** How the dashboard behaves with a large region. Not part of the normal run:
 *   MINA_PERF=1 npx playwright test perf
 * Needs ./build.sh web and sqlite3. Prints one JSON line. */
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "@playwright/test";

const root = new URL("../../../", import.meta.url).pathname;
const secret = "0123456789abcdef0123456789abcdef";
const base = "http://127.0.0.1:4320";
const EVENTS = Number(process.env.MINA_PERF_EVENTS ?? 20000);
let dir = "";
let server: ChildProcess;

test.skip(!process.env.MINA_PERF, "set MINA_PERF=1 to measure");
test.beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), "mina-perf-"));
  const db = join(dir, "m.db");
  execFileSync("sqlite3", [db], { input: readFileSync(join(root, "gen/schema.sql")) });
  const seed = execFileSync(join(root, "bin/mina-admin"), ["seed", "--events", String(EVENTS), "--regions", "1", "--seed", "1"], { maxBuffer: 1 << 28 });
  execFileSync("sqlite3", ["-bail", db], { input: seed });
  server = spawn(join(root, "bin/mina-server"), { env: { MINA_DB: db, MINA_SECRET: secret, MINA_PORT: "4320" }, stdio: "ignore" });
  await expect.poll(async () => fetch(`${base}/v1/health`).then((r) => r.ok, () => false)).toBe(true);
});
test.afterAll(() => { server?.kill(); if (dir) rmSync(dir, { recursive: true, force: true }); });

test("large region", async ({ page }) => {
  test.setTimeout(240_000);
  const incidents = Number(execFileSync("sqlite3", [join(dir, "m.db"), "SELECT count(*) FROM incidents"], { encoding: "utf8" }));
  const token = execFileSync(join(root, "bin/mina-admin"), ["token", "--sub", "1", "--role", "responder", "--regions", "1"], { env: { MINA_SECRET: secret }, encoding: "utf8" }).trim();
  // long tasks: stretches of more than 50 ms in which the page cannot respond
  await page.addInitScript(() => {
    (window as any).__long = [];
    new PerformanceObserver((l) => { for (const e of l.getEntries()) (window as any).__long.push(e.duration); }).observe({ type: "longtask", buffered: true });
  });
  await page.goto(`${base}/command/`);
  await page.getByLabel("Access token").fill(token);
  const start = Date.now();
  await page.getByRole("button", { name: "Sign in" }).click();
  const list = page.getByRole("list", { name: "Incidents" });
  await expect(list.getByRole("listitem").first()).toBeVisible({ timeout: 60_000 });
  const firstMs = Date.now() - start;
  // every event is on the device
  await expect.poll(() => page.evaluate(() => new Promise<number>((resolve) => {
    const open = indexedDB.open("mina-command");
    open.onsuccess = () => { const c = open.result.transaction("events").objectStore("events").count(); c.onsuccess = () => { open.result.close(); resolve(c.result); }; };
  })), { timeout: 180_000, intervals: [1000] }).toBe(EVENTS);
  const allMs = Date.now() - start;
  await page.waitForTimeout(2000);
  const loading = await page.evaluate(() => (window as any).__long.splice(0));
  const rows = await list.getByRole("listitem").count();
  const nodes = await page.evaluate(() => document.getElementsByTagName("*").length);
  expect(rows, "only the top of the list is put on the page").toBeLessThanOrEqual(200);
  await page.getByRole("button", { name: /Show 200 more/ }).click();
  await expect(list.getByRole("listitem")).toHaveCount(400);
  const clicks: number[] = [];
  for (let i = 1; i <= 5; i++) {
    clicks.push(await page.evaluate(async (n) => {
      const button = document.querySelectorAll<HTMLButtonElement>('[aria-label="Incidents"] button')[n * 3]!;
      const t = performance.now();
      button.click();
      await new Promise<void>((r) => requestAnimationFrame(() => requestAnimationFrame(() => r())));
      return performance.now() - t;
    }, i));
  }
  await page.evaluate(() => (window as any).__long.splice(0));
  await page.waitForTimeout(20_000);                                       // several synchronisations with nothing new
  const idle = await page.evaluate(() => (window as any).__long.splice(0));
  const sum = (a: number[]) => Math.round(a.reduce((x, y) => x + y, 0));
  console.log(JSON.stringify({ events: EVENTS, incidents, rows, dom_nodes: nodes, first_row_ms: firstMs, all_events_ms: allMs,
    long_tasks_while_loading: loading.length, longest_while_loading_ms: Math.round(Math.max(0, ...loading)), blocked_while_loading_ms: sum(loading),
    click_to_paint_ms: clicks.map(Math.round), long_tasks_idle_20s: idle.length, longest_idle_ms: Math.round(Math.max(0, ...idle)) }));
});
