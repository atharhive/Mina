# Architecture

State of the tree at the end of Milestone A: the inherited engine with a health-only MINA
contract. The planned application design is in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

## Build lifecycle

`./build.sh`:

1. Downloads the SQLite 3.54.1 amalgamation if absent and checks its SHA-256.
2. `lake build`: Lean elaborates `spec/` and the kernel checks every theorem in it.
   (At Milestone A the specification holds the contract and the generator; it states no
   theorems yet.)
3. `lake exe derive ../build`: `Mina.Emit.appGen` fills the `@{...}` slots of
   `spec/Mina/templates/app.c`.
4. Compares `build/app_gen.c` with the checked-in `gen/app_gen.c` and stops on any difference.
5. Compiles one translation unit, `runtime/server.c`, which includes `sqlite3.c`, the runtime
   and the generated code (`-O2 -march=native`, `SQLITE_THREADSAFE=2`).

## Request lifecycle

| Step | Where |
|---|---|
| One thread drives several io_uring rings; each has a `SO_REUSEPORT` listener, a table of direct descriptors and a provided-buffer ring (1024 x 2 KB) | `uring.c: transport_init`, `ring_init` |
| Multishot accept into a direct descriptor, then multishot receive | `uring.c: arm_accept`, `arm_recv`, `handle_cqe` |
| Bytes are framed as HTTP/1.1; partial requests are kept per connection | `uring.c: on_data`, `parse_requests`; `http.c: http_parse` |
| The generated router turns a request into a job, or answers with a constant response | `app_gen.c: app_decode` |
| All jobs of one round of completions form a batch served by one SQLite transaction | `app_gen.c: app_batch`; `db.c: db_batch_begin`, `db_batch_end` |
| Responses are written into pooled buffers and sent only after the batch ends | `out.c`; `uring.c: deliver`, `conn_send` |
| A connection that sent a write is held until its batch commits (keeps order) | `uring.c: conn_hold`, `release_holds` |
| After a light round (< 64 jobs) the loop sleeps 250 us so the next round batches | `uring.c: transport_run` |

Persistence: WAL, `synchronous=NORMAL`, 1 GiB mmap. Automatic checkpoints are replaced by a
second thread with its own connection (`db.c: wal_hook`, `ckpt_main`); the request thread
checkpoints itself only if the log passes 16,384 frames.

Available to generated code but unused by the health-only contract: B-tree cursors and record
decoding over SQLite's own pager (`db.c`), foreign-writer detection (`db_foreign_write`),
HS256 verification (`jwt.c`), the JSON scanner (`json.c`).

## Application independence

`runtime/` knows nothing about the application except two functions the generated code must
provide, `app_decode` and `app_batch` (plus `app_init`, called by `server.c`), and the
`job_t` fields the transport reads: `kind`, `is_write`, `close_after`, `conn`, `gen`, `resp`.

## Known limitations of the engine

| Limitation | Effect | Planned |
|---|---|---|
| Lost eventfd wakeups on some kernels | Worked around with a 1 ms bounded idle wait; costs idle CPU (measured in BASELINE.md) | E: evaluate a single ring that blocks in `io_uring_enter` |
| Ring memory counts against `RLIMIT_MEMLOCK` | With the 8 MB default, an immediate restart can fail with `io_uring_setup: Cannot allocate memory` | B/F: raise the limit in the service unit; retry on start |
| `/v1/health` is the only route; no TLS, rate limits or bounded queues | Not deployable | B, F |
| Idle connections are never closed | A client can hold slots indefinitely | B |
| Chunked request bodies are rejected | Clients must send `Content-Length` | documented |
| Custom HTTP and JSON parsers are not fuzzed | Unknown defects | F |
| One writer process, one server | No redundancy | documented; backups in F |
