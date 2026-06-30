# Configuration & network plane

> 🟢 **As-built reference.** The operator-neutral configuration surface of the
> V2 stack: how each binary is configured (positional args + env vars), which
> ports each one listens on, the public/private network boundary that the
> firewall must enforce, and the two-tier TLS architecture the edge terminates.
> This is engine reference — it holds for *any* operator self-hosting rove. The
> specifics of a particular deploy (host list, hardware spec, DNS records, which
> ACME provider, rollout history) live in that operator's own infra repo, not
> here. For the publish/blob/log runtime flow see
> [deployment-and-logs.md](deployment-and-logs.md); for routing/ingress see
> [routing-and-ingress.md](routing-and-ingress.md); for the control plane see
> [control-plane.md](control-plane.md).

## Process / port / config map

All three binaries are positional-arg + env-var configured. Tables verified
against `src/{cp,front,rewind}/main.zig` + `src/blob/env.zig`.

### `rewind-worker` (DP worker) — `rewind-worker <data_dir> <http_port>`

| Env | Meaning |
|---|---|
| `REWIND_NODE_ID` | this node's 1-based raft id (∈ voter set); enables multi-node |
| `REWIND_VOTERS` | comma-sep voter ids, e.g. `1,2,3` |
| `REWIND_PEERS` | comma-sep raft transport `host:port` (cross-node consensus, **distinct** from `<http_port>`); listen = `peers[node_id−1]` |
| `REWIND_CLUSTER_ID` | this DP cluster's id (matches a `REWIND_CLUSTERS` entry on the CP) |
| `REWIND_CP_URL` | CP origin(s) for route/plan/cert reads (`;`-join for HA) |
| `REWIND_MOVE_SECRET` | gates `/_system/v2-*` move + `/_system/v2-kv` |
| `REWIND_ADMIN_DOMAIN` | admin/`__root__` tenant host |
| `REWIND_ROOT_TOKEN` | admin bootstrap token |
| `REWIND_PUBLIC_SUFFIX` | customer tenant wildcard eTLD+1 (e.g. `rewindjs.app`) |
| `REWIND_INTERNAL_FRONT` | tenant door: comma-sep **bare IPs** of the fronts on the private plane (vRack/WireGuard); outbound fetches to `*.{public/system suffix}` hosts pin their connect here instead of resolving public DNS, so tenant→tenant calls never hairpin through the public edge ([effects-and-handlers.md](effects-and-handlers.md)). The door fires **only for the front's TLS port** (so a `…:9090` URL can't be pinned at the co-located CP) — `:443` by default; set `REWIND_INTERNAL_FRONT_PORT` only if the front's TLS port differs (test topologies). Unset = inert |
| `REWIND_INTERNAL_FRONT_PORT` | tenant door: the front TLS port the door accepts + pins (default `443`). Operators leave it unset in prod; test harnesses set it to the front's high port |
| `REWIND_RAFT_TICK_MS` | raft logical-tick cadence (ms); election timeout ≈ `election_tick(10) × this`. Default `1` (~15-20ms election, aggressive); production should set `10` (~100-300ms, the industry band). See [raft-best-practices.md](../plans/raft-best-practices.md) "how to size" |
| `S3_*` / `AWS_*` | blob/log/tape backend (see below) |

### `rewind-cp` (control plane) — `rewind-cp <port>`

