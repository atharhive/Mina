# Baseline

Measurements of the inherited engine, taken on 2026-11-26 from a scratch copy of the original
source before it was changed for MINA. They describe the previous application on this
machine. **They are not MINA results** and not comparable with measurements on other hardware.

## Environment

| | |
|---|---|
| CPU | Intel Core i5-12450H (4 performance + 4 efficiency cores), governor `powersave` |
| Memory | 15 GB; a shared desktop, about 6.7 to 7.1 GB available during load runs |
| Kernel | Ubuntu `7.0.0-44-generic` |
| Toolchain | gcc 15.2.0, Lean 4.35.0, SQLite 3.54.1 amalgamation |

## Build and proofs

- `lake build` and code generation succeed; the generated C equals the checked-in copy.
- The C build succeeds with 7 `-Wstringop-overflow` warnings (a 12-byte scratch buffer
  passed to a formatter that can write 20 bytes; the values used never exceed 10).
- No `sorry`, `axiom` or `native_decide` in the specification. `#print axioms` for the six
  main theorems (storage invariant: soundness of the startup check and preservation by both
  writes; both read plans equal their specification) lists only `propext`,
  `Classical.choice` and `Quot.sound`.

## Correctness suite

| Binary | Result |
|---|---|
| **Original source, unmodified** | **fails**: stops answering during the third check |
| With the one-line kernel workaround | 42 of 42 checks pass |

### Why the original hangs here

Each ring is created with `IORING_SETUP_DEFER_TASKRUN` and an eventfd that one `epoll_wait`
watches. On this kernel the eventfd of a ring fires for its first batch of deferred task work
and then stays silent, while `IORING_SQ_TASKRUN` stays set. A connection arriving on an
already-used ring is never accepted.

- Reproduced with the server: sequential `curl` requests began to hang at the 4th to 9th
  connection in three of three runs.
- Reproduced without the server: `tests/kernel/eventfd_wakeup.c` reports 7 of 8 wakeups lost.
- Likely cause (inferred from the changelog and mailing-list descriptions, not confirmed in
  kernel source): this kernel carries *io_uring: defer eventfd signaling when queued from a
  wakeup handler* (CVE-2026-80920), and its changelog shows no sign of the earlier follow-up
  *io_uring/eventfd: reset deferred signal state*, without which a deferred signal is queued
  only once. The `7.0.0-43` changelog lists the first patch too.

Workaround: `epoll_wait` gets a 1 ms timeout instead of none. The loop already checks each
ring's TASKRUN flag on every iteration. With it, 600 of 600 sequential requests were
answered. Every load figure below includes this change.

## Native read plans against SQL

In process, one thread pinned to a performance core, inside one read transaction, 100,000 to
200,000 iterations, three repetitions that agreed within 0.03 us.

| Query | SQL | Native B-tree plan | Ratio |
|---|---:|---:|---:|
| List of the 20 newest items | 11.26 us | 2.97 us | 3.8x |
| One item by id | 0.92 us | 0.57 us | 1.6x |

Output was byte-identical for the list and for 20,000 random items. The inherited
documentation reported 16.7 to 5.4 us for the list query on its own machine; the direction
and size of the gain reproduce.

## Load

Server alone on CPU 0 in a 2 GB cgroup with a 65,535 descriptor limit; load generator on CPUs
2 to 11; private network namespace over loopback. The generator reproduces the original load
script's user model: list read, think 3 to 7 s, item read, think 3 to 8 s, a write for 15 % of
cycles and a second kind of write for 2 %, idle 5 to 15 s (about 0.106 requests per second per
user). One keep-alive connection per user. One run per step.

