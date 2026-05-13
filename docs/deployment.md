# Deployment runbook

Production Loop46 is four processes per host. This document covers
installation, env wiring, service order, and common operational checks.
For the architecture rationale, see [`PLAN.md`](PLAN.md) §13 (live
process / surface map).

## The four binaries

| Binary | Listens on | Responsibility |
|---|---|---|
| `loop46 worker` | `:443` (h2 + TLS) | Client traffic, JS dispatch, raft consensus |
| `files-server-standalone` | `:8444` (h2 + TLS) | Per-tenant manifests + bytecode |
| `log-server-standalone` | `:8445` (h2 + TLS) | Per-tenant request log query |
| `sse-server-standalone` | `:8446` (h2 + TLS) | SSE fan-out from worker emits |

The wildcard cert (`*.loop46.me`) covers all four — each one terminates
TLS in-process. They share `LOOP46_SERVICES_JWT_SECRET` for service-to-
service auth (worker mints JWTs at `/_system/services-token`; the three
standalones verify every request). The worker proposes raft entries
that the standalones consume; the standalones don't talk to each other.

## Prerequisites

1. **DNS A records** point at the host(s):
   - `loop46.me`
   - `*.loop46.me` (wildcard for customer tenants + `app.` + `files.` + `logs.` + `sse.`)

2. **TLS cert** — `scripts/rove-lego-renew.sh` issues a wildcard cert
   via ACME DNS-01. The systemd timer at `scripts/systemd/rove-cert-renew.timer`
   keeps it fresh. Cert lives at `~/.rove/tls/{cert,key}.pem`.

3. **S3** — endpoint + region + bucket + access keys. The bucket holds
   per-tenant blobs, log batches, and snapshots; one bucket per cluster.

4. **Privileged-port bind** — the worker binds `:443`. Either:
   - lower the kernel threshold once:
     `sudo sysctl -w net.ipv4.ip_unprivileged_port_start=443` (persist
     under `/etc/sysctl.d/99-rove.conf`), or
   - grant the cap per-binary:
     `sudo setcap cap_net_bind_service=+ep ~/.local/bin/loop46`
     (must re-apply after each `zig build install`)

5. **Edge proxy (required for public-internet deployments).** rove-h2
   is HTTP/2-only. TLS clients without h2 ALPN fail the handshake
   silently; plaintext HTTP/1.x clients get a 426 Upgrade Required.
   An L7 reverse proxy in front of the worker translates HTTP/1.x ↔
   h2 so old clients work, terminates client TLS, and adds the
   `X-Forwarded-*` headers the worker uses for client-IP and
   missing-proxy detection. Any of Cloudflare, AWS ALB, GCP Load
   Balancer, nginx, or HAProxy works.

   The worker logs a warning at startup-plus-N-requests if no
   `X-Forwarded-For` header is observed in the first 100 requests —
   that's the most common "operator forgot the proxy" shape. See
   [`http-send-plan.md`](http-send-plan.md) §3.1 for the
   underlying h2-only design rationale.

   **Minimum proxy configuration:**

   - Terminate client TLS at the proxy with a wildcard cert (or your
     own cert chain).
   - Speak h2 (or h2c, on the same private network) to the rove
     worker on port 443. Most managed proxies do this by default.
     For nginx: `proxy_pass https://worker:443; proxy_http_version 2;`.
   - Add `X-Forwarded-For`, `X-Forwarded-Proto`, and `X-Forwarded-Host`
     headers. Cloudflare and ALB do this automatically. For nginx:
     `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`
     plus the other two.
   - Forward to the worker pool (round-robin or sticky-by-IP both
     work — workers don't keep session state across the request
     boundary; raft replicates everything that matters).

   For development against `127.0.0.1` the proxy is unnecessary
   and the missing-XFF warning is informational only.

## Install

As the deploy user, **no root**:

```bash
# Build (Zig 0.15+; system libs nghttp2 + openssl + sqlite3 + libz).
zig build install -Doptimize=ReleaseFast

# Place binaries on PATH.
install -D -m 0755 zig-out/bin/loop46                    ~/.local/bin/loop46
install -D -m 0755 zig-out/bin/files-server-standalone   ~/.local/bin/files-server-standalone
install -D -m 0755 zig-out/bin/log-server-standalone     ~/.local/bin/log-server-standalone
install -D -m 0755 zig-out/bin/sse-server-standalone     ~/.local/bin/sse-server-standalone

# If using the per-binary capability path:
sudo setcap cap_net_bind_service=+ep ~/.local/bin/loop46

# Place the four service units.
mkdir -p ~/.config/systemd/user
install -m 0644 scripts/systemd/rove-files-server.service ~/.config/systemd/user/
install -m 0644 scripts/systemd/rove-log-server.service   ~/.config/systemd/user/
install -m 0644 scripts/systemd/rove-sse-server.service   ~/.config/systemd/user/
install -m 0644 scripts/systemd/rove-loop46.service       ~/.config/systemd/user/
```

