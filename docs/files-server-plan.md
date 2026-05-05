# Files-server plan — own subdomain, S3 manifest, worker as read-only consumer

This document expands `docs/PLAN.md` §2.4 (File API + static serving)
into an implementable plan that **fully decouples the worker from the
files-server**. Stays unchanged from §2.4: routing resolution rules,
path validation, content-type / cache header semantics, size caps.
This doc is about the *coupling between worker and files-server* and
the *storage shape that makes them independent*.

The motivating framing: today the worker hairpin-proxies every
upload/deploy through `/_system/files/*` to the files-server thread,
and the worker holds per-tenant `files.db` SQLite + an in-memory
manifest cache that mirrors the files-server's local SQLite. The two
are two replicas of the same state, kept in sync via raft envelope
type 3 + a 2s polling refresh on the worker. We want to break the
proxy entirely and reduce the worker to a pure *consumer* of files
state that lives in S3.

Stated end state:

- **Customer pushes code to a separate subdomain** (e.g.
  `files.{public_suffix}` or `api.loop46.com/files/...`). Worker
  doesn't see those requests; doesn't know files-server's address.
- **Manifest lives in S3**, not per-node SQLite. Files-server writes
  it; worker reads it. Raft envelope type 3 goes away.
- **Bytecode + statics live in S3** (already true with
  `BLOB_BACKEND=s3`). Worker reads on cache miss.
- **Deploy and release are separate steps.** Files-server writing a
  new manifest to S3 is the *deploy*. Activating it on workers is the
  *release* — an explicit `_deploy/active = {target_dep_id}` write
  through the customer's kv that rides existing raft replication.
  Workers observe the marker via the same writeset-scan path SSE
  uses (`markDirtyFromWriteset`), load the new manifest + bytecodes
  asynchronously from S3, and atomically swap the active manifest
  pointer when the load is complete. **No polling.** No new RPC
  surface between files-server and worker. No new envelope type.
- **Static files are served by the worker as a proxy with aggressive
  HTTP caching** (hash ETag + `immutable` Cache-Control). The
  "redirect to S3 URL" alternative is discussed and rejected as
  default; opt-in mode for `_static/_immutable/` is left as a future
  knob.

---

## 1. Architecture

```
┌─────────────────┐  upload/deploy  ┌──────────────────┐
│ customer / CLI  │────────────────▶│  files-server    │
│ (admin auth)    │  HTTPS          │ (own subdomain)  │
└─────────────────┘                 │                  │
                                    │ - QuickJS compile│
                                    │ - SHA + PUT blob │
                                    │ - PUT manifest   │
                                    │ - swap `current` │
                                    └────────┬─────────┘
                                             │ S3 PUTs
                                             ▼
                  ┌─────────────────────────────────────────────┐
                  │  S3 bucket                                  │
                  │   tenants/{id}/blobs/{sha256_hex}           │
                  │   tenants/{id}/deployments/{dep_id}.json    │
                  └─────────────────────────────────────────────┘
                                             ▲
                                             │ GET (on release marker)
                                             │ manifest + new blobs
                                             │
                                    ┌────────┴─────────┐
                                    │     worker       │       ┌──────────────┐
                                    │ (per-tenant      │◀──────│ raft apply   │
                                    │  TenantFiles     │ kv    │ envelope 0   │
                                    │  with active +   │ marker│ (the release │
                                    │  pending pointers│       │  signal)     │
                                    │  no files.db,    │       └──────────────┘
                                    │  no proxy)       │              ▲
                                    └────────┬─────────┘              │
                                             │ HTTPS                  │ kv.put
                                             ▼                        │ _deploy/active
                                    ┌─────────────────┐               │
                                    │ end-user browser│       ┌───────┴──────┐
                                    └─────────────────┘       │ admin call   │
                                                              │ POST .../_   │
                                                              │ admin/release│
                                                              └──────────────┘
```

Two coupling channels, neither of which involves direct
worker↔files-server RPC:

1. **S3** carries the bytes (blobs, manifests). Files-server writes;
   worker reads.