| Env | Meaning |
|---|---|
| `REWIND_CP_NODE_ID` / `REWIND_CP_VOTERS` / `REWIND_CP_PEERS` | directory raft membership (same shape as the worker's) |
| `REWIND_CP_PEER_URLS` | CP HTTP origins for CP-HA leader-forwarding |
| `REWIND_CP_DATA_DIR` | durable directory store |
| `REWIND_CLUSTERS` | `id=url,url,url;…` — DP cluster → node-URL set |
| `REWIND_PLACEMENT` | `tenant=cluster;…` — seed placement |
| `REWIND_HOSTS` | `host=tenant;…` — seed host→tenant index |
| `REWIND_MOVE_SECRET` | gates `/_control/*` (move, provision, host, plan, cert) |
| `REWIND_PUBLIC_SUFFIX` / `REWIND_SYSTEM_SUFFIX` | e.g. `rewindjs.app` / `rewindjs.com` |
| `REWIND_ACME_DIRECTORY` | ACME dir URL — **inert unless set** (enables the leader-elected issuer) |
| `REWIND_ACME_CONTACT` / `REWIND_ACME_INSECURE_TLS` | issuer contact / Pebble test toggle |
| `REWIND_CP_RECONCILE_SECS` | reconciliation cadence |
| `REWIND_RAFT_TICK_MS` | raft tick cadence for the directory group — keep IDENTICAL to the worker's so election timing is uniform on the node |

### `rewind-front` (stateless edge) — `rewind-front <tls_port>`

| Env | Meaning |
|---|---|
| `REWIND_CP_URL` | **required** — CP origin(s) to resolve placement (`;`-join for HA) |
| `REWIND_TLS_CERT` / `REWIND_TLS_KEY` | default (platform-wildcard) cert; per-host certs sync from the CP |
| `REWIND_HTTP_PORT` | plaintext `:80` listener (ACME HTTP-01 + HTTP→HTTPS redirect); `0` disables |
| `REWIND_ROUTE_CACHE_MS` | route-cache TTL (default 1000; `0` = always-fresh) |
| `REWIND_CERT_SYNC_MS` | CP cert-pull cadence |

### Blob/S3 backend (process-wide, all binaries via `rove-blob`)

**S3 is mandatory — there is no fs backend.** `src/blob/env.zig`'s `loadFromEnv`
hard-errors at boot if any of `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`,
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` is unset. Optional:
`S3_KEY_PREFIX_BASE` (default `""`; production should use a prefix like `prod/`),
`S3_USE_TLS` (default `1`). There is no `BLOB_BACKEND` var (that was V1).

## Firewall / network plane

| Port | Plane | Exposure |
|---|---|---|
| `:443`, `:80` (front) | public | **internet** |
| `:8443` (worker h2c) | front → worker | private (cluster nodes only) |
| `:8501` (worker raft) | worker ↔ worker | private |
| `:9090` (CP http) | front/worker → CP | private |
| `:9101` (CP raft) | CP ↔ CP | private |

Ports above are **recommended canonical values**, operator-set. The front→worker
hop is private h2c (TLS terminates at the front). With the tenant door enabled
(`REWIND_INTERNAL_FRONT`, above) workers additionally dial the fronts' `:443` on
the private-plane interface (worker → front, TLS) for tenant→tenant fetches —
the fronts bind `0.0.0.0`, so this needs no extra listener, just private-plane
reachability of `:443` between the nodes.

> **⚠ Security — the private plane has NO app-layer auth.** The raft transports
> (`:8501`, `:9101`) are unauthenticated and unencrypted, and the worker `:8443`
> is plaintext h2c. **The firewall is the sole security boundary** — these four
> ports must be reachable *only* between the cluster nodes (private network /
> security group / WireGuard), never the public interface. Two more must-dos
> before exposing anything: set a strong **`REWIND_MOVE_SECRET`** (gates all
> `/_control` + `/_system/v2-*`) and a strong **`REWIND_ROOT_TOKEN`** (it falls
> back to a compiled-in default that would otherwise leave `/_system/admin-kv`
> open with a known token).

### As-built facts behind the boundary

- **Inter-node auth is the firewall, full stop.** There is no V2 services-JWT
  (V1's `LOOP46_SERVICES_JWT_SECRET` / `Cap.RAFT_SNAPSHOT` is gone). The control
  surface (`/_system/v2-*`, `/_control/*`, `/_system/v2-kv`) is gated by
  `REWIND_MOVE_SECRET` (header `X-Rewind-Move-Secret`); the raft transport
  (`src/consensus/transport.zig`) carries no token/TLS/auth.
- **Admin bootstrap is automatic, but the root token defaults.** The worker
  auto-creates the admin instance at first boot (`createInstance(ADMIN_INSTANCE_ID)`);
  `REWIND_ADMIN_DOMAIN` → admin host, `REWIND_ROOT_TOKEN` → the `/_system/admin-kv`
  bearer. Both fall back to compiled-in defaults, so **`REWIND_ROOT_TOKEN` MUST
  be set in production.**
- **The raft WAL is not separable from `data_dir`.** It lives under `{data_dir}`
  (`consensus/bridge.zig`, `node.zig`); there is no separate-mount knob. Mount
  the whole `data_dir` on the fastest (power-loss-protected) NVMe available —
  raft commit is fsync-latency-bound.
- **The cluster-id contract.** The worker's `REWIND_CLUSTER_ID` must equal a
  cluster id in the CP's `REWIND_CLUSTERS`, and **must be set together with
  `REWIND_CP_URL`** — either one unset makes a local-miss `404` instead of
  serve-or-forwarding. The URLs in `REWIND_CLUSTERS` are the worker h2c origins
  the front proxies to.
- **Front→worker is plaintext h2c.** The worker listens h2c (`.tls_config = null`);
  the front dials it over `http://` prior-knowledge h2c and terminates public TLS
  itself. Worker `:8443` is plaintext → firewall it.

## Two-tier TLS architecture

The front terminates public h2-over-TLS with **SNI cert selection**: per
incoming Host, an exact-match per-host cert wins, else the default wildcard. Two
sources feed it.

**Tier 1 — the operator's own domains → one DNS-01 wildcard.** A wildcard cert
for the operator's registrable domain(s) (plus the bare apexes — wildcards don't
match the apex), issued via **DNS-01** (the only ACME challenge that yields a
wildcard; HTTP-01 cannot). This is the front's default cert
(`REWIND_TLS_CERT`/`KEY`) and covers all first-party tenants plus any customer
subdomains of the operator's domains. It also removes any bootstrap wrinkle: the
front has a real wildcard from first boot — no boot-ordering or `:80`-first
dance. *How* the wildcard is issued and distributed to the fronts (which ACME
client, which DNS provider plugin, the renewal deploy-hook) is operator-specific
deploy detail.

**Tier 2 — customer custom domains → the CP's HTTP-01 issuer.** A customer's own
domain (`customer.com`, `api.customer.com`) is not under the operator's wildcard,
so each gets its own per-host cert from the platform's **leader-elected ACME
issuer** (`src/cp/acme.zig`, HTTP-01, built + Pebble-proven). Flow: customer
points DNS at the fronts → `POST /_control/host` maps host→tenant → the issuer
serves the HTTP-01 challenge via the front `:80` (forwarded to
`/_cp/acme-challenge`) → cert lands in the CP cert axis → **CertSync** fans it to
all fronts → served by SNI exact-match.

- **Toggle:** `REWIND_ACME_DIRECTORY` is **unset** until the first custom domain
  is onboarded (Tier-1 covers every first-party host). Built + ready, just not
  exercised until then.
- **Scope:** specific hosts only. A wildcard on the *customer's* domain
  (`*.customer.com`) needs DNS-01 on *their* zone (CNAME-delegation / acme-dns) —
  not currently supported.
- **Onboarding gotcha:** a brief window between "DNS points at us" and "cert
  minted" where that one host's TLS fails; first-party / wildcard hosts
  unaffected.

Custom domains are intended as a metered, plan-gated feature — enforce via the
`rove-plan` tier table (a per-tenant cap checked at `POST /_control/host`, plus
an issuance rate limit that protects against ACME abuse and Let's Encrypt's
account-level limits). See [control-plane.md](control-plane.md) for the plan-tier
levers.
