# Architecture

State of the tree at the end of Milestone C: the inherited engine with MINA's API.
Synchronisation reads come from native B-tree plans, everything else from SQL. What comes next is in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

## Build lifecycle

`./build.sh`:

1. Downloads the SQLite 3.54.1 amalgamation if absent and checks its SHA-256.
2. `lake build`: Lean elaborates `spec/` and the kernel checks every theorem in it
   ([PROOFS.md](PROOFS.md)).
3. `lake exe derive ../build` writes `app_gen.c` (the `@{...}` slots of
   `spec/Mina/templates/app.c` filled in), `domain.h` (roles, kinds, field rules and the
   transition table), `schema.sql` and `queries.sql`.
4. Compares each with the checked-in copy in `gen/` and stops on any difference.
5. Compiles one translation unit, `runtime/server.c`, which includes `sqlite3.c`, the runtime
   and the generated code (`-O2 -march=native`, `SQLITE_THREADSAFE=2`), and
   `tools/mina-admin.c`. `./build.sh sanitize` builds both with ASan and UBSan.

## Specification

| Module | Holds |
|---|---|
| `Mina.Domain` | roles, categories, statuses, event kinds with their rules, permitted transitions, limits |
| `Mina.Schema` | tables and the region index; produces the schema and a startup layout check |
| `Mina.Query` | the SQL that defines what reads return |
| `Mina.Contract` | routes, errors, response shapes, rate limits |
| `Mina.Model`, `Plan`, `Sync`, `Transition` | the event store as a model, and the theorems about reads, retries, cursors and transitions |
| `Mina.Codegen`, `Mina.Emit` | the generator |

## Request lifecycle

| Step | Where |
|---|---|
| One thread drives several io_uring rings; each has a `SO_REUSEPORT` listener, a table of direct descriptors and a provided-buffer ring (1024 x 2 KB) | `uring.c: transport_init`, `ring_init` |
| Multishot accept into a direct descriptor, then multishot receive | `uring.c: arm_accept`, `arm_recv`, `handle_cqe` |
| Bytes are framed as HTTP/1.1; partial requests are kept per connection | `uring.c: on_data`, `parse_requests`; `http.c: http_parse` |
| The generated router matches the route; its decoder authenticates, validates, applies rate limits and queues a job, or answers with a constant response | `app_gen.c: app_decode`, `decode_event`, `decode_sync`, `decode_incident`, `issue_session` |
| All jobs of one round of completions form a batch served by one SQLite transaction: reads first, then writes in order | `app_gen.c: app_batch`; `db.c: db_batch_begin`, `db_batch_end` |
| A write looks up its event id (a retry is answered from the stored row), checks the transition, appends the event and updates the incident | `app_gen.c: exec_event`, `apply_transition` |
| An unexpected statement or commit failure rolls the batch back and answers every write in it with 500 | `app_gen.c: app_batch`; `db.c: db_batch_abort` |
| Responses are written into pooled buffers and sent only after the batch ends | `out.c`; `uring.c: deliver`, `conn_send` |
| A connection that sent a write is held until its batch commits (keeps order) | `uring.c: conn_hold`, `release_holds` |
| After a light round (< 64 jobs) the loop sleeps 250 us so the next round batches | `uring.c: transport_run` |

## Web application

`./build.sh web` builds the citizen app (served at `/`) and the responder dashboard (served at
`/command/`); `tools/embed-assets.mjs` writes each file as complete responses: brotli, gzip (each only if smaller), plain, and "304 Not Modified". `runtime/assets.c`
sends them from read-only memory, without copies or file access, for a `GET` that matches no API
route. A path ending in `/` means that directory's `index.html`; otherwise paths match exactly. Files under `assets/` carry a hash in their name and are cached for
good; the others are revalidated by entity tag. Responses set a same-origin content security
policy. A plain `./build.sh` embeds nothing.

Both apps share one client library (`frontend/shared`): the protocol generated from the
specification, an outbox in IndexedDB, cursor synchronisation, and for responders the incident
list built from the event stream and the permitted transitions.

The Observatory (`/observatory/`) polls `GET /v1/metrics` with an admin token held in memory,
derives rates from successive readings, and shows recorded benchmarks and the proved theorems
separately from the live figures.

