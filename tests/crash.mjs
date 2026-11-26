// Crash recovery: the server is killed (SIGKILL) again and again while many clients submit.
// Clients retry with the same event id until answered. At the end the database must hold every
// acknowledged event exactly once, under the sequence number the client was given.
//
//   node tests/crash.mjs [crashes]        (default 25; MINA_SERVER, MINA_TEST_PORT, MINA_CRASH_SEED)
//
// Needs ./build.sh and sqlite3. A process crash only: power loss is not simulated.
import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const SERVER = process.env.MINA_SERVER ?? join(root, "bin/mina-server");
const PORT = Number(process.env.MINA_TEST_PORT ?? 3917);
const CRASHES = Number(process.argv[2] ?? 25);
const CLIENTS = 32;
const secret = "0123456789abcdef0123456789abcdef";
const dir = mkdtempSync(join(tmpdir(), "mina-crash-"));
const db = join(dir, "m.db");
const sql = (q) => execFileSync("sqlite3", [db, q], { encoding: "utf8", maxBuffer: 1 << 28 }).trim();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let seed = Number(process.env.MINA_CRASH_SEED ?? 1);
const random = () => ((seed = (seed * 48271) % 2147483647) / 2147483647);

execFileSync("sqlite3", [db], { input: readFileSync(join(root, "gen/schema.sql")) });
const token = execFileSync(join(root, "bin/mina-admin"), ["token", "--sub", "1", "--role", "admin"], { env: { MINA_SECRET: secret }, encoding: "utf8" }).trim();

let server, log = "";
let failedStarts = 0;
async function start() {
  for (let attempt = 0; attempt < 50; attempt++) {
    const child = spawn(SERVER, { env: { MINA_DB: db, MINA_SECRET: secret, MINA_PORT: String(PORT) }, stdio: ["ignore", "ignore", "pipe"] });
    let said = "";
    child.stderr.on("data", (d) => (said += d));
    for (let i = 0; i < 200 && child.exitCode === null; i++) {
      try { if ((await fetch(`http://127.0.0.1:${PORT}/v1/health`)).ok) { server = child; child.stderr.on("data", (d) => (log += d)); log += said; return; } } catch { /* starting */ }
      await sleep(10);
    }
    failedStarts++;
    log += said;
    child.kill("SIGKILL");
    await sleep(200);
  }
  throw new Error(`the server did not start again:\n${log.slice(-2000)}`);
}
const kill = () => new Promise((resolve) => { server.once("exit", resolve); server.kill("SIGKILL"); });

const acked = new Map();               // eid -> {seq, incident, kind}
const incidents = [];
let next = 0, retried = 0, refused = 0, unexpected = [], stopping = false;

async function client(id) {
  while (!stopping) {
    const eid = `${String(id).padStart(8, "0")}${String(++next).padStart(24, "0")}`;
    let body;
    if (incidents.length && random() < 0.3) {
      const incident = incidents[Math.floor(random() * incidents.length)];
      body = random() < 0.7 ? { eid, kind: 2, incident } : { eid, kind: 4, incident };
    } else body = { eid, kind: 1, region: 1 + (id % 4), category: 1 + (next % 5), body: `crash test ${next}` };
    for (let attempt = 0; ; attempt++) {
      let status, reply;
      try {
        const r = await fetch(`http://127.0.0.1:${PORT}/v1/events`, { method: "POST", headers: { authorization: `Bearer ${token}` }, body: JSON.stringify(body), signal: AbortSignal.timeout(5000) });
        status = r.status;
        reply = await r.json();
      } catch {
        retried++;
        await sleep(5 + random() * 20);
        continue;                                      // no answer: the same event id again
      }
      if (status === 201 || (status === 200 && reply.duplicate)) {
        acked.set(eid, { seq: reply.seq, incident: reply.incident, kind: body.kind });
        if (body.kind === 1) incidents.push(reply.incident);
      } else if (status === 409 && body.kind !== 1) refused++;       // someone else moved the incident
      else if (status >= 500) { retried++; await sleep(10); continue; }
      else unexpected.push(`${status} ${JSON.stringify(reply)}`);
      break;
    }
  }
}

