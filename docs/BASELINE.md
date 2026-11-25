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
