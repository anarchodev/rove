# rewind CLI — tenant operations, design plan

Status: **proposal, 2026-06-15.** No code yet. This doc proposes a Zig
`rewind` operator CLI to replace `scripts/publish_tenant.py` and the
hand-run curl that surrounds it, and names the server-side seam the CLI
should eventually consolidate onto.

## 0. The problem

"Deploy" today means two unrelated things, and only one of them is in
good shape:

| | Platform binaries | Tenant content |
|---|---|---|
| What ships | `rewind` / `rewind-cp` / `rewind-front` | a tenant's handler bundle + statics |
| Driver | `scripts/deploy.sh` (the `/deploy` skill) | `scripts/publish_tenant.py` (the `/publish` skill) |
| Cadence | rare (engine changes) | every site/handler edit |
| Reaches | the 3 hosts over SSH + systemctl | S3 + CP + a worker over the private plane |

`deploy.sh` is mature: build → test gate → rolling one-host-at-a-time
restart (cp → worker → front) with health/leader probes between each,
aborting if a node fails to rejoin quorum. **It stays as-is.** It is
infra orchestration, not a tenant operation, and a CLI should not absorb
it.

The tenant-content path is the ad-hoc half. `publish_tenant.py` welds
four conceptually-separate operations into one Python script driven by
optional flags, and reaches four different binaries on three planes with
five different secrets, entirely via hand-rolled `curl` (much of it
tunneled over SSH because the targets are private-plane only).

### What `publish_tenant.py` does today (the welded operations)

1. **Classify** the bundle locally — duplicates `classify()` in
   `src/files_server/bootstrap.zig`; can silently drift.
2. **Provision** (`--provision`): `POST {cp}/_control/provision` with
   `X-Rewind-Move-Secret`, over SSH.
3. **Compile**: spawn a local `files-server-v2` against prod S3, then
   `POST /{tenant}/upload` per handler → `POST /{tenant}/deploy`.
4. **Statics**: `PUT /{tenant}/blobs/{sha}` per asset (content-addressed).
5. **Manifest**: read back the authoritative compiled manifest, keep only
   this bundle's entries (dodging the carry-forward trap), then
   `POST /{tenant}/deployments`.
6. **Release flip**: `POST {worker}/_system/release` with
   `REWIND_ROOT_TOKEN`, over SSH + h2-prior-knowledge, with a 6× round-robin
   leader-aware retry across all workers.
7. **Custom host** (`--host`): two calls with two different secrets — CP
   `/_control/host` (`REWIND_MOVE_SECRET`) **and** worker
   `/ops/assign-domain` (`ADMIN_OPS_SECRET`).
8. **Verify** (`--verify-host`): `GET https://host/` expects 200.

### Why it reads as ad-hoc

- **Five secrets** in one env file, each gating a different endpoint on a
  different binary: `LOOP46_SERVICES_JWT_SECRET`, `REWIND_ROOT_TOKEN`,
  `REWIND_MOVE_SECRET`, `ADMIN_OPS_SECRET`, S3/AWS keys.
- **Everything is curl-over-SSH** — there is no single front-facing admin
  API; the script reaches *through* a host into the private plane.
- **Classification logic duplicated** from Zig in Python.
- **Four operations, one mega-script** with optional flags, rather than
  composable commands.
- The deeper cause: **the server side never consolidated.** The script is
  ad-hoc because the surface it talks to is.

## 1. Decisions taken (2026-06-15)

- **Language: Zig.** A subcommand in the existing tree, reusing the jwt
  minting, the bundle classifier (kills the Python/Zig drift), and the
  `rove-blob` env reader. Ships as one binary, no Python in the operator
  path — consistent with "no dev-only features" and "adding Zig in `src/`
  is fine when it's the prod path, not a primitives smell."
- **Scope: plan only, for review.** This doc. No code until signed off.
- Open: whether the CLI is a *thin wrapper* over today's exact calls or
  whether it lands together with a *consolidated admin API* (§4). The
  recommendation below is to ship thin first, then consolidate.

## 2. Proposed command surface

One binary, `rewind` (operator-facing; distinct from the `rewind` worker —
see §6 naming note). Subcommands map to the *actual operations*, not to
one flagged megacall:

