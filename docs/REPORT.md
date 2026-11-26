# MINA: project report

2026-11-26. MINA is an offline-first disaster communication system: one native C server on Linux
io_uring and SQLite, with its application layer specified in Lean 4, and three web applications
it serves itself. It is a research system and **not a replacement for official emergency
services**.

## In short

- The whole flow works: a report made offline arrives exactly once, a responder acts on it, the
  reporter sees the result.
- On one development laptop, over loopback, **100,000 virtual users** were served with no errors
  by a server restricted to one CPU and 2 GB.
- The **300,000-user target has not been reached or tested**.
- Lean proves properties of a **model**. The C is tested against that model and against SQL; it
  is not proved correct.
- It is **not ready for real use**: no HTTPS, no independent review, no field testing.

## Targets and results

| Target | Goal | Result |
|---|---|---|
| Concurrent active users | 300,000+ | 100,000 on one machine. Not reached |
| Throughput | 26,000 to 30,000+ requests/s | about 10,000 requests/s offered and served at 100,000 users; the maximum was not measured |
| Servers, compute, memory | 1 server, 1 vCPU, 2 GB | one pinned laptop core (faster than a small cloud vCPU), 2 GB cgroup, peak 525 MB at 100,000 users in the heaviest runs of the current settings |
| Lean specification, generated C | yes | data, rules, schema, routes, serializers and tables are generated; the request handlers are a hand-written C template that the generator fills, and the transport is hand-written C |
| Direct B-tree execution | yes | synchronisation; other reads and all writes use SQL |
| Query acceleration | 2 to 5 times | 1.6 to 1.8 on full pages, 4.1 on small answers, 47 to 83 on empty ones, measured inside the process; no established difference in whole-server CPU |
| Duplicate stored events | none | none in any test |
| Lost acknowledged events | none under process crashes | none in forced-crash tests; power loss not tested; see restore below |
| Citizen JavaScript | under 100 KB compressed | 104 KB gzip (90 KB brotli): over |
| Offline reporting | yes | yes, on `localhost` or HTTPS |
| Lighthouse performance | 95+ | 100 for all three applications: first screen, simulated mobile, same machine |

## What was built

| Part | Contents | Non-blank lines |
|---|---|---:|
| `runtime/` | io_uring transport, HTTP, JSON, tokens, buffers, SQLite access, metrics, embedded files | 2,002 |
| `spec/` (Lean) | domain, schema, queries, contract, generator | 1,550, of which 538 model and theorems and 240 oracle |
| `spec/Mina/templates/app.c` | request handlers filled by the generator | 654 |
| `gen/` | generated C, SQL and TypeScript, checked in | 1,029 |
| `frontend/` | shared sync engine, citizen app, responder dashboard, observatory | 1,474, and 899 of tests |
| `tests/`, `bench/` | suites, fuzzers, load generator and runners | 1,554 and 720 |
| `tools/` | operator tool, seed data, backup, restore, notices | |

Line counts at commit `6e1114d`. Design: [ARCHITECTURE.md](ARCHITECTURE.md). Reusing the Lean
pipeline: [REUSING.md](REUSING.md).

## Verification

All checks ran one after another from a clean build at commit `8290d1f` (kernel
`7.0.0-44-generic`). 33 of 34 passed. The other, the oracle comparison on the sanitizer build,
found **no difference** but never generated one of the 26 required kinds of answer, so it
reported failure; the generator was corrected in `6e1114d` and the same run then passed.

| Check | Result |
|---|---|
| Build: Lean proofs, generation, comparison with `gen/`, compile | passes, 0 compiler warnings |
| Theorems and their axioms (`tests/proofs.sh`) | pass |
| Query plans under the bundled SQLite | 10 statements, none scans or sorts |
| API contract: release, sanitizer, SQL forced, web build | 176, 175, 175, 176 checks, no failure |
| Seed data and file serving, release and sanitizer | 19 and 45 checks, no failure |
| Native reads against SQL | 100,000 requests (and 10,000 sanitized), 0 differences |
| Server against the Lean oracle | 50,000 requests, 0 differences |
| Backup and restore; durability system calls | 19 checks; as specified |
| Forced crashes (`kill -9`) | 26 crashes with 46,361 acknowledged events, and 16 with 25,052 sanitized: none lost or duplicated |
| Parser fuzzing, 120 s | 10.1 million rounds, no report |
| Network fuzzing, 60 s | 192,599 requests over damaged connections, no report, nothing left open |
| Web applications | 49 unit tests, type check, 5 browser tests |

Afterwards, `3c0f261` added the third-party licence notices to the web build (a gap found while
writing this report); the citizen browser tests (now 4), the contract and the file-serving suites
were rerun and passed.

Planted bugs, in copies of the code, were detected by the native-against-SQL test, the oracle,
the crash test and both parser fuzz cases tried.

## What Lean establishes

Details and assumptions: [PROOFS.md](PROOFS.md). No `sorry`, no new axioms, no `native_decide`.

| Proved about the model | Used by the server to |
|---|---|
| The index scan and the two-stream merge equal the reference queries | answer synchronisation without sorting or the SQL interpreter |
| A cursor at the newest event has an empty answer, and remembered heads stay exact | answer up-to-date clients without reading the database tables |
| Retries change nothing; cursors never go back, pages compose, nothing is skipped | define safe retry and synchronisation behaviour |
| Incidents follow the permitted life cycle; public updates carry no text or location | generate the transition table |

**Not established:** that the C, the runtime, the generator or SQLite are correct. The C is
compared with SQL and with the oracle. The oracle shares the field rules and transitions with the
server, so an error in those rules would not show.

