# Reusing the Lean specification and generator

MINA's server is built from three layers. Two of them know nothing about disasters, so another
HTTP application with a SQLite database can be built on them.

```
spec/Mina/*.lean            what the application is: data and, later, theorems
        │  lake exe derive
        ▼
gen/app_gen.c, domain.h,    the application layer in C, the schema and the reference queries
schema.sql, queries.sql
        │  cc  (one translation unit)
        ▼
runtime/*.c                 io_uring, HTTP, JSON, tokens, buffers, SQLite
```

**What Lean does here today.** The specification is typed data, and a generator written in Lean
turns it into C. The same specification carries a model of the event table and theorems about
the read plans ([PROOFS.md](PROOFS.md)). Those theorems are about the model: nothing proves the
generated or runtime C correct. Test what you generate, as `tests/diff.sh` does by comparing
each native plan with SQL.

**Licence.** This code is under the AGPL-3.0 (see `LICENSE`). Software built from it, including
a network service, has to meet that licence's terms.

## Which files to keep, which to replace

| Path | Role | In a new application |
|---|---|---|
| `runtime/` | transport and libraries | keep; rename the `MINA_*` environment variables in `server.c` |
| `spec/Mina/Wire.lean` | statuses, errors, JSON shapes, routes | keep; add statuses as needed |
| `spec/Mina/Codegen/C.lean`, `Serialize.lean`, `Responses.lean`, `Routes.lean`, `Schema.lean` | the generator | keep |
| `spec/Mina/Codegen/Domain.lean` | C constants and tables from the domain | replace along with the domain |
| `spec/Mina/Domain.lean`, `Schema.lean`, `Query.lean`, `Contract.lean` | the application | replace |
| `spec/Mina/Model.lean`, `Plan.lean`, `Sync.lean`, `Transition.lean` | the model and theorems | replace; the proof pattern (reference query, plan, equality) carries over |
| `spec/Mina/Oracle.lean`, `OracleMain.lean` | an executable reference for tests | replace; keep the pattern of comparing every answer |
| `spec/Mina/Emit.lean` | which generated text fills which template slot | rewrite for your slots |
| `spec/Mina/templates/app.c` | handlers: the C that is not generated | rewrite; keep the batch skeleton |
| `tools/`, `tests/`, `bench/workload_*.h` | operator tool, tests, workload | replace |

## What the runtime expects from your code

Everything is compiled as one translation unit, `runtime/server.c`, so these are ordinary static
functions. Your generated file must define:

| Function | Called | Duty |
|---|---|---|
| `void app_init(void)` | once, after the database is open | check the layout, prepare statements |
| `void app_decode(const req_t *rq, job_t *j)` | for each complete request | set `j->resp` (answered), or set `j->kind` and `j->is_write` (queued) |
| `void app_batch(job_t *js, int n)` | after each round of requests | give every queued job a `j->resp`; the answers leave when it returns |

Rules that the transport relies on:

- The pointers in `req_t` (path, query, headers, body) point into a receive buffer and are valid
  only inside `app_decode`. Copy what a job needs into memory of your own and point `j->data` at
  it. MINA uses an arena that `app_batch` resets at its end.
- Set `j->is_write` for requests that change data. The connection is then held until the batch
  has run, which keeps a client's requests in order.
- A batch is one transaction. MINA runs reads first, then writes, then commits, and replaces
  every write's answer with an error if the commit fails.
- `app_batch` runs on the only request thread. Anything slow in it delays every connection.

`server.c` also needs `MIN_SECRET_BYTES` from your generated code, and `tools/` uses the names
in MINA's `domain.h`.

What you can call:

| Module | Functions |
|---|---|
| `out.c` | `obuf_static`; `out_begin`, `out_need`, `out_lit`, `out_i64`, `out_jstr`, `out_finish`, `out_abort` |
| `json.c` | `json_members` (validate a body and pick members), `json_unescape` |
| `http.c` | `query_param`; route matching is generated |
| `jwt.c` | `jwt_sign`, `jwt_verify` (HS256; claims `sub`, `role`, `rg`, `exp`) |
| `db.c` | `db_prepare`, `step_reset`, `db_batch_begin`, `db_batch_end`, `db_batch_abort`, `table_layout`, `index_layout`; B-tree cursors (`cursor_new`, `cur_seek`, `cur_next`, `rec_cols`, `col_int`, ...) |
| `uring.c` | `now_s`, the wall clock in seconds |