## Env files

Five files under `~/.config/rove/`, all `chmod 0600`. The common file
is read by every service; the others are service-specific.

### `common.env` (shared by all four services)

```ini
# Shared HMAC for service-to-service JWTs. Generate once, never rotate
# without simultaneously restarting all four services.
#   head -c32 /dev/urandom | xxd -p | tr -d '\n'
LOOP46_SERVICES_JWT_SECRET=<64 hex chars>

# S3 — one bucket per cluster.
BLOB_BACKEND=s3
S3_ENDPOINT=s3.us-east-1.amazonaws.com
S3_REGION=us-east-1
S3_BUCKET=loop46-prod
S3_USE_TLS=true
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
# Optional; defaults to empty. Multi-cluster setups use unique prefixes
# to share a bucket safely.
S3_KEY_PREFIX_BASE=
```

### `files-server.env`

```ini
FILES_LISTEN=127.0.0.1:8444
DATA_DIR=/home/<user>/.rove/data
TLS_CERT=/home/<user>/.rove/tls/cert.pem
TLS_KEY=/home/<user>/.rove/tls/key.pem
ADMIN_ORIGIN=https://app.loop46.me
LEADER_URL=https://app.loop46.me
```

### `log-server.env`

```ini
LOG_LISTEN=127.0.0.1:8445
DATA_DIR=/home/<user>/.rove/data
TLS_CERT=/home/<user>/.rove/tls/cert.pem
TLS_KEY=/home/<user>/.rove/tls/key.pem
ADMIN_ORIGIN=https://app.loop46.me
LOG_S3_KEY_PREFIX=logs/
LOG_POLL_INTERVAL_MS=500
```

### `sse-server.env`

```ini
SSE_LISTEN=127.0.0.1:8446
TLS_CERT=/home/<user>/.rove/tls/cert.pem
TLS_KEY=/home/<user>/.rove/tls/key.pem
# Opaque bearer that the worker stamps on every emit POST. Must match
# the worker's SSE_INTERNAL_TOKEN in loop46.env.
SSE_INTERNAL_TOKEN=<32+ random chars>
```

### `loop46.env`

```ini
# Raft membership. Single-node: NODE_ID=0, PEERS=<this host>:40146.
# 3-node cluster: list all three hosts; each NODE_ID is its index.
NODE_ID=0
PEERS=10.0.1.10:40146,10.0.1.11:40146,10.0.1.12:40146
RAFT_LISTEN=10.0.1.10:40146

HTTP_LISTEN=0.0.0.0:443
DATA_DIR=/home/<user>/.rove/data
TLS_CERT=/home/<user>/.rove/tls/cert.pem
TLS_KEY=/home/<user>/.rove/tls/key.pem

PUBLIC_SUFFIX=loop46.me
ADMIN_API_DOMAIN=app.loop46.me
ADMIN_ORIGIN=https://app.loop46.me

# The worker tells the dashboard which standalone to hit for files,
# logs, and SSE. These are the public origins clients connect to —
# typically the public DNS name + port of each standalone.
FILES_PUBLIC_BASE=https://files.loop46.me:8444
LOG_PUBLIC_BASE=https://logs.loop46.me:8445
SSE_PUBLIC_BASE=https://sse.loop46.me:8446

WORKERS=0          # 0 → nCPU - 1
LOOP46_ROOT_TOKEN=<64 hex chars>   # bearer for /_system/* + login
SSE_INTERNAL_TOKEN=<same value as in sse-server.env>
```

systemd's `EnvironmentFile` does **not** expand `%h`. Write absolute
paths in env files. The `%h` you see in the unit files is a unit-file
specifier that systemd substitutes on the unit-file side only.

## Start order

```bash
# Reload the user manager once after dropping unit files.
systemctl --user daemon-reload

# Standalones first — the worker has After= on all three.
systemctl --user enable --now rove-files-server.service
systemctl --user enable --now rove-log-server.service
systemctl --user enable --now rove-sse-server.service

# Worker last.
systemctl --user enable --now rove-loop46.service

# Confirm.
systemctl --user list-units 'rove-*'
journalctl --user -u rove-loop46.service -f
```

