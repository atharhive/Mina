# MINA

Infrastructure for when infrastructure fails.

MINA is an offline-first disaster communication system in development: one native C server on
Linux io_uring and SQLite, with its application layer specified in Lean 4 and generated into C.

**Status: Milestone D in progress.** The server API works end to end, and synchronisation runs on native
B-tree plans that are proved in Lean to equal the reference SQL, with differential tests of the
C against that SQL ([what is and is not proved](docs/PROOFS.md)). On one development machine
over loopback, 100,000 virtual users were served on 28 % of one CPU
([measurements and their limits](docs/BASELINE.md)); nothing larger has been run. No frontend or
TLS exists yet. The server serves the citizen web app itself; its offline features need HTTPS
anywhere but on `localhost`. See [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md); blocked work is listed in
[docs/PENDING.md](docs/PENDING.md).

MINA is not a replacement for official emergency services.

## Requirements

- Linux with io_uring (6.1 or newer), x86-64
- A C compiler, `curl`, `unzip`, `sha256sum`
- Lean 4.35.0 through [elan](https://github.com/leanprover/elan); the version is pinned in
  `spec/lean-toolchain`
- For the tests: `sqlite3`, `jq`, `openssl`

## Build and test

```bash
./build.sh              # check the specification, generate C, compile the server and tool
tests/unit.sh           # runtime modules, under ASan and UBSan
tests/contract.sh       # exact responses, roles, transitions, sync, limits, framing
tests/seed.sh           # the synthetic data generator
tests/proofs.sh         # the theorems and the axioms they use
tests/diff.sh           # native read plans against the reference SQL
tests/plans.sh          # no statement scans or sorts
tests/assets.sh         # serving a web application from memory
bench/micro.sh          # their cost, in process

./build.sh sanitize     # bin/mina-server-san, bin/mina-admin-san
MINA_BUILD=sanitize tests/assets.sh
MINA_ADMIN=$PWD/bin/mina-admin-san tests/contract.sh bin/mina-server-san
```

## Run

```bash
sqlite3 mina.db < gen/schema.sql
bin/mina-admin seed --events 10000 --regions 16 | sqlite3 mina.db     # optional synthetic data
export MINA_SECRET="$(openssl rand -hex 32)"
MINA_DB=mina.db bin/mina-server &

TOKEN="$(curl -s -X POST http://127.0.0.1:8080/v1/session | jq -r .token)"
curl -H "Authorization: Bearer $TOKEN" 'http://127.0.0.1:8080/v1/sync?region=1&limit=5'
bin/mina-admin token --sub 1 --role responder --regions 1,2          # responder token
```

| Variable | Default | |
|---|---|---|
| `MINA_DB` | required | a database with the schema applied |
| `MINA_SECRET` | required | token key, at least 32 bytes |
| `MINA_HOST` | `127.0.0.1` | there is no TLS: keep it on loopback or behind a TLS proxy |
| `MINA_PORT` | `8080` | |
| `MINA_IDLE_S` | `120` | seconds a connection may go without a request or progress |
| `MINA_FORCE_SQL` | unset | answer reads with the reference SQL instead of the native plans |

After changing `spec/`, regenerate the checked-in copies with
`(cd spec && lake exe derive ../gen)`.

## API

All bodies are JSON. Every route except health and session needs `Authorization: Bearer`.

| Route | Answer |
|---|---|
| `GET /v1/health` | `{"status","db","uptime_s"}` |
| `POST /v1/session` | 201 `{"token","sub","exp"}`: a new citizen identity |
| `POST /v1/events` | 201 `{"seq","incident"}`; a retry: 200 with the same and `"duplicate":true` |
| `GET /v1/sync?region=R&after=C&limit=N` | `{"head","events","next","more"}`; `N` up to 256; 409 `resync` if `C > head` |
| `GET /v1/incidents/:id` | responders: summary and report; the reporter: summary |

A submission is `{"eid": 32 lowercase hex digits chosen by the client, "kind": k, ...}`:

| `kind` | Meaning | Who | Required | Optional |
|---|---|---|---|---|
| 1 | emergency report | anyone | `region`, `category` 1..5 | `body`, `lat`+`lon`, `at` |
| 2 | acknowledged | responder | `incident` | `at` |
| 3 | status update | responder | `incident`, `status` 2 or 3 | `at` |
| 4 | resolved | responder | `incident` | `at` |
| 5 | safety status | anyone | `region`, `status` 1 safe, 2 needs help | `body`, `lat`+`lon`, `at` |
| 6 | regional alert | responder | `region`, `body` | `at` |

Categories: 1 medical, 2 rescue, 3 evacuation, 4 food, 5 water. Incident status: 1 open,
2 acknowledged, 3 in progress, 4 resolved. `body` is at most 280 characters; `lat` and `lon` are
degrees times 100,000; `at` is the device's creation time in Unix seconds.

A synchronised event is the array
`[seq, kind, ts, incident, category, status, body, lat, lon, at]`. Citizens receive kinds 2, 3,
4 and 6, which never carry a report's text or location. Responders of the region also receive
reports and safety statuses.

## Build your own server on it

[docs/REUSING.md](docs/REUSING.md) explains how the Lean specification, the C generator and the
runtime fit together, with a worked example of adding a route.

## Web app

Needs Node 22 and pnpm; the end-to-end test also needs Google Chrome.

```bash
cd frontend && pnpm install
pnpm test                      # outbox and sync, including a run against the built server
pnpm --dir citizen dev         # development server; proxies /v1 to 127.0.0.1:8080
cd .. && ./build.sh web        # compile the app into bin/mina-server
cd frontend && pnpm --dir citizen e2e    # report offline, reconnect, delivered, resolved
```

With the `web` build, open `http://127.0.0.1:8080`. Browsers allow service workers and location
only on `localhost` or over HTTPS, so on a phone the app needs a TLS proxy in front of the server.

## Layout

```
spec/      Lean specification and C generator
gen/       generated application layer, constants, schema and reference queries
runtime/   application-independent C: transport, HTTP, JSON, tokens, buffers, SQLite
tools/     mina-admin: offline tokens and synthetic data
tests/     unit, contract and seed tests, a kernel probe
bench/     load generator and single-machine benchmark runner
frontend/  shared sync engine and the citizen web app
docs/      architecture, proofs, guide to reusing the Lean pipeline, plan, measurements
```

## Benchmarks

```bash
bench/mina.sh 10000 20 90 20          # MINA workload on a fresh seeded database

cc -O2 -pthread -DWORKLOAD='"workload_health.h"' -Ibench -o bin/loadgen bench/loadgen.c
MINA_DB=mina.db MINA_SECRET="$(openssl rand -hex 32)" MINA_PORT=3000 \
  bench/run.sh bin/loadgen 10000 20 60 25 -- bin/mina-server
```

Needs unprivileged user namespaces, a systemd user session and `jq`. Loopback results from one
machine are not comparable with a two-machine measurement.