## Performance

Full tables, commands and raw rows: [BASELINE.md](BASELINE.md), `bench/reports/`. One laptop
(Intel i5-12450H), server alone on one core in a 2 GB cgroup, load generator on other cores,
loopback. About 0.1 request/s per user.

| Run | Users | Requests/s | p99 | Server CPU | Peak memory |
|---|---:|---:|---:|---:|---:|
| Sustained, 5 minutes (`5b30529`) | 100,000 | 10,007 | 1.6 ms | 28 % | 446 MB |
| All connect within 5 s | 100,000 | 10,076 | 1.4 ms | 33 % | 438 MB |
| 40 % of citizen requests are new reports (3 runs, current log limit) | 100,000 | 10,030 | 1.8 to 1.9 ms | 35 % | 518 to 525 MB |
| 60 % retries | 50,000 | 5,003 | 1.7 ms | 28 % | 249 MB |
| Mass reconnection, 100,000 events behind | 20,000 | 4,285 | 2.0 ms | 24 % | 130 MB |

**Read these with care.** CPU figures on this machine have differed by up to about 60 % between
sessions; only runs alternated within one session are comparable. Loopback charges part of the
network work to the load generator. Most rows are single runs. No run was longer than 5 minutes,
and nothing used a second machine. Stretching the first row linearly to 300,000 users gives about
85 % of this core and 1.3 GB: arithmetic, not evidence.

In-process cost of a synchronisation at `8290d1f` (`bench/micro.sh`), native against SQL, in
microseconds: 64 events 14.5 against 24.5; responder merge 15.2 against 28.0; 256 events 57
against 92; a few new events 0.34 against 1.38; up to date 0.02 against 1.09.

Changes that mattered, with before and after: [OPTIMIZATION_LOG.md](OPTIMIZATION_LOG.md). The
largest was fixing an insert that scanned an index, which had saturated the server at 100,000
users. `MINA_SYNC=full` (survives power loss) raised median latency from 0.8 to 6.8 ms.

## Web applications

| | Citizen | Responder | Observatory |
|---|---|---|---|
| JavaScript, gzip | 104.3 KB | 106.7 KB | 105.7 KB |
| Lighthouse performance, accessibility, best practices | 100, 100, 100 | 100, 100, 100 | 100, 100, 100 |

The server binary is 1.31 MB, or 3.01 MB with the applications compiled in (at `8290d1f`). With 7,045
incidents the responder dashboard answers a click in about 30 ms; loading all 20,000 events takes
about 27 s.

## Security and correctness limitations

| Limitation | Consequence |
|---|---|
| No TLS | tokens and reports are readable on the network without a proxy; offline features fail away from `localhost` |
| No token revocation | a leaked token works until it expires or the key is replaced |
| The new-session limit is server-wide; the citizen limit is per identity | one abuser can block new citizens, or rotate identities |
| Citizens may report in any area | false reports are not confined |
| Default durability is `normal` | recently acknowledged writes can be lost in a power cut |
| Restoring a backup | only devices that return resend; responder actions on lost incidents are refused |
| Parsers fuzzed by random mutation only | defects on rare paths may remain |
| One server, one writer | no redundancy |
| One author, no independent review | unknown defects of design and code |

## Not done

| Planned | State |
|---|---|
| 300,000+ users; two-machine and 30-minute runs; kernel profiling | blocked, [PENDING.md](PENDING.md) |
| AWS deployment, off-machine backups, monitoring, access policy | not started |
| HTTPS ("secure" benchmark category), real phones | blocked |
| Power-loss testing | not started |
| Reserved capacity for emergency writes (`reserve_safe`) and congestion control | not built or proved |
| Native plans for incident reads and duplicate lookup | not built; no measured need yet |
| Map background, translations | blocked on choices |
| Server-side request latency, queue and buffer occupancy over time | the Observatory shows batch times and exhaustion counts instead |
| Repeated measurements to settle the effect of native reads on server CPU | to do |

## Defects found and fixed along the way

An insert that scanned a whole index; generated code left stale by a build that missed template
changes; answers queued without bound for a client that was not reading; stalled connections never
closed; the
citizen app blank when reopened offline; one app's offline cache deleting another's; a restore
that would have made clients silently skip events, and clients that did not resend after it; a
sync loop that a faulty server could keep running; request-thread stalls under heavy writing;
shipped web code without its licence notices.

## Reproducing

```bash
./build.sh && ./build.sh sanitize
tests/proofs.sh && tests/plans.sh && tests/unit.sh && tests/contract.sh && tests/seed.sh
tests/assets.sh && tests/diff.sh 100000 && node tests/oracle.mjs 50000
tests/backup.sh && tests/durability.sh && node tests/crash.mjs
tests/fuzz.sh 120 && node tests/netfuzz.mjs
./build.sh web && (cd frontend && pnpm install && pnpm test && pnpm typecheck \
  && pnpm --dir citizen e2e && pnpm --dir command e2e && pnpm --dir observatory e2e)
bench/lighthouse.sh; bench/micro.sh; bench/mina.sh 100000 60 300 30
```

## Suggested next steps

1. Two or more cloud machines: run to 200,000 and 300,000 users, for 30 minutes at the highest
   step that holds. This settles the main target either way.
2. Profile the kernel time, which was about two thirds of server CPU, before optimising further.
3. HTTPS in front of the server, then real phones.
4. A review by someone else, starting with authentication and the request parsers.

## Licence and attribution

AGPL-3.0 (`LICENSE`). Third-party components: [ATTRIBUTION.md](../ATTRIBUTION.md).
