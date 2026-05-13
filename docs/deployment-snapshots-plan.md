# Deployment snapshots — process-shared, content-addressed, refcount-pinned

This document plans the refactor of the worker's deployment state
(`TenantFiles` + `DeploymentLoader`) from per-worker-thread duplication
to one process-shared, refcounted, content-addressed model.

It collapses four currently-separate concerns into one mechanism:

1. **Per-worker bytecode duplication.** Today every worker thread on a
   node holds its own `tenant_files_map`. 4 workers × 1k tenants ×
   ~10kb bytecode/tenant = ~40MB wasted per node.
2. **Per-worker reload fan-out race.** A `/_system/release` POST goes
   to one worker via SO_REUSEPORT; only that worker's loader reloads.
   Subsequent requests load-balanced to peer workers find
   `current_deployment_id == 0` and 503. See `main.zig:346-350` — the
   existing "Multi-worker fan-out is a follow-up" comment. Every
   smoke that talks to `__admin__` after platform bootstrap trips this.
3. **Per-release redundant fetches.** A typical release changes one
   or two files; the rest of the bytecode is byte-identical to the
   previous deployment. Today each worker re-fetches the whole new
   manifest's bytecodes on every release.
4. **Mid-request version coherence.** `reloadDeployment` free-then-
   replaces the bytecodes map in place
   (`worker.zig:1870-1881`). The dispatcher holds pointers into that
   map for the duration of the request; an `import("foo")` after a
   reload could see a new map. The race window is short (handlers are
   ms) but real.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          NodeState (one per process)                │
│  ┌─────────────────────┐  ┌──────────────────────────────────┐      │
│  │ TenantSlotMap       │  │ BytecodeCache (content-addressed) │      │
│  │   tenant_id → Slot  │  │   sha256_hex → *BlobBytes (refct) │      │
│  └─────────────────────┘  └──────────────────────────────────┘      │
│  ┌─────────────────────────────────────────────────────────┐        │
│  │ DeploymentLoader (single thread, owns the fetch queue)  │        │
│  └─────────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────────┘
                              ▲
                              │ borrowed by-pointer
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
   Worker thread 0      Worker thread 1      Worker thread N
   (h2 dispatch)        (h2 dispatch)        (h2 dispatch)
```

### TenantSlot

One per tenant per process. Owns the per-tenant connections (kv,
blob, manifest backends). Holds the atomic pointer to the current
`*TenantFilesSnapshot`.

```zig
pub const TenantSlot = struct {
    instance_id:       []const u8,            // owned
    app_kv:            *kv_mod.KvStore,       // borrowed (cluster's)
    blob_backend:      blob_mod.BlobBackend,  // owned (bytecode + source bytes)
    manifest_backend:  blob_mod.BlobBackend,  // owned (per-deployment manifest JSON)
    current:           std.atomic.Value(?*TenantFilesSnapshot),  // null until first ready

    /// Cold-start prefetched manifest bytes (production.md #1.4).
    /// Consumed by the loader on first reload to skip an HTTP hop.
    prefetched_manifest: ?PrefetchedManifest,
};
```

### TenantFilesSnapshot

Immutable. Refcounted. One per *deployment version currently referenced*.

```zig
pub const TenantFilesSnapshot = struct {
    deployment_id:   u64,
    bytecodes:       std.StringHashMapUnmanaged(*BlobBytes),  // path → blob lease
    source_hashes:   std.StringHashMapUnmanaged([64]u8),
    statics:         std.StringHashMapUnmanaged(StaticEntry),
    triggers:        []TriggerEntry,
    manifest_bytes:  []u8,                                     // raw manifest JSON
    refcount:        std.atomic.Value(u32),                    // starts at 1
    allocator:       std.mem.Allocator,

    pub fn retain(self: *TenantFilesSnapshot) void {
        _ = self.refcount.fetchAdd(1, .acquire);
    }

    pub fn release(self: *TenantFilesSnapshot, cache: *BytecodeCache) void {
        if (self.refcount.fetchSub(1, .release) == 1) {
            // last reference: drop blob leases, free maps + manifest, destroy.
            ...
        }
    }
};
```

Bytecode entries are *`*BlobBytes`* (lease), not `[]u8`. Each entry
holds a refcount on the underlying content-addressed blob. Snapshot
deinit drops every lease; the BytecodeCache frees blobs whose
refcount hits zero.

### BytecodeCache (content-addressed)

Process-wide. Keyed by 64-char hex sha256.

```zig
pub const BlobBytes = struct {
    bytes: []u8,
    refcount: std.atomic.Value(u32),
};

