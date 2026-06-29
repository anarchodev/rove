# rove

`rove` is a Zig systems library for building distributed serverless
worker infrastructure: content-addressed code deployment, a
QuickJS-based JS runtime (`arenajs`), an HTTP/2 server, and a
distributed KV store with per-tenant Raft consensus.

Third-party dependencies are **pinned and fetched at build time** —
Zig/C packages (`arenajs`, `kvexp`, the multi-raft engine
`raft-rs-zig`) via `build.zig.zon`; the raft engine's Rust crates via
Cargo. The first build needs network access; subsequent builds use the
Zig package cache. (This replaced the former vendor-everything mandate
once the raft-rs Rust closure proved too large to vendor — see
`docs/decisions.md` §10.11.)

The product face of `rove` is **rewind.js**, a "purely functional
serverless" platform: handler code is a pure function of `(request,
kv)`, every external effect is a declarative command resolved
asynchronously, and every captured request can be replayed
deterministically. Locked architecture and the phased build plan live
in [`docs/PLAN.md`](docs/PLAN.md); [`docs/README.md`](docs/README.md)
is the documentation map.

## Build

Requires **Zig 0.15+** and a **Rust toolchain** (pinned by
`rust-toolchain.toml`) for the consensus-linked steps — anything that
pulls in the per-tenant raft engine builds raft-rs-zig's Rust FFI via
cargo. The bare `zig build` install step does not.

System libraries: nghttp2, OpenSSL (ssl + crypto), libcurl, liblmdb
(via kvexp), zlib. SQLite3 is needed only for the `rewind-logs` binary.

```bash
zig build               # build all modules + examples
zig build test          # run all inline Zig tests
zig build rewind-worker # the worker (src/rewind/main.zig)
zig build rewind-cp     # control plane (directory + provisioning)
zig build rewind-front  # stateless Host→cluster front door
zig build rewind-logs   # log query surface
zig build rewind-ops    # operator CLI
zig build v2-test       # multi-raft substrate tests
zig build install -Doptimize=ReleaseFast   # production binaries under zig-out/bin/
```

## Smoke tests

Python scripts in `scripts/` drive end-to-end tests against running
binaries. Each spawns its own topology and tears it down via `atexit` /
signal handlers. V2 smokes need S3 credentials in the environment first
(`set -a; . ./.env; set +a`) — there is no filesystem blob backend.

```bash
python3 scripts/rewind_smoke.py        # single-node write path (propose → commit → 204)
python3 scripts/ctl_smoke_v2.py        # provision → deploy → serve through the front door
python3 scripts/three_node_smoke.py    # multi-node HA: move onto a 3-node cluster, kill the leader
python3 scripts/tenant_move_smoke.py   # live tenant move cluster-1 → cluster-2
```

`scripts/smoke_lib_v2.py` is the V2 harness — `V2Cluster.spawn` brings
up rewind-cp + front door + rewind node(s) and exposes `provision` /
`deploy_handlers` / `wait_for_handler`. `ctl_smoke_v2.py` is the
canonical shape for new smokes. (`scripts/v2_topology.py` holds the
per-binary spawn primitives.)

## Repo layout

```
src/
  rove/         core ECS (Entity / Row / Collection / Registry)
  io/           io_uring wrapper (TCP accept, recv buffer ring, TLS)
  h2/           HTTP/2 + HTTP/1.1 + WebSocket server on rove-io (nghttp2)
  kv/           raft-kv: kvexp KV facade + envelope codec (no consensus inside)
  consensus/    multi-raft (per-tenant raft-rs groups) behind the Bridge + cross-node transport
  cp/           control plane: tenant→cluster directory, provisioning, moves
  front/        stateless Host→cluster proxy (no raft state)
  blob/         S3 blob storage (libcurl, SigV4) — S3-only, no fs backend
  files/        content-addressed file store + deploy index
  log/          per-tenant request log records
  log_server/   log query HTTP surface
  bodies/       body-batch S3 buffer
  tape/         deterministic replay tape encoder
  tenant/       account / domain metadata (Tenant + Instance)
  qjs/          arenajs wrapper (one frozen base arena + per-request reset)
  acme/         ACME HTTP-01 client
  jwt/  ssrf/  plan/   leaf modules (HS256 / SSRF blocklist / tier table)
  js/           worker dispatcher (request → handler → response loop)
  rewind/       rewind-worker binary (rove-js on the Bridge)
  cli/          rewind-ops operator CLI + the rewind customer CLI
scripts/        Python V2 smokes + harness (smoke_lib_v2.py)
docs/           PLAN.md, decisions.md, architecture/ (as-built), in-flight plans
examples/       echo / h2 / ws standalones + bench drivers
```

There is no `vendor/` directory — all dependencies are fetched (see
**Build** above). The first-party web apps (admin dashboard, replay
shell, marketing) live in the private `rewind-apps` repo and are
published as ordinary tenant bundles.

## Documentation pointers

- [`docs/README.md`](docs/README.md) — **the documentation map.** Start here.
- [`docs/PLAN.md`](docs/PLAN.md) — product architecture + phased build
  plan (source of truth for direction). §7 lists explicitly-rejected
  alternatives; §13 is the live process / surface map.
- [`docs/decisions.md`](docs/decisions.md) — locked decisions +
  rejected alternatives (the *why*). Check here before re-litigating a
  settled call.
- [`docs/architecture/`](docs/architecture/) — as-built references, one
  doc per subsystem (`overview`, `consensus-and-storage`,
  `effects-and-handlers`, `routing-and-ingress`, `control-plane`,
  `deployment-and-logs`, `auth-and-domains`, `observability`).
- [`docs/effect-algebra.md`](docs/effect-algebra.md) and
  [`docs/handler-shape.md`](docs/handler-shape.md) — the customer-facing
  effect model + handler API surface.
- [`CLAUDE.md`](CLAUDE.md) — repo orientation, build/test commands, and
  conventions for working across git worktrees.
