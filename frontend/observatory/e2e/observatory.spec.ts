/** The Observatory served by the real server. Needs ./build.sh web and sqlite3. */
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "@playwright/test";

const root = new URL("../../../", import.meta.url).pathname;
const secret = "0123456789abcdef0123456789abcdef";
const base = "http://127.0.0.1:4319";
let dir = "";
let server: ChildProcess;
const token = (...args: string[]) => execFileSync(join(root, "bin/mina-admin"), ["token", ...args], { env: { MINA_SECRET: secret }, encoding: "utf8" }).trim();

test.beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), "mina-obs-"));
  execFileSync("sqlite3", [join(dir, "m.db")], { input: readFileSync(join(root, "gen/schema.sql")) });
  server = spawn(join(root, "bin/mina-server"), { env: { MINA_DB: join(dir, "m.db"), MINA_SECRET: secret, MINA_PORT: "4319" }, stdio: "ignore" });
  await expect.poll(async () => fetch(`${base}/v1/health`).then((r) => r.ok, () => false)).toBe(true);
  expect((await fetch(`${base}/observatory/`)).status, "the server has no web application: run ./build.sh web").toBe(200);
});
test.afterAll(() => { server?.kill(); rmSync(dir, { recursive: true, force: true }); });

test("shows live measurements, apart from recorded benchmarks", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => { if (m.text().includes("Content Security Policy")) errors.push(m.text()); });
  await page.goto("/observatory/");
  await page.getByLabel("Admin token").fill(token("--sub", "5", "--role", "responder", "--regions", "1"));
  await page.getByRole("button", { name: "Connect" }).click();
  await expect(page.getByRole("alert")).toContainText("Only an admin token");

  const recorded = page.getByRole("region", { name: "Recorded benchmarks" });
  await page.getByLabel("Admin token").fill(token("--sub", "1", "--role", "admin"));
  await page.getByRole("button", { name: "Connect" }).click();
  const live = page.getByRole("region", { name: "Live measurements" });
  await expect(live.getByTestId("requests-per-second")).toHaveText(/^\d/, { timeout: 15_000 });

  const citizen = await (await fetch(`${base}/v1/session`, { method: "POST" })).json();
  let busy = true;
  const traffic = (async () => { while (busy) await fetch(`${base}/v1/sync?region=1`, { headers: { authorization: `Bearer ${citizen.token}` } }); })();
  await expect.poll(async () => Number((await live.getByTestId("requests-per-second").textContent())!.replace(/,/g, "")), { timeout: 20_000 }).toBeGreaterThan(20);
  await expect(live.getByTestId("sync-quiet-share")).toHaveText("100 %", { timeout: 10_000 });
  await expect(live.getByTestId("connections")).toHaveText(/^[1-9]/);
  busy = false;
  await traffic;

  await expect(recorded).toContainText("not live");
  await expect(recorded.getByRole("row")).toHaveCount(10);                    // 9 runs and the header
  await expect(recorded).toContainText("Intel Core i5-12450H");
  await expect(page.getByRole("region", { name: "Proved in Lean" })).toContainText("syncPlan_eq");
  await expect(page.getByRole("region", { name: "Proved in Lean" })).toContainText("not the C");

  server.kill();                                                              // the server goes away
  await expect(page.getByRole("status", { name: "Connection" })).toContainText("No answer", { timeout: 15_000 });
  expect(errors).toEqual([]);
});
