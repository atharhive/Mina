// Power loss: the server runs in a virtual machine whose disk is this program. The disk has a
// volatile cache: a write is durable only once the guest has asked for a flush, and a flush takes
// up to 8 ms, as on a real device, so that cuts fall while one is under way. A power cut kills
// the machine and then drops the unflushed writes, or on every other cut keeps a random half of
// their 512-byte sectors (reordered and torn writes). The next boot starts from that disk, so the
// guest does its own file system and database recovery; a copy is recovered here and compared
// with every acknowledgement the clients saw.
//
//   node tests/powerloss.mjs [cuts]                              (default 20)
//     MINA_SYNC=full|normal   the server's durability setting (default full)
//     MINA_DISK=lying         the disk ignores flushes: the test must then FAIL
//     MINA_KERNEL=path        a bzImage with virtio and ext4 built in (default build/vm/vmlinuz)
//     MINA_CUT_SEED, MINA_SERVER
//
// Needs ./build.sh, KVM, qemu-system-x86_64, cc, cpio, e2fsprogs and sqlite3. Ubuntu keeps its
// installed kernel unreadable, so fetch a copy:
//   mkdir -p build/vm/root && (cd build/vm && apt-get download linux-image-$(uname -r)) &&
//   dpkg-deb -x build/vm/linux-image-*.deb build/vm/root && cp build/vm/root/boot/vmlinuz-* build/vm/vmlinuz
//
// With MINA_SYNC=normal losing recently acknowledged events is documented behaviour: they are
// counted, and only damage to what remains fails the test.
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const SERVER = process.env.MINA_SERVER ?? join(root, "bin/mina-server");
const KERNEL = process.env.MINA_KERNEL ?? join(root, "build/vm/vmlinuz");
const SYNC = process.env.MINA_SYNC ?? "full";
const LYING = process.env.MINA_DISK === "lying";
const CUTS = Number(process.argv[2] ?? 20);
const SIZE = 256 * 1024 * 1024, SECTOR = 512;
let seed = Number(process.env.MINA_CUT_SEED ?? 1);
const random = () => ((seed = (seed * 48271) % 2147483647) / 2147483647);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
if (!existsSync(KERNEL)) { console.error(`no kernel at ${KERNEL}: see the head of tests/powerloss.mjs`); process.exit(2); }

const dir = mkdtempSync(join(tmpdir(), "mina-power-"));
const at = (name) => join(dir, name);
const run = (cmd, args, options = {}) => execFileSync(cmd, args, { encoding: "utf8", maxBuffer: 1 << 28, ...options });