2. **Raft kv** carries the release signal (`_deploy/active`). The
   admin call writes; the worker observes via the same
   writeset-scan path SSE uses.

Worker doesn't know files-server exists. Files-server doesn't know
which workers are running. Both can be killed and restarted at will.
(Same invariant we adopted for logs in `docs/logs-plan.md`.)

---

## 2. Subdomain layout

Customer / CLI hits files-server at a dedicated origin. Two reasonable
choices:

- **`files.{public_suffix}`** — symmetric with the existing pattern
  (`app.loop46.me`, `replay.loop46.me`). Same TLS cert (wildcard or
  per-host). Files-server terminates TLS itself; no worker hairpin.
- **`api.loop46.com/v1/files/...`** — share a `api.` host with other
  control-plane endpoints later. More routing logic on the api host
  (path-based dispatch); needs an api-router that's not yet built.

V1: **`files.{public_suffix}`**. One service, one origin, one TLS
cert. The api-host idea is a future consolidation if we add more
control-plane services.

The worker's `/_system/files/*` proxy is removed. Customer admin UI
points at `files.{public_suffix}` directly. CORS is configured to
allow the admin origin (`app.{public_suffix}`).

---

## 3. Storage layout (S3)

### 3.1 Object keys

```
tenants/{tenant_id}/blobs/{sha256_hex}                  ← raw bytes
                                                          (source, bytecode, static)
tenants/{tenant_id}/deployments/{dep_id:020d}.json      ← per-deployment manifest
```

- `blobs/` is the existing `BlobBackend.openPerTenant` layout when
  `BLOB_BACKEND=s3`. Keys are content-addressed; immutable; never
  rewritten. No change.
- `deployments/{dep_id:020d}.json` — one JSON file per deployment.
  Lexicographic sort = chronological. Listing the prefix gives
  deployment history; files-server's admin UI reads it via
  `LIST tenants/{id}/deployments/` (cheap — typically a few hundred
  entries per tenant under retention).

**No `latest.json` or `current.json`.** The runtime pointer is the
kv marker (§3.5); raft replication carries it to every node.
Listing handles the operator's "what's been deployed?" question. A
separate "latest pointer" file would be a redundant source of truth
without earning its keep — see §10.6 for the tradeoffs considered.

### 3.2 `deployments/{dep_id}.json` shape

```json
{
  "v": 1,
  "deployment_id": 42,
  "created_at_ms": 1730764800000,
  "parent_id": 41,
  "comment": "fix the thing",
  "files": {
    "_static/index.html":      { "kind": "static",  "hash": "abc...", "content_type": "text/html; charset=utf-8" },
    "_static/style.css":       { "kind": "static",  "hash": "def...", "content_type": "text/css" },
    "index.mjs":               { "kind": "handler", "source_hash": "ghi...", "bytecode_hash": "jkl..." },
    "api/users.mjs":           { "kind": "handler", "source_hash": "mno...", "bytecode_hash": "pqr..." },
    "_triggers/audit/index.mjs": { "kind": "handler", "source_hash": "stu...", "bytecode_hash": "vwx..." }
  }
}
```

Self-contained: every blob the worker needs to serve this deployment
is referenced by hash. The worker can verify integrity (recompute
sha256 of fetched bytes against the manifest hash) before promoting
the new deployment.

### 3.3 Concurrent deploy protection

S3's strong read-after-write consistency (default since 2020-12 on
AWS, default on OVH and R2) makes the manifest PUT atomic.

Concurrent deploys racing for the same `dep_id` are guarded by S3's
`PUT-if-not-exists` (`If-None-Match: *`, supported by AWS, OVH,
Cloudflare R2, MinIO; documented as "S3 conditional writes").
Files-server allocates the next deployment id by listing the
`deployments/` prefix, picking max+1, and PUT-if-not-exists. On
collision (another deploy already wrote that id), it retries with
max+1 of the new listing. Bounded retry loop; in practice rare.

This replaces today's `expected_parent_id` CAS that runs against
`files.db`.