| Users | Ramp / hold | Requests/s | p50 / p95 / p99 ms | Errors | CPU | CPU per request | Memory peak (kernel part at hold) |
|---:|---|---:|---|---:|---:|---:|---|
| 1,000 | 10 / 60 s | 107 | 0.96 / 1.55 / 1.79 | 0 | 2.8 % | 260 us | 46 MB (22) |
| 10,000 | 20 / 90 s | 1,056 | 0.75 / 1.47 / 1.62 | 0 | 8.4 % | 80 us | 89 MB (56) |
| 50,000 | 40 / 120 s | 5,285 | 0.77 / 1.14 / 1.50 | 0 | 26.7 % | 51 us | 245 MB (206) |
| 100,000 | 60 / 120 s | 10,578 | 0.79 / 1.09 / 1.28 | 0 | 32.0 % | 30 us | 441 MB (394) |

All connections stayed open through every hold and offered throughput matched achieved.

Reading these numbers:

- Over loopback part of the kernel receive path is charged to the client's CPU, which
  flatters the server. This core is also faster than a small cloud vCPU.
- CPU per request at low load is dominated by fixed cost (idle wakeups, small batches).
- About 70 % of server CPU time was kernel time.
- Kernel memory grows by roughly 4 KB per connection. Extrapolated, not measured: 300,000
  connections would need about 1.2 GB.

## Milestone C: native sync plans

| Check | Result |
|---|---|
| `tests/proofs.sh` | all listed theorems present; only `propext`, `Classical.choice`, `Quot.sound` |
| `MINA_DIFF_SEED=7 tests/diff.sh 1000000` (commit `683a4ad`) | 1,000,000 requests, 0 mismatches, 2,910 s; no fallback to SQL during the run |
| The same test with a bug planted in a copy: heads not advanced; restricted stream ignored; page limit off by one | each fails within the first 17 requests |
| `tests/diff.sh 10000`, ASan and UBSan build | 0 mismatches, no sanitizer report |
| `tests/contract.sh` with `MINA_FORCE_SQL=1` | 156 of 156 |

`bench/micro.sh 200000 16`: the application's read and response serialization only (no network,
HTTP parsing, token check or transaction), in process on CPU 0, one open read transaction,
100,000 requests per case, answers compared byte for byte before timing. Three runs; the table
shows the lowest and highest.

| Case | Native, us | SQL, us | SQL / native | Answer, bytes |
|---|---|---|---|---:|
| Public stream, 64 events | 15.1 to 16.7 | 26.3 to 28.1 | 1.7 | 4,227 |
| Responder merge, 64 events | 16.0 to 17.2 | 29.5 to 31.8 | 1.8 to 1.9 | 4,743 |
| Public stream, 256 events | 58.1 to 64.1 | 99.5 to 104.5 | 1.6 to 1.7 | 16,557 |
| Public stream, a few new events | 0.30 to 0.31 | 1.38 to 1.47 | 4.7 to 4.8 | 191 |
| Up to date, citizen | 0.02 | 1.08 to 1.14 | 49 to 53 | 125 |
| Up to date, responder | 0.02 | 2.03 to 2.05 | 91 to 96 | 125 |

Reading these numbers:

- The research target of 2 to 5 times is reached for small and empty answers, not for full
  pages. A full page still costs about 0.25 us per event: one table seek per row, because the
  index does not cover the columns, plus serialization. Which dominates has not been profiled.
- An up-to-date answer needs no B-tree access (`head_empty`); the 20 ns is building the
  response.
- The saving for the server as a whole is much smaller, see the load results below.

## MINA workload under load

`bench/mina.sh <users> <ramp> <hold> <rampdown> [native|sql]`: the request mix documented in
`bench/workload_mina.h` (about 0.1 request/s per user; 92 % of citizen requests are syncs, 5 %
submissions), 64 regions, 200,000 seeded events, one keep-alive connection per user. Server
alone on CPU 0 in a 2 GB cgroup, generator on CPUs 2 to 11, loopback, database on ext4, one run
each. Tokens are signed by the generator; session creation is not part of the load.

