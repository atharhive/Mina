// The server against the Lean oracle (spec/Mina/Oracle.lean): the same random requests, valid and
// invalid, go to both, and every status and body must agree. Times the server assigns are masked.
// Not covered: token verification, rate limits (identities are spread so none is reached) and
// number spellings such as 1e2, which the oracle's JSON reader does not keep apart from 100.
//
//   node tests/oracle.mjs [requests] [seed]      (default 20000 1; MINA_SERVER, MINA_TEST_PORT)
//
// Needs ./build.sh and sqlite3. Builds the oracle first, so that it is never stale (lake from
// LAKE, or ~/.elan/bin/lake).
import { execFileSync, spawn } from "node:child_process";
import { createHmac } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { isDeepStrictEqual } from "node:util";

const root = new URL("..", import.meta.url).pathname;
const SERVER = process.env.MINA_SERVER ?? join(root, "bin/mina-server");
const ORACLE = join(root, "spec/.lake/build/bin/oracle");
const PORT = Number(process.env.MINA_TEST_PORT ?? 3917);
const REQUESTS = Number(process.argv[2] ?? 20000);
let seed = Number(process.argv[3] ?? 1);
const random = () => ((seed = (seed * 48271) % 2147483647) / 2147483647);
const below = (n) => Math.floor(random() * n);
const pick = (a) => a[below(a.length)];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const LAKE = process.env.LAKE ?? (existsSync(join(homedir(), ".elan/bin/lake")) ? join(homedir(), ".elan/bin/lake") : "lake");
execFileSync(LAKE, ["build", "oracle"], { cwd: join(root, "spec"), stdio: ["ignore", "ignore", "inherit"] });

const dir = mkdtempSync(join(tmpdir(), "mina-oracle-"));
const db = join(dir, "m.db");
const secret = "0123456789abcdef0123456789abcdef";
execFileSync("sqlite3", [db], { input: readFileSync(join(root, "gen/schema.sql")) });
const server = spawn(SERVER, { env: { MINA_DB: db, MINA_SECRET: secret, MINA_PORT: String(PORT) }, stdio: ["ignore", "ignore", "pipe"] });
let log = "";
server.stderr.on("data", (d) => (log += d));
const oracle = spawn(ORACLE, [], { stdio: ["pipe", "pipe", "inherit"] });
const answers = createInterface({ input: oracle.stdout })[Symbol.asyncIterator]();
async function ask(operation) {
  oracle.stdin.write(JSON.stringify(operation) + "\n");
  const { value, done } = await answers.next();
  if (done) throw new Error("the oracle stopped");
  return JSON.parse(value);
}

const b64 = (v) => Buffer.from(JSON.stringify(v)).toString("base64url");
function actor(sub, role, regions = []) {
  const claims = { sub: String(sub), role, ...(regions.length ? { rg: regions.join(",") } : {}), exp: Math.floor(Date.now() / 1000) + 3600 };
  const text = `${b64({ alg: "HS256" })}.${b64(claims)}`;
  return { sub, role, regions, token: `${text}.${createHmac("sha256", secret).update(text).digest("base64url")}` };
}
const citizens = Array.from({ length: 900 }, (_, i) => actor(1000 + i, 1));
const responders = [actor(1, 2, [1]), actor(2, 2, [1, 2]), actor(3, 2, [3]), actor(4, 3)];
const someone = () => (random() < 0.55 ? pick(citizens) : pick(responders));
const REGIONS = [1, 2, 3, 4];

const incidents = [], eids = [], sent = [], reporters = new Map();
let next = 0, head = 0;
const bodies = ["water rising", "  trimmed  ", "", "   ", "\n\t", "say \"go\" \\ now", "line one\nline two", "tab\there", "bad\u0001control", "cr\rhere",
  "é→𝔘 unicode", " nbsp ", "　", "x".repeat(280), "x".repeat(281), "é".repeat(280), "é".repeat(281), "𝔘".repeat(280)];
function submission() {
  const kind = pick([1, 1, 1, 2, 2, 3, 3, 4, 5, 6, 6, 0, 7, 99]);
  const eid = random() < 0.9 || !eids.length ? (++next).toString(16).padStart(32, "0") : pick(eids);
  const body = { eid, kind };
  const incident = incidents.length && random() < 0.9 ? pick(incidents) : below(head + 3);
  if (kind === 1) Object.assign(body, { region: pick(REGIONS), category: 1 + below(5) });
  if (kind === 5) Object.assign(body, { region: pick(REGIONS), status: 1 + below(2) });
  if (kind === 6) Object.assign(body, { region: pick(REGIONS), body: "alert " + next });
  if (kind >= 2 && kind <= 4) body.incident = incident;
  if (kind === 3) body.status = 2 + below(2);
  if ((kind === 1 || kind === 5) && random() < 0.5) body.body = pick(bodies);
  if ((kind === 1 || kind === 5) && random() < 0.3) Object.assign(body, { lat: below(200) - 100, lon: below(200) - 100 });
  if (random() < 0.3) body.at = below(2_000_000_000);
  // a bad incident number needs an update kind and this very field: ask for it directly, or short
  // runs may never produce it
  if (kind >= 2 && kind <= 4 && random() < 0.06) body.incident = pick([0, -1, 1.5, "1", null]);
  // now and then, break something
  for (let k = random() < 0.35 ? 1 + below(2) : 0; k > 0; k--) {
    const field = pick(["eid", "kind", "region", "category", "status", "incident", "body", "lat", "lon", "at"]);
    const how = below(4);
    if (how === 0) delete body[field];
    else if (how === 1) body[field] = pick([0, -1, 1, 3, 6, 1024, 1025, 9000001, 18000001, 100000000000, 1.5, "1", null, true, [1], {}]);
    else if (field === "body") body.body = pick(bodies);
    else if (field === "eid") body.eid = pick(["abc", "0".repeat(31), "0".repeat(33), "G".repeat(32), "A".repeat(32), 5]);
    else body[field] = pick([1, 2, 4, 7, 90, 1024]);
  }
  if (typeof body.eid === "string" && body.eid.length === 32) eids.push(body.eid);
  return random() < 0.02 ? pick(["nope", "[1]", "", "{", "\"text\"", "7"]) : JSON.stringify(body);
}

