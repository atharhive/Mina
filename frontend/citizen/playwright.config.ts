import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "e2e",
  timeout: 90_000,
  workers: 1,
  reporter: "list",
  // the installed Chrome: no browser is downloaded
  projects: [{ name: "phone", use: { ...devices["Pixel 7"], channel: "chrome" } }],
  use: { baseURL: "http://127.0.0.1:4317" },
});