| Users | Build, reads | Hold | Requests/s, achieved of offered | p50 / p99 ms | Errors | CPU | CPU per request | Memory peak (kernel) |
|---:|---|---:|---:|---|---:|---:|---:|---|
| 10,000 | `c75adc8`, native | 90 s | 1,000 of 1,000 | 0.86 / 13.70 | 0 | 26.4 % | 264 us | 89 MB (56) |
| 50,000 | `c75adc8`, native | 120 s | 4,998 of 4,997 | 3.81 / 42.50 | 0 | 65.0 % | 130 us | 249 MB (207) |
| 50,000 | `c75adc8`, SQL | 120 s | 4,998 of 4,998 | 3.71 / 26.11 | 0 | 64.8 % | 130 us | 248 MB (206) |
| 100,000 | `c75adc8`, native | 300 s | **7,253 of 10,000** | 3,604 / 6,095 | 0 | 99.9 % | 138 us | 597 MB (395) |
| 100,000 | `c75adc8`, SQL | 300 s | **7,201 of 10,000** | 3,703 / 6,160 | 0 | 99.9 % | 139 us | 595 MB (395) |
| 10,000 | `5b30529`, native | 90 s | 1,000 of 1,000 | 0.73 / 1.74 | 0 | 6.6 % | 66 us | 89 MB (56) |
| 50,000 | `5b30529`, native | 120 s | 5,000 of 5,000 | 0.71 / 1.63 | 0 | 19.5 % | 39 us | 246 MB (206) |
| 100,000 | `5b30529`, native | 300 s | 10,007 of 10,007 | 0.75 / 1.60 | 0 | 28.4 % | 28 us | 446 MB (395) |
| 100,000 | `5b30529`, SQL | 300 s | 10,007 of 10,007 | 0.78 / 1.50 | 0 | 31.7 % | 32 us | 446 MB (395) |

Every connection stayed open through every hold and every answer was the expected one. At
100,000 users about 71 % of syncs returned events (events: 200,000 at the start, about 307,000
at the end).

Reading these numbers:

- The step from `c75adc8` to `5b30529` is one fix, see
  [OPTIMIZATION_LOG.md](OPTIMIZATION_LOG.md).
- At 100,000 users the run with SQL forced used 31.7 % CPU and the native run 28.4 %, one run
  each. Repeat runs of one build on this machine have differed by up to 14 % (see below), so
  these two runs do **not** establish that native reads change the server's total CPU use.
  Settling it needs alternating repeated runs. Most server time is in the kernel (about two
  thirds).
- Loopback charges part of the receive path to the generator, this core is faster than a small
  cloud vCPU, and an idle server process left running on this machine used about 2 % of the
  sibling hardware thread during all of these runs.
- Straight-line extrapolation to 300,000 users gives about 85 % of this core and 1.3 GB. That is
  arithmetic, not a measurement, and leaves little margin.
- Not measured: any step above 100,000 users, a 30-minute stability run, a two-machine run,
  TLS, or session creation under load.

## Citizen app bundle

`vite build`, gzip sizes of the single JavaScript file, 2026-11-26. The budget is 100 KB.

| Variant | JavaScript, gzip | End-to-end test |
|---|---:|---|
| As committed: React 19.3.1 and Dexie 4.4.7 | 105.15 KB | passes |
| The same with Dexie left out of the bundle (for size only, does not run) | 74.09 KB | not run |
| Preact 11.2.0 compatibility layer in place of React, with Dexie (trial copy, not committed) | 44.05 KB | passes unchanged |

The stylesheet adds 2.72 KB. Lighthouse has not been run.

As served by the server (brotli): JavaScript 90,032 bytes, stylesheet 2,348 bytes, against
333,656 and 9,254 uncompressed. Embedding the app grows the server binary from 1.30 MB to
1.87 MB. With the web build, `tests/contract.sh` passes 155 of 155, `tests/assets.sh` 40 of 40
on release and sanitizer builds, and the browser test passes against the server alone.