function operation() {
  const dice = below(100);
  if (dice < 5 && sent.length) {                                      // the same bytes again, perhaps from someone else
    const again = pick(sent);
    return { ...again, actor: random() < 0.8 ? again.actor : someone() };
  }
  if (dice < 52) {
    const op = { op: "submit", actor: someone(), raw: submission() };
    sent.push(op);
    if (sent.length > 500) sent.shift();
    return op;
  }
  if (dice < 90) {
    const number = (good) => (random() < 0.92 ? String(good) : pick(["", "x", "-1", "-", "0", "1025", "257", "1.5", "1234567890123456789"]));
    const query = {};
    if (random() < 0.97) query.region = number(pick([...REGIONS, 999]));
    if (random() < 0.85) query.after = number(pick([0, below(head + 1), Math.max(0, head - below(20)), head, head + 1 + below(3)]));
    if (random() < 0.6) query.limit = number(pick([1, 2, 7, 64, 256]));
    return { op: "sync", actor: someone(), query };
  }
  const id = random() < 0.85 && incidents.length ? String(pick(incidents)) : pick(["0", "abc", "-1", String(head + 9), "1.5"]);
  // half of the time the person who reported it asks, who sees only the summary
  return { op: "incident", actor: (random() < 0.5 && reporters.get(Number(id))) || someone(), id };
}

async function real(op) {
  const headers = { authorization: `Bearer ${op.actor.token}` };
  const url = op.op === "submit" ? "/v1/events" : op.op === "incident" ? `/v1/incidents/${op.id}` : `/v1/sync?${Object.entries(op.query).map(([k, v]) => `${k}=${v}`).join("&")}`;
  const r = await fetch(`http://127.0.0.1:${PORT}${url}`, { headers, ...(op.op === "submit" ? { method: "POST", body: op.raw } : {}) });
  const body = await r.json();
  if (body.events) for (const e of body.events) e[2] = null;
  if (body.report) body.report.ts = null;
  return { status: r.status, body };
}

const seen = new Map();
let failed = false;
try {
  for (let i = 0; i < 200; i++) { try { if ((await fetch(`http://127.0.0.1:${PORT}/v1/health`)).ok) break; } catch { await sleep(20); } }
  for (let i = 0; i < REQUESTS; i++) {
    const op = operation();
    const got = await real(op);
    const want = await ask({ ...op, actor: { sub: op.actor.sub, role: op.actor.role, regions: op.actor.regions } });
    if (!isDeepStrictEqual(got, want)) {
      console.log(`MISMATCH at request ${i}\n request ${JSON.stringify({ ...op, actor: { ...op.actor, token: undefined } })}\n server  ${JSON.stringify(got).slice(0, 700)}\n oracle  ${JSON.stringify(want).slice(0, 700)}`);
      failed = true;
      break;
    }
    if (op.op === "submit" && got.status === 201) {
      head = Math.max(head, got.body.seq);
      if (JSON.parse(op.raw).kind === 1) { incidents.push(got.body.incident); reporters.set(got.body.incident, op.actor); }
    }
    const outcome = `${op.op} ${got.status} ${got.body.error ?? (got.body.duplicate ? "duplicate" : got.body.events ? (got.body.events.length ? "page" : "empty") : got.body.report ? "report" : "ok")}`;
    seen.set(outcome, (seen.get(outcome) ?? 0) + 1);
  }
  // every kind of answer the server can give to these requests must have occurred
  const expected = ["submit 201 ok", "submit 200 duplicate", "submit 400 invalid json", "submit 400 invalid event id", "submit 400 invalid kind",
    "submit 400 missing or unexpected field", "submit 400 invalid region", "submit 400 invalid category", "submit 400 invalid status", "submit 400 invalid incident",
    "submit 400 invalid location", "submit 400 invalid time", "submit 400 invalid body", "submit 403 not permitted", "submit 403 region not authorized",
    "submit 404 no such incident", "submit 409 invalid transition", "submit 409 event id already used", "sync 200 page", "sync 200 empty", "sync 400 invalid query",
    "sync 403 region not authorized", "sync 409 resync", "incident 200 ok", "incident 200 report", "incident 404 no such incident"];
  if (!failed) {
    const missing = expected.filter((e) => !seen.has(e));
    console.log(`${REQUESTS} requests agreed, ${seen.size} kinds of answer, ${head} events stored`);
    if (missing.length) { console.log(`  FAIL never occurred: ${missing.join("; ")}`); failed = true; }
  }
  if (/runtime error|Sanitizer|batch rolled back|native plan failed/.test(log)) { console.log(`  FAIL server log\n${log.slice(-1500)}`); failed = true; }
} finally {
  server.kill("SIGKILL");
  oracle.stdin.end();
  oracle.kill();
  rmSync(dir, { recursive: true, force: true });
}
console.log(failed ? "oracle: FAILED" : "oracle: ok");
process.exit(failed ? 1 : 0);