### 3.5 `_deploy/active` kv marker (the release signal)

The runtime "what should the workers run" pointer is a single key in
the customer's `app.db`:

```
key:   _deploy/active
value: {"v": 1, "target_deployment_id": 42, "set_at_ms": 1730764800000}
```

- Reserved-prefix `_deploy/` (added to `reserved.zig` alongside
  `_events/`, `_outbox/`, etc.). Customer JS cannot write it.
- Written by the admin handler in response to a `POST .../_admin/release`
  call. Replicates through raft envelope type 0 (the standard
  customer kv writeset) — same machinery as every other kv write.
- Workers observe new values via `markDirtyFromWriteset`-style scans
  on the post-commit hook (existing pattern from SSE).
- "Target" semantics: the value names the deployment_id the worker
  *should* be running. The worker's TenantFiles tracks what it's
  *currently* running (`active.deployment_id`). When target ≠ active,
  a load is in flight or queued.

The marker IS the source of truth at runtime. `latest.json` is
informational. Most of the time they match (deploy → release
immediately); they can intentionally diverge for "uploaded but not
released" workflows (canary deploys, scheduled rollouts).

---

## 4. Worker load path

### 4.1 Trigger: marker observation, not polling

Workers do not poll S3. The trigger to load a new deployment is an
observed change to `_deploy/active` in the tenant's kv. The
observation path mirrors the existing SSE pattern in
`src/js/worker_dispatch.zig` (`events_pump.markDirtyFromWriteset`):

```
1. customer admin writes _deploy/active = {target: 42}  (via admin handler)
2. writeset commits locally + proposes through raft
3. worker (every node, every worker thread): post-commit hook
   scans the just-committed writeset for keys under `_deploy/`
4. if `_deploy/active` is in the set, parse the value, compare
   target_deployment_id against TenantFiles.active.deployment_id
5. if different and no matching pending load: kick off async load
```

The hook is a 5-line scan; adds nothing measurable to commit latency.
Quiet tenants impose zero S3 cost (no kv writes → no scan → no
load). Active tenants only do S3 work when a release actually
happens.

### 4.2 Async load + atomic pointer swap

`TenantFiles` carries two manifest pointers:

```zig
const TenantFiles = struct {
    active:  *TenantManifest,     // currently serving requests
    pending: ?*PendingLoad,       // load in flight (if any)
    ...
};

const TenantManifest = struct {
    deployment_id: u64,
    bytecodes:     StringHashMap([]u8),
    statics:       StringHashMap(StaticEntry),
    triggers:      []TriggerEntry,
    source_hashes: StringHashMap([64]u8),
    refcount:      Atomic(u32),    // see §4.3
};

const PendingLoad = struct {
    target_deployment_id: u64,
    next_manifest:        ?*TenantManifest,
    progress: enum { fetching_manifest, fetching_blobs, ready, failed },
    started_ns:           i64,
};
```

Load is non-blocking. The worker spawns a one-shot OS thread (or
posts a job to a small per-worker thread pool) that:

```
1. GET tenants/{id}/deployments/{target_dep_id:020d}.json
2. parse → manifest
3. for each bytecode_hash not already in active.bytecodes:
       GET tenants/{id}/blobs/{hash}
       (parallelizable; typically only changed files)
4. allocate next_manifest, populate bytecodes / statics / triggers
5. mark pending.progress = ready, post completion to a worker queue
```

The dispatch loop continues serving against `active` for the entire
duration. On the next worker tick after `pending.progress = ready`,
the worker:

```
1. take old = TenantFiles.active
2. TenantFiles.active = pending.next_manifest
3. TenantFiles.pending = null
4. release(old)   ← refcount-aware free; see §4.3
```

The swap is a single pointer write, ordered against subsequent
dispatches by the worker's single-threaded poll loop. No requests
are blocked; no requests dispatched after the swap see the old
manifest; no requests dispatched before the swap see the new.

### 4.3 Manifest lifetime + safe free

