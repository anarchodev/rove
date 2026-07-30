# Deployment & logs

> 🟢 **As-built reference.** How customer code is published and loaded, how
> static assets are served, and how request logs reach a queryable store. Owns
> the publish path (now the worker's `/_system/deploy`), the worker's
> deployment loader (`src/js/deployment_cache.zig` + siblings), `src/blob/`,
> and `src/log_server/`. Neither path goes through raft for bytes — both ride
> the shared content-addressed store / S3. Why: [decisions.md §7](../decisions.md)
> (the customer-logs vs operator-signals split) and §11 (deployment/logs
> storage decisions).
>
> ⚠️ **Update (2026-06-15): files-server dissolved.** The separate
> `files-server-v2` publisher binary is **gone** — compile + content-address +
> stamp-manifest now run **in the worker** on a background `DeployThread`
> behind `POST /_system/deploy` (sibling to `/_system/release`). The mechanism
> below (compile → content-addressed blobs → manifest in the per-tenant
> `deployments/` backend → `_deploy/current` flip) is unchanged; only the
> *host* moved from a standalone binary into the worker. Where this doc says
> "files-server", read "the worker's `/_system/deploy`". See
> [cli-and-deploy.md §4](cli-and-deploy.md) for the why + the design.

## The shape in one paragraph

Publishing is **cluster-free**: `files-server-v2` compiles a deployment, writes
its blobs and a content-addressed manifest to S3, and a *separate* release step
writes one `_deploy/current` pointer through raft (envelope 0). Workers are pure
**consumers** — they apply the pointer, then load the manifest + bytecode from
the shared store, sharing identical bytecode across tenants by content hash, and
serve static assets from a **bounded in-memory LRU** (cold miss → stream from
the tenant's file-blobs), never buffering MB-sized bytes on the dispatch thread.
Request logs bypass raft entirely: each node writes one interleaved, per-record-
deflated S3 batch per flush, and a standalone `log-server` indexes them into
SQLite for query.

## Code map

| File | Role |
|---|---|
| `src/files_server/main.zig` | The `files-server-v2` binary — cluster-free publisher (no raft of its own). |
| `src/files_server/root.zig`, `bootstrap.zig` | Deploy/upload/list routes; the `__admin__` bootstrap (S3 PUTs + release). |
| `src/files/manifest_json.zig` | Manifest codec + `computeDeploymentId(entries)` (content-addressed u64 = sha256 prefix). |
| `src/files/app_manifest.zig` | Bundle-root `manifest.json` validator (name+version required; inert capability grants validated at deploy). |
| `src/blob/backend.zig`, `s3.zig` | `BlobBackend` vtable + `openPerTenant` factory; `S3BlobStore` (libcurl, SigV4, presigned URLs). |
| `src/js/deployment_cache.zig` | `TenantSlot`, the immutable refcounted `TenantFilesSnapshot`, the manifest-diff loader. |
| `src/js/bytecode_cache.zig` | Process-wide, content-addressed (sha256), refcounted bytecode leases — cross-tenant sharing. |
| `src/js/deployment_loader.zig` | The loader thread: manifest diff → acquire/fetch bytecode blobs. |
| `src/js/response_builder.zig` | Static-asset serving: friendly-path lookup (`tryServeStatic`), ETag/304, LRU-hit inline vs `stream_static` on miss; `emitStaticRedirect` (301 trailing-slash canon only). |
| `src/js/static_cache.zig` | Process-wide byte-capped LRU keyed by content hash (`REWIND_STATIC_CACHE_MB`, default 256; 0 = off); prewarmed on the loader thread. |
| `src/js/builtin_modules/static.mjs` | The `__system/static` builtin — streams a static blob from the tenant's file-blobs on the fetch thread when the LRU misses. |
| `src/js/worker_dispatch.zig` | `/_system/release` → writes `_deploy/current` (envelope 0). |
| `src/log/root.zig`, `src/js/worker_log.zig` | Worker-side per-node log buffer + flush + push-notify. |
| `src/log_server/*` | Standalone log-server: `flush_writer` (encode), `sidecar`, `indexer`, `index_db` (SQLite), `standalone` (query API). |

## Deploy publish flow

1. **Compile + upload** — `files-server-v2` compiles the bundle to bytecode and
   PUTs each blob to `{prefix}{tenant}/file-blobs/{hash}` (content-addressed,
   immutable).
2. **Deploy** — it assembles the manifest and PUTs
   `{prefix}{tenant}/deployments/{dep_id}.json` with `If-None-Match: *`
   (lexicographic dep_id = chronological). It returns the `dep_id`; it does
   **not** touch the release marker.
3. **Release** (a separate, approval-gated step) — `POST worker/_system/release
   {tenant, dep_id}` writes `_deploy/current` to the tenant KV and proposes it
   via **envelope 0**. The apply path detects the marker and enqueues the loader.

This deploy/release split is what keeps deploys approval-gated (`_deploy/current`
is the flip) — see [decisions.md §11](../decisions.md).

## Content-addressed deployment & snapshots

- **`computeDeploymentId`** truncates `sha256(canonical sorted entries)` to a
  u64 (stored as 16-char hex) — same content → same id, cross-process.
- **`TenantFilesSnapshot`** is immutable and refcounted: bytecodes, source
  hashes, statics, triggers, subscriptions, manifest bytes. A request retains it
  at dispatch and releases at dispatch end; a reload atomically swaps the slot
  pointer and drops the slot's reference, so the old snapshot frees only when the
  last in-flight request releases it (no mutate-in-place).
- **`BytecodeCache`** is process-wide and content-addressed, so identical
  bytecode is shared across tenants and across deployments. A reload reuses the
  unchanged blobs and fetches only what changed — `O(changed files)`.
### Static asset serving (non-blocking, immutable, content-addressed)

Served from a bounded in-memory LRU; the dispatch thread only ever touches
memory or hands off a stream — it never issues a synchronous S3 read. (This
superseded both the original "302 to a presigned S3 URL" — the per-request
signature defeats content-addressed caching — and an interim blocking inline
`get()`.)

- **The LRU** (`static_cache.zig`) is process-wide and byte-capped
  (`REWIND_STATIC_CACHE_MB`, default 256; `0` disables it), keyed by content
  hash. Content-addressing makes entries immutable (no invalidation) and
  dedupes across tenants and deployments. v1 read path copies bytes into the
  per-request allocator under the lock (no refcount/lifetime machinery; the
  copy is memory-only).
- **Prewarm at deploy time** — `reloadDeployment` (the loader thread, off the
  dispatch loop) builds a `statics_by_hash` index on the snapshot and prewarms
  each static blob's bytes into the LRU via a *synchronous* blob get (blocking
  is fine there); oversized assets are skipped and fall back to streaming.
- **Serving** (`tryServeStatic`): friendly-path resolution (`/app.js`, `/` →
  `index.html`, `.html` suffix, directory index, 301 trailing-slash canon via
  `emitStaticRedirect`). Every static — **including `text/html`** — is served
  at its stable, *mutable* friendly path with a strong ETag (= content hash)
  and `Cache-Control: public, max-age=0, must-revalidate`, so revalidation is
  a cheap 304. **No 302 to a hashed URL**: a redirect would rebase a document's
  origin *and* an ES module's base URL, breaking relative imports (`./api.js`).
  - **LRU hit** → serve inline (pure memory copy, never blocks).
  - **LRU miss** (cold / evicted / oversized) → `stream_static`: stream the
    blob from the tenant's own file-blobs via the engine-fired `__system/static`
    builtin, whose fetch runs on the FetchPool thread — never a redirect, never
    a blocking read on the dispatch thread.
- **Immutable `/_assets/{hash}`** is a reserved route serving a
  content-addressed blob with `public, max-age=31536000, immutable` — permanent
  caching with no revalidation, available for publish-time ref-rewriting or a
  Cloudflare edge layer (pure upside; the immutability is already in the
  headers). Only `kind=static` blobs are served this way; bytecode, logs,
  tapes, and request bodies never enter this path.

See [decisions.md §11](../decisions.md) for the storage-origin-vs-worker-RAM
decision this rests on.

## BlobStore backends & S3 layout

The backend is process-wide (`BLOB_BACKEND=fs|s3`). `openPerTenant(cfg, id,
subdir)` scopes every per-tenant store to `{key_prefix_base}{id}/{subdir}/`,
mirroring the on-disk layout so leader and followers hit identical keys:

- `…/{tenant}/file-blobs/{sha256}` — bytecode + statics (immutable).
- `…/{tenant}/deployments/{dep_id}.json` — manifests.
- `…/_logs/{node_id}/{batch_id}.ndjson` — log batches (cluster-scoped, **not**
  per-tenant — see below).

Raft replicates only the manifest *pointer* (`_deploy/current`, and the per-file
`file/{path}` → `{hash, kind, content_type}`), never the bytes (consensus-and-
storage's blob-replication rule).

### Storage namespace

`key_prefix_base` scopes a bucket to a *deployment* (staging vs prod). The
**storage namespace** scopes it to one *lifetime* of that deployment, and those
are different things.

Most keys above are named by an id that counts up from state inside a tenant's
`app.db` — `_log/next_request_seq` for request ids, the deployment sequence for
`deployments/{dep_id}.json`. A cold bring-up wipes `~/.rove/data`, so those
counters restart at zero. The object store is deliberately **not** wiped
alongside it: S3 has no delete-by-prefix (deleting means LIST + DeleteObjects
over every key), and the blobs are the deployed code. A cluster that came up
into the un-namespaced store would therefore re-issue ids over keys a previous
lifetime already wrote, and its records would be adopted into that older
history — the log index would drop each colliding record silently, because it
is keyed `(tenant_id, request_id)` and written `INSERT OR IGNORE`.

So each lifetime gets a generation:

- The marker is one object at `{key_prefix_base}_namespace`, deliberately
  OUTSIDE the segment it names so it survives every bump. `_certs/{host}` (the
  certificate mirror, [auth-and-domains.md](auth-and-domains.md)) sits beside it
  and outside generations for the same reason: a certificate outlives the
  cluster lifetime that requested it. Its body is the
  generation: a decimal count, or empty for the original un-segmented layout.
- Every store hangs off `{key_prefix_base}{generation}/`, applied once at
  startup — file-blobs, log-blobs, deployments and the body pool move
  together, because they are one key space and splitting them would strand a
  tenant's blobs from its manifests.
- Content-addressed keys (`file-blobs/{sha256}`) don't need this and don't
  suffer from it; a repeat there is a match, not a collision. It is the
  id-keyed prefixes that require the generation.

`rewind-ops storage-namespace` reads it (`--show`, the default), claims an
existing un-namespaced store as generation 0 (`--adopt`), or moves to the next
generation (`--bump`). A cold bring-up bumps; nothing is deleted, and the
previous generation stays readable for forensics while the new cluster simply
cannot see it.

**Every service refuses to start against a store with no marker.** A missing
marker means the store's generation is unknown, and the failure mode of
guessing is invisible: two lifetimes merged into one key space, with every
health counter green. `scripts/smoke/storage_namespace_smoke_v2.py` runs two
lifetimes over one store and asserts both halves — that the second lifetime's
records are lost without a bump, and kept with one.

## Logs

- **Worker-side buffer** (`src/log/root.zig`): one in-memory buffer per node
  across all tenants (each record carries its own `tenant_id`). Flush on 1024
  records / 1 MiB / 1 s, leader-gated.
- **Batch encoding** (`flush_writer.zig`): one S3 object per node per flush —
  `[u32 sidecar_size][sidecar JSON][per-record raw-deflate frames]`. Per-record
  deflate (via **libz**, `windowBits=-15`; the Zig stdlib flate is incomplete)
  lets a single click-through decompress one record with one range-GET. One PUT
  per flush regardless of tenant count — the per-node interleaved layout collapses
  what would be `O(active tenants)` PUTs to one (see decisions.md §11).
- **Indexer** (`src/log_server/indexer.zig`): **one log-server per node**, each
  an independent COMPLETE replica — it polls the shared S3 store (LIST → head
  range-GET the sidecar → `INSERT OR IGNORE` into its own local SQLite), so every
  node can answer a query for any tenant's logs. It binds the node's
  **private-plane IP** `:8444` (not loopback), so peer nodes' workers can reach
  it — firewalled to the node IPs, same isolation as the raft/CP ports.
- **Push fan-out** (`worker_log.zig` → `POST /v1/_internal/batch-pushed`,
  services-JWT): a batch indexed by-key immediately, closing the S3 LIST
  eventual-consistency window. Because a log query can land on **any** node's
  `__admin__` leader → its LOCAL indexer, each worker fans out every flushed
  batch key to **all** nodes' log-servers (`REWIND_LOG_PUSH_BASES`, a list;
  unset → the single local base). The push carries only the S3 object keys (~62 B
  each, ≤1024/POST), never record bytes — the records are already in the batch
  object the flusher PUT; a target does one direct GET per key. A per-target
  failure is soft: that node's LIST poll is the catch-up. Polling is the
  fallback for every node regardless.
- **Query** (`standalone.zig`): `list` is answered from the SQLite index (no S3);
  `show/{request_id}` range-GETs the one record's frame and inflates it. Logs are
  the customer-facing replay store (page-encrypted at rest); operator signals go
  to Grafana Cloud — the two-sink split is decisions.md §7.

### Promotion-time LogRecord recovery (the walker)

The flush above is best-effort *early visibility*: it drains the RAM buffer to S3
**unordered against raft commit**. A leader that dies between proposing a
writeset and flushing loses those buffered records from RAM — the followers hold
the replicated entries (KV state is safe) but no `LogRecord` ever reaches S3, so
the request would vanish from the customer's logs. The **promotion walker** closes
that window.

- **Invariant.** A request whose **writes persist** has a log record that survives
  failover; read-only requests are best-effort (a pre-flush crash may drop them).
  This falls out of the mechanism: the walker rebuilds only from raft entries, and
  an entry exists iff a writeset committed — so a read-only or pre-quorum-crash
  request has nothing to walk.
- **Mechanism** (`src/js/worker_upload_walker.zig` + `src/js/log_walker.zig`): on a
  follower→leader edge (the `Bridge.drainPromotions` promotion signal, drained by
  `runPromotionHook`), the new leader walks its group's live log
  `[firstIndex .. lastIndex]`, bounded `WALKER_BATCH_CAP` entries per poll tick
  (each read is a pump control op, so the cap bounds pump contention). Each entry's
  readset carries a trailing `LogHeader` (`src/tape/root.zig`) precisely so any
  node can rebuild the customer `LogRecord` from the entry alone; the rebuilt
  records append to the normal flush buffer.
- **Resume derives from the live log, not a durable mark.** A node-local checkpoint
  can't say how far a *different* dead leader's flusher got, so there is none —
  correctness rests on the indexer's idempotent `(tenant_id, request_id)`
  `INSERT OR IGNORE` (a re-derived record the dead leader had already flushed is a
  harmless duplicate) plus the compaction-window bound (flush lag ≪ compaction
  lag, so the live log always still holds anything unflushed). `firstIndex` is the
  first uncompacted index, exposed through `Bridge.firstIndex` → `Node.firstIndex`
  → raft-rs `raft_manager_first_index`.
- **Faithful replay needs the input in the raft copy.** A writing *resume* hop
  (`send_callback` / `wake` / `fetch_chunk` / `ws`) tapes its activation Msg into
  the readset (`ctx`/Msg → `trigger_payload`, fetch event → `fetch_responses`)
  **before** the propose serializes it, so the walker rebuilds a replay-faithful
  record — not just the log line. (The stamp-before-propose ordering is the same
  discipline `resumeIntoStream` already followed via `StreamResumeCtx.tapes`.)

## Known limitations (as-built)

- **No log retention/GC compactor** yet (design locked, operator-policy default
  for now); same for an orphan-batch janitor.
- **`TenantSlot` has no live refcount** — dropping a tenant mid-flight is restart-
  required (a Phase-5 follow-up).
- **`BytecodeCache` has no eviction policy / memory cap** — deferred until
  measured at scale.
- **The log index is a single SQLite file** (cluster-scoped); sharding by
  `hash(tenant) % N` is a future lever, and the indexer full-scans each poll
  (a per-node `start-after` cursor is the obvious optimization).
- **Walker fidelity gap for `wake_batch` / `ws_message`** — their activation Msg
  (the `wakes[]` fired-watch bag; the WS frame) rides `activation_bytes`, which is
  NOT one of the five readset channels, so it reaches only the flushed S3 copy, not
  the raft entry. A walker-recovered writing wake/ws hop replays with its `ctx` but
  without `request.activation.wakes` / `.data` (issue #199). Survival of the log
  line is unaffected — the `LogHeader` rides raft regardless.