pub const BytecodeCache = struct {
    allocator: std.mem.Allocator,
    mutex:     std.Thread.Mutex,
    by_hash:   std.StringHashMapUnmanaged(*BlobBytes),

    /// Try to acquire a lease on an already-cached blob.
    /// Returns null if not cached; caller fetches + inserts.
    pub fn acquire(self: *BytecodeCache, hash_hex: []const u8) ?*BlobBytes;

    /// Insert a freshly-fetched blob with refcount=1.
    pub fn insert(self: *BytecodeCache, hash_hex: []const u8, bytes: []u8) !*BlobBytes;

    /// Drop a lease. If refcount hits 0, removes the entry and frees the blob.
    pub fn release(self: *BytecodeCache, blob: *BlobBytes, hash_hex: []const u8) void;
};
```

Cross-tenant sharing: if 200 tenants all use the same
`loop46-sdk-base.js` bytecode, that's one blob in memory regardless
of tenant count. Same for any common starter / framework bytecode.

### DeploymentLoader

Single thread per process. Same general shape as today
(`deployment_loader.zig`), but the load function operates against the
NodeState's slot+cache instead of a single worker's TenantFiles. Key
algorithm change is **manifest diffing**:

```
On `_deploy/current → N+1` for tenant T:

1. Look up slot[T]. If slot.current is not null, capture
   old = slot.current.load(.acquire).  Read its bytecode_hash set.
2. Fetch manifest N+1 (via slot.manifest_backend).
3. Decode manifest entries. For each entry (path, bc_hash, src_hash, ...):
     a. If cache.acquire(bc_hash) returns blob, reuse — no fetch.
        (Either old snapshot already had it, or another tenant did.)
     b. Else fetch bytes via slot.blob_backend, then cache.insert.
        Schedule fetches in parallel (libcurl Easy pool already supports
        concurrent gets) but build the snapshot serially as fetches
        complete.
4. When the snapshot is fully built (all bytecode leases held),
   atomicStore(slot.current, new_snap, .release).
5. If old != null: old.release(cache) — drops one ref. Old snapshot
   frees once all in-flight requests using it complete.

On prefetch failure (any blob fetch error):
- Discard the partial new snapshot (drop leases acquired so far).
- Log + leave slot.current untouched.
- Do not retry automatically. Next release attempt re-enqueues; the
  customer can also re-POST /_system/release.
```

Per-release work is O(changed files). A typical release that touches
one file does one blob fetch and ~M hashmap operations where M is
the deployment's file count. Manifest fetch is one HTTP hop; that's
the floor.

### Per-request snapshot pinning

The dispatcher captures the snapshot at request entry, refcounts it,
and threads `*TenantFilesSnapshot` through the dispatch path. Every
bytecode lookup, every static fetch, every trigger walk consults the
same pinned snapshot. The request sees deployment N completely, or
N+1 completely, never a mix.

```zig
// At request entry, before any handler / kv / module work:
const snap = slot.current.load(.acquire) orelse {
    return respond503("no deployment for this tenant");
};
snap.retain();
defer snap.release(node.bytecode_cache);