A request dispatched against `active` may take ms to complete; if the
swap happens mid-request, the in-flight request still holds pointers
into the old manifest's `bytecodes` slice (the JS context's loaded
bytecode is borrowed, not copied). Freeing the old manifest at swap
time would dangle.

Discipline: refcount on `TenantManifest`. Each in-flight request
that resolves a bytecode takes +1 on the manifest at dispatch start;
releases on dispatch end (the existing per-request cleanup hook).
The `active` slot itself holds +1; the swap drops that reference.
The manifest is freed when refcount hits 0 — which is "no in-flight
requests still using it AND it's no longer the active." Single-
threaded refcount math is fine because the worker thread owns all
mutations.

### 4.4 Concurrent and rapid-fire releases

If a new marker arrives while `pending` is still loading:

- If `new.target == pending.target`: no-op (already loading the right
  thing).
- If `new.target != pending.target`: cancel the in-flight load (set
  a stop flag the loader thread checks between blob GETs), free
  `pending.next_manifest` if partially built, kick off a fresh load
  for the new target. Avoids spending bandwidth on bytecode for a
  superseded deployment.

Failed loads (S3 outage, manifest sha mismatch, blob not found): set
`pending.progress = failed`, log, leave `active` untouched. Next
release attempt (or a retry timer) starts a fresh load. The active
deployment keeps serving regardless.

### 4.5 Parking requests during a cold load

A request that arrives while its tenant's `active` manifest is null
(first request after worker boot, before the load completes) needs
to wait. This is the same parking-collection pattern the worker
already uses for raft (`raft_pending`) and the files / log proxies
(`code_proxy.pending`, `log_proxy.pending`).

**New collection:** `pending_deploy_load: StreamColl` — same row
type as the other parking collections so an entity preserves every
component (headers, body, session, scope) across the move in and
out.

Dispatch flow:

```
1. dispatcher pulls entity for tenant T from request_out
2. tc = getOrOpenTenantFiles(T)        ← reads kv marker, allocates TenantFiles
3. if tc.active != null: dispatch normally
4. if tc.pending == null: kick off async load against the marker's target
5. move entity from request_out → pending_deploy_load
   (no other work this tick for this entity)
```

Resume flow (on the worker tick after the loader thread posts
`pending.progress = ready`):

```
1. swap tc.active = pending.next_manifest, clear tc.pending
2. walk pending_deploy_load, for each entity whose tenant id == T,
   move it back to request_out
3. next dispatch tick picks them up against the now-loaded manifest
```

**Timeout:** the worker tick also scans `pending_deploy_load` for
entities older than `deploy_load_timeout_ns` (mirror of
`commit_wait_timeout_ns`, default 5s) and emits 503 with a
`Retry-After: 1` header. Same fate when the load explicitly fails —
the loader sets `pending.progress = failed`, the next worker tick
walks parked entities for that tenant and 503s them, then clears
`tc.pending` so the next request triggers a fresh load attempt.

The tenant id lookup for the resume walk uses the existing authority
component on each entity. Linear scan is fine at realistic backlogs
(a few hundred parked entities × a few resumed tenants per tick is
microseconds).

### 4.6 Cold start

Worker startup does **zero** S3 work for files. The kv markers
(`_deploy/active`) live in each tenant's `app.db`, which is replicated
through raft — a fresh node joining the cluster gets every tenant's
marker via raft state transfer; a hot restart re-opens the local
stores with markers already present. TenantFiles is opened lazily on
the first request per tenant (existing `getOrOpenTenantFiles`
pattern); on that open, the worker reads the in-memory marker, kicks
off the load, and parks the request per §4.5.

If a tenant has never had a release call (`_deploy/active` absent),
the worker returns 503 "no deployment yet" — the existing behavior
for fresh tenants. There is no cold-start fallback to S3 listing;
the kv marker is the only runtime pointer.

Disaster recovery (kv lost but S3 intact) is handled by a separate
one-shot `loop46 reconcile-kv-from-s3` tool that walks
`tenants/*/deployments/`, picks the highest `dep_id` per tenant, and
writes the kv marker. Run once on recovery, not in the steady-state
boot path.

