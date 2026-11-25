# Implementation plan

Targets, not achievements. Nothing here is claimed until a command in this repository has
produced it.

## Goal

An offline-first disaster communication system served by one native C process, generated from
a Lean 4 specification, targeting more than 300,000 concurrent virtual users on 1 vCPU and
2 GB of RAM. MINA is a research system and not a replacement for official emergency services.

## Storage

```sql
events(seq INTEGER PRIMARY KEY,   -- server-assigned, monotone (rowid)
       eid BLOB NOT NULL UNIQUE,  -- 16-byte client id: idempotency
       region INTEGER NOT NULL, vis INTEGER NOT NULL,  -- 0 public, 1 responders only
       kind INTEGER NOT NULL, incident INTEGER, actor INTEGER NOT NULL,
       ts TEXT NOT NULL, body TEXT CHECK(length(body) <= 280));
CREATE INDEX events_region_vis ON events(region, vis);   -- ordered by (region, vis, seq)
incidents(id INTEGER PRIMARY KEY /* seq of SOS_CREATED */, owner, region, category, status, updated_seq);
```

Event kinds: `SOS_CREATED`, `SAFETY_REPORTED` (vis 1); `SOS_ACKNOWLEDGED`, `STATUS_UPDATED`,
`INCIDENT_RESOLVED` (vis 0, redacted: incident, category, status; no text or location);
`ALERT_PUBLISHED` (vis 0). A citizen matches the incident id returned for their report
against the public stream to see its progress.

## API v1

| Route | Notes |
|---|---|
| `GET /v1/health` | done |
| `POST /v1/session` | rate limited; citizen device token. Responder and admin tokens come from an offline tool |
| `GET /v1/sync?region=R&after=C&limit=N` | N <= 256; `{"next","more","head","events":[...]}`; cursor beyond head: 409 `resync` |
| `POST /v1/events` | `{"eid","kind",...}`; 201 `{seq,incident}`; retry: 200 with the original and `"duplicate":true` |
| `GET /v1/incidents/:id` | responders see all; the owner a redacted view |
| `GET /v1/metrics` | admin token |
| `GET /*` | precompressed static assets compiled into the binary |

## Proof-guided execution

1. Sync scan: seek `(region, vis, after+1)` in the index, walk forward, seek each row.
   Responders merge the two visibility ranges by `seq`. No sort, no bytecode interpreter.
2. Empty sync: `head[region][vis]`, derived in-memory state updated after each commit. If
   `after >= head` the answer is empty without a B-tree access. (Proven derived state is
   allowed; response and query-result caches are not.)
3. Idempotent insert: `ON CONFLICT(eid) DO NOTHING`, then an index seek for the original.

Each native plan keeps a SQL reference path (`MINA_FORCE_SQL=1`) for fallback and testing.

### Theorems to prove (no `sorry`, no new axioms)

| Theorem | Statement |
|---|---|
| `syncPlan_eq` | under `Inv`, the native scan equals filter, sort by seq, take n |
| `merge_eq` | merging the two ranges equals the filtered reference for responders |
| `head_empty` | under `HeadInv`, `after >= head` implies the reference answer is empty |
| `head_preserved` | append and head update preserve `HeadInv` |
| `apply_idem` | applying an event twice equals applying it once |
| `cursor_mono`, `no_skip` | cursors never go back; under prefix visibility no matching event is missed |
| `transition_valid` | permitted (role, status, kind) steps preserve validity; the C table is generated from the same data |
| `reserve_safe` | (later) background reads never take capacity reserved for emergency writes |

Assumptions go in `docs/PROOFS.md`. The generated C is tested, not proved: an executable
oracle in Lean and differential runs against the SQL path.

## Milestones

| | Content | Done when |
|---|---|---|
| A | Audit, baseline, restructure | baseline measured, health pipeline builds and passes |
| B | Schema, contract, auth and roles, `mina-admin`, SQL plans, transition table, rate limits, bounded queues, synthetic seed | contract suite and ASan/UBSan build pass |
| C | Model, invariant, plans, sync, transitions; native plans; oracle; differential tests | theorems checked; no mismatch in 10^6 requests; native vs SQL measured |
| D | Citizen, Command, Observatory; outbox and sync; static assets | bundle sizes and Lighthouse measured; offline create, reconnect, delivered |
| E | Profile, change one thing, measure, keep or revert (`docs/OPTIMIZATION_LOG.md`); scale to 100K locally, then AWS | results per step; AWS cost approved first |
| F | Crisis workloads, `kill -9` recovery, fuzzing, secure (TLS) category | no lost acknowledged event, no duplicate |
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