If `systemctl --user` returns "Failed to connect to user scope bus" in
an SSH session, the user manager isn't started for that login. Enable
linger once so the user manager stays up across logins (required for
production where you'll log out):

```bash
sudo loginctl enable-linger $USER
```

## Multi-node cluster

Three nodes is the minimum for raft fault tolerance (one-failure
quorum). On each host:

- Set `NODE_ID` to that host's index into `PEERS` (0/1/2).
- Set `RAFT_LISTEN` to that host's address (must be reachable from the
  other peers — typically a private network address, not loopback).
- Keep `PEERS` identical on every host.
- Every host runs all four services. The standalones are not raft
  members; they're per-host helpers that read shared S3 state.

DNS for `app.` / `files.` / `logs.` / `sse.` should round-robin across
all three hosts, OR a load balancer should fan out (preferred — handles
node failure transparently).

A non-voting **learner** can replace one voter for disaster-recovery
shape (full state, no quorum vote). Add `--node-learner` to the
worker's args; see `production.md` §1.2 for the lost-quorum recovery
path via `loop46 promote-learner`.

## Health + observability

Every binary exposes an unauthenticated liveness endpoint that always
returns `200 ok\n` while the process is serving requests. Wire these
into your load balancer's health checks; they have no leadership or
cluster-membership semantics, just "this process is responsive."

| Binary | Endpoint |
|---|---|
| `loop46 worker` | `/_system/health` |
| `files-server-standalone` | `/v1/health` |
| `log-server-standalone` | `/v1/health` |
| `sse-server-standalone` | `/v1/health` |

```bash
curl -sk https://app.loop46.me/_system/health     # → 200 ok
curl -sk https://files.loop46.me:8444/v1/health   # → 200 ok
curl -sk https://logs.loop46.me:8445/v1/health    # → 200 ok
curl -sk https://sse.loop46.me:8446/v1/health     # → 200 ok
```

For leader-aware probes (e.g., to route writes), use
`/_system/leader` on the worker — 200 on the leader, 503 (with
`retry against the cluster leader`) on followers. Auth-gated:
requires admin bearer or services-JWT.

**Metrics.** The worker exposes Prometheus-text counters at
`/_system/metrics` (root-token gated). Today's surface includes the
io_uring buffer pool conservation pair, the h2 collection depths,
and `raft_is_leader`. Scrape from your Prometheus / Datadog agent.
The three standalones don't yet emit metrics — slot when alerting
needs surface for them.

**Recommended alerts:**
- `/v1/health` (or `/_system/health`) returns non-200 for ≥30s → page.
- All workers report `raft_is_leader=0` for ≥30s → page (cluster has
  no leader, writes blocked).
- io_uring buffer pool conservation pair drifts → investigate (the
  panic at 3 consecutive surfacings already fires; alert before that).

## Validation

```bash
# Quick acceptance check, no auth required:
curl -sk https://app.loop46.me/_system/health         # → 200 ok
curl -sk https://files.loop46.me:8444/v1/health       # → 200 ok
curl -sk https://logs.loop46.me:8445/v1/health        # → 200 ok
curl -sk https://sse.loop46.me:8446/v1/health         # → 200 ok

# Cluster has a leader:
for h in 10.0.1.10 10.0.1.11 10.0.1.12; do
    curl -sk https://$h:443/_system/leader -H "Host: app.loop46.me"
done
# Exactly one host should return 200, the others 503.

# All services running:
systemctl --user is-active rove-loop46 rove-files-server rove-log-server rove-sse-server
```

For deeper checks see the smoke scripts in `scripts/*_smoke.py` —
they bring up an isolated cluster from scratch and exercise the full
deploy → fetch → log → SSE round trip.

## Common operational tasks

**Cert rotation.** `rove-cert-renew.timer` runs daily and lego no-ops
unless within 30 days of expiry. All four binaries stat the cert path
on each TLS handshake; renewal is picked up without restart.

**Rolling restart.** Restart the standalones any time — they're
stateless wrt customer traffic. Restart the worker one node at a time
with `systemctl --user restart rove-loop46` so raft keeps quorum.

**Logs.** Everything goes to journald.
`journalctl --user -u rove-<unit> --since=-1h` for recent activity.

**Lost quorum.** If you lose ≥2 voters, see `production.md` §1.2 step
3. `loop46 promote-learner --data-dir ... --allow-single-peer` rebuilds
a 1-node cluster from a learner's data dir.