### 4.7 Bytecode cache hit rate

A new deployment typically reuses 90%+ of the previous deployment's
bytecodes (only the changed handler files have new hashes). The
loader's "GET only blobs not already in active.bytecodes" rule keeps
the fetch list small. A typical release loads only 1-3 new blobs.

### 4.8 What goes away on the worker

- `TenantFiles.files_kv: *kv_mod.KvStore` (the per-tenant `files.db`
  handle).
- Worker's `blob_mod.BlobBackend` for *file blobs* — replaced by direct
  S3 GETs from a per-worker `std.http.Client` pool. (Note: rove-blob's
  `BlobBackend` stays in use for log payload reads on the indexer
  side; it's the worker's coupling to it that goes away.)
- `files_mod.FileStore` instantiation in `openTenantFiles`.
- The `/_system/files/*` proxy subsystem (`code_proxy` field on
  Worker, `code_addr` config, `connectProxies` / `flushProxyPending`
  / `drainProxyResponses` for the code subsystem).
- `proposeFilesWriteSet` and the entire envelope type 3 path.
- `deployStarterContent` (replaced by direct-to-S3 bootstrap; see §7).
- `refreshDeployments` polling phase + `next_refresh_ns` timer field
  on `TenantFiles`. The marker-scan path replaces it entirely.

### 4.9 What stays / what's added

- The in-memory `bytecodes` map keyed by deployment path (now living
  on `TenantManifest`, not `TenantFiles` directly).
- The `statics` map. Bytes still fetched on demand, from S3 directly.
- The `triggers` array (derived from manifest entries matching
  `_triggers/.../index.{mjs,js}`).
- Source-hashes map for tape replay.
- **New:** `TenantFiles.{active, pending}` pointer pair for the
  atomic-swap model.
- **New:** `markDirtyFromWriteset` extension that scans for
  `_deploy/active` keys (alongside the existing `_events/` scan).
- **New:** Per-worker loader (one-shot threads or small pool) for
  async manifest + bytecode fetches.
- **New:** `pending_deploy_load: StreamColl` — parking collection
  for requests that arrived during a cold load (§4.5). Same shape
  and lifecycle as `raft_pending`.
- **New:** `deploy_load_timeout_ns` config (mirror of
  `commit_wait_timeout_ns`, default 5s) for parked-request
  expiration.

The shape of `TenantFiles` changes more than it shrinks.

---

## 5. Static file serving

### 5.1 Default: worker proxies, browser caches forever

Worker handles `GET /<path>`, looks up `_static/<path>` in the
manifest, GETs `tenants/{id}/blobs/{hash}` from S3, streams bytes back
with:

```
Content-Type:  <from manifest>
ETag:          "<hash>"            ← content hash
Cache-Control: public, max-age=600, must-revalidate
```

Or for files explicitly under `_static/_immutable/`:

```
Cache-Control: public, max-age=31536000, immutable
```

Because the URL is content-addressed (well, the *bytes* are; the URL
is `/foo.png`), the ETag is stable across identical content but
changes when the customer redeploys. After the first hit per browser:

- Within `max-age`: served from browser cache, zero network round
  trip.
- After `max-age`: browser sends `If-None-Match: <hash>`; worker
  matches against current manifest hash; returns `304 Not Modified`
  with no body.

A 304 is a few hundred bytes of headers; the worker doesn't fetch
from S3 to answer it. So worker bandwidth becomes "first hit per
browser per redeploy" only.

Cloudflare in front of `/_static/*` (PLAN §2.4) handles the cold-cache
case across browsers — most static fetches never reach the worker
at all.

### 5.2 The "redirect to S3 URL" alternative — analyzed, deferred

Considered: instead of the worker proxying the bytes, return a 307
redirect to a public S3 URL.

Pros:
- Worker carries zero static bytes after the first manifest GET.
- Same model as image CDNs (S3 with public bucket → direct browser
  GET).