// Carry snap through the dispatch path:
//   dispatcher.run(..., snap, ...)
//   findBytecode(snap, path) → ?*BlobBytes
//   trigger walk uses snap.triggers
//   static fetch uses snap.statics
```

The release happens after raft drain too — so for write requests
parked on `raft_pending`, the snapshot stays alive until the
response moves to `response_in` (bounded by `commit_wait_timeout_ns`).

## Migration phases

### Phase 1 — Hoist state into NodeState — **shipped 2026-05-13** (`9d75950`)

Refactor without changing semantics. Created `NodeState` owned by
`main.zig`; moved `tenant_files_map`, `tenant_logs`,
`deployment_loader`, and the schedules-store/loader-publish plumbing
in. Each `Worker` gets `*NodeState` instead of its own copies.

All workers share one `TenantFiles` per tenant. The fan-out race is
gone (single loader, single map). Mid-request coherence not yet
fixed — `reloadDeployment` still mutated in place at this point.

### Phase 2 — Refcounted immutable snapshots — **shipped 2026-05-13** (`78b2910`)

Introduced `TenantFilesSnapshot` (immutable, refcounted) +
`TenantSlot` (persistent: instance_id, blob backends, atomic
pointer to current snapshot). `reloadDeployment` builds a fresh
snapshot outside `pin_lock`, atomic-swaps under it, releases the
old after unlock so pinned in-flight readers stay valid.

Three latent loader bugs surfaced + got fixed in the same commit
(found by the Python smoke rewrite):

  - `deploymentLoadFnNode` lazy-opens the slot for runtime-created
    tenants. Without this, apply.zig's `_deploy/current` enqueue
    fires before any request has hit the new tenant, the slot
    lookup returns null, and the enqueue gets dropped.
  - `deployStarterTrampoline` enqueues the loader after commit
    (belt-and-braces with apply.zig).
  - `handleRelease` idempotent fast-path enqueues the loader on
    dep_id match. Sequential local counters collide between the
    seed's offline bootstrap and files-server's runtime PUTs (both
    mint dep_id=1 against a fresh S3 prefix); without this the
    worker keeps serving the seed's empty manifest.

Also dropped the loader thunk's `currentDeploymentId == dep_id`
short-circuit and `reloadDeployment`'s cached-manifest-bytes path
— same content-vs-counter mismatch.

#### Follow-up: content-addressed dep_id (commit `70c32c6`)

After phase 2 landed, the three loader workarounds got removed by
fixing the root cause: dep_ids are no longer sequential local
counters. `files_mod.manifest_json.computeDeploymentId(entries)`
takes the first 8 bytes of sha-256 over the canonical (sorted-by-
path, NUL-separated) entries representation. Same content → same
id, deterministically, across processes. The loader's short-circuit
is back (and now sound); `handleRelease`'s fast-path keeps the
defensive loader-enqueue as belt-and-braces.

Wire format change: manifest's `deployment_id` JSON field is a
16-char hex string (was a number) so high-bit-set hashes don't trip
std.json's i64 `.integer` variant. Log-record sidecar parser accepts
both `.integer` and `.number_string`. SQLite log index uses
`@bitCast` for the u64 ↔ i64 reinterpret.

Release order: a separate per-tenant `_release/{ts_ms:020}` →
`{id:016x}` side table records the chronological sequence of
releases, written through raft alongside `_deploy/current` in the
same `/_system/release` envelope. Decouples chronology from id so
the dashboard's Deploys tab can still list newest-first.

Snapshot construction in phase 2 *still re-fetches every bytecode*.
That's a regression vs phase 1 (which reused the in-memory map). The
phase 3 cache restores reuse and goes beyond it.

### Phase 3 — Content-addressed BytecodeCache

Replace `TenantFilesSnapshot.bytecodes` value type from `[]u8` to
`*BlobBytes`. Add the process-wide `BytecodeCache`. Loader diffs the
new manifest's hashes against what the cache already holds; only
fetches the misses.

Storage and bandwidth become O(changed files). Cross-tenant blob
sharing falls out for free.

### Phase 4 — Same model for sources and statics

`source_hashes` already keys by content hash; the source-blob fetch
that QuickJS's module loader uses on cache miss can go through the
same `BytecodeCache` (rename to `BlobCache` at this point). Statics
too. After this phase, every byte payload the worker holds in memory
is shared via the cache.

(`source_hashes` themselves are 64-byte fixed-size keys; the
`StringHashMapUnmanaged([64]u8)` stays. Only the SOURCE BYTES move
into the cache.)

## Edge cases + decisions

### Reload during in-flight request

Request A starts at deployment N (retains `snap_N`). Mid-handler,
deployment N+1 arrives, prefetch completes, slot swaps to `snap_N+1`.
`snap_N`'s refcount drops by 1 (the slot's reference); A still holds
its retain so `snap_N` stays alive. Request B starts after the swap,
retains `snap_N+1`. Both run their full module-resolution paths
against their own pinned snapshot. When A completes, `snap_N`'s
refcount hits 0 and it's freed.

Memory ceiling per tenant: number of deployment versions currently
in-flight. In steady state: 1. Under heavy releases overlapping with
long-running requests: 2 or 3.

### Failed prefetch

Loader returns `Error.PrefetchFailed`. `slot.current` is unchanged;
all in-flight requests continue on the old snapshot. Operator sees
a log line. Next release attempt will retry from scratch.

No automatic retry on the loader side — releases are explicit
operator actions; a failed release shouldn't blast retries at S3.

### Tenant drop mid-flight

`platform.instances.drop(t)` writes a tombstone to `__root__`; the
slot needs to deinit. Treat like a tenant going from "has snapshot"
to "no snapshot": atomicStore(slot.current, null). New requests get
503. In-flight requests keep their retained snapshot until they
finish, then the snapshot frees normally. The slot itself can deinit
only after the last retainer drops, so the slot needs its own
refcount too. (Phase 5 follow-up; until then, tenant drop is a
restart-required operation.)

### Cache memory pressure

`BytecodeCache` size is bounded by the union of bytecodes across all
live snapshots. There's no explicit max-bytes cap and no eviction
sweep — blobs free when refcount hits zero, which happens when no
snapshot references them. Under normal release rhythm: cache size ≈
unique-bytecodes-in-active-deployments. If that grows past memory
budget, that's an operator-visible signal (too many tenants × too
much bytecode per tenant for this node's RAM). Eviction sweep is a
future concern; defer until we see the pressure.

### Snapshot construction failure mode

Mid-construction, one of the bytecode fetches fails. We've already
acquired N-1 leases on already-cached blobs and downloaded K blobs
that succeeded. The partial snapshot must be torn down without
leaking those leases. The build path uses an errdefer that walks the
in-progress snapshot's entries and `cache.release`s each.

### Cross-process: kvexp MDB_NOLOCK

The kvexp manifest is opened with MDB_NOLOCK. Only one process
reads/writes the file at a time. The loader's manifest fetches go
through `manifest_backend` (S3 or fs blob), not through kvexp, so
the loader thread doesn't contend with workers' kv reads.

### Refcount overflow

`std.atomic.Value(u32)` — 4 billion concurrent retainers. Per-request
+1 means we'd need 4B in-flight requests on the same snapshot to
overflow. Not a concern. Document the assumption + assert in debug.

### Test coverage

- Phase 1: existing smokes (which all hit the per-worker race today)
  should go from FAIL → PASS on the cluster-wide release path.
  Specifically: `ctl`, `triggers`, `signup`, `admin`, `cookie_auth`,
  `notifications`, `rate_limit`, `replay`, `static`.
- Phase 2: unit test for snapshot pinning across a simulated reload
  (start request A, fire reload, verify A sees old bytecode for its
  imports; new request B sees new bytecode).
- Phase 3: unit test that an unchanged-file release fetches zero
  bytes (mock the blob backend, count gets).
- Phase 4: unit test that two tenants with the same source/bytecode
  hash share one blob (cache.acquire returns the same `*BlobBytes`).

## Out of scope

- Sharing the QuickJS *compiled function* objects across requests.
  The bytecode bytes get re-deserialized into each request's arena
  by `JS_ReadObject` — that's per-context and intentionally so
  (arenas reset between requests). Sharing the parsed function trees
  would require pinning a QuickJS context across requests, which
  conflicts with arenajs's per-request reset model.
- Eviction policy when the cache grows past a memory budget. See the
  "cache memory pressure" note above; defer until measured.
- Snapshot prefetch parallelism beyond what libcurl's `EasyPool`
  already provides. The blob fetches are I/O-bound; current pool
  concurrency is sufficient.
- Moving `tenant_logs` into NodeState. It's a candidate (the
  `RequestIdMinter` could be process-shared) but the data model is
  different (per-tenant counter, not deployment state). Address
  separately if there's a similar duplication concern.

## Related docs

- `docs/PLAN.md` §2.4 — deployment surface
- `docs/files-server-plan.md` — where bytecode + manifest blobs live
- `docs/production.md` #1.4 — cold-start manifest prefetch
