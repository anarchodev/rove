# raft-kv: a multi-store raft library

> **Status: SHIPPED.** Substance landed via the natural evolution of
> the kv module (2026-04 → 2026-05). Two live consumers: **loop46**
> (`src/loop46/main.zig` + `src/js/apply.zig`) drives a raft group
> servicing per-tenant `app.db` + singleton `__root__.db` with
> multi-envelope atomicity via `encodeMultiEnvelope`;
> **files-server-standalone** (`src/files_server/thread.zig` +
> `examples/files_server_standalone.zig`) drives its own raft group
> for manifest writes, using `Cluster.proposeAndWait`. Package
> renamed `rove-kv` → `raft-kv` 2026-05-27 in a build-system sweep.
>
> Original design note for the consolidation discussed 2026-05-10 in
> `docs/production.md` #1.0 + #1.4. Replaced the de facto
> "one KvStore + one raft group" framing of `rove-kv` with
> the abstraction rewind.js already uses in practice and that
> files-server adopted as the second consumer.

## Motivation

The original `rove-kv` framing was "kv store + raft group."
Reality has diverged:

- rewind.js's leader runs **one** raft group servicing **N**
  SQLite stores (per-tenant `app.db`, singleton
  `__root__.db`, singleton `schedules.db`). Routing between
  them lives in `src/js/apply.zig` — leaking rewind.js-specific
  mechanics into the rove-kv namespace.
- files-server-standalone has **no** raft group today: it
  writes manifests to S3 with no replication, no consensus,
  no DR. Its bootstrap path takes 1012s to seed 10k tenants
  (one S3 PUT per tenant). Real production blocker.

The library should expose what rewind.js already does — one
raft group, N stores, multi-envelope-per-entry atomicity —
as a clean primitive that any application can build against.
files-server is the second consumer; the two of them
together pressure the API into being honest.

## Scope of this consolidation

In:
- `Cluster` type that owns a raft group + a set of KvStores.
- Pluggable storage `Backend` (SQLite today; future
  custom in-memory-pending backend swappable in).
- Envelope registration with leader-skip flag.
- `LeaderTxn` primitive for multi-store atomic commits via
  multi-envelope-per-raft-entry.
- Snapshot tick (stamp-and-compact) operating across all
  registered stores.
- Learner peer mode (already partly landed via PeerAddr).
- Send_snapshot peer-to-peer streaming as a library
  feature.

Out:
- Application-level routing logic (which envelope hits
  which store) — applications register handlers.
- Domain-specific value encodings (e.g., schedules.db's
  StoredSchedule) — applications wrap KvStore in their own
  typed APIs.
- Wire-compat with existing on-disk shapes — pre-launch,
  clean slate is fine.

## Naming