Cons (the reasons it's not the default):
1. **Bucket exposure.** S3 URL leaks bucket name + key prefix layout.
   For a multi-tenant bucket where prefix = tenant id, this leaks
   the customer's instance id structure to anyone who watches the
   redirect chain.
2. **Cookies stripped on cross-origin redirect.** A static asset that
   needs the platform session cookie (rare but real — e.g.,
   `__Host-rove_sid` on a script that calls back into the worker)
   loses it on the hop. Same-origin proxy preserves it.
3. **Custom domains.** PLAN §2.10 ships custom domains
   (`acme.com/logo.png`). Redirecting customer traffic to
   `s3.foo.com/...` is a UX regression; visible in DevTools, breaks
   per-domain CSP, breaks "everything served from one origin"
   simplicity.
4. **CSP / SRI / SubresourceIntegrity.** Many SPAs lock origins via
   CSP; a redirect to a third-party origin requires the customer to
   add that origin to their CSP, which they can't easily do per-asset.
5. **Private buckets.** rove's S3 bucket is private (no anonymous
   reads — keys are SigV4-signed). Public-read mode would weaken the
   security posture significantly. Pre-signed URLs work but expire
   (TTL'd; can't cache forever) and add CPU per request to sign.
6. **3xx-followers.** Some HTTP clients (older mobile SDKs, some
   server-side fetchers) don't follow 3xx automatically. Same-origin
   200 is more universally supported.

Verdict: not the default. The proxy-with-aggressive-caching model
gives you 90% of the bandwidth savings (after first hit, browser
caches forever) without the failure modes.

**Opt-in mode** for the future: a per-deployment manifest flag
`{"static_serve": "redirect"}` that switches the worker's static
handler to issue 307s to pre-signed S3 URLs (with a 1-hour TTL,
Cache-Control aligned to TTL). Useful for huge customer-facing assets
where bandwidth dominates and the customer has explicitly chosen
public-URL exposure. Deferred until a customer needs it.

### 5.3 Range requests for large statics

For statics > a threshold (say 1 MiB), proxy with `Range` passthrough:
worker accepts `Range: bytes=0-1023`, forwards to S3, streams the
range. Avoids buffering the whole file. (The 1 MiB cap in PLAN §2.4
keeps this from being a v1 issue; relevant if the cap ever lifts.)

---

## 6. Files-server changes

### 6.1 Drops the worker proxy interface

Today: files-server runs as a thread on each worker process, listening
on a loopback port that the worker proxies to. After this change:
files-server runs as its own process (or its own thread but with a
public-internet-facing TLS listener), terminating TLS for
`files.{public_suffix}`.

The existing `files_server.thread.spawn` keeps its shape but binds
to the public listen address instead of an ephemeral loopback port.
Same h2 server, same handlers; just different network exposure +
TLS config.

### 6.2 Writes manifest to S3

The existing `deployManifest` / `putFileAndDeploy` / `deploy` paths in
`src/files_server/root.zig` change in one spot: instead of writing
manifest rows to `files.db` + proposing through raft, they write
`tenants/{id}/deployments/{dep_id:020d}.json` to S3 with
`If-None-Match: *` (PUT-if-not-exists). On 412 (collision), increment
`dep_id` and retry. The blob PUTs (already going to S3 in s3 mode)
are unchanged.

Files-server returns the new `deployment_id` to the caller. **It does
NOT touch the kv release marker.** The release is a separate,
explicit step performed by the caller (admin UI, CI tool, or an
automated post-deploy hook), via `POST {tenant}/_admin/release` —
which is just a kv write through the customer's admin handler.

