# Deployment & logs

> 🟢 **As-built reference.** How customer code is published and loaded, how
> static assets are served, and how request logs reach a queryable store. Owns
> the `files-server-v2` publisher, the worker's deployment loader (`src/js/
> deployment_cache.zig` + siblings), `src/blob/`, and `src/log_server/`. Neither
> path goes through raft for bytes — both ride the shared content-addressed
> store / S3. Why: [decisions.md §7](../decisions.md) (the customer-logs vs
> operator-signals split) and §11 (deployment/logs storage decisions).

## The shape in one paragraph

Publishing is **cluster-free**: `files-server-v2` compiles a deployment, writes
its blobs and a content-addressed manifest to S3, and a *separate* release step
writes one `_deploy/current` pointer through raft (envelope 0). Workers are pure
**consumers** — they apply the pointer, then load the manifest + bytecode from
the shared store, sharing identical bytecode across tenants by content hash, and
**302-redirect** static assets to presigned S3 instead of buffering them.
Request logs bypass raft entirely: each node writes one interleaved, per-record-
deflated S3 batch per flush, and a standalone `log-server` indexes them into
SQLite for query.

## Code map

| File | Role |
|---|---|
| `examples/files_server_v2.zig` | The `files-server-v2` binary — cluster-free publisher (no raft of its own). |
| `src/files_server/root.zig`, `bootstrap.zig` | Deploy/upload/list routes; the `__admin__` bootstrap (S3 PUTs + release). |
| `src/files/manifest_json.zig` | Manifest codec + `computeDeploymentId(entries)` (content-addressed u64 = sha256 prefix). |
| `src/files/app_manifest.zig` | Bundle-root `manifest.json` validator (name+version required; inert capability grants validated at deploy). |
| `src/blob/backend.zig`, `s3.zig` | `BlobBackend` vtable + `openPerTenant` factory; `S3BlobStore` (libcurl, SigV4, presigned URLs). |
| `src/js/deployment_cache.zig` | `TenantSlot`, the immutable refcounted `TenantFilesSnapshot`, the manifest-diff loader. |
| `src/js/bytecode_cache.zig` | Process-wide, content-addressed (sha256), refcounted bytecode leases — cross-tenant sharing. |
| `src/js/deployment_loader.zig` | The loader thread: manifest diff → acquire/fetch bytecode blobs. |
| `src/js/response_builder.zig` | Static-asset 302 to a presigned S3 URL. |
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
- **Static assets** are served as a **302** to a presigned S3 URL (`ETag: <hash>`,
  `Cache-Control`, 304 on `If-None-Match`). The worker never buffers MB-sized
  asset bytes; the browser (and the CDN edge) fetches from S3 directly. This was
  a deliberate pivot away from worker-RAM caching — see [decisions.md §11](../decisions.md).

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
- **Indexer** (`src/log_server/indexer.zig`): a standalone process polls S3
  (LIST → head range-GET the sidecar → `INSERT OR IGNORE` into SQLite). A worker
  **push** (`POST /v1/_internal/batch-pushed`, services-JWT) indexes a batch
  by-key immediately, closing the S3 LIST eventual-consistency window; polling is
  the catch-up fallback.
- **Query** (`standalone.zig`): `list` is answered from the SQLite index (no S3);
  `show/{request_id}` range-GETs the one record's frame and inflates it. Logs are
  the customer-facing replay store (page-encrypted at rest); operator signals go
  to Grafana Cloud — the two-sink split is decisions.md §7.

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