// ---- the virtual machine's files ---------------------------------------------------------------
for (const d of ["initrd/dev", "initrd/proc", "initrd/data", "disk"]) mkdirSync(at(d), { recursive: true });
run("cc", ["-O2", "-Wall", "-Wextra", "-static", "-o", at("initrd/init"), join(root, "tests/power/guest.c")]);
copyFileSync(SERVER, at("initrd/mina-server"));
for (const lib of run("ldd", [SERVER]).match(/\/\S+(?= \(0x)/g) ?? []) {
  mkdirSync(at(`initrd${dirname(lib)}`), { recursive: true });
  copyFileSync(lib, at(`initrd${lib}`));
}
writeFileSync(at("initrd/token"), run(join(root, "bin/mina-admin"), ["token", "--sub", "1", "--role", "admin"], { env: { MINA_SECRET: "0123456789abcdef0123456789abcdef" } }));
run("sh", ["-c", `cd '${at("initrd")}' && find . | cpio -o -H newc --quiet | gzip -1 > '${at("initrd.gz")}'`]);
run("sqlite3", [at("disk/m.db")], { input: readFileSync(join(root, "gen/schema.sql")) });
run("mke2fs", ["-q", "-t", "ext4", "-d", at("disk"), at("image"), `${SIZE >> 20}m`]);

// ---- the disk: an NBD server -------------------------------------------------------------------
const durable = readFileSync(at("image"));                 // what survives a power cut
const current = Buffer.from(durable);                      // what the guest reads back
let cache = [];                                            // writes not yet flushed
let powered = false;

function serve(socket) {
  let buffer = Buffer.alloc(0), stage = "flags", noZeroes = false;
  const u16 = (v) => { const b = Buffer.alloc(2); b.writeUInt16BE(v); return b; };
  const u32 = (v) => { const b = Buffer.alloc(4); b.writeUInt32BE(v >>> 0); return b; };
  const u64 = (v) => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(v)); return b; };
  const exportInfo = () => Buffer.concat([u64(SIZE), u16(1 | 4)]);        // has flags, can flush
  const optionReply = (option, type, data = Buffer.alloc(0)) =>
    socket.write(Buffer.concat([u64(0x3e889045565a9n), u32(option), u32(type), u32(data.length), data]));
  const reply = (cookie, data) => socket.write(Buffer.concat([u32(0x67446698), u32(0), cookie, ...(data ? [data] : [])]));
  socket.write(Buffer.concat([Buffer.from("NBDMAGICIHAVEOPT"), u16(3)]));
  socket.on("error", () => {});
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      if (!powered) return;
      if (stage === "flags") {
        if (buffer.length < 4) return;
        noZeroes = (buffer.readUInt32BE(0) & 2) !== 0;
        buffer = buffer.subarray(4);
        stage = "options";
      } else if (stage === "options") {
        if (buffer.length < 16 || buffer.length < 16 + buffer.readUInt32BE(12)) return;
        const option = buffer.readUInt32BE(8);
        buffer = buffer.subarray(16 + buffer.readUInt32BE(12));
        if (option === 1) { socket.write(Buffer.concat([exportInfo(), Buffer.alloc(noZeroes ? 0 : 124)])); stage = "io"; }
        else if (option === 6 || option === 7) {
          optionReply(option, 3, Buffer.concat([u16(0), exportInfo()]));
          optionReply(option, 1);
          if (option === 7) stage = "io";
        } else if (option === 2) socket.end();
        else optionReply(option, 0x80000001);              // not supported
      } else {
        if (buffer.length < 28) return;
        const type = buffer.readUInt16BE(6), cookie = Buffer.from(buffer.subarray(8, 16));
        const offset = Number(buffer.readBigUInt64BE(16)), length = buffer.readUInt32BE(24);
        const payload = type === 1 ? length : 0;
        if (buffer.length < 28 + payload) return;
        if (type === 0) reply(cookie, Buffer.from(current.subarray(offset, offset + length)));
        else if (type === 1) {
          const data = Buffer.from(buffer.subarray(28, 28 + length));
          data.copy(current, offset);
          cache.push({ offset, data });
          reply(cookie);
        } else if (type === 3) {
          const covered = cache.length ? cache[cache.length - 1] : null;   // the writes before this flush
          setTimeout(() => {
            if (!powered) return;                          // cut during the flush: nothing is promised
            if (!LYING) for (const w of cache.splice(0, cache.indexOf(covered) + 1)) w.data.copy(durable, w.offset);
            flushes++;
            reply(cookie);
          }, random() * 8);
        } else if (type === 2) { socket.end(); return; }
        else throw new Error(`unexpected disk command ${type}`);
        buffer = buffer.subarray(28 + payload);
      }
    }
  });
}
let flushes = 0;
const disk = createServer(serve);
await new Promise((r) => disk.listen(at("nbd"), r));

/** What reaches the platters of the cache's contents when the power goes. */
function powerCut(torn) {
  const pending = cache.length;
  if (torn) for (const { offset, data } of cache)
    for (let s = 0; s < data.length; s += SECTOR) if (random() < 0.5) data.copy(durable, offset + s, s, s + SECTOR);
  cache = [];
  durable.copy(current);
  return pending;
}

// ---- one boot ----------------------------------------------------------------------------------
/** Boot, collect acknowledgements for `ms` after the first one, cut the power. */
async function boot(number, ms) {
  powered = true;
  const vm = spawn("qemu-system-x86_64", ["-enable-kvm", "-cpu", "host", "-smp", "2", "-m", "512", "-nodefaults", "-display", "none", "-no-reboot",
    "-kernel", KERNEL, "-initrd", at("initrd.gz"), "-append", `console=ttyS0 quiet panic=-1 mina.sync=${SYNC} mina.boot=${number}`,
    "-serial", `file:${at("serial.log")}`, "-drive", `file=nbd:unix:${at("nbd")},format=raw,if=virtio,cache=writeback`,
    "-device", "virtio-serial-pci", "-chardev", "stdio,id=acks,signal=off", "-device", "virtconsole,chardev=acks"], { stdio: ["pipe", "pipe", "pipe"] });
  let text = "", errors = "", exited = false;
  vm.stdout.on("data", (d) => (text += d));
  vm.stderr.on("data", (d) => (errors += d));
  const gone = new Promise((r) => vm.on("close", () => { exited = true; r(); }));
  for (let i = 0; i < 3000 && !exited && !text.includes("\n"); i++) await sleep(10);
  const started = text.includes("\n");
  if (started) await sleep(ms);
  powered = false;                                         // the disk stops answering ...
  vm.kill("SIGKILL");                                      // ... and the machine stops
  await gone;
  const acks = [...text.matchAll(/^A ([0-9a-f]{32}) (\d+)\r?\n/gm)].map((m) => [m[1], Number(m[2])]);
  const serial = existsSync(at("serial.log")) ? readFileSync(at("serial.log"), "utf8") : "";
  return { started, acks, log: errors + serial };
}