This split is intentional. Deploy and release have different
authorization boundaries (deploy = "I can write code for this
tenant"; release = "I can change what users see right now"), different
audit semantics, and naturally support workflows like "upload now,
release later" or "release a specific older deployment." Coupling
them with an automatic release-on-upload would prevent both.

For the common case where the customer wants both in one step, the
CLI does both calls back-to-back. The convenience composition lives
in the CLI, not in files-server.

### 6.3 Files-server keeps a small local SQLite for its own state

Even with the manifest in S3, files-server benefits from a local
SQLite for:

- Idempotency of deploy attempts (same client retry doesn't double-
  deploy).
- Per-deploy job state (compile-in-progress, errors).
- A mirror cache of the manifest for faster reads back to the admin
  UI (avoids a round-trip to S3 on `GET /list`).

This is files-server's *internal* state, not replicated, not consumed
by the worker. If lost, files-server reconstructs from the S3
listing on next startup.

### 6.4 Authentication

Today: `/_system/files/*` is gated by the worker's admin auth (root
token via `Authorization: Bearer`). After the move, files-server
authenticates directly:

- **Root token** (existing) for operator + admin UI.
- **Per-instance deploy tokens** (future, PLAN §2.2 says deferred):
  scoped tokens issued to a specific instance, allowing CI systems
  to deploy without holding the root token.

V1: root-token-only, same as today. Just enforced at files-server's
own listener instead of the worker's proxy.

---

## 7. Bootstrap

Today: `loop46 worker` calls `bootstrapHandler` which writes
admin/replay manifests + blobs through `FileStore` (SQLite-backed).
After this change, bootstrap is a deploy-then-release sequence
performed directly against S3 + the root kv:

```
1. for each embedded file:
     compute sha256 of bytes
     PUT tenants/__admin__/blobs/{sha256}     ← idempotent if already present
2. build manifest JSON referencing the hashes
3. PUT tenants/__admin__/deployments/00000000000000000001.json
   with If-None-Match: * (skip if already exists)
4. write _deploy/active = {target: 1} into __admin__'s app.db
   (this rides through the regular kv path so workers observe it)
```

Steps 1-3 are the deploy. Step 4 is the release. Same split as
the customer-facing flow.

No QuickJS compilation in bootstrap (admin handler bytecode is
embedded in the binary alongside the source — same as today, just
the storage destination changes).

`loop46 seed` does the same for manifest-driven tenants.

Bootstrap is **idempotent**: each step is a no-op when the target
state already matches (PUT-if-not-exists for the manifest; kv marker
write is a no-op when the value is unchanged). Allows safe restart
without re-uploading or re-releasing.

---

## 8. What gets removed

After this lands:

- `TenantFiles.files_kv` field + per-tenant `files.db` files on disk.
- Worker's `code_proxy: ProxySubsystem` + `code_addr` config field.
- `connectProxies` / `ingestProxyConnects` / `flushProxyPending` /
  `drainProxyResponses` for the code subsystem (the proxy primitives
  themselves stay if other subsystems use them, but the wiring for
  files goes).
- `/_system/files/*` route handling in worker_dispatch.
- Envelope type 3 (`files_writeset`) in `apply.zig`, including
  `applyFilesWriteSet` and the follower-side `getFilesKv` /
  `files_stores` cache.
- `proposeFilesWriteSet` in raft_propose.
- Files-server's `thread.spawn` loopback-binding mode (replaced by
  public-listener mode).
- `refreshDeployments` polling phase + `next_refresh_ns` /
  `refresh_interval_ns` config / fields. Replaced by
  marker-observation in the post-commit hook.

The cleanup ripples through `loop46/main.zig` (drops `code_addr` and
`refresh_interval_ms` plumbing through `WorkerCtx`),
`files_server/thread.zig` (TLS config + public listener), and the
proxy module if no other subsystem remains using it.

---

## 9. Migration order

Same staging philosophy as `logs-plan.md`: each step shippable +
smoke-testable on its own.

1. **Add S3 manifest layer to files-server** behind a config flag
   (`files.manifest_backend = sqlite | s3`). Default stays `sqlite`.
   files-server writes both stores in parallel for safety; reads
   prefer SQLite.
2. **Add S3 manifest read path to worker** behind a flag
   (`files.read_from = sqlite | s3`). Default stays `sqlite`. When
   `s3`, worker polls `current.json` and loads from S3; ignores
   `files.db`.