The package becomes `raft-kv` (drop the "rove-" prefix —
it's a generic library, not a rewind.js thing). Internal
public type is `Cluster`. Existing imports of `rove-kv`
get rewritten as a separate cleanup; semantics carry over.

Note: Not done — build.zig still exports `rove-kv`; the
rename remains an optional, deferred migration step.

## API sketch

```zig
const raftkv = @import("raft-kv");

// A raft cluster + N stores. The application instantiates
// one of these per process (rewind.js has one; files-server
// has its own). Independent — they don't share consensus.
pub const Cluster = struct {
    pub const Config = struct {
        data_dir: []const u8,        // {data_dir}/raft.log.db, {data_dir}/{store_id}/...
        node_id: u32,
        peers: []const PeerAddr,     // mode = .voter / .learner
        backend: Backend,            // storage vtable; default: SqliteBackend
        // ... election timing, listener addr, etc.
    };

    pub fn init(allocator, Config) !*Cluster;
    pub fn deinit(self) void;

    // Lifecycle. Open a store the cluster will manage.
    // Idempotent: getStore returns an existing one if open.
    // The store id maps to a directory under data_dir; the
    // backend determines on-disk shape.
    pub fn openStore(self, store_id) !*Store;
    pub fn closeStore(self, store_id) void;
    pub fn getStore(self, store_id) ?*Store;

    // Envelope registration. Application declares per-type
    // apply functions at startup. Type byte 0..255; 0 reserved
    // for the library's own writeset envelope shape.
    pub const ApplyFn = *const fn (cluster: *Cluster, env: Envelope, raft_idx: u64) ApplyError!void;
    pub fn registerEnvelope(self, type_byte, .{
        .apply = ApplyFn,
        .leader_skip = bool,    // true: pre-write via TrackedTxn, apply on
                                //       leader is a no-op
                                // false: apply runs on every node
    }) void;

    // Single-envelope propose. For applications that don't need
    // multi-store atomicity.
    pub fn propose(self, payload) !u64;       // returns raft idx on commit

    // Multi-envelope wrapper. Atomically commits N inner envelopes
    // in one raft entry — same semantics as today's type-7 multi.
    pub fn proposeMulti(self, []const Envelope) !u64;

    // Multi-store leader transaction. Pre-writes to multiple stores
    // via TrackedTxn (read-your-writes inside the application's
    // request scope), then proposes a multi-envelope on commit.
    // On failure (proposal rejected, leader changed mid-commit):
    // every store's TrackedTxn.rollback() discards its kvexp
    // speculative overlay (volatile — never reached LMDB).
    pub fn beginLeaderTxn(self) !*LeaderTxn;

    // Snapshot tick. Caller invokes from the raft thread on a
    // periodic timer; library does the rest (stamp _apply_state
    // for every registered store + willemt begin/end +
    // incremental_vacuum equivalent).
    pub fn tickSnapshot(self, now_ns) !?TickResult;

    // Send-snapshot wiring (#1.1 step 3). Library handles the
    // peer-to-peer streaming; application doesn't touch it.
    // willemt's send_snapshot callback fires → library drives
    // the receive side via Backend.streamFromPeer.
};
```

## Backend interface

**Superseded by the kvexp cutover (commits f2a0d2a→ccde36c,
2026-05-13):** there is no storage vtable. `kvexp.Store`
(LMDB-backed) is wrapped by `KvStore` directly; the pluggable-
SQLite-backend abstraction below was not built.

```zig
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Open / close a store. For the SQLite backend: opens an
        // app.db file. For a future in-memory-pending backend:
        // allocates the in-memory state + opens the persistent
        // commit-log.
        openStore: *const fn (ptr, allocator, store_id, root_dir) anyerror!*Store,
        closeStore: *const fn (ptr, store: *Store) void,

        // Apply a writeset to a store. Library calls this from the
        // apply path. SQLite backend: applyEncodedWriteSet against
        // KvStore. In-memory-pending backend: append to commit log,
        // schedule batch-flush.
        applyWriteSet: *const fn (ptr, store: *Store, payload, raft_idx) anyerror!void,

        // Read _apply_state.last_applied_raft_idx. Library calls
        // this for snapshot-replay filtering.
        lastAppliedIdx: *const fn (ptr, store: *Store) anyerror!u64,

        // Stamp _apply_state.last_applied_raft_idx atomically with
        // any pending writes. Library calls during snapshot tick.
        // For SQLite: setLastAppliedRaftIdx. For in-memory-pending:
        // flush pending + persist mark.
        stampApplied: *const fn (ptr, store: *Store, idx: u64) anyerror!void,

        // Stream the store's bytes for send_snapshot / restore.
        // Ships the LMDB `cluster.kv` file whole (commit d0a63ad /
        // 39ee170), not a SQLite backup stream.
        streamForSnapshot: *const fn (ptr, store: *Store, writer) anyerror!void,
        loadFromSnapshotStream: *const fn (ptr, allocator, store_id, root_dir, reader) anyerror!*Store,
    };
};

// Default SQLite backend wraps the existing kvstore.zig.
pub const SqliteBackend = struct {
    pub fn init() Backend { ... }
};

// Future: in-memory-pending backend. Pending writes live in a
// per-store hashmap; commit-log appends are batched. On crash,
// recovery reads the commit log and rebuilds the in-memory state.
// Replaces SqliteBackend without library API changes.
pub const InMemPendingBackend = struct { ... };  // not implemented yet
```

The Backend trait is what makes the future SQLite-replacement
viable. The library's API doesn't bake in SQLite-specific
calls; everything that touches storage goes through the
vtable. Adding a new backend becomes "implement these N
functions" without touching application code.

## Envelope shape

```
[1B type][2B id_len BE][id bytes][payload]
```

Same wire format we have today. Library reserves type 0 for
"writeset against the store named by `id`" (the most common
case). Other types are application-specific. id_len = 0 is
permitted for envelopes that don't target a specific store
(the multi-envelope wrapper itself, schedule envelopes that
write to a singleton store, etc.).

## LeaderTxn

This is the multi-store generalization of today's TrackedTxn.

```zig
pub const LeaderTxn = struct {
    pub fn put(self, store_id, key, value) !void;
    pub fn delete(self, store_id, key) !void;
    pub fn proposeAndWait(self) !u64;  // builds multi-envelope, proposes,
                                       // waits for raft commit
    pub fn rollback(self) !void;       // TrackedTxn.rollback() on each touched store
};
```

Local pre-writes happen on every store the LeaderTxn touched
(via that store's backend-provided TrackedTxn equivalent).
On `proposeAndWait` success: the raft commit guarantees every
node has applied the multi-envelope atomically. On failure:
`rollback` calls `TrackedTxn.rollback()` on each touched store,
discarding its kvexp speculative overlay (volatile — the
pre-writes never reached LMDB, so a crash needs no explicit
undo either). Same crash-safety property today's single-store
TrackedTxn provides, generalized to N stores.

## Snapshot mechanics

Inherited from #1.1 (already shipped):

- `tickSnapshot`: stamp `_apply_state` to current commit_idx
  on every registered store; call willemt begin/end; library
  compacts the raft log.
- Bytes-on-disk are the snapshot — no separate VACUUM INTO,
  no S3 PUT, no manifest serialize.
- Per-pass cost: ~1ms per registered store (one
  `stampApplied` call). Bench-verified in
  `docs/snapshot-bench-results.md`.

## Send-snapshot

Inherited from #1.1 step 3 (shipped — commits dc31c1e/12f9fae/0f2935b):

- willemt `send_snapshot` callback fires → library streams
  bytes from each registered store via
  `Backend.streamForSnapshot` to the receiving peer.
- Receiver calls `Backend.loadFromSnapshotStream` to install.
- Ships the LMDB `cluster.kv` file whole (commit d0a63ad /
  39ee170), not a SQLite backup stream.

## Learner

Inherited from #1.2 step 1 (already shipped):

- `PeerAddr.mode = .voter | .learner`. Library wires through
  to `raft_add_node` vs `raft_add_non_voting_node`. willemt
  handles quorum math.

## Two consumers

**rewind.js** (the existing application):
- Stores: `__admin__/app.db`, per-tenant `app.db` (lazy-opened),
  `__root__.db`, `schedules.db`.
- Envelopes: 0 (writeset, leader_skip), 2 (root_writeset,
  leader_skip), 1 (multi), 8/9/10/11 (schedule_*).
- rewind.js's `apply.zig` shrinks to envelope-handler
  registrations + tenant lifecycle policy.

**files-server** (the new consumer):
- Stores: per-tenant `files.db` (deploy index), singleton
  `manifests.db` (or maybe per-tenant — TBD; smaller stores
  reduce raft entry size for manifest writes).
- Envelopes: 0 (manifest writeset), maybe 1 (deploy commit
  with content-hash+manifest atomically).
- Bootstrap: no S3 PUT per tenant; manifest goes through
  raft (a few KB per deploy). 10k empty tenants is one
  initial cluster-wide `_init_done = true` flag, then
  per-customer-deploy entries as customers actually deploy.
- DR: learner replica in another region (#1.2 pattern).

## Shipped, not as a single project

The consolidation happened incrementally rather than as one named
migration. By 2026-05 the kv module already exposed `Cluster`
(`src/kv/cluster.zig`) with envelope registration + multi-envelope
encoding + snapshot tick + learner peer mode + send_snapshot
streaming. loop46 and files-server-standalone both opened their own
`Cluster` instances against it. The package rename `rove-kv` →
`raft-kv` happened 2026-05-27 in one mechanical sed pass across
build.zig + 22 source files; build clean, tests green.

## What's deferred

- **`LeaderTxn` as a named primitive.** The capability exists today
  via `TrackedTxn` (per-store, `src/kv/kvstore.zig:734`) +
  `Cluster.proposeAndWait` (`src/kv/cluster.zig:743`) +
  `encodeMultiEnvelope` (`src/js/apply.zig:209`). loop46 uses the
  three pieces directly at 4 sites; files-server is single-store and
  doesn't use multi at all. A wrapper would centralize loop46's
  pattern but adds API surface no consumer asks for. Defer per
  `feedback_compose_from_primitives` until a third consumer or a
  proliferation of multi-store callsites makes the wrapper pay for
  itself.
- **Custom in-memory-pending backend.** Backend interface keeps the
  door open; no implementation candidate yet.
- **Cross-cluster coordination (loop46 ↔ files-server).** They
  remain independent raft groups with their own elections. Workers
  reach files-server via its HTTP API.