// ---- recovery of a copy, and what it holds -----------------------------------------------------
function inspect() {
  writeFileSync(at("copy"), durable);
  const fsck = spawnSync("e2fsck", ["-fy", at("copy")], { encoding: "utf8" });
  for (const f of ["m.db", "m.db-wal", "m.db-shm", "out.db", "out.db-wal", "out.db-shm"]) rmSync(at(f), { force: true });
  for (const [from, to] of [["m.db", "out.db"], ["m.db-wal", "out.db-wal"]]) spawnSync("debugfs", ["-R", `dump /${from} ${at(to)}`, at("copy")]);
  const sql = (q) => run("sqlite3", [at("out.db"), q], { stdio: ["ignore", "pipe", "pipe"] }).trim();
  try {
    const integrity = sql("PRAGMA integrity_check");
    const rows = new Map(sql("SELECT lower(hex(eid)), seq FROM events").split("\n").filter(Boolean).map((l) => { const [e, s] = l.split("|"); return [e, +s]; }));
    const whole = sql("SELECT (SELECT count(*) = coalesce(max(seq), 0) FROM events) AND (SELECT count(*) FROM events WHERE kind = 1) = (SELECT count(*) FROM incidents) AND NOT EXISTS (SELECT 1 FROM incidents i LEFT JOIN events e ON e.seq = i.updated_seq WHERE e.incident IS NOT i.id)") === "1";
    return { fsck: fsck.status, integrity, rows, whole };
  } catch (e) {
    return { fsck: fsck.status, integrity: String(e.stderr ?? e.message).trim().slice(0, 300), rows: new Map(), whole: false };
  }
}

// ---- the test ----------------------------------------------------------------------------------
const expected = new Map();                                // eid -> seq of every acknowledged event
const problems = { start: [], fsck: [], integrity: [], whole: [], lost: [] };
let acknowledged = 0, discarded = 0, lost = 0, reused = 0, lostSeqs = new Set();
try {
  for (let n = 1; n <= CUTS; n++) {
    const { started, acks, log } = await boot(n, 200 + random() * 3000);
    discarded += powerCut(n % 2 === 0);
    if (!started) { problems.start.push(`boot ${n}: ${log.slice(-600)}`); break; }
    for (const [eid, seq] of acks) expected.set(eid, seq);
    acknowledged += acks.length;
    const state = inspect();
    if (state.fsck >= 4) problems.fsck.push(`cut ${n}: e2fsck exit ${state.fsck}`);
    if (state.integrity !== "ok") problems.integrity.push(`cut ${n}: ${state.integrity}`);
    if (!state.whole) problems.whole.push(`cut ${n}`);
    const missing = [...expected].filter(([eid, seq]) => state.rows.get(eid) !== seq);
    // a lost event's number now belongs to another event: a client that had read that far skips it
    reused += [...state.rows.values()].filter((seq) => lostSeqs.has(seq)).length;
    for (const seq of state.rows.values()) lostSeqs.delete(seq);
    for (const [eid, seq] of missing) { expected.delete(eid); lostSeqs.add(seq); }
    if (missing.length) problems.lost.push(`cut ${n}: ${missing.length} of ${expected.size + missing.length}`);
    lost += missing.length;
  }
  if (!problems.start.length) {
    const last = await boot(CUTS + 1, 0);
    powerCut(false);
    if (!last.started) problems.start.push(`after the last cut: ${last.log.slice(-600)}`);
  }
} finally {
  disk.close();
  rmSync(dir, { recursive: true, force: true });
}

let failed = 0;
const check = (name, found) => { console.log(found.length ? `  FAIL ${name}\n       ${found.slice(0, 4).join("; ")}` : `  ok   ${name}`); if (found.length) failed++; };
console.log(`${CUTS} power cuts, durability ${SYNC}${LYING ? ", disk ignoring flushes" : ""}: ${acknowledged} events acknowledged, ${discarded} unflushed disk writes at the cuts, ${flushes} flushes`);
check("the server started again after every cut", problems.start);
check("the file system recovered", problems.fsck);
check("the database is intact", problems.integrity);
check("sequence numbers and incidents are consistent", problems.whole);
check("the test discarded unflushed writes", discarded ? [] : ["no write was pending at any cut"]);
if (SYNC === "normal") console.log(`  note acknowledged events lost: ${lost}; their sequence numbers later given to other events: ${reused}`);
else check("every acknowledged event is stored as acknowledged", problems.lost);
console.log(failed ? "powerloss: FAILED" : "powerloss: ok");
process.exit(failed ? 1 : 0);
