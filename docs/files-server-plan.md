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
- **Atomic deployment switch is a single S3 object overwrite** of
  `tenants/{id}/deployments/current.json`. Worker polls; on change,
  loads the new manifest + bytecodes.
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
                  │   tenants/{id}/deployments/current.json     │
                  └─────────────────────────────────────────────┘
                                             ▲
                                             │ poll current.json (5s)
                                             │ GET on change: manifest + new blobs
                                             │
                                    ┌────────┴─────────┐
                                    │     worker       │
                                    │ (per-tenant      │
                                    │  TenantFiles     │
                                    │  cache, no       │
                                    │  files.db, no    │
                                    │  proxy)          │
                                    └────────┬─────────┘
                                             │ HTTPS
                                             ▼
                                    ┌─────────────────┐
                                    │ end-user browser│
                                    └─────────────────┘
```

S3 is the **only** coupling point between worker and files-server.
Worker doesn't know the files-server exists; files-server doesn't
know which workers are running. Both can be killed and restarted at
will. (Same invariant we adopted for logs in
`docs/logs-plan.md`.)

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
tenants/{tenant_id}/deployments/current.json            ← atomic pointer
```

- `blobs/` is the existing `BlobBackend.openPerTenant` layout when
  `BLOB_BACKEND=s3`. Keys are content-addressed; immutable; never
  rewritten. No change.
- `deployments/{dep_id:020d}.json` — one JSON file per deployment.
  Lexicographic sort = chronological. Listing the prefix gives
  deployment history.
- `deployments/current.json` — single small file with the active
  deployment_id + integrity hash. Overwritten on each deploy.

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

### 3.3 `deployments/current.json` shape

```json
{
  "v": 1,
  "deployment_id": 42,
  "manifest_key": "tenants/acme/deployments/00000000000000000042.json",
  "manifest_sha256": "abc...",
  "switched_at_ms": 1730764800000
}
```

Tiny (~200 bytes). Worker GETs this on every poll; the polling cost
is one HEAD-equivalent per tenant per polling interval.

### 3.4 Atomic switch

S3's strong read-after-write consistency (default since 2020-12 on AWS,
default on OVH and R2) makes the swap atomic from the worker's
perspective: a single PUT replaces `current.json` in one shot. Workers
that GET *before* the PUT see the old manifest; workers that GET
*after* see the new. No partial state visible.

For multi-step protection against a torn deploy (files-server crashes
between writing `deployments/{dep_id}.json` and overwriting
`current.json`): the manifest is uploaded **first**, then `current.json`
is flipped. A crash mid-way leaves an unreferenced manifest in
`deployments/`. Janitor pass collects them.

For protection against concurrent deploys racing on `current.json`:
S3's `If-Match: <etag>` conditional PUT (supported by AWS, OVH,
Cloudflare R2, MinIO; documented as "S3 conditional writes") lets
files-server CAS the swap. Two concurrent `POST /deploy` calls
serialize: the loser sees the etag mismatch and either retries or
returns 409. This replaces today's `expected_parent_id` CAS that runs
against `files.db`.

---

## 4. Worker load path

### 4.1 Polling

Each worker, per cached tenant, on its existing `refreshDeployments`
tick (default 2s):

```
1. GET tenants/{id}/deployments/current.json
2. parse → {deployment_id, manifest_key, manifest_sha256}
3. if deployment_id == cached.deployment_id: done (no work)
4. GET manifest_key
5. verify sha256(manifest_bytes) == manifest_sha256 (else log + skip)
6. parse manifest → {files map}
7. for each new bytecode_hash not in cache: GET tenants/{id}/blobs/{hash}
8. atomically promote new manifest + bytecode cache
9. update cached.deployment_id
```

Step 1 is the hot path: one small GET per tenant per 2s. With S3
charging per-request rather than per-byte, this is the dominant cost.
A 5s interval with 1000 active tenants per node = 200 GETs/s/node;
meaningful but well under any operator's budget. The interval is
configurable; can also gate by tenant activity (only poll tenants
with traffic).

Step 7 is amortized: a new deployment typically reuses 90%+ of the
previous deployment's bytecodes (only the changed handler files have
new hashes). Bytecode cache hit rate stays high across deploys.

### 4.2 What goes away on the worker

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
- `deployStarterContent` (replaced by direct-to-S3 bootstrap; see §6).

### 4.3 What stays

- The in-memory `bytecodes` map keyed by deployment path.
- The `statics` map (path → {hash, content_type}). Bytes still fetched
  on demand, just from S3 directly instead of via blob_backend.
- The `triggers` array (derived from manifest entries matching
  `_triggers/.../index.{mjs,js}`).
- `refreshDeployments` poll loop (rewired to GET S3 instead of
  reading files.db).
- Source-hashes map for tape replay.

The shape of `TenantFiles` shrinks; the lifecycle stays.

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

### 6.2 Writes manifest + current to S3

The existing `deployManifest` / `putFileAndDeploy` / `deploy` paths in
`src/files_server/root.zig` change in one spot: instead of writing
manifest rows to `files.db` + proposing through raft, they write
`tenants/{id}/deployments/{dep_id}.json` to S3 then CAS-overwrite
`tenants/{id}/deployments/current.json`. The blob PUTs (already going
to S3 in s3 mode) are unchanged.

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
After this change: `bootstrapHandler` becomes a direct-to-S3
function:

```
1. for each embedded file:
     compute sha256 of bytes
     PUT tenants/__admin__/blobs/{sha256}     ← idempotent if already present
2. build manifest JSON referencing the hashes
3. PUT tenants/__admin__/deployments/00000000000000000001.json
4. PUT tenants/__admin__/deployments/current.json (deployment_id=1)
```

No QuickJS compilation in bootstrap (admin handler bytecode is
embedded in the binary alongside the source — same as today, just
the storage destination changes).

`loop46 seed` does the same for manifest-driven tenants.

Bootstrap can be **idempotent**: if `current.json` already exists and
points at the embedded admin handler's hash, skip. Allows safe
restart without re-uploading.

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

The cleanup ripples through `loop46/main.zig` (drops `code_addr`
plumbing through `WorkerCtx`), `files_server/thread.zig` (TLS config
+ public listener), and the proxy module if no other subsystem
remains using it.

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
