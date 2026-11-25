# MINA

Infrastructure for when infrastructure fails.

MINA is an offline-first disaster communication system in development: one native C server on
Linux io_uring and SQLite, with its application layer specified in Lean 4 and generated into C.

**Status: Milestone A.** The engine and the Lean to C pipeline work; the only route is
`GET /v1/health`. No emergency features, theorems or frontend exist yet. See
[docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md).

MINA is not a replacement for official emergency services.

## Requirements

- Linux with io_uring (6.1 or newer), x86-64
- A C compiler, `curl`, `unzip`, `sha256sum`; `sqlite3` for the tests
- Lean 4.35.0 through [elan](https://github.com/leanprover/elan); the version is pinned in
  `spec/lean-toolchain`

## Build, test, run

```bash
./build.sh                 # check the specification, generate C, compile bin/mina-server
tests/contract.sh          # exact responses, framing and connection wakeups

sqlite3 mina.db < gen/schema.sql
MINA_DB=mina.db MINA_SECRET="$(openssl rand -hex 32)" bin/mina-server
curl http://127.0.0.1:8080/v1/health
```

| Variable | Default |
|---|---|
| `MINA_DB` | required |
| `MINA_SECRET` | required |
| `MINA_HOST` | `127.0.0.1` |
| `MINA_PORT` | `8080` |

After changing `spec/`, regenerate the checked-in copy with
`(cd spec && lake exe derive ../gen)`.

## Layout

```
spec/      Lean specification and C generator
gen/       generated application layer, checked in for reading
runtime/   application-independent C: transport, HTTP, JSON, tokens, buffers, SQLite
tests/     contract tests and a kernel probe
bench/     load generator and single-machine benchmark runner
docs/      architecture, reuse map, plan, measurements
```

## Benchmarks

```bash
cc -O2 -pthread -DWORKLOAD='"workload_health.h"' -Ibench -o bin/loadgen bench/loadgen.c
MINA_DB=mina.db MINA_SECRET="$(openssl rand -hex 32)" MINA_PORT=3000 \
  bench/run.sh bin/loadgen 10000 20 60 25 -- bin/mina-server
```

Needs unprivileged user namespaces, a systemd user session and `jq`. Loopback results from one
machine are not comparable with a two-machine measurement.