```
rewind provision <tenant> [--cluster prod] [--host H ...]
rewind publish   <tenant> <bundle> [--release] [--verify-host H]
rewind release   <tenant> <dep_id>
rewind rollback  <tenant>                 # release the parent of current
rewind host add  <host> <tenant>
rewind host rm   <host>
rewind status    <tenant>                 # placement, current dep_id, host maps
rewind deployments <tenant>               # list deployment ids + parents
```

Design notes:

- **`publish` defaults to NOT releasing.** It compiles, uploads, stamps a
  manifest, and prints the `dep_id` — then stops. `--release` (or a
  separate `rewind release`) flips it live. This makes the
  approval-gated-deploy stance (`_deploy/current` stays human-gated) the
  default behavior, not an honor system. Today's script always releases.
- **`provision` and `publish` are separate verbs**, not a `--provision`
  flag on publish. First-time bring-up is
  `rewind provision X && rewind publish X ./bundle --release`.
- **`rollback` becomes a first-class verb.** The deployment manifest
  already carries `parent_id`; releasing the parent is a rollback. Today
  there is no rollback path at all.
- **`status` / `deployments` are new** read surfaces — there is no way to
  ask "what's live for this tenant?" today without reading raft/S3 by hand.

## 3. Phase A — thin CLI (no server changes)

Port the exact existing calls, 1:1, into the Zig binary. Same endpoints,
same secrets, same SSH-tunnel reachability. This is mechanical and removes
the script sprawl + the classification drift immediately.

Pieces:

- **Config:** read the operator env file (`~/.config/rove/prod.env`,
  legacy `.env.prod`) via the existing `rove-blob` env reader plus a small
  loader for the `ROVE_*` operator vars. Same file `publish_tenant.py`
  reads, so no migration.
- **Bundle classifier:** call `classify()` in
  `src/files_server/bootstrap.zig` directly instead of reimplementing it.
  This is the single biggest correctness win of going Zig — one source of
  truth for what is a handler vs a static vs skipped.
- **JWT mint:** reuse `rove-jwt` (HS256) — the Python side mints with
  `LOOP46_SERVICES_JWT_SECRET`; same code path in Zig.
- **HTTP:** the calls are small JSON/byte POSTs. Either reuse the existing
  Zig HTTP client used elsewhere, or — to preserve the private-plane
  reachability exactly — keep the **SSH-tunnel transport** by shelling
  `ssh <host> curl ...` the way the script does. Phase A keeps SSH; Phase B
  removes it (§4). Decide per-endpoint: the local `files-server-v2` spawn
  is loopback (no SSH); CP + worker calls are SSH-tunneled.
- **`files-server-v2` spawn:** *fallback only.* If rewind-files is stood up
  first (§4 — the recommended next work), the CLI targets that standing
  endpoint directly and skips the local spawn + the S3 creds on the client
  box. The spawn-locally path stays documented only for the interim before
  the service unit lands.
- **Release retry:** keep the 6× round-robin leader-aware retry loop;
  transient 503/421 while group leadership settles is normal.

Phase A is a faithful, typed, single-binary replacement for the script
(plus rollback/status). But its value is gated on §4: with rewind-files
standing, the CLI is a thin client of two services; without it, the CLI
still has to spawn-and-curl. **So §4 comes first** — it's the next work,
because it unlocks the client.

## 4. Root cause + fix — dissolve files-server into the worker

The deploy path is ad-hoc because **the build/stage service isn't deployed**,
and the reason it was a separate binary at all turns out to be historical, not
architectural. `files-server-v2` does two things: **content-addressed blob
storage** + a **QuickJS compiler**. Both already exist inside the worker.

### Why files-server is redundant

- **Compile is the only irreducible-native bit, and the worker already has
  it.** Source→bytecode is `Context.compileToBytecode` (`src/qjs/root.zig:193`,
  `JS_Eval(COMPILE_ONLY)`→`JS_WriteObject`) — a privileged engine op, *not*
  expressible from sandboxed JS, and nothing compile-shaped is exposed to
  handlers. The worker links `rove-qjs` and wires a `QjsCompiler` straight into
  `Worker.create` (`src/rewind/main.zig:63,221`) — a near-duplicate of
  files-server's own (`src/files_server/bootstrap.zig:292`). The compiler is
  already running in the worker.