With the responder dashboard added: its JavaScript is 104.9 KB gzip (90,974 bytes brotli), the
citizen app's 104.2 KB gzip (90,530 bytes brotli), and the server binary is 2.42 MB.
`tests/assets.sh` passes 45 of 45 on both builds, the shared library's tests 27 of 27, and both
applications' browser tests pass.

Decision (2026-11-26): React is kept, 5 KB over the budget. The difference costs a first visit
only, since the service worker then holds the application; at 50 kbit/s, 61 KB is about 10 s.
Revisit if the bundle grows.

## Cost of the server's counters, and run-to-run variation

50,000 users, `bench/mina.sh 50000 40 120 25 native`, builds immediately before (`6a4db4f`) and
after (`39a4be2`) the `/v1/metrics` counters were added, alternating, 2026-11-26. Every run
served 5,000 requests/s with no errors.

| Pair | Before: CPU, us per request | After: CPU, us per request |
|---:|---|---|
| 1 | 24.8 %, 49.7 | 25.0 %, 50.0 |
| 2 | 24.8 %, 49.6 | 25.0 %, 49.9 |
| 3 | 24.0 %, 48.1 | 21.5 %, 43.0 |
| Mean | 24.5 %, 49.1 | 23.8 %, 47.6 |

The counters have no measurable cost. The same build ranged from 43.0 to 50.0 us per request,
and the earlier single run of an older build gave 39.0: the laptop's frequency governor and
other activity move these figures by this much. Treat a single run's CPU figure as accurate to
perhaps 20 %.

## Observatory

Its JavaScript is 105.6 KB gzip (91,441 bytes brotli); the server binary with all three
applications is 2.99 MB. `tests/contract.sh` passes 173 of 173 (172 with `MINA_FORCE_SQL=1`,
which has one check fewer), and the browser tests of all three applications pass.

## Lighthouse

`bench/lighthouse.sh 3`: Lighthouse 13.6.0, default mobile settings (simulated slow 4G, 4x CPU
slowdown), Google Chrome headless, applications served by `bin/mina-server` on the same
machine, 2026-11-26. Raw rows: `bench/reports/2026-11-26-lighthouse.jsonl`.

| Page | Performance | Accessibility | Best practices | First paint | Largest paint | Blocking | Bytes transferred |
|---|---:|---:|---:|---:|---:|---:|---:|
| Citizen `/` | 100 | 100 | 100 | 0.75 s | 1.65 s | 0 ms | about 95 KB |
| Command `/command/` (sign-in) | 100 | 100 | 100 | 0.75 s | 0.75 to 1.50 s | 0 ms | about 96 KB |
| Observatory `/observatory/` | 100 | 100 (98 before a landmark fix) | 100 | 0.75 s | 0.75 to 1.50 s | 0 ms | about 95 KB |

These measure the first screen. They say nothing about a signed-in dashboard full of data (next
section), a real phone or a real network.

## Responder dashboard with a large region

`MINA_PERF=1 npx playwright test perf` in `frontend/command`: 20,000 seeded events (7,045
incidents) in one area, desktop Chrome, one run per row, 2026-11-26.

| Build | Page elements | Click to paint | Time blocked while loading | All events on the device |
|---|---:|---|---|---:|
| Whole list rendered | 49,547 | 304 to 375 ms | 15.4 s in 69 long tasks, longest 435 ms | 59.8 s |
| 200 rows at a time (`9ae6de0`) | 1,634 | 22 to 31 ms | none | 38.6 s |
| and backlog fetched without waiting (`55c0a03`) | 1,634 | 25 to 31 ms | none | 27.1 s |
| and the position plot added | 1,768 | 22 to 32 ms | none | 27.4 s |

The remaining load time has not been profiled; the dashboard re-reads all stored events after
each page it saves, which is the first thing to look at.

## Crash recovery

`node tests/crash.mjs`: 32 clients submit reports and transitions while the server is killed
with `SIGKILL` at random moments and started again; unanswered requests are retried with the same
event id. Afterwards the database is compared with what the clients were told.
2026-11-26, ext4 and tmpfs-backed temporary directory of this machine.