3. **Switch worker's read default to `s3`** in dev. Verify smokes
   (files_server_smoke, ctl_smoke) end-to-end.
4. **Switch files-server's authoritative store to `s3`** — drop
   the parallel SQLite write. SQLite now serves as files-server's
   internal idempotency cache only.
5. **Move files-server to its own subdomain.** Public TLS listener,
   admin UI repointed at `files.{public_suffix}`. Worker's
   `/_system/files/*` proxy stays as a bridge for unmoved CLI
   clients during transition.
6. **Remove the proxy.** Worker no longer accepts `/_system/files/*`.
   CLI clients all moved to `files.{public_suffix}`.
7. **Remove envelope type 3, files.db, files-server's loopback mode.**
   Final cleanup.

Smokes after each step:

- `files_server_smoke.sh` — exercises compile/upload/deploy/fetch.
  Should pass throughout (route may change between worker proxy and
  direct hit in step 5).
- `ctl_smoke.sh` — uses ctl's deploy path to install a handler and
  hit it. Should pass throughout.
- `s3_blob_smoke.sh` — sanity on the S3 backend. Unchanged.

---

## 10. Open questions / deferred

### 10.1 Cloudflare in front of static

PLAN §2.4 mentions "Cloudflare fronts static; edge caches decrypted
bytes." Compatible with this plan: Cloudflare sits in front of the
worker, hashes-as-ETag means edge caches behave well, the worker still
makes the auth decision on cache miss. No design change needed; ops
question only.

### 10.2 Bytecode pre-warming

Cold worker startup currently warms tenant bytecodes by walking
`files.db`. After this change: warm by walking S3
`tenants/*/deployments/current.json` for known tenants. Slower (one
GET per tenant) but parallelizable. For 1000 tenants × 50ms S3 RTT
× 16-way parallelism = ~3s startup penalty. Acceptable; can defer
to lazy-load if it becomes painful.

### 10.3 Manifest schema migration

The `v: 1` in the manifest envelope leaves room for additive changes.
Breaking changes (new required field, removed field) need a
deploy-during-migration plan: workers must be on the new code before
files-server starts writing the new shape. Standard rolling-deploy
discipline.

### 10.4 Listing deployment history

Today: `GET /_system/files/{id}/deployments` returns recent deploys
from `files.db`. After: `LIST tenants/{id}/deployments/` returns the
same set (filenames are zero-padded ids; sort gives chronology). One
LIST call; no pagination needed for typical tenant scales.

### 10.5 Static-redirect mode

Per §5.2, opt-in `{"static_serve": "redirect"}` is left for a future
customer ask. The flag lives in the manifest (per-deployment), not
the tenant config, so it can be tested by deploying with the flag
and rolled back by redeploying without it.

### 10.6 Why no `latest.json` (per-tenant or global)

Considered and rejected during planning.

**Per-tenant `tenants/{id}/deployments/latest.json`:** would only
earn its keep as a cold-start fallback when no kv marker exists. But
the kv markers replicate via raft, so a fresh node already has every
tenant's marker after raft state transfer; greenfield bootstrap
writes the marker as part of the bootstrap flow; new tenants without
a release legitimately return 503 ("no deployment yet"). The genuine
"no marker" recovery scenario is kv-loss, which is a one-shot
reconciler-tool job, not a runtime cold-path. A per-tenant
`latest.json` would just be a redundant source of truth that has to
stay in sync with the kv marker, with nothing to show for the
synchronization work.

**Global `latest.json`:** would replace N per-tenant files with one
combined file. Worse: every deploy across every tenant contends on
the same object (CAS via If-Match works for correctness but
throughput collapses at scale); the file grows unbounded with tenant
count (~200 bytes × N entries — 100k tenants = 20MB read on every
consultation); a misbehaving deploy can corrupt all tenants'
pointers at once. The contention cost alone disqualifies it.

The kv marker is the single source of truth for "what should the
worker run." Listing `tenants/{id}/deployments/` covers the
"what's been deployed" admin question.
