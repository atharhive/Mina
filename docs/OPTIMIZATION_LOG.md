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

Kept. (Single runs; run-to-run variation of up to about 20 % in CPU figures, measured later, is
far smaller than this change.)
