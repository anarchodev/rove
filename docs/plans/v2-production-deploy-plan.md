# V2 production deployment plan

> **Status: plan / not yet built (2026-06-08).** The first production deploy
> of the V2 `rewind` stack, plus the repeatable *feature-done → deploy → docs*
> workflow. Supersedes the V1 deploy story in
> [`architecture/deployment-and-logs.md`](../architecture/deployment-and-logs.md) +
> `scripts/systemd/*.service`, **all of which target the retired four-binary
> V1 topology** (`loop46`, `files-server-standalone`, `log-server-standalone`,
> `sse-server-standalone`) and must not be used. Companions:
> [`architecture/routing-and-ingress.md`](../architecture/routing-and-ingress.md),
> [`architecture/control-plane.md`](../architecture/control-plane.md).

## 0. The gap this plan closes

The V2 engine, CP/DP split, and edge are done and green (cutover checklist).
What does **not** exist is any way to run V2 in production: there are no V2
systemd units, no V2 runbook, and no deploy script. Every operational artifact
in the tree is V1. "Deploy to production" therefore means **build the V2 deploy
machinery first, then cut over** — that is the bulk of this plan.

## 1. Locked decisions (from the 2026-06-08 design discussion)

### 1.1 Topology — 3 bare-metal nodes, single DC, fully co-located

```
bhs-1 / bhs-2 / bhs-3             (identical OVH Advance bare-metal, one DC: BHS)
 ├─ rewind-cp      :9090 + raft :9101   directory raft — 3-voter quorum
 ├─ rewind worker  :8443 + raft :8501   DP multi-raft — tenant groups span all 3
 └─ rewind-front   :443 (TLS) + :80      stateless edge: TLS term + ACME + redirect
shared: OVH Object Storage (S3) for blobs / logs / tape (one bucket)
public ingress: round-robin DNS A-records → the three fronts
```

Rationale (full reasoning in the chat that produced this doc):

- **Bare metal eliminates the co-location failure mode.** OVH classic VPS gives
  no hard anti-affinity, so two raft voters can land on one hypervisor → a
  single host failure takes quorum. Bare metal makes every node physically
  distinct by definition.
- **Co-locate CP + worker + front on the same 3 boxes.** The architecture
  requires CP to be its own *binary and raft cluster*, not its own *hardware*.
  The CP is near-idle steady-state (directory ops + cached route lookups), so
  it rides free on worker headroom; a systemd resource slice keeps a worker
  spike from starving it. Six machines (3 CP + 3 DP) buys nothing functional.
- **3 voters per cluster** (CP and DP) tolerate **1** full-node loss
  (quorum = 2). Never 4 or 6 *as one cluster* — even sizes are strictly worse.
- **Growth path:** scale DP horizontally by adding cheap **DP-only VPS
  workers** (a dead VPS worker just makes its tenant groups re-replicate — a
  non-event). The CP quorum never grows past 3. This is why we don't start at
  5/6.

#### Phased rollout — ~~bootstrap on VPS, migrate to bare metal~~ start directly on bare metal (revised 2026-06-12)

The 2026-06-08 decision was a two-phase rollout: bootstrap on 3 region-spread
VPS (GRA/SBG/BHS — region-spread as the anti-affinity substitute), then
migrate to bare metal later, dogfooding the move machinery on the way.
**Superseded 2026-06-12: deploy straight onto the destination — 3 separate
bare-metal boxes, all in BHS** (`bhs-1` / `bhs-2` / `bhs-3`). Consequences:

- **No migration phase.** The first production deploy lands on the final
  hardware; perf characteristics (PLP-NVMe fsync, dedicated cores) are real
  from day one — no VPS-vs-prod benchmark ambiguity.
- **Co-location risk is covered the bare-metal way** (the §1.1 rationale):
  three physically distinct machines, no shared hypervisor possible. Single-DC
  exposure (a BHS-level event takes the cluster) matches the locked single-DC
  destination; the answer to DC loss remains the async DR learner (§1.3), not
  region-spread voters.
- **The old Phase-2 dogfood loses its forcing function.** CP voter add/retire
  (Path A) is still built — the DR learner shares its conf-change foundation
  (§8 item 7) — and `/_control/move` gets dogfooded against a scratch second
  DP cluster before any customer relies on it, instead of via a hardware
  migration.

### 1.2 Per-node spec — sized for an fsync/RTT-bound workload, not CPU

