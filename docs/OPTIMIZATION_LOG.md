# Optimisation log

One change at a time, measured before and after. Environments and full tables are in
[BASELINE.md](BASELINE.md).

## 1. The event insert scanned an index (`5b30529`)

**Symptom.** Under the MINA workload the server saturated at 100,000 users: 7,253 of 10,000
requests/s, p99 6.1 s. About 95 % of its CPU time was in user space, and forcing reads to SQL
changed nothing, so the read path was not the cause.

**Cause.** The insert took the next sequence number with
`FROM (SELECT coalesce(max(seq), 0) + 1 AS s FROM events)`. SQLite planned this as a scan of
the covering index `events_region_vis`, so every insert read every event. Measured with the
sqlite3 shell on a 279,805-event database: 7.17 ms per insert, against 0.05 ms for the
corrected form. The cost grew with the number of events stored.

**Why tests missed it.** The query plan check covered only reads, and the functional tests use
small databases.

**Change.** `FROM (SELECT coalesce((SELECT max(seq) FROM events), 0) + 1 AS s)`. Every prepared
statement is now in `spec/Mina/Query.lean`, and `tests/plans.sh` rejects any of them that scans
or sorts under the bundled SQLite.

**Result** (same machine and workload):

| Users | CPU before / after | CPU per request | p99 |
|---:|---|---|---|
| 10,000 | 26.4 % / 6.6 % | 264 / 66 us | 13.7 / 1.74 ms |
| 50,000 | 65.0 % / 19.5 % | 130 / 39 us | 42.5 / 1.63 ms |
| 100,000 | 99.9 % (saturated) / 28.4 % | 138 / 28 us | 6,095 / 1.60 ms |

Kept. (Single runs. CPU figures on this machine were later seen to differ by up to about 60 %
between sessions; this change is several times larger than that.)

## 2. The request thread stalled to checkpoint under heavy writing

**Symptom.** With many new reports, the log said `checkpointed in the request thread`, each time
stalling every connection: 3.8 to 9.2 ms, 23 times in one 155 s run.

**Cause.** Continuous commits never leave the moment in which the write-ahead log could restart,
so whenever the background checkpoint falls behind, the log grows to its limit (`WAL_HIGH`) and
the request thread checkpoints it.

**Change tried.** `WAL_HIGH` from 16,384 to 65,536 frames. Nothing else differs between the
builds. Six alternating runs of each, 40 % of citizen requests new reports (about 1,700 and
3,400 new events/s), 2026-11-26; raw rows in
`bench/reports/2026-11-26-wal-limit.jsonl`.

| Users | Limit | Runs with stalls | Stalls (min / median / max) | 99.9th percentile, per run | Worst request, per run | Peak memory, per run |
|---:|---:|---|---|---|---|---|
| 50,000 | 16,384 | 1 of 3 | 12 (5.3 / 9.1 / 12.0 ms) | 2.9, 2.9, **5.6** ms | 5.4, 5.1, **18.5** ms | 281, 281, 342 MB |
| 50,000 | 65,536 | 0 of 3 | none | 2.9, 3.1, 2.9 ms | 5.5, 6.0, 5.4 ms | 281, 281, **444** MB |
| 100,000 | 16,384 | 1 of 3 | 37 (1.8 / 10.5 / 12.8 ms) | 2.6, **11.9**, 2.9 ms | 5.7, **18.6**, 5.8 ms | 518, 568, 533 MB |
| 100,000 | 65,536 | 0 of 3 | none | 2.6, 2.6, 3.7 ms | 6.5, 8.0, 9.0 ms | 519, 518, 525 MB |

Server CPU (32.7 to 35.3 %) and throughput did not differ; every acknowledged event was stored.

**Reading it.** The condition comes and goes: it appeared in 2 of 6 runs at the old limit, which
then had the long tail. It cannot be forced, so the larger limit is shown to help only as far as
those runs reach. Its cost is a larger log when the background thread is behind: one run used
about 160 MB more page cache (reclaimable memory, counted against the 2 GB). A restart after a
crash has more log to scan; that time was not measured.

Kept.

