# rove

`rove` is a Zig systems library for building distributed serverless
worker infrastructure: content-addressed code deployment, a
QuickJS-based JS runtime (`arenajs`), an HTTP/2 server, a
distributed KV store with Raft consensus, and a deterministic
replay capture pipeline. All C dependencies are vendored — `zig
build` works from a fresh clone with no network access.

The product face of `rove` is **Loop46**, a "purely functional
serverless" platform: handler code is a pure function of `(request,
kv)`, every external effect is a declarative command resolved
asynchronously, every captured request can be replayed
deterministically with breakpoints. See [`docs/PLAN.md`](docs/PLAN.md)
for the locked architecture decisions and the phased build plan;
[`docs/dashboard-design-brief.md`](docs/dashboard-design-brief.md)
for the dashboard / replay-shell design context.

## Build

Requires Zig 0.15+ and system libraries: nghttp2, OpenSSL (ssl +
crypto), SQLite3, LMDB, libcurl, zlib.

```bash
zig build              # build all modules + examples
zig build test         # run all inline Zig tests
zig build loop46       # build the Loop46 product binary
                       #   subcommands: `loop46 worker` (production)
                       #               `loop46 seed` (offline tenant provisioning)
                       #               `loop46 snapshot` / `restore-from-snapshot`
                       #               `loop46 promote-learner` (recovery)
                       #               `loop46 kv-get` (offline inspection)
zig build install -Doptimize=ReleaseFast   # production binaries under zig-out/bin/
```

## Smoke tests

```bash
# Each smoke spawns its own 3-node cluster + standalones and tears
# them down via signal handlers / atexit on exit.
python3 scripts/replay_wasm_smoke.py    # WASM replay path end-to-end
python3 scripts/files_server_smoke.py   # compile / upload / deploy / fetch
python3 scripts/ctl_smoke.py            # /_system/* control surface
python3 scripts/penalty_smoke.py        # CPU-budget penalty box
python3 scripts/leader_failover_smoke.py
```

`scripts/smoke_lib.py` is the shared harness. New smokes pattern off
the existing ones — `cookie_auth_smoke.py` and `replay_wasm_smoke.py`
are the canonical shapes.

## Dev cluster (browse the dashboard)

```bash
# Spin up a 3-node cluster + files-server + log-server with the demo
# tenants seeded, drive a few requests, print URLs + a magic-link
# login.
python3 scripts/replay_wasm_dev.py

# Public mode — bind to 0.0.0.0, generate a self-signed *.loop46.com
# cert on first run, browse from anywhere DNS resolves the suffix.
python3 scripts/replay_wasm_dev.py --public-suffix loop46.com --bind 0.0.0.0
```

The script blocks on SIGINT; Ctrl-C tears everything down. Admin /
replay UI source lives on disk under `web/{admin,replay}/` and is
read at every files-server boot, so dashboard / replay-shell edits
ship without a `zig build` — restart the dev script and refresh.

## Repo layout

```
src/
  rove/         core ECS (Entity / Row / Collection / Registry)
  io/           io_uring wrapper (TCP accept, recv buffer ring, TLS)
  h2/           HTTP/2 server on top of rove-io
  kv/           KvStore + Cluster (raft + LMDB) — leaf module
  blob/         pluggable blob storage (fs + s3 backends)
  files/        content-addressed module store + deploy index
  files_server/ files-server HTTP surface (compile / upload / deploy)
  log/          per-tenant request log records + NodeLogBuffer
  log_server/   log-server HTTP surface (list / show / batch-push)
  tape/         deterministic replay tape encoder
  tenant/       account / domain metadata (Tenant + Instance)
  qjs/          arenajs wrapper (one frozen base arena + per-request reset)
  js/           worker dispatcher (request → handler → response loop)
  loop46/       main.zig + seed + snapshot + the loop46 CLI
vendor/
  arenajs       quickjs-ng fork with dual-arena reset + replay bindings
  raft          willemt/raft consensus library
  kvexp         embedded multi-tenant LMDB-backed KV
web/
  admin/        dashboard SPA (served by __admin__ tenant)
  replay/       replay shell (WASM scrubber)
scripts/        Python smokes + dev cluster bringup
docs/           PLAN.md (canonical), sub-plans, design briefs
examples/       loop46-demo-tenants/ + bench drivers + standalones
```

## Documentation pointers

- [`docs/PLAN.md`](docs/PLAN.md) — canonical architecture + phased
  build plan. **Read before making decisions that could contradict
  existing direction.** §7 lists explicitly-rejected alternatives;
  §13 is the live process / surface map.
- [`docs/dashboard-design-brief.md`](docs/dashboard-design-brief.md)
  — page inventory + visual brief for iterating on the dashboard
  and replay shell.
- [`docs/replay-wasm-plan.md`](docs/replay-wasm-plan.md) —
  arenajs-WASM replay path (timeline, stack walker, stepping).
- [`docs/files-server-plan.md`](docs/files-server-plan.md),
  [`docs/logs-plan.md`](docs/logs-plan.md),
  [`docs/snapshot-plan.md`](docs/snapshot-plan.md),
  [`docs/http-send-plan.md`](docs/http-send-plan.md),
  [`docs/observability-plan.md`](docs/observability-plan.md) — sub-plans
  for individual subsystems.
- [`CLAUDE.md`](CLAUDE.md) — agent instructions including build
  commands, smoke conventions, and architectural conventions.
- [`vendor/README.md`](vendor/README.md) — vendored C dependencies,
  upstream revisions, patch notes.