| Component | Spec | Why |
|---|---|---|
| Disk | **2× datacenter NVMe with power-loss protection (PLP), RAID1** | The #1 lever. Raft commit is fsync-latency-bound; PLP turns fsync from a NAND flush into a DRAM-cache ack (tens of µs vs ms). PLP matters far more than RAID level or drive count. RAID1 so a single-disk failure doesn't drop a voter. |
| NIC | **10 Gbps preferred**, 1 Gbps acceptable | 1 Gbps was a measured ceiling (S3 PUT ≈ 117 MB/s = NIC-limited, `project_s3_throughput_ceiling`). 10 Gbps lifts the blob/log/replication ceiling. |
| CPU | **8 physical cores (16 threads) min**, modern EPYC/Xeon/Ryzen | Sized for concurrency + isolation (worker pool + front TLS + uncontended raft/CP), not throughput — the workload is I/O-bound. Count **physical cores**, treat SMT as ~20–40% bonus. |
| RAM | **64 GB** (32 GB floor) | Per-tenant kvexp/LMDB mmap + per-worker arena base snapshot + bytecode cache. |
| Homogeneity | **All 3 identical** | Raft commit is gated by the slowest voter in the quorum. |

OVH line: **Advance** (price/performance sweet spot; confirm the NVMe SKU has
PLP). Pin a systemd `MemoryMax` / `CPUWeight` slice on `rewind-cp` and reserve
a core or two (`AllowedCPUs`) for the raft thread so consensus latency stays
consistent under customer JS load.

> **Disk follow-up (deferred, measure first):** 4× NVMe RAID10 buys *aggregate
> throughput*, not *single-fsync latency* — the wrong axis for this workload.
> If we ever go to 4 drives, the higher-value layout is a **dedicated RAID1
> mirror for the raft WAL** (latency isolation from random state I/O) — but the
> WAL is **not separable from `data_dir` today** (verified §10), so that needs a
> code knob first; for now mount the whole `data_dir` on the fast NVMe mirror.
> Don't pre-buy until production I/O metrics show a throughput ceiling.

### 1.3 DR posture — single-DC core + async learner (+ interim backup)

- **No latency cost from DR.** A non-voting **learner** does not count toward
  quorum, so the leader commits on the local 3-voter quorum and streams to the
  learner asynchronously. Request-path write latency is unaffected; the learner
  trails by ~one cross-region one-way (~10ms = the recovery window / RPO).
  **It must stay non-voting** — promoted to voter only during an actual
  DC-loss failover (a 4th voter would change quorum geometry + be an even
  count).
- **The learner needs building in V2** (it was V1-only via willemt; V2 is
  raft-rs multi-raft, so "a DR follower" = a non-voting member of *every*
  tenant group → needs learner-placement in the CP). **Scheduled as feature #1
  in the post-launch loop**, not a launch blocker. **Shares its foundation with
  the CP voter add/retire (Path A, §8):** a learner is an `AddLearnerNode`
  conf-change, so the same raft-rs-zig conf-change FFI extension unblocks both —
  build that FFI piece once, early.
- **Interim DR, free, until the learner ships:** periodic per-tenant kvexp
  bundle dump (reusing the tenant-move dump path) to a **second-region S3
  bucket**. Minutes-RPO coverage for "the DC fell into the sea" until the
  learner brings it to ~10ms-RPO.

## 2. Process / port / config map (the source of truth for the units)

All three binaries are positional-arg + env-var configured. **Verified against
`src/{cp,front,rewind}/main.zig` + `src/blob/env.zig` 2026-06-08.**

### 2.1 `rewind-worker` (DP worker) — `rewind-worker <data_dir> <http_port>`

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
| `REWIND_PUBLIC_SUFFIX` | customer tenant wildcard eTLD+1 (`rewindjs.app`) |
| `REWIND_INTERNAL_FRONT` | tenant door: comma-sep **bare IPs** of the fronts on the private plane (vRack/WireGuard); outbound fetches to `*.{public/system suffix}` hosts pin their connect here instead of resolving public DNS, so tenant→tenant calls never hairpin through the public edge (`docs/architecture/effects-and-handlers.md`). The door fires **only for the front's TLS port** (so a `…:9090` URL can't be pinned at the co-located CP) — `:443` by default; set `REWIND_INTERNAL_FRONT_PORT` only if the front's TLS port differs (test topologies). Unset = inert |
| `REWIND_INTERNAL_FRONT_PORT` | tenant door: the front TLS port the door accepts + pins (default `443`). Operators leave it unset in prod; test harnesses set it to the front's high port |
| `REWIND_RAFT_TICK_MS` | raft logical-tick cadence (ms); election timeout ≈ `election_tick(10) × this`. Default `1` (~15-20ms election, aggressive); prod sets `10` (~100-300ms, the industry band). See `docs/plans/raft-best-practices.md` "how to size" |
| `S3_*` / `AWS_*` | blob/log/tape backend (see §2.4) |

### 2.2 `rewind-cp` (control plane) — `rewind-cp <port>`