| Run | Crashes | Events acknowledged | Lost, changed or duplicated | Failed restarts |
|---|---:|---:|---:|---:|
| Release build, seed 1 | 26 | 52,465 | 0 | 0 |
| Release build, seed 99 | 26 | 56,488 | 0 | 0 |
| ASan and UBSan build, 15 requested | 16 | 24,330 | 0 | 0 |

The database passed `PRAGMA integrity_check`, sequence numbers had no gaps, every incident
agreed with its last event, and synchronisation after recovery matched SQL. With a bug planted
that reports success for a rolled-back transaction, the test fails. This is a **process** crash:
the operating system kept running. Power loss has not been tested, and with
`synchronous=NORMAL` recently acknowledged writes may be lost then.

## Fuzzing

| Test | What ran | Result |
|---|---|---|
| `tests/fuzz.sh 60 <seed>`, seeds 1 to 4: HTTP framing, route and request decoders, JSON, tokens; exact-size buffers, ASan and UBSan | 19.8 million rounds, every outcome type reached | no report |
| The same with `find_head_end` or the `\u` escape check made to read past the end (copy) | | each found within the run |
| `node tests/netfuzz.mjs 45 <seed>`, seeds 1 to 3: damaged and pipelined requests in random pieces, closed or unread connections, sanitizer build | 424,613 requests | no report; afterwards no connection or queued answer left behind |

The fuzzer mutates seed requests without coverage guidance (clang is not installed), so it
explores less deeply than libFuzzer or AFL would.

## Not measured

- Any step above 100,000 users, a five-minute confirmation hold, or a two-machine run.
- The original load tool (k6 is not installed).
- A CPU profile: `perf` needs `kernel.perf_event_paranoid` of 1 or lower, or root.

The inherited result of 280,000 users and 26,683 requests per second was measured elsewhere,
on other hardware, and has not been reproduced here.

## MINA at the end of Milestone A (health route only)

| Check | Result |
|---|---|
| `./build.sh` | succeeds; release compile has 0 warnings |
| `tests/contract.sh` | 13 of 13 |
| Same suite against a build with an unbounded idle wait | fails, including the 200-connection check |
| Idle CPU, 20 s, no connections | 3.4 % of one CPU with a 1 ms wait (a second run: 2.6 %); 0.55 % with 10 ms; 0.00 % unbounded |
| 10,000 users, health route only, 60 s hold | 1,000 req/s, p99 1.57 ms, 0 errors, 6.5 % CPU, 79 MB peak |

The last row only shows that the pipeline and harness work; a health check is not a
meaningful workload.

## MINA at the end of Milestone B

Same machine, 2026-11-26.

| Check | Result |
|---|---|
| `tests/unit.sh` | passes |
| `tests/contract.sh`, release build | 156 of 156 |
| `tests/contract.sh`, ASan and UBSan build | 154 of 154, no sanitizer report; the resident-memory check is skipped |
| `tests/seed.sh`, both builds | pass |
| A client that does not read 200 answers (23.9 MB) | server resident size grew 1.3 MB; all 200 answers arrived once it read |

Health route only, 10,000 users, 20 s ramp, 60 s hold, one run each, back to back, loopback.
This checks that the transport changes cost nothing measurable on an idle-heavy load; it says
nothing about the cost of MINA's own routes, which have not been load tested. The Milestone B
binary was built before two later input-validation fixes in query parsing and batch writes.

| Build | Requests/s | p50 / p99 ms | Errors | CPU | CPU per request | Memory peak |
|---|---:|---|---:|---:|---:|---:|
| End of Milestone A | 1,000 | 0.72 / 1.55 | 0 | 6.5 % | 65 us | 79 MB |
| End of Milestone B | 1,000 | 0.73 / 1.57 | 0 | 6.6 % | 66 us | 79 MB |