## How the generator works

`Mina.Emit.appGen` takes `templates/app.c` and replaces each `@{NAME}` with text computed in
Lean. The pairs are listed in `Emit.lean`.

| You write in Lean | You get in C |
|---|---|
| `ErrorCase` list | a complete constant response per error, sent with `ERR(NAME)` |
| `Status` list | header prefixes, `HDR_200`, ... |
| `Shape` | serializer statements, with constant bytes merged and buffer room computed |
| `Route` list | `app_decode`: method and path matching, then your decoder |
| `Endpoint` list | the `enum` of job kinds |
| `Table`, `Index` | `schema.sql` and a `schema_check()` that compares the real database with it |
| SQL strings | C literals, and `queries.sql` so tests can inspect the query plans |

A `Shape` names the C variables it reads. Where the slot is expanded, these must be in scope:

| Shape | C needed |
|---|---|
| `.int "x"` | `i64 x` |
| `.nint "x" "has_x"` | `i64 x`, and a condition `has_x`; writes `null` when false |
| `.str "s"` | `const u8 *s`, `u32 s_len` |
| `.nstr "s" "has_s"` | the same, and a condition |
| `.bool "b"` | a condition `b` |
| `.raw json` | nothing: constant text |
| `.embed "part"` | marks where your code writes; use `emitAround` for the text before and after |

Every serializer writes to an `out_t *o`.

## Worked example: add `GET /v1/uptime`

**1. State it** in `spec/Mina/Contract.lean`. Put this above `def health`:

```lean
def uptimeShape : Shape := .obj [("uptime_s", .int "uptime")]
def uptime : Endpoint := { kind := "K_UPTIME" }
```

add `uptime` to the `endpoints` list, and add this line to `routes`:

```lean
  ⟨.get, [.lit "v1", .lit "uptime"], uptime, none⟩,
```

**2. Give it a slot** in the list in `spec/Mina/Emit.lean`:

```lean
    ("UPTIME_BODY", emitWhole uptimeShape),
```

**3. Handle it** in `spec/Mina/templates/app.c`, inside the `switch` of `exec_read`:

```c
  case K_UPTIME: {
    i64 uptime = now_s - started_at;
    @{UPTIME_BODY}
    j->resp = out_finish(o, @{HDR_OK}, sizeof @{HDR_OK} - 1);
    return;
  }
```

**4. Generate, build, call it:**

```bash
(cd spec && lake build && lake exe derive ../gen)
./build.sh
curl http://127.0.0.1:8080/v1/uptime          # {"uptime_s":3}, with the server running
```

A route that needs input names a decoder, for example `some "decode_sync"`: a function in the
template, `int f(const req_t *rq, job_t *j)`, which authenticates, validates and fills
`j->data`. It returns 0 when it has already answered. A path with `.id` passes the segment as two
more arguments.

## Other changes

**A table or column.** Edit `Schema.lean`. The generator updates `schema.sql` and the startup
check; the server then refuses a database with the old layout. Migrating existing data is yours.

**A query.** Add it to `Query.lean` and to `Query.all`, give it a slot, prepare it in
`app_init`. Check its plan in a test, as `tests/contract.sh` does.

**An event kind.** Add a constructor to `Domain.Kind` and to `Kind.all`, then fill in its cases.
Lean refuses to build while `code`, `name`, `roles`, `restricted`, `required` or `optional` lack
one. `statusRange`, `fixedStatus` and the `transitions` list have defaults, so check those by
hand. The C validation and transition tables follow from these definitions.

**A rate limit.** `Contract.Bucket` values become constants in the template.

## Keeping the specification and the code together

- `gen/` is checked in. `./build.sh` regenerates into `build/` and stops if the two differ. Never
  edit `gen/` by hand.
- A file embedded with `include_str` must be declared in `spec/lakefile.toml` (`[[input_file]]`
  and `needs`). Otherwise Lake does not notice changes to it, and the comparison above passes on
  stale output.
- Run the suites against the sanitizer build as well: `./build.sh sanitize`.
- When you add theorems, they cover the Lean model only. Keep a differential test between the C
  and a reference, such as plain SQL.