| | Citizen | Command |
|---|---|---|
| Identity | a session the server issues when first needed | a token from `mina-admin`; signing out erases the device's data |
| Offline | opens and records reports without a network (service worker) | keeps working while the page is open; actions wait. No service worker yet, so it cannot be reopened offline |
| Long lists | 50 reports, 20 alerts | rows off screen are not laid out (`content-visibility`) |

## Measurements the server keeps

`runtime/stats.c` holds counters and two histograms (four buckets per power of two), updated by
plain increments on the request thread; the checkpoint thread writes its three atomically.
`runtime/metrics.c` formats them with process CPU and memory and the network namespace's TCP
figures, and the application adds its own (how syncs were answered, refusals, retries).
`GET /v1/metrics` is for admins. "Batch time" is time spent serving a batch inside the server;
no network time is included, and per-request latency is not measured by the server.

## Bounds

| Bound | Value | When reached |
|---|---|---|
| Request head, body | 16 KiB each | 431, 413 |
| Requests of one connection per batch | 8 | the rest wait for the next batch |
| Answers waiting on one connection | 256 KiB before parsing pauses | resumes as sends complete |
| Buffered input of a paused connection | 64 KiB | disconnected |
| Answers waiting on all connections | 256 MiB | paused connections are disconnected |
| Idle or stalled connection | `MINA_IDLE_S`, 120 s | disconnected; a trickling request does not count as activity |
| New citizen sessions | 100/s, burst 200, whole server | 429 |
| Submissions of one citizen | 1/s, burst 30 | 429 |
| Request data held for a batch | 4 MiB | 503 |

A single answer can exceed the pause mark: 256 events of 280 four-byte characters are about
320 KB, so with 8 requests per batch one connection can hold about 3 MB in the worst case.

Persistence: WAL, `synchronous=NORMAL`, 1 GiB mmap. Automatic checkpoints are replaced by a
second thread with its own connection (`db.c: wal_hook`, `ckpt_main`); the request thread
checkpoints itself only if the log passes 16,384 frames.

A write is answered only after its batch has committed. With `synchronous=NORMAL` a committed
write survives a process crash but may be lost on power failure; the choice against `FULL` is to
be measured. Neither case has been tested yet (Milestone F).

## Native read plans

`GET /v1/sync` does not run SQL. It seeks the `events_region_vis` index just past the client's
cursor, walks it (two cursors merged by sequence number for responders) and fetches each row by
rowid through SQLite's own B-tree layer, so the pager, WAL and locking are unchanged. If the
cursor has reached the remembered newest sequence number of every stream it reads, the answer is
written without touching a B-tree. [PROOFS.md](PROOFS.md) states what is proved about this, what
is assumed and when the server falls back to SQL.

## Application independence

`runtime/` knows nothing about the application except two functions the generated code must
provide, `app_decode` and `app_batch` (plus `app_init`, called by `server.c`), and the
`job_t` fields the transport reads: `kind`, `is_write`, `close_after`, `conn`, `gen`, `resp`.
`data` belongs to the application. `server.c` and `mina-admin` also read the minimum key length
and the role codes from `domain.h`.

## Known limitations of the engine

| Limitation | Effect | Planned |
|---|---|---|
| Lost eventfd wakeups on some kernels | Worked around with a 1 ms bounded idle wait; costs idle CPU (measured in BASELINE.md) | E: evaluate a single ring that blocks in `io_uring_enter` |
| Ring memory counts against `RLIMIT_MEMLOCK` | With the 8 MB default, an immediate restart can fail with `io_uring_setup: Cannot allocate memory` | B/F: raise the limit in the service unit; retry on start |
| No TLS | Tokens and reports cross the network in the clear unless a proxy terminates TLS; without HTTPS, browsers away from `localhost` also refuse the service worker, so the app does not work offline | F |
| The session limit is server-wide | One abusive client can stop new citizens from getting a session | F: limit by source address, here or at the proxy |
| The citizen limit is per identity | An abuser can rotate identities, at up to the session rate | F |
| No token revocation | A leaked token works until it expires; replacing `MINA_SECRET` revokes all of them | later |
| Citizens may report in any region | Region scoping protects reading, not submitting | by design; revisit with real data |
| Anyone with a token can read any public stream | Alerts and redacted updates are public | by design |
| Chunked request bodies are rejected | Clients must send `Content-Length` | documented |
| Custom HTTP and JSON parsers are not fuzzed | Unknown defects | F |
| One writer process, one server | No redundancy, no backups yet | documented; backups in F |
