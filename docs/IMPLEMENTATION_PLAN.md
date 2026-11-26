# Implementation plan

Targets, not achievements. Nothing here is claimed until a command in this repository has
produced it.

## Goal

An offline-first disaster communication system served by one native C process, generated from
a Lean 4 specification, targeting more than 300,000 concurrent virtual users on 1 vCPU and
2 GB of RAM. MINA is a research system and not a replacement for official emergency services.

## Storage

Specified in `spec/Mina/Schema.lean`; the SQL is `gen/schema.sql`.

- `events`: append-only. `seq` (server-assigned, monotone rowid), `eid` (16-byte client id,
  unique: idempotency), `region`, `vis` (0 public, 1 responders only), `kind`, `incident`,
  `category`, `status`, `actor`, `ts`, `at`, `lat`, `lon`, `body`.
- Index `events_region_vis (region, vis)`, so entries are ordered by `(region, vis, seq)`.
- `incidents`: `id` (the `seq` of the report), `owner`, `region`, `category`, `status`,
  `updated_seq`.

Changes from the first plan: `category`, `status`, `at`, `lat` and `lon` were added because the
reports must carry them; timestamps are integers.

## API v1

Implemented as described in the [README](../README.md#api). `GET /v1/metrics` moved to D, with
the Observatory that reads it. `GET /*` (precompressed static assets compiled into the binary)
is D.

## Proof-guided execution

1. Sync scan: seek `(region, vis, after+1)` in the index, walk forward, seek each row.
   Responders merge the two visibility ranges by `seq`. No sort, no bytecode interpreter. Done.
2. Empty sync: `head[region][vis]`, derived in-memory state updated after each commit. If
   `after >= head` the answer is empty without a B-tree access. (Proven derived state is
   allowed; response and query-result caches are not.) Done.
3. Idempotent insert: today a SQL lookup by event id, then the insert. A native seek of the
   unique index is a candidate for E, if profiling shows it matters.

Each native plan keeps a SQL reference path (`MINA_FORCE_SQL=1`) for fallback and testing.

### Theorems

Proved, without `sorry` or new axioms: see [PROOFS.md](PROOFS.md). Still to do:
`reserve_safe` (background reads never take capacity reserved for emergency writes), which needs
the scheduling policy it describes, and an executable oracle in Lean as a second reference
beside the SQL.

## Milestones

| | Content | Done when |
|---|---|---|
| A | Audit, baseline, restructure | baseline measured, health pipeline builds and passes |
| B | Done: schema, contract, auth and roles, `mina-admin`, SQL plans, transition table, rate limits, bounded queues, idle timeout, synthetic seed | contract suite and ASan/UBSan build pass (see BASELINE.md) |
| C | Done except the Lean oracle: model, invariant, plans, sync, transitions; native plans; differential tests | theorems checked; no mismatch in 10^6 requests; native vs SQL measured (see BASELINE.md) |
| D | Started: outbox, sync, the citizen app and serving it from the server are done; Command, Observatory with metrics, maps and Lighthouse remain | bundle sizes and Lighthouse measured; offline create, reconnect, delivered |
| E | Started: MINA workload to 100K locally, one fix (`docs/OPTIMIZATION_LOG.md`). Profile, change one thing, measure, keep or revert; then AWS | results per step; AWS cost approved first |
| F | Crisis workloads, `kill -9` recovery, power loss in a virtual machine, fuzzing, secure (TLS) category | no lost acknowledged event, no duplicate |
| G | Final report, then stop | publication approved separately |

## Frontend

A pnpm workspace, three independent Vite builds and a shared package: React, TypeScript,
Tailwind, Dexie, a hand-written service worker; MapLibre and ECharts loaded lazily. Citizen
budget: 100 KB gzip of initial JavaScript, measured early. If React plus Dexie exceed it,
the alternatives are presented for a decision.

Outbox states: Saved locally, Awaiting sync, Delivered, Acknowledged, Resolved. Retries use
exponential backoff with jitter. The cursor advances only after the local transaction commits.

## Benchmarks

Steps: 1K, 10K, 50K, 100K (local), 200K, 280K, 300K, 350K, 400K, 500K (AWS, if sustained).
Categories reported separately: Native, Secure, Crisis. A fixed, documented request mix;
offered and achieved throughput; open connections reported apart from virtual users; at least
5 minutes sustained, 30 minutes where feasible; server and kernel network memory.

Budget: 300,000 users at about 0.1 request/s each is about 30,000 requests/s, which leaves at
most 28 us of one CPU per request, kernel included, at 85 % utilisation. A sync workload is
lighter per request than the inherited engine's list workload, so results are not compared
across applications; the engine is separately re-measured on an equivalent micro-workload.