| Env | Meaning |
|---|---|
| `REWIND_CP_NODE_ID` / `REWIND_CP_VOTERS` / `REWIND_CP_PEERS` | directory raft membership (same shape as the worker's) |
| `REWIND_CP_PEER_URLS` | CP HTTP origins for CP-HA leader-forwarding |
| `REWIND_CP_DATA_DIR` | durable directory store |
| `REWIND_CLUSTERS` | `id=url,url,url;…` — DP cluster → node-URL set |
| `REWIND_PLACEMENT` | `tenant=cluster;…` — seed placement |
| `REWIND_HOSTS` | `host=tenant;…` — seed host→tenant index |
| `REWIND_MOVE_SECRET` | gates `/_control/*` (move, provision, host, plan, cert) |
| `REWIND_PUBLIC_SUFFIX` / `REWIND_SYSTEM_SUFFIX` | `rewindjs.app` / `rewindjs.com` |
| `REWIND_ACME_DIRECTORY` | ACME dir URL — **inert unless set** (enables the leader-elected issuer) |
| `REWIND_ACME_CONTACT` / `REWIND_ACME_INSECURE_TLS` | issuer contact / Pebble test toggle |
| `REWIND_CP_RECONCILE_SECS` | reconciliation cadence |
| `REWIND_RAFT_TICK_MS` | raft tick cadence for the directory group — keep IDENTICAL to the worker's (§2.1) so election timing is uniform on the node. Prod `10` |

### 2.3 `rewind-front` (stateless edge) — `rewind-front <tls_port>`

| Env | Meaning |
|---|---|
| `REWIND_CP_URL` | **required** — CP origin(s) to resolve placement (`;`-join for HA) |
| `REWIND_TLS_CERT` / `REWIND_TLS_KEY` | default (platform-wildcard) cert; per-host certs sync from the CP |
| `REWIND_HTTP_PORT` | plaintext `:80` listener (ACME HTTP-01 + HTTP→HTTPS redirect); `0` disables |
| `REWIND_ROUTE_CACHE_MS` | route-cache TTL (default 1000; `0` = always-fresh) |
| `REWIND_CERT_SYNC_MS` | CP cert-pull cadence |

### 2.4 Blob/S3 backend (process-wide, all binaries via `rove-blob`)

**S3 is mandatory — there is no fs backend** (verified §10). Required:
`S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY` (the binary hard-errors at boot if any is unset).
Optional: `S3_KEY_PREFIX_BASE` (default `""` — use `prod/`), `S3_USE_TLS`
(default `1`). No `BLOB_BACKEND` var (that was V1).

### 2.5 Firewall / network plane

| Port | Plane | Exposure |
|---|---|---|
| `:443`, `:80` (front) | public | **internet** |
| `:8443` (worker h2c) | front → worker | private (3 nodes only) |
| `:8501` (worker raft) | worker ↔ worker | private |
| `:9090` (CP http) | front/worker → CP | private |
| `:9101` (CP raft) | CP ↔ CP | private |

Ports above are **recommended canonical values**, operator-set. The front→worker
hop is private h2c (TLS terminates at the front). With the tenant door enabled
(`REWIND_INTERNAL_FRONT`, §2.1) workers additionally dial the fronts' `:443` on
the private-plane interface (worker → front, TLS) for tenant→tenant fetches —
the fronts bind `0.0.0.0`, so this needs no extra listener, just private-plane
reachability of `:443` between the nodes.

> **⚠ Security — the private plane has NO app-layer auth (verified §10).** The
> raft transports (`:8501`, `:9101`) are unauthenticated and unencrypted, and the
> worker `:8443` is plaintext h2c. **The firewall is the sole security boundary**
> — these four ports must be reachable *only* between the 3 nodes (private
> network / security group / WireGuard), never the public interface. Two more
> must-dos before exposing anything: set a strong **`REWIND_MOVE_SECRET`** (gates
> all `/_control` + `/_system/v2-*`) and a strong **`REWIND_ROOT_TOKEN`** (it
> falls back to a compiled-in default that would leave `/_system/admin-kv` open).

## 3. What must be BUILT before the first deploy

A pre-deploy checklist.

- [x] **V2 systemd units** under `scripts/systemd/v2/`
  (`rewind-cp.service`, `rewind-worker.service`, `rewind-front.service`) +
  `common.env.example` / `node.env.example` + a `README.md`. Each
  `EnvironmentFile=`s `common.env` (deploy-wide) + `node.env` (just the node
  ids); `Restart=always`; front `After=`/`Wants=` worker+cp; cp gets the
  `CPUWeight`/`MemoryMin` slice. `systemd-analyze verify`-clean.
- [x] **Retired the 8 V1 units** (`git rm scripts/systemd/rove-*.service|.timer`).
- [x] **`scripts/deploy.sh`** + `deploy.conf.example` (gitignored real conf):
  build ReleaseFast → `v2-test` + `test` gate → per-host atomic-rename binary
  push. Two modes: **rolling** (default) = quorum-safe one-at-a-time restart
  (cp→worker→front, health-gated on `/_cp/leader` + `/_system/health`, settle
  between hosts) of an already-formed cluster — refuses if no directory leader
  is reachable; **genesis** (`--genesis`) = clean-slate cold bring-up — WIPE
  `~/.rove/data` on all hosts, push all, start every CP together so the
  cold-multi directory elects, start workers (cold-multi) + fronts, then
  `rewind-ops genesis` provisions `__admin__` born `{1,2,3}` cold-multi +
  deploys it — refuses if a leader already exists (`ROVE_GENESIS_FORCE=1` to
  override). The genesis mode codifies §5 steps 5–8. ONE env profile (cold-multi)
  for both modes; the reconciler stays OFF. Binaries only — no secrets pushed.
- [x] **`/deploy` skill** (`.claude/skills/deploy/SKILL.md`) — the approval-gated
  release procedure (§6): show the diff, human go/no-go, run `deploy.sh`,
  validate, tag `prod-deployed`.
- [x] **`scripts/rove-cert-deploy.sh`** — the certbot deploy hook for the
  Tier-1 wildcard (§4.1): installs the renewed cert on every front (local +
  ssh peers) + restarts each (front cert hot-reload unproven — §10 open item,
  restart is the safe form). Installed at
  `/etc/letsencrypt/renewal-hooks/deploy/` on the certbot host; note it does
  NOT fire on the very first issuance — run it once manually with
  `RENEWED_LINEAGE=/etc/letsencrypt/live/platform`.
- [ ] **`docs/v2-deployment.md`** — the full V2 runbook (the `README.md` is a
  condensed install; the runbook adds membership changes, cert rotation,
  lost-quorum recovery, validation curls). Replaces V1 `architecture/deployment-and-logs.md`.
- [ ] **Prove the V2 handler-publish path** (gates the §11 tenants) + the
  **first-party tenant bundles** — marketing (static) first as the pipeline
  proof, then admin/auth/docs/cluster-manager (§11).
- [x] **Verify-before-write items in §10** resolved.

## 4. DNS + TLS / ACME wiring

Two registrable domains (the auth/domain isolation boundary):
**`*.rewindjs.app`** (customer tenant wildcard) and **`*.rewindjs.com`**
(platform/system surfaces: `app.`/`auth.`/`replay.`…).

- **DNS:** round-robin **A-records** for the relevant names → the 3 host public
  IPs, short TTL (e.g. 60s). Serve-or-forward means DNS only needs to land you
  on *a* live front; it proxies to the right cluster regardless. (An OVH Load
  Balancer / L4 front is a later hardening step, not a launch blocker.)
### 4.1 Two-tier TLS certs (decided 2026-06-08)

The front terminates public h2-over-TLS with **SNI cert selection**: per incoming
Host, an exact-match per-host cert wins, else the default wildcard. Two sources
feed it.

**Tier 1 — your own domains → one certbot DNS-01 wildcard.** `*.rewindjs.com` +
`*.rewindjs.app` (+ the bare apexes — wildcards don't match the apex), issued by
**certbot + the Cloudflare DNS plugin** (DNS-01 is the only way to get a wildcard;
HTTP-01 can't) and auto-renewed via `certbot.timer`. This is the front's default
cert (`REWIND_TLS_CERT`/`KEY`) and covers **all** first-party tenants + any
customer subdomains of our domains. It also resolves the old "bootstrap wrinkle":
it's the *automated* form of "seed a cert," so the front has a real wildcard from
first boot — no boot-ordering dance, no `:80`-first dance.
- **Distribution (option B):** run certbot on ONE host (or the ops box — DNS-01
  needs only outbound to LE + Cloudflare), and a `--deploy-hook`
  (`scripts/rove-cert-deploy.sh`) rsyncs the renewed cert to all 3 fronts'
  `REWIND_TLS_CERT`/`KEY` paths and reloads each (restart `rewind-front` — safe,
  it's stateless). Scoped Cloudflare token (`Zone.DNS:Edit` on the 2 zones),
  creds ini `chmod 600`.

**Tier 2 — customer custom domains → the CP's HTTP-01 issuer.** `customer.com` /
`api.customer.com` are not under our wildcard, so each gets its own per-host cert
from the platform's leader-elected ACME issuer (`src/cp/acme.zig`, HTTP-01, built
+ Pebble-proven). Flow: customer points DNS at our fronts → `POST /_control/host`
maps host→tenant → the issuer serves the HTTP-01 challenge via the front `:80`
(forwarded to `/_cp/acme-challenge`) → cert lands in the CP cert axis →
**CertSync** fans it to all 3 fronts → served by SNI exact-match.
- **Toggle:** `REWIND_ACME_DIRECTORY` is **unset at launch** (Tier-1 covers every
  first-party host) and **flipped on when onboarding the first custom domain**.
  Built + ready, just not exercised until then.
- **Scope:** specific hosts only. A wildcard on the *customer's* domain
  (`*.customer.com`) needs DNS-01 on *their* zone (CNAME-delegation / acme-dns) —
  deferred.
- **Onboarding gotcha:** a brief window between "DNS points at us" and "cert
  minted" where that one host's TLS fails; first-party / wildcard hosts unaffected.

**Custom domains are a metered, plan-gated, PAID feature (product decision
2026-06-08).** Enforce via the shipped `rove-plan` tier table (gap #1): a
per-tenant **cap** on custom domains checked at `POST /_control/host`, plus an
**issuance rate limit** (protects against ACME abuse + Let's Encrypt's own
account-level limits). Free tier = subdomains of our domains only; custom domains
= paid tier / add-on (the Vercel/Netlify model). Post-launch feature, tied to
the plan-tier levers (`architecture/control-plane.md`, shipped) +
`docs/strategy/pricing-model.md` (not built).

## 5. First-deploy runbook (outline — full version → `docs/v2-deployment.md`)

1. **Provision** 3 OVH Advance boxes (§1.2), same DC, private network between
   them, public IPs on host-1..3. Lock the firewall per §2.5.
2. **OVH Object Storage:** one bucket; create an S3 credential; set
   `S3_KEY_PREFIX_BASE` (e.g. `prod/`). Create the **second-region bucket** for
   interim DR backups.
3. **Build + ship binaries:** `zig build rewind-worker rewind-cp rewind-front`
   (ReleaseFast) → `rsync` `rewind`, `rewind-cp`, `rewind-front` to
   `~/.local/bin` on each host.
4. **Env files:** `~/.config/rove/common.env` (shared) + `~/.config/rove/node.env`
   (per-host id/peers) per §2.
5. **Bring up CP cluster:** start `rewind-cp` on all 3 (`REWIND_CP_NODE_ID`
   1/2/3, shared `REWIND_CP_VOTERS=1,2,3`, `REWIND_CP_PEERS`, `REWIND_CP_PEER_URLS`).
   Confirm a leader via `GET /_cp/leader`.
6. **Bring up DP cluster:** start `rewind` on all 3 (`REWIND_NODE_ID` 1/2/3,
   `REWIND_VOTERS=1,2,3`, `REWIND_PEERS`, `REWIND_CLUSTER_ID=prod`,
   `REWIND_CP_URL` → the 3 CPs). `REWIND_CLUSTERS=prod=<3 worker URLs>` on the CP.
7. **Bring up fronts:** start `rewind-front` on all 3 (`REWIND_CP_URL` → CPs,
   `REWIND_TLS_CERT/KEY` = platform wildcard, `REWIND_HTTP_PORT=80`).
8. **Provision the first tenant:** `POST /_control/provision
   {tenant, cluster:"prod", host}` (move-secret gated) → group forms across all
   3 → placement written → host routable. Deploy the dashboard bundle to it.
9. **Validate:** `/_cp/leader`, worker `/_system/health` on each node, a public
   HTTPS request through a front returns 200 from the tenant, kill one node →
   confirm the promoted follower still serves (the Phase-5 exit criterion).
10. **Enable units:** `systemctl --user enable --now` the three; confirm
    `Restart=always` recovery.

## 6. The repeatable workflow — *feature done → deploy → docs*

A feature is **not done** until all four of these are true. Encoded as the
**`/deploy` skill** (`.claude/skills/deploy/SKILL.md`) — the approval-gated
release procedure that wraps `scripts/deploy.sh` behind a mandatory human
go/no-go, validates, and records the deployed commit (`prod-deployed` git tag).
Matches the locked "deploys stay approval-gated" stance
(`project_ai_integration_shape`).

**Definition of done:**
1. **Code + targeted tests green** — `zig build v2-test` + the feature's
   smoke(s) + `zig build test` (now green post-merge). No `zig build test`
   regressions.
2. **Reference docs updated** — the customer-facing doc-site page for any
   changed handler API / builtin lib / effect surface (§7). Sub-plan docs in
   `docs/` updated too if the shipped shape moved
   (`feedback_subplan_docs_lag_shipped_api`).
3. **Deployed to prod** via the rolling deploy below.
4. **Post-deploy smoke green** against prod.

**Rolling deploy (zero-downtime on the 3-node cluster):** each raft cluster
tolerates 1 node down, so restart **one node at a time**, waiting for it to
rejoin + catch up (boot-time tenant-group recovery exists, commit `dd836b4`)
before the next:

```
for host in host-3 host-2 host-1:        # leader last; fronts are stateless
    rsync new binaries → host
    systemctl --user restart rewind-worker     # wait: /_system/health 200 + group rejoin
    systemctl --user restart rewind-cp         # wait: /_cp/leader healthy
    systemctl --user restart rewind-front
    validate host, pause, next
```

`deploy.sh` gates each step on the health/leader probes and aborts the rollout
if a node doesn't recover quorum — never proceed past a node that didn't come
back.

## 7. Docs site

The "reference docs on a docs site" = the **customer/developer-facing** product
reference (handler API, builtin libs, effect model), distinct from the internal
architecture notes in `docs/`. A first-class goal is **executable examples**:
code snippets I run through the WASM replayer (`replay-wasm-plan.md`) so the
output is *verified, not asserted* — and that a reader can edit-and-re-run in
the browser.

### 7.1 Decision: full dogfood — docs are a rewind.js app

**Locked 2026-06-08.** The docs site is served by the platform itself, as a
deployed tenant (alongside the admin/dashboard tenant). Most on-brand — the
reference docs for rewind.js *are* a rewind.js app — and it removes every
external docs-toolchain decision: no MkDocs, no Node/MDX, no GitHub/Cloudflare
Pages. **The platform deploys before the docs exist** (user's call); the docs
tenant is an early feature *through* the new loop (§8), not a launch blocker.

**Content + rendering.** The customer-facing markdown is rendered to HTML at
build/deploy time and shipped in the docs tenant's deploy bundle as static
assets, served through the platform's static-asset path (content-addressed, so
it rides the same CDN-over-object-storage story as any tenant's statics). No
request-time markdown rendering needed.

**Executable examples (a framework-agnostic web component).** The `<rewind-example
src="hello.js">` custom element + the replay `.wasm` are static assets in the
docs bundle; a small JS bundle registers the element, loads the wasm, mounts a
code editor (CodeMirror 6), and runs the snippet client-side (the replayer is
client-side by design). Two seams:

- **Authoring/CI-time (the higher-value half):** the docs *build step* runs each
  example through the replayer and embeds the verified output — examples become
  tested artifacts that can't silently go stale.
- **Reader-time:** the same `.wasm` runs in the browser for edit-and-run.

The replay wasm is **single-threaded** (arenajs/QuickJS, no `SharedArrayBuffer`,
verified §10), so **no COOP/COEP headers are needed** at all — and we control
them anyway when dogfooding.

**Artifact handoff:** the wasm is **not** a `zig build` target — it's
`qjs_arena_wasm.{js,wasm}`, built from arenajs via Emscripten (`emmake make
qjs_arena_wasm`) and already checked in at **`web/replay/_static/`** (where an
existing replay harness also lives). The docs build copies those prebuilt assets
into the docs tenant's bundle; regen via emsdk only when arenajs changes.

**The payoff for the workflow:** "update the docs site" becomes *just another
tenant deploy* — the same `_deploy/current` release flip as every other tenant.
No separate docs-publish pipeline; the §6 loop's docs step unifies with its
deploy step.

### 7.2 Considered + rejected for launch

- **Static generator on GitHub/Cloudflare Pages** (Material for MkDocs / Astro
  Starlight / Docusaurus). Would work *before* the platform is live and needs no
  dogfood bootstrap — but it's a parallel toolchain + host to own, and the user
  chose deploy-platform-first + docs-after. The `<rewind-example>` web component
  is generator- and host-independent, so this stays a clean fallback if dogfood
  ever proves painful (and the build-time-verified-examples pattern is identical
  either way).

## 8. Build / sequencing order

1. **Resolve §10 verify-items** (cheap, unblocks accurate env files).
2. **Build the V2 deploy machinery** (§3): systemd units, `deploy.sh`,
   `docs/v2-deployment.md`; delete V1 units.
3. **First production deploy** (§5) — the milestone, onto the **production
   cluster** (3 bare-metal boxes in BHS, §1.1). Stands up the platform + the
   auto-created admin instance. **Docs not required (user's call.)**
4. **Prove the V2 handler-publish path** — compile → publish (`files-server-v2`)
   → `/_system/release` flip → served. This single proof gates every first-party
   tenant (§11); confirm it before standing them up.
5. **First-party tenants** (§11), ASAP order: **marketing (static)** → **admin +
   auth/OIDC** → **docs** → **cluster-manager UI**. Marketing is the pipeline's
   end-to-end proof.
6. **Wire the feature→deploy→docs loop** (§6) as the standing process.
7. **Early platform features through the loop** (order by priority):
   - **CP membership change — voter add/retire (Path A)** + **DR learner**
     (§1.3). Build these *together* because they **share a foundation**: the
     raft-rs-zig **conf-change FFI extension** (a learner is an `AddLearnerNode`
     conf-change; a voter add/retire is `AddNode`/`RemoveNode`). Layer stack,
     bottom-up: ① **raft-rs-zig Rust FFI** — export `propose_conf_change` +
     `apply_conf_change`→`ConfState`; rebuild + bump the pin
     (`project_dependency_fetch_migration`). ② **raft-rs-zig Zig `Manager`** —
     `proposeConfChange`/`applyConfChange`, persist the new confstate via the
     storage vtable. ③ **`src/consensus`** — `addVoter`/`removeVoter`/`addLearner`
     passthrough + apply committed ConfChange entries. ④ **`transport.zig`** —
     runtime peer add/remove (peers are static today). ⑤ **`src/cp`** —
     `/_control/cp-node` add/remove (leader- + move-secret-gated): join as
     learner → snapshot-catchup → promote to voter; retire = demote → remove.
     **Path B (directory export/import) is NOT a separate deliverable** — its
     export substrate falls out of ⑤'s join-snapshot; a thin CP-backup tool can
     wrap it later.
   - **Custom-domain billing** (§4.1): per-tenant cap (enforced at
     `POST /_control/host`) + issuance rate limit via the `rove-plan` tier table;
     paid-tier gate. Lands when onboarding the first custom-domain customer.
   - **Static-asset CDN** over object storage (the earlier ingress discussion;
     fold into §4 when built).
8. ~~**Migrate to bare metal** (§1.1 Phase 2), dogfooding the move machinery~~
   — **superseded 2026-06-12** (§1.1): we deploy straight onto bare metal, so
   there is no migration. The dogfood proofs move elsewhere: `/_control/move`
   against a scratch second DP cluster before the first customer-visible move;
   CP voter add/retire (Path A) proven by the DR-learner work (item 7).

## 9. Open decisions (need your call) — all resolved 2026-06-09

- ~~**Docs-site host**~~ — **RESOLVED: full dogfood** (docs = a rewind.js app),
  deploy platform *before* docs (§7.1).
- ~~**TLS bootstrap**~~ — **RESOLVED: two-tier certs** (§4.1). Tier-1 certbot
  DNS-01 wildcard for our domains (auto-renewed, distributed via deploy-hook B);
  Tier-2 CP HTTP-01 issuer for customer custom domains (toggled on when needed).
- ~~**Deploy trigger**~~ — **RESOLVED: approval-gated `/deploy` skill**
  (`.claude/skills/deploy/SKILL.md`, built 2026-06-09), run on request. Chosen over
  GitHub Actions CI/CD-on-merge (which needs CI secrets in a public repo + removes
  the human gate that the gated-deploy stance wants, `project_ai_integration_shape`).

## 10. Verify-before-build — RESOLVED (2026-06-08, against the live source)

- [x] **Blob backend — S3-only, mandatory.** `src/blob/env.zig` `loadFromEnv` is
  S3-only: it hard-errors (`MissingS3Endpoint` …) without `S3_ENDPOINT`/`S3_REGION`
  /`S3_BUCKET`/`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`. Optional:
  `S3_KEY_PREFIX_BASE` (default `""`), `S3_USE_TLS` (default `1`). **There is no
  `BLOB_BACKEND` var and no fs path** — CLAUDE.md's `BLOB_BACKEND=fs|s3` is V1.
  (A stale "fs or s3" comment survives at `rewind/main.zig:393`; the loader it
  calls is S3-only.)
- [x] **Inter-node auth — `REWIND_MOVE_SECRET`, and the raft transport is
  UNAUTHENTICATED.** No V2 services-JWT (V1's `LOOP46_SERVICES_JWT_SECRET` /
  `Cap.RAFT_SNAPSHOT` is gone). The control surface (`/_system/v2-*`,
  `/_control/*`, `/_system/v2-kv`) is gated by `REWIND_MOVE_SECRET` (header
  `X-Rewind-Move-Secret`). **The raft transport (`src/consensus/transport.zig`,
  worker `:8501` / CP `:9101`) carries NO token/TLS/auth** — the private-network
  firewall is the *sole* security boundary. See the §2.5 security note.
- [x] **Admin bootstrap — auto, but the root token DEFAULTS.** The worker
  auto-creates the admin instance at first boot (`createInstance(ADMIN_INSTANCE_ID)`,
  `rewind/main.zig:404`) — no manual `__root__` write. `REWIND_ADMIN_DOMAIN` →
  admin host; `REWIND_ROOT_TOKEN` → the `/_system/admin-kv` bearer
  (`node_tenant.root_token_secret`). **Both fall back to compiled-in defaults**
  (`DEFAULT_ADMIN_ROOT_TOKEN`) — so **`REWIND_ROOT_TOKEN` MUST be set in prod** or
  admin-kv is reachable with a known token. See §2.5.
- [x] **WAL is NOT separable from `data_dir`.** The raft WAL lives under
  `{data_dir}` (`consensus/bridge.zig:215-234`, `node.zig`); no separate-mount
  knob. So the §1.2 dedicated-WAL-mirror option needs a code change — for now,
  mount the whole `data_dir` on the fast NVMe mirror. (Confirms the fsync model:
  "a committed write is durable in the fsync'd raft WAL the instant it commits",
  `node.zig:77`.)
- [x] **Cluster-id contract confirmed.** CP seeds `REWIND_CLUSTERS`
  (`id=url,url,url;…`), `REWIND_PLACEMENT` (`tenant=cluster`), `REWIND_HOSTS`
  (`host=tenant`). The worker's `REWIND_CLUSTER_ID` must equal a cluster id in
  `REWIND_CLUSTERS`, and **must be set together with `REWIND_CP_URL`** — either
  unset → a local-miss `404`s instead of serve-or-forwarding
  (`rewind/main.zig:382-390`). The URLs in `REWIND_CLUSTERS` are the worker h2c
  origins the front proxies to.
- [x] **Front→worker h2c confirmed.** The worker listens **plaintext h2c**
  (`.tls_config = null`, `rewind/main.zig`); the front dials it over `http://`
  prior-knowledge h2c (`front/main.zig:726,753`) and terminates public TLS
  itself. Worker `:8443` is plaintext → firewall it (§2.5).
- [x] **Replay WASM — single-threaded, prebuilt, NOT a `zig build` target.** It's
  `qjs_arena_wasm.{js,wasm}` built from **arenajs via Emscripten** (`emcmake/emmake
  make qjs_arena_wasm`, `replay-wasm-plan.md:555`), and the prebuilt artifacts
  already live in **`web/replay/_static/`** (plus an existing replay harness
  there). QuickJS/arenajs is **single-threaded** (no pthreads/`SharedArrayBuffer`)
  → **no COOP/COEP needed**, period. §7.1's "artifact handoff" is therefore: the
  docs build copies the prebuilt `web/replay/_static/qjs_arena_wasm.*` (regen via
  emsdk when arenajs changes), not a `zig build` step.
- [ ] **(open) Front default-cert hot-reload?** Does `rewind-front` watch
  `REWIND_TLS_CERT`/`KEY` and reload on change (V1 had a stat-and-reload poll), or
  must it restart to pick up a renewed Tier-1 wildcard (§4.1)? If it hot-reloads,
  `rove-cert-deploy.sh` can drop the front restart; if not, the restart stays
  (safe — front is stateless).

## 11. First-party tenant roadmap (the dogfood surface)

**Locked 2026-06-08.** The platform hosts itself: a small set of first-party
tenants stood up as the first real workloads. **Gated behind two upstream
things** (not the tenants themselves): the platform must be *deployed* (§5) and
the **V2 handler-publish path proven** end-to-end (compile → publish via
`files-server-v2` → `/_system/release` flip → served) — that single proof
unblocks all of them.

| Tenant | Host (system suffix) | Auth | V1 scope | Depends on |
|---|---|---|---|---|
| **Marketing** | `rewindjs.com` / `www.` | public, none | **static** (V1) | publish path only |
| **Docs** | `docs.rewindjs.com` | public, none | content + `<rewind-example>` player (§7) | publish + `web/replay/_static` wasm |
| **Admin** (incl. cluster manager) | `app.rewindjs.com` | **authed** | dashboard + ops UI | **auth tenant** below |
| **Auth / OIDC** | `auth.rewindjs.com` | — (is the IdP) | the `__auth__` IdP (platform OIDC) | — |

The **auth/OIDC tenant is the hidden prerequisite** for everything authed —
counted explicitly so it isn't a surprise. (Customer tenants live on the
*separate* eTLD+1 `*.rewindjs.app`; these are all system surfaces on
`rewindjs.com`, per the auth-domain isolation boundary.)

**Cluster manager = a section of the Admin tenant, not its own tenant (option
b).** It reuses the admin tenant's `platform.root.*` privileges; **cluster
features (provision / move / placement / node health, the `REWIND_MOVE_SECRET`-
and `/_control/*`-backed actions) are gated to the operator role only** —
non-operator admin principals never see or invoke them. The fleet authority
(move-secret / CP control calls) stays **server-side in the admin handler**,
never shipped to the browser and never exposed to a non-operator session. This
avoids putting fleet keys inside a customer-style sandbox (the confused-deputy
concentration the capability model warns about, `decisions.md` §13.2).

**Build order (ASAP-optimized, each a pass through the §6 loop):**

1. **Marketing (static)** — first, *because* it's the minimal end-to-end proof of
   the pipeline: publish → release → serve → custom domain → front TLS → ACME. If
   `https://rewindjs.com` serves, the platform is real. (Contact-info capture is
   **deferred**; V1 is static. When decided, it becomes a handler + a `kv` write —
   the moment marketing stops being pure-static and exercises the handler path
   too.)
2. **Admin + the auth/OIDC tenant** — mostly exists (the admin instance
   auto-creates at boot, §10); needed to operate + provision the rest from a UI
   instead of curl.
3. **Docs** — bigger (content + example player), no new infra.
4. **Cluster-manager UI** — last, because `/_control/*` is already drivable by
   curl/CLI, so the fleet is operable without the UI from day one. Convenience,
   not a launch blocker.
```
