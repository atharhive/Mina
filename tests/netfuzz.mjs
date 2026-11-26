// Fuzzes the transport: many connections send damaged and pipelined requests in pieces of random
// size, some close in the middle, some never read. The server must keep answering, and a
// sanitizer build must stay silent.
//
//   node tests/netfuzz.mjs [seconds] [seed]        (default 60 1; MINA_SERVER, MINA_TEST_PORT)
//
// Needs ./build.sh sanitize (the default server) and sqlite3.
import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const SERVER = process.env.MINA_SERVER ?? join(root, "bin/mina-server-san");
const PORT = Number(process.env.MINA_TEST_PORT ?? 3917);
const SECONDS = Number(process.argv[2] ?? 60);
let seed = Number(process.argv[3] ?? 1);
const random = () => ((seed = (seed * 48271) % 2147483647) / 2147483647);
const below = (n) => Math.floor(random() * n);
const pick = (a) => a[below(a.length)];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const dir = mkdtempSync(join(tmpdir(), "mina-netfuzz-"));
const db = join(dir, "m.db");
const secret = "0123456789abcdef0123456789abcdef";
execFileSync("sqlite3", [db], { input: readFileSync(join(root, "gen/schema.sql")) });
const token = execFileSync(join(root, "bin/mina-admin"), ["token", "--sub", "1", "--role", "admin"], { env: { MINA_SECRET: secret }, encoding: "utf8" }).trim();
const server = spawn(SERVER, { env: { MINA_DB: db, MINA_SECRET: secret, MINA_PORT: String(PORT), MINA_IDLE_S: "3" }, stdio: ["ignore", "ignore", "pipe"] });
let log = "";
server.stderr.on("data", (d) => (log += d));
/** One request on its own connection, closed afterwards: none of ours is left open to be
 * mistaken for a stuck one. Resolves to the body, or null. */
const ask = (path, auth = "") => new Promise((resolve) => {
  const socket = connect(PORT, "127.0.0.1", () => socket.write(`GET ${path} HTTP/1.1\r\n${auth}Connection: close\r\n\r\n`));
  let got = "";
  socket.setTimeout(5000, () => socket.destroy());
  socket.on("data", (d) => (got += d));
  socket.on("error", () => {});
  socket.on("close", () => resolve(got.startsWith("HTTP/1.1 200") ? got.slice(got.indexOf("\r\n\r\n") + 4) : null));
});
const healthy = async () => (await ask("/v1/health")) !== null;
for (let i = 0; i < 200 && !(await healthy()); i++) await sleep(50);

let eid = 0;
function request() {
  const auth = `Authorization: Bearer ${token}\r\n`;
  const body = JSON.stringify({ eid: String(++eid).padStart(32, "0"), kind: pick([1, 6]), region: 1 + below(3), category: 1, body: "x".repeat(below(200)) });
  return pick([
    `GET /v1/sync?region=${1 + below(3)}&after=0&limit=256 HTTP/1.1\r\n${auth}\r\n`,
    `POST /v1/events HTTP/1.1\r\n${auth}Content-Length: ${body.length}\r\n\r\n${body}`,
    `GET /v1/health HTTP/1.1\r\n\r\n`, `GET /v1/metrics HTTP/1.1\r\n${auth}\r\n`, `GET / HTTP/1.1\r\nAccept-Encoding: br\r\n\r\n`,
    `POST /v1/session HTTP/1.1\r\n\r\n`, `GET /v1/incidents/${below(50)} HTTP/1.1\r\n${auth}Connection: close\r\n\r\n`,
  ]);
}
function damaged() {
  let text = Array.from({ length: 1 + below(random() < 0.05 ? 400 : 8) }, request).join("");
  let bytes = Buffer.from(text, "latin1");
  if (random() < 0.5) {
    for (let k = 1 + below(5); k; k--) {
      const at = below(bytes.length + 1);
      const op = below(4);
      if (op === 0 && bytes.length) bytes[below(bytes.length)] = below(256);
      else if (op === 1) bytes = Buffer.concat([bytes.subarray(0, at), Buffer.from(pick(["\r\n", "\r\n\r\n", "Content-Length: 99999\r\n", "{", "\"", "\0", "a".repeat(below(20000))])), bytes.subarray(at)]);
      else if (op === 2) bytes = Buffer.concat([bytes.subarray(0, at), bytes.subarray(at + below(40))]);
      else bytes = bytes.subarray(0, at);
    }
  }
  return bytes;
}
let connections = 0, sent = 0, received = 0;
function one() {
  return new Promise((resolve) => {
    const socket = connect(PORT, "127.0.0.1");
    const timer = setTimeout(() => socket.destroy(), 200 + below(random() < 0.05 ? 4000 : 400));
    socket.on("error", () => {});
    socket.on("close", () => { clearTimeout(timer); resolve(); });
    socket.on("connect", async () => {
      connections++;
      if (random() >= 0.1) socket.on("data", (d) => (received += d.length));     // some never read
      else socket.pause();
      const bytes = damaged();
      for (let i = 0; i < bytes.length && !socket.destroyed; ) {
        const n = 1 + below(random() < 0.2 ? 7 : 4000);
        socket.write(bytes.subarray(i, i + n));
        i += n;
        sent += n;
        if (random() < 0.3) await sleep(below(3));
      }
      if (random() < 0.2) socket.end();
      else if (random() < 0.1) socket.destroy();
    });
  });
}
const end = Date.now() + SECONDS * 1000;
let alive = true;
await Promise.all(Array.from({ length: 64 }, async () => { while (Date.now() < end && server.exitCode === null) await one(); }));
await sleep(4000);                                     // let the idle sweep clear what is left
alive = server.exitCode === null && (await healthy());
await sleep(200);
const metrics = alive ? JSON.parse(await ask("/v1/metrics", `Authorization: Bearer ${token}\r\n`)) : null;
const clean = !/runtime error|ERROR: [A-Za-z]*Sanitizer|batch rolled back|fatal/.test(log);
const stuck = metrics ? metrics.runtime.connections_open : -1;
console.log(`netfuzz: ${connections} connections, ${Math.round(sent / 1024)} KiB sent, ${Math.round(received / 1024)} KiB received` +
  (metrics ? `, ${metrics.runtime.requests} requests, ${metrics.runtime.status_2xx} 2xx, ${metrics.runtime.status_4xx} 4xx, open afterwards ${stuck}, queued bytes ${metrics.runtime.queued_bytes}` : ""));
server.kill("SIGKILL");
rmSync(dir, { recursive: true, force: true });
if (!alive) console.log(`  FAIL the server stopped answering\n${log.slice(-3000)}`);
if (!clean) console.log(`  FAIL sanitizer report or error in the log\n${log.slice(-3000)}`);
if (alive && (stuck > 1 || metrics.runtime.queued_bytes > 100000)) console.log(`  FAIL connections or queued answers were left behind: ${stuck}, ${metrics.runtime.queued_bytes}`);
const ok = alive && clean && stuck <= 1 && metrics.runtime.queued_bytes <= 100000 && metrics.runtime.status_2xx > 0 && metrics.runtime.status_4xx > 0;
console.log(ok ? "netfuzz: ok" : "netfuzz: FAILED");
process.exit(ok ? 0 : 1);
