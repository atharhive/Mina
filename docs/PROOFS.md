# What is proved, and what is assumed

`./build.sh` makes the Lean kernel check every theorem. `tests/proofs.sh` also confirms that
the theorems below exist, that the specification contains no `sorry`, `axiom` or
`native_decide`, and that each theorem depends on no axiom beyond `propext`,
`Classical.choice` and `Quot.sound`.

**These are theorems about a model written in Lean.** They do not prove that the generated C,
the runtime or SQLite are correct.

## Read plans (`Mina/Plan.lean`)

| Theorem | Statement |
|---|---|
| `syncPlan_eq` | seeking to `(region, vis, after + 1)` in the index, walking while the prefix matches and fetching the first `n` rows gives exactly the reference query |
| `syncAllPlan_eq` | merging the two visibility streams by sequence number and keeping `n` gives exactly the responder's reference query |

## Skipping reads, retries and cursors (`Mina/Sync.lean`)

| Theorem | Statement |
|---|---|
| `head_empty`, `head_empty_all` | a cursor at or past a stream's newest sequence number has an empty answer |
| `head_preserved` | updating the remembered newest number at each insert keeps it exact |
| `inv_empty`, `inv_submit` | the storage invariant holds initially and after every submission |
| `apply_idem` | submitting an event id twice is submitting it once, whatever the retry carries |
| `cursor_mono` | a returned cursor is never behind the one sent |
| `pages_compose` | a page of `n` followed by a page of `m` equals one page of `n + m` |
| `no_skip` | every event of the stream up to the returned cursor is in the page, also if more events were appended meanwhile |

## Incident life cycle (`Mina/Transition.lean`)

| Theorem | Statement |
|---|---|
| `resolved_is_final` | no transition leaves `resolved`, and none keeps a status unchanged |
| `updates_are_public` | updates about incidents are public and cannot carry text or location |
| `citizens_cannot_update` | no citizen may submit a transition |
| `target_determined` | the new status comes from the kind, or from a `status` field whose accepted range contains it |
| `status_codes_valid` | every transition ends in a known status other than `open` |

## Assumptions

1. **The model mirrors storage.** `Db.events` is the `events` table in rowid order. Only the
   columns that decide which rows a read returns are modelled.
2. **Queries.** `syncRef` and `syncAllRef` say what the SQL in `gen/queries.sql` returns. The
   correspondence is by reading and by test, not by proof.
3. **B-trees.** SQLite's index B-tree yields `events_region_vis` entries in the order
   `(region, vis, rowid)`, and a seek by rowid returns the row stored under it.
4. **One writer.** Only this server writes the database. A commit by another connection must
   turn off every plan and remembered value derived here.
5. **Visibility in order.** Sequence numbers are assigned inside the writing transaction and
   rows are never updated or deleted, so events become visible in sequence order. `no_skip`
   depends on this. Restoring a backup would break it by reusing numbers; `tools/restore.sh`
   jumps ahead of them, which keeps the store ordered with a gap. Resending after a restore is
   ordinary submission of the same event ids (`apply_idem` covers those the backup holds).
6. **Generation.** The C transition and validation tables are printed from `Mina.Domain` by a
   generator that is not itself proved.

## Where the server uses them

| Proof | C in `spec/Mina/templates/app.c` | Check on the C |
|---|---|---|
| `syncPlan_eq`, `syncAllPlan_eq` | `sync_native`, `stream_entry` | `tests/diff.sh` against SQL |
| `head_empty`, `head_empty_all` | the `quiet` test in `exec_sync_native` | the same |
| `head_preserved` | `native_init`, `advance_heads` | the same, with writes interleaved |

The server answers with SQL instead when `MINA_FORCE_SQL` is set, for good once another
connection has written (assumption 4), and if a plan meets a row whose type or order is not what
it was derived for. Incident reads and the duplicate lookup still use SQL.
