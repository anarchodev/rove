# Self-hosting rove (V2)

This is the operator-neutral guide to running the V2 stack on your own hosts:
build the binaries, write the env, install the systemd units, bring a cluster
up. It carries the **example systemd units** as the public reference (the live
units for our own deploy live in a separate private repo).

For the architecture behind it, see
[`architecture/overview.md`](../architecture/overview.md),
[`architecture/deployment-and-logs.md`](../architecture/deployment-and-logs.md),
and [`architecture/configuration-and-network.md`](../architecture/configuration-and-network.md)
for the per-binary env/port config map, the firewall boundary, and the two-tier
TLS architecture. Our own production deploy (host spec, vRack, genesis, rollout
history) lives in the private operator repo (`rewind-infra`) — a worked example,
not a requirement.

## The four processes

The stack is four user-scoped processes, **co-located on every node**:

| Binary | Listens | Role |
|---|---|---|
| `rewind-cp` | `:9090` HTTP + raft `:9101` | directory raft (tenant→cluster), `/_control`, `/_cp` |
| `rewind-worker` | `:8443` h2c + raft `:8501` | data plane: per-tenant multi-raft + JS dispatch |
| `rewind-front` | `:443` + `:80` | stateless public TLS edge (Host→worker proxy) |
| `rewind-logs` | `127.0.0.1:8444` h2c + metrics `:9113` | request-log / tape indexer + query API |

`rewind-cp` / `rewind-worker` hold raft state and must reach their peers on the
private network — firewall `:8501` and `:9101` to the cluster nodes only; there
is no app-layer auth on them. `rewind-front` is the only process with a public
surface. `rewind-logs` is loopback-only — the local worker reaches it for the
`__admin__` log-query door and the batch-push fast-path.

Minimum HA cluster is **3 nodes** (each raft group tolerates one down). A single
node works for dev.

## Prerequisites

- **Zig 0.15.0+** and a **Rust toolchain** (pinned by `rust-toolchain.toml`) —
  the consensus-linked binaries build raft-rs-zig's FFI via cargo. The first
  build needs network (deps are fetched, not vendored).
- **System libraries:** nghttp2, OpenSSL (ssl + crypto), libcurl, liblmdb,
  zlib; **SQLite3** additionally for `rewind-logs`.
- **S3-compatible object storage** (AWS / MinIO / R2 / B2 / OVH …). Storage is
  mandatory even single-node — every node reads the same content-addressed
  store. There is no filesystem backend.

## Build

```bash
zig build rewind-worker rewind-cp rewind-front rewind-logs -Doptimize=ReleaseFast
install -D -m0755 zig-out/bin/rewind-worker ~/.local/bin/rewind-worker
install -D -m0755 zig-out/bin/rewind-cp     ~/.local/bin/rewind-cp
install -D -m0755 zig-out/bin/rewind-front  ~/.local/bin/rewind-front
install -D -m0755 zig-out/bin/rewind-logs   ~/.local/bin/rewind-logs
```

`scripts/ops/build.sh` wraps this — it builds all four shipped binaries (+
`rewind-ops`) at `ReleaseFast` and runs the test gate. The ship + restart
orchestration (rolling / genesis across a host list) is operator-specific and
lives outside this public repo; the bring-up steps below are the manual
equivalent.

## Configure

Two env files per node, installed to `~/.config/rove/` (chmod `0600` — they hold
secrets), loaded by the units via `EnvironmentFile=`:

- **`common.env`** — deploy-wide, identical on every node. Copy
  [`scripts/systemd/v2/common.env.example`](../../scripts/systemd/v2/common.env.example)
  and fill it in. Every variable is documented there; the load-bearing ones:
  - **S3:** `S3_ENDPOINT` / `S3_REGION` / `S3_BUCKET` / `S3_KEY_PREFIX_BASE` /
    `S3_USE_TLS` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (binaries
    hard-error if unset).
  - **Secrets:** `REWIND_MOVE_SECRET` (gates `/_control` + `/_system/v2-*`) and
    `REWIND_ROOT_TOKEN` (the worker **refuses to boot** on the default/empty
    value). Use strong unique randoms. Also `LOOP46_SERVICES_JWT_SECRET` (the
    HMAC the worker mints log-server tokens with; the log-server verifies the
    same).
  - **Cluster topology:** `REWIND_VOTERS` / `REWIND_PEERS` (worker raft) and
    `REWIND_CP_VOTERS` / `REWIND_CP_PEERS` (directory raft) — the full static
    voter set, so each group is born knowing its members and elects on its own.
  - **Log indexer:** `REWIND_LOG_INTERNAL_BASE=http://127.0.0.1:8444` (the
    worker's view of the LOCAL log-server — this one base drives both the
    `__admin__` query door and the batch-push fast-path), `LOG_S3_KEY_PREFIX`
    (a per-cluster prefix; node ids repeat across clusters, so a shared bucket
    needs a unique value here to keep `_logs/{node}/` from colliding), and
    `REWIND_LOGS_METRICS_PORT` (default 9113).
- **`node.env`** — per-node, just the node identity. Copy
  [`scripts/systemd/v2/node.env.example`](../../scripts/systemd/v2/node.env.example).

> **systemd env files are plain `KEY=VALUE`** — no `%h` or shell expansion. Use
> absolute values. Anything that needs `%h` (data dirs, TLS paths) is set with
> `Environment=` inside the unit, where specifiers DO expand.

## systemd units (example reference)