**Far-behind follower.** Handled automatically: if a node falls past
the leader's raft compaction floor, the leader sends a
`snap_fetch_offer`, the follower's fetcher thread downloads the
snapshot bundle, stages it under `{data_dir}/.snap-in-{snap_id}/`,
then exits cleanly. `Restart=always` on `rove-loop46.service`
restarts the worker; boot picks up the staged bundle via
`installStagedSnapshotIfPresent` and resumes raft at the leader's
floor. End-to-end smoke at `scripts/snap_catchup_smoke.py` (which
simulates the supervisor by re-spawning manually — production has
systemd do it).

**Backup.** See "Backup automation" below — `rove-snapshot.timer`
fires `loop46 snapshot` daily; leader-only via wrapper script.

## Backup automation

Daily snapshot capture is wired through a user-scoped systemd timer.
Each pass:

1. The timer fires `rove-snapshot.service` on every node.
2. The service runs `rove-snapshot-pass.sh`, which probes
   `https://127.0.0.1:$PORT/_system/leader`. Followers exit 0 in
   under a millisecond — only the leader proceeds.
3. The leader runs `loop46 snapshot --data-dir $DATA_DIR`. Each
   tenant's `app.db` plus `__root__.db` get `VACUUM INTO`-ed into a
   staging dir, sha256'd, uploaded to S3 under
   `cluster/snapshots/{snap_id}/`. A `manifest.json` ties the
   sha256s together.

**Install:**

```bash
install -D -m 0755 scripts/rove-snapshot-pass.sh \
    ~/.local/bin/rove-snapshot-pass.sh
install -D -m 0644 scripts/systemd/rove-snapshot.service \
    ~/.config/systemd/user/rove-snapshot.service
install -D -m 0644 scripts/systemd/rove-snapshot.timer \
    ~/.config/systemd/user/rove-snapshot.timer
systemctl --user daemon-reload
systemctl --user enable --now rove-snapshot.timer

# Force a first capture (also a good wiring smoke):
systemctl --user start rove-snapshot.service
journalctl --user -u rove-snapshot.service -n 30
# expect: "captured snapshot <14hex-12hex>"
```

Default cadence is daily at 02:00 with 1h jitter. For a tighter
recovery-point objective, edit `rove-snapshot.timer`:

```ini
OnCalendar=hourly                        # 24× the S3 PUT count
OnCalendar=*-*-* 02,14:00:00             # twice-daily
```

**Retention via S3 lifecycle.** rove doesn't prune snapshots itself.
Configure the bucket's lifecycle policy to expire old keys under
`cluster/snapshots/`:

```json
{
  "Rules": [{
    "ID": "loop46-snapshot-retention",
    "Status": "Enabled",
    "Filter": { "Prefix": "cluster/snapshots/" },
    "Expiration": { "Days": 30 }
  }]
}
```

Apply with:

```bash
aws s3api put-bucket-lifecycle-configuration \
    --bucket loop46-prod \
    --lifecycle-configuration file://lifecycle.json
```

This is a sledgehammer — "anything older than 30 days is dead". For
graded retention (keep 7 daily + 4 weekly + 12 monthly), you'd need
either a custom pruner CLI or to write a periodic job that
selectively deletes by snap_id. Out of scope here; flag if needed.

**Restoring from a snapshot.**

```bash
# 1. List available snapshots (manifests live at
#    s3://$S3_BUCKET/cluster/snapshots/{snap_id}/manifest.json):
aws s3 ls "s3://$S3_BUCKET/cluster/snapshots/" | tail -20

# 2. On a FRESH node (no prior tenant dbs in $DATA_DIR), install:
loop46 restore-from-snapshot \
    --snap-id <snap_id_from_step_1> \
    --data-dir $DATA_DIR

# 3. Start the worker normally. Raft picks up from snap_last_idx
#    recorded in the manifest. For a full-cluster restore (lost all
#    nodes), do this on one host and let it become a single-node
#    cluster via `--peers <self>:40146`, then add learners + promote
#    per the lost-quorum recovery path.
```

Manifests carry `apply_position=0` by default (the offline capture
CLI doesn't have access to the running raft node's commit idx).
Restored nodes therefore replay every committed raft entry post-
snapshot — correct but more work than a "live" snapshot would
require. Not a concern for disaster recovery; would be a concern
for "promote a follower from a recent snapshot" which isn't a flow
we expose today.