let failed = 0;
const check = (name, ok, detail = "") => { console.log(ok ? `  ok   ${name}` : `  FAIL ${name}\n       ${detail}`); if (!ok) failed++; };
try {
  await start();
  const clients = Array.from({ length: CLIENTS }, (_, i) => client(i));
  for (let i = 0; i < CRASHES; i++) {
    await sleep(80 + random() * 400);
    await kill();
    await start();
  }
  await sleep(300);
  stopping = true;
  await Promise.all(clients);
  await kill();                                        // the last crash, with nothing running
  await start();

  const rows = new Map(sql("SELECT lower(hex(eid)), seq, coalesce(incident, ''), kind FROM events").split("\n").filter(Boolean).map((l) => { const [e, s, i, k] = l.split("|"); return [e, { seq: +s, incident: i === "" ? null : +i, kind: +k }]; }));
  console.log(`${CRASHES + 1} crashes, ${acked.size} acknowledged, ${retried} retries, ${refused} refused transitions, ${failedStarts} failed starts`);
  const lost = [...acked].filter(([e, a]) => { const r = rows.get(e); return !r || r.seq !== a.seq || r.incident !== a.incident || r.kind !== a.kind; });
  check("every acknowledged event is stored as acknowledged", lost.length === 0, `${lost.length} lost or changed, for example ${JSON.stringify(lost.slice(0, 3))}`);
  check("nothing is stored that no client was told about", rows.size === acked.size, `${rows.size} stored, ${acked.size} acknowledged`);
  check("clients were interrupted and retried", retried > CRASHES, `${retried} retries`);
  check("the database is intact", sql("PRAGMA integrity_check") === "ok", sql("PRAGMA integrity_check"));
  check("sequence numbers have no gaps or repeats", sql("SELECT count(*) = max(seq) AND min(seq) = 1 FROM events") === "1");
  check("one incident per report", sql("SELECT (SELECT count(*) FROM events WHERE kind = 1) - (SELECT count(*) FROM incidents)") === "0");
  check("incidents agree with their last event", sql("SELECT count(*) FROM incidents i LEFT JOIN events e ON e.seq = i.updated_seq WHERE e.incident IS NOT i.id OR i.status != (CASE WHEN e.kind = 1 THEN 1 ELSE e.status END) OR EXISTS (SELECT 1 FROM events x WHERE x.incident = i.id AND x.seq > i.updated_seq)") === "0");
  // the restarted server's remembered heads: its sync answers match the database
  for (let region = 1; region <= 4; region++) {
    const page = await (await fetch(`http://127.0.0.1:${PORT}/v1/sync?region=${region}&after=${rows.size - 40}&limit=256`, { headers: { authorization: `Bearer ${token}` } })).json();
    const want = sql(`SELECT json_group_array(seq) FROM (SELECT seq FROM events WHERE region = ${region} AND seq > ${rows.size - 40} ORDER BY seq)`);
    check(`region ${region} synchronises after recovery`, JSON.stringify(page.events.map((e) => e[0])) === want, `${JSON.stringify(page.events.map((e) => e[0]))} / ${want}`);
  }
  check("every restart succeeded at once", failedStarts === 0, `${failedStarts} failed: ${log.match(/.*(fatal|io_uring|memory).*/i)?.[0] ?? ""}`);
  check("no unexpected answer or server warning", unexpected.length === 0 && !/runtime error|Sanitizer|batch rolled back/.test(log), unexpected.slice(0, 3).join(" ") + log.slice(-500));
} finally {
  stopping = true;
  server?.kill("SIGKILL");
  rmSync(dir, { recursive: true, force: true });
}
console.log(failed ? "crash: FAILED" : "crash: ok");
process.exit(failed ? 1 : 0);