Install each to `~/.config/systemd/user/`, then
`systemctl --user daemon-reload`. These are operator-neutral `%h`-specifier
templates — no secrets, no host specifics.

### `rewind-cp.service`

```ini
[Unit]
Description=rewind-cp (V2 control plane: directory raft + provisioning)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=%h/.config/rove/common.env
EnvironmentFile=%h/.config/rove/node.env
Environment=REWIND_CP_DATA_DIR=%h/.rove/data/cp
ExecStartPre=/usr/bin/install -d -m0700 %h/.rove/data/cp
ExecStart=%h/.local/bin/rewind-cp 9090
Restart=always
RestartSec=2
TimeoutStopSec=20
LimitNOFILE=524288
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.rove
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=default.target
```

### `rewind-worker.service`

```ini
[Unit]
Description=rewind worker (V2 data plane: multi-raft + per-tenant JS dispatch)
After=network-online.target rewind-cp.service
Wants=network-online.target rewind-cp.service

[Service]
Type=simple
EnvironmentFile=%h/.config/rove/common.env
EnvironmentFile=%h/.config/rove/node.env
ExecStartPre=/usr/bin/install -d -m0700 %h/.rove/data/worker
ExecStart=%h/.local/bin/rewind-worker %h/.rove/data/worker 8443
# Restart=always is load-bearing: a restarted node re-joins every tenant raft
# group it hosts and catches up from quorum.
Restart=always
RestartSec=2
TimeoutStopSec=30
# Per-worker io_uring rings + per-tenant LMDB maps blow past the 1024 default.
LimitNOFILE=524288
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.rove
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=default.target
```

### `rewind-front.service`

```ini
[Unit]
Description=rewind-front (V2 stateless public TLS edge)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=%h/.config/rove/common.env
# Drop your TLS cert/key at these paths (set here — common.env can't expand %h).
Environment=REWIND_TLS_CERT=%h/.rove/tls/platform.crt
Environment=REWIND_TLS_KEY=%h/.rove/tls/platform.key
ExecStart=%h/.local/bin/rewind-front 443
Restart=always
RestartSec=1
TimeoutStopSec=10
LimitNOFILE=524288
ProtectSystem=strict
ProtectHome=read-only
ReadOnlyPaths=%h/.rove
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=default.target
```

### `rewind-logs.service`

One per node, co-located with the worker. It reads the shared S3 batch store
(every node's `_logs/{node}/` prefix) and indexes into a **local** SQLite cache,
so each node's log-server is an independent **complete replica**. The local
worker reaches it on loopback `:8444`; the batch-push fast-path warms this
node's index immediately while the S3 poll fills in the other nodes. Stateless
(no raft) — the SQLite index is a rebuildable cache; restart or wipe it freely.

```ini
[Unit]
Description=rewind-logs (V2 request-log / tape indexer + query API, per-node)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Inherits S3 creds + LOOP46_SERVICES_JWT_SECRET + LOG_S3_KEY_PREFIX +
# REWIND_LOGS_METRICS_PORT from the same env the worker uses.
EnvironmentFile=%h/.config/rove/common.env
EnvironmentFile=%h/.config/rove/node.env
ExecStartPre=/usr/bin/install -d -m0700 %h/.rove/data/logs
ExecStart=%h/.local/bin/rewind-logs --data-dir %h/.rove/data/logs --listen 127.0.0.1:8444 --poll-interval-ms 5000
Restart=always
RestartSec=2
TimeoutStopSec=10
LimitNOFILE=524288
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.rove
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=default.target
```

## Bring up a cluster

A fresh multi-node cluster is a **cold-multi** start: every raft group is born
with the full static voter set and elects on its own, so the CPs must come up
together (a lone CP with `REWIND_CP_VOTERS=1,2,3` has no peers to elect with).

1. On every node: binaries in `~/.local/bin`, `common.env` + `node.env` in
   `~/.config/rove/`, the four units in `~/.config/systemd/user/`, your TLS
   cert/key at `~/.rove/tls/`, then `systemctl --user daemon-reload`.
2. **Start all CPs together** and wait for the directory group to elect a
   leader (~1–2s cross-host):
   `systemctl --user start rewind-cp.service` on each node.
3. **Start the workers** (cold-multi) + fronts on each node:
   `systemctl --user start rewind-worker.service rewind-front.service`.
4. **Start the log-servers:** `systemctl --user start rewind-logs.service`.
5. Provision your first tenant + deploy the admin/control app (see the
   control-plane + deployment docs; our genesis automates this via
   `rewind-ops genesis`).

The key invariants to preserve if you script this: **start the CPs together**
for a cold genesis (a lone cold-multi CP can't elect), **roll one node at a
time** for updates of a formed cluster (each raft group tolerates one down), and
**health-gate** each step (cp leader → worker `/_system/health` → front → logs)
before touching the next host. Our own operator repo's `deploy.sh` implements
exactly this on top of `scripts/ops/build.sh`.

A **single node** is the same minus the peers: set `REWIND_VOTERS=1` /
`REWIND_CP_VOTERS=1` (empty peer lists), start the four units in order.

## Observability

Each process exposes Prometheus metrics on a dedicated loopback HTTP/1.1 port
(the data ports are h2c-only and unscrapeable): worker `:9110`, cp `:9111`,
front `:9112`, **log-server `:9113`**. Point your scraper (Alloy, Prometheus,
…) at `127.0.0.1:{9110..9113}` per node. The log-server exposes `log_indexer_*`
(poll), `log_push_*` (batch-push fast-path — a non-zero `push_indexed` means
push is live), and `log_query_*` counters.