- **Storage is the `blob.*` primitive.** Sources, bytecode, statics, manifests
  are all content-addressed blobs (sha256 key, per-tenant `{tenant}/…` prefix,
  same S3 `BlobBackend` files-server uses). Customers already get this surface.
- **The worker is the same stack.** It links `rove-blob` + `rove-files`
  (`build.zig:1092,1096`) — the same backend + FileStore files-server uses.
  files-server is a *second copy* of machinery the worker carries.

### Why this dodges the cross-tenant problem (the key move)

The one thing `blob.*` deliberately does **not** allow is cross-tenant writes
(no `platform.root` blob path; isolation enforced by S3 prefix + SigV4 — the
audited core). So a *centralized* "admin pushes into every tenant's namespace"
deploy would need that hole punched. **But deploy doesn't need it if it runs
in-tenant:** scoped to the *target* tenant, deploy writes the tenant's **own**
blobs — exactly what `blob.*` already supports. So the blob primitive needs
**zero extension**; the reach that looked necessary (cross-tenant) is the part
to avoid, and in-tenant execution sidesteps it.

### The shape: a per-tenant `/_system/deploy` on the worker

Add a worker system endpoint, sibling to the existing `/_system/release`:

```
client / website ──▶ rewind-worker /_system/deploy   # BUILD/STAGE (in-tenant)
                       compile (worker's own engine, OFF the poll loop)
                       write bytecode + statics → this tenant's own blobs
                       stamp manifest → tenant's deployments/
                     → returns dep_id

client ──────────▶ rewind-worker /_system/release    # ACTIVATE (raft, gated)
```

Both are per-tenant worker system endpoints under the **same** gating
(root/services token) — `files-server-v2` and its separate
`LOOP46_SERVICES_JWT_SECRET` trust domain are **deleted**. The build/stage vs.
release split stays (build is cheap/in-tenant; release is raft + gated).

### Against the two goals

- **Simpler** — zero new binaries, zero new services, files-server deleted, one
  fewer process holding prod S3 creds. (This supersedes the earlier draft's
  "stand up rewind-files as a 4th service" — there's no binary to stand up.)
- **Auth easy to manage** — deploy + release are two endpoints on the worker
  under the per-tenant gating you already run; the bespoke files-server secret
  disappears. One auth model, on the tenant.

### Honest caveats (constraints, not blockers)

1. **Compile moves onto the data plane** — files-server isolated it in its own
   process; in the worker it **must run off the poll loop** (a worker thread),
   per `front_door_never_blocks_loop`, or it stalls serving. The engine's
   already instantiated; this is scheduling discipline.
2. **Confirm the worker's current `compile_fn` usage** (boot bundles for system
   tenants? on-demand?) so `/_system/deploy` reuses that plumbing rather than
   duplicating it.
3. **Source ingest target moves** from files-server to `/_system/deploy` (same
   client shape, different host). The CLI/website push there.
4. **Manifest/load path is unchanged** — in-tenant deploy writes bytecode to
   the same per-tenant `file-blobs/` the deployment loader already reads, and
   the cross-module-import compile (the worker resolves the bundle's other
   sources at compile time) carries over from files-server's existing path.

### Next work

Not "deploy rewind-files" — **add `/_system/deploy` to the worker and delete
files-server.** Bigger than a config change, smaller than it sounds (every
piece exists in the worker). The thin CLI (§3) then points at two worker
endpoints (`/_system/deploy`, `/_system/release`) + CP for provision/host,
and the `files-server-v2 → rewind-files` rename is **moot** (no binary).

Open question deferred to implementation: whether `/_system/deploy` is reached
only on the **private plane** (operator + first-party website via the internal
front) or also **publicly** (external customer tooling) — the same trust call
as the eventual customer CLI; private-plane-only is the safe launch default.

## 5. `/ops/assign-domain` — resolved (and why `host add` is two writes)

`POST {worker}/ops/assign-domain` (`publish_tenant.py:292`) is **live, not
dead** — it is not a Zig route. It is a handler route in
`web/admin_interim/index.mjs:39`, a rewind.js app deployed to the
`__admin__` tenant (hence the call carries `Host: {admin_host}`). It is:

- bearer-gated by `OPS_SECRET`, baked into the bundle at deploy time
  (= `ADMIN_OPS_SECRET` in the operator env; handlers can't read process
  env, so it's stamped in), and
- does `platform.root.set("domain/${host}", tenant)` — a `root_writeset`
  replicated through raft. The worker's host resolver consults these
  `domain/{host}` aliases for any host that isn't `{tenant}.{public suffix}`.
- explicitly **interim**: its own comment says the full dashboard
  (`web/admin/`, an OIDC relying party) replaces it once the `__auth__` IdP
  tenant lands (deploy-plan §11).

The architecturally important part: a custom host needs **two writes to two
different stores**, and they are not redundant —

1. CP `/_control/host` → the **directory raft** (front-door host→cluster
   routing — which cluster owns the host), and
2. worker `/ops/assign-domain` → the per-platform **`domain/{host}`
   root_writeset** (the worker's host→tenant resolver — which tenant on that
   cluster serves the host).

That is the real reason `host add` is two calls today. It is also a concrete
thing **Phase B's consolidated `host add` would hide behind one CP
endpoint** (CP does both writes, fanning the second to the admin tenant /
worker internally). One caveat for Phase B: the worker-side write currently
flows through the `__admin__` JS app, so consolidation either keeps that hop
(CP → admin handler) or promotes `domain/{host}` writes to a first-class CP
path — a decision to make when the dashboard replaces `admin_interim`.

## 6. Naming — rename the worker, free `rewind` for the client

The worker binary is `rewind` today, which collides with naming a client
CLI `rewind`. **Decision: rename the worker binary `rewind` →
`rewind-worker` and reserve the command name `rewind` for the
customer/developer CLI.** Three reasons:

1. **It fixes an existing asymmetry.** The systemd units already name the
   worker `rewind-worker.service`, but its `ExecStart` runs the binary
   `rewind` (`scripts/systemd/v2/rewind-worker.service:22`), while the
   siblings match (`rewind-cp.service`→`rewind-cp`,
   `rewind-front.service`→`rewind-front`). Renaming makes all three
   binary==unit. Net cleanup independent of the CLI.
2. **The brand name belongs to the tool humans type.** The worker is a
   systemd-launched daemon nobody invokes by hand. A customer/developer
   `rewind` CLI ships in v1 anyway (`project_ai_integration_shape`:
   "MCP + cross-platform CLI ship together in v1") — so `rewind` the
   *command* should be reserved for that (the `vercel`/`wrangler`/`fly`
   slot).
3. **Keep daemon and CLI as separate binaries — do not multi-call.** A
   single `rewind serve` (daemon) vs `rewind publish` (client) binary
   would drag the worker's raft-rs/cargo FFI consensus closure onto
   operator/developer laptops and couple their release lifecycles. Two
   binaries.

Consequence for this plan: the operator commands here become a
credential-gated **`rewind admin <verb>`** namespace on the one `rewind`
CLI (one tool to install; gating is by operator secret + CP endpoint,
§4) — *not* a separate `rewindctl`. The customer-facing verbs and the
operator `admin` namespace share a binary but are gated by credential.

**Blast radius of the worker rename** (bounded, mechanical; pre-launch, no
back-compat — `feedback_no_prelaunch_backcompat`):

- `build.zig:1101-1102` — exe `.name` + the `b.step("rewind", …)` build step
- `scripts/systemd/v2/rewind-worker.service:22` ExecStart + the README table
- `scripts/smoke_lib_v2.py:45` — `REWIND = BIN_DIR / "rewind"`
- `scripts/deploy.sh` — the `BINS=(rewind …)` array entry + push loop (the
  `systemctl restart rewind-worker.service` line is already correct)
- docs: `CLAUDE.md`, `PLAN.md` §13, `v2-production-deploy-plan.md` §2.1; a
  few memory lines

## 7. Out of scope

- **Binary deploys** (`deploy.sh` / `/deploy`) — unchanged.
- **Runtime cluster management** (no `addCluster` endpoint exists yet;
  separate gap) — not addressed here.
- **Customer-facing deploy** — this is an *operator* CLI for first-party
  tenants and ops. A customer-facing publish surface is a later, separate
  product question.
