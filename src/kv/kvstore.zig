//! KvStore — handle into a `kvexp.Store` within a node-wide manifest.
//!
//! Phase 1 of the kvexp cutover. SQLite is gone; the data engine is
//! anarchodev/kvexp (vendored at `vendor/kvexp/`). One kvexp manifest
//! per binary holds all of that binary's stores; each tenant /
//! `__root__` / `schedules` lives as a `store_id` within. Mapping
//! `string store_id → u64` is `std.hash.Wyhash`.
//!
//! ## Two open modes
//!
//! - **Attached** (production): caller holds the `*kvexp.Manifest`
//!   for the whole binary and asks `KvStore.attach(...)` for a
//!   handle into one of its stores. `close` releases handle state
//!   only; the manifest stays alive.
//! - **Standalone** (tests, CLI tools): `KvStore.open(path)` builds
//!   its own kvexp stack (PagedFile + BufferPool + PageCache +
//!   Manifest) backing a fresh file with a single store inside.
//!   `close` tears the whole thing down. Standalone mode preserves
//!   the pre-cutover one-file-per-thing semantics for callers that
//!   haven't been consolidated yet.
//!
//! ## Durability
//!
//! Writes mutate the in-memory page cache. `kvexp.Manifest.durabilize`
//! flushes them; that runs from `Cluster.tickSnapshot` on the raft
//! thread. Crash before durabilize loses in-memory state but the
//! raft log is the WAL — replay reconstitutes everything past
//! `manifest.lastAppliedRaftIdx()`.
//!
//! ## Legacy seq surface
//!
//! `nextSeq` / `maxSeq` / `putSeq` / `delta` existed because the
//! SQLite path needed an explicit row-level seq column for raft
//! snapshot deltas. With raft-as-WAL the engine doesn't need it.
//! The API is preserved as in-memory counters (no on-disk state)
//! so callers compile; the delta-based snapshot path will be
//! replaced by `kvexp.dumpSnapshot` / `loadSnapshot` in a follow-up.

const std = @import("std");
const kvexp = @import("kvexp");

pub const Error = error{
    NotFound,
    OutOfMemory,
    Conflict,
    /// Underlying engine error. Name preserved so callers that
    /// switch on `Error.Sqlite` keep compiling; rename is a future
    /// cleanup pass.
    Sqlite,
    Io,
    /// This txn's chain predecessor faulted while it was open, so a
    /// rollback cascade invalidated it (kvexp `error.TxnInvalidated`,
    /// active-writer cascade protection). The batch must self-abort:
    /// roll back and return a retriable 5xx — its speculative basis is
    /// gone. Distinct from `Conflict` (which means "retry the same txn
    /// later"); an invalidated txn must NOT be retried.
    TxnInvalidated,
};

pub const Entry = struct {
    key: []u8,
    value: []u8,
};

pub const DeltaEntry = struct {
    key: []u8,
    value: []u8,
    seq: u64,
};

pub const RangeResult = struct {
    entries: []Entry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RangeResult) void {
        for (self.entries) |e| {
            self.allocator.free(e.key);
            self.allocator.free(e.value);
        }
        self.allocator.free(self.entries);
        self.entries = &.{};
    }
};

pub const DeltaResult = struct {
    entries: []DeltaEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DeltaResult) void {
        for (self.entries) |e| {
            self.allocator.free(e.key);
            self.allocator.free(e.value);
        }
        self.allocator.free(self.entries);
        self.entries = &.{};
    }
};

/// Lock-free monotonic counter. In the SQLite era this was sourced
/// from `kv_seq` AUTOINCREMENT. Under kvexp it's a pure in-memory
/// counter; the value is used as `TrackedTxn.txn_seq` and as a
/// debugging breadcrumb. No on-disk state.
pub const SeqCounter = struct {
    value: std.atomic.Value(u64) align(std.atomic.cache_line),

    pub fn init(initial: u64) SeqCounter {
        return .{ .value = .init(initial) };
    }

    pub fn next(self: *SeqCounter) u64 {
        return self.value.fetchAdd(1, .monotonic) + 1;
    }

    pub fn raiseTo(self: *SeqCounter, floor: u64) void {
        var cur = self.value.load(.monotonic);
        while (cur < floor) {
            cur = self.value.cmpxchgWeak(cur, floor, .monotonic, .monotonic) orelse return;
        }
    }

    pub fn current(self: *const SeqCounter) u64 {
        return self.value.load(.monotonic);
    }
};

/// Thread-safe map from tenant id → owned `*SeqCounter`. Multiple
/// `KvStore`s for the same tenant share one counter so `txn_seq`
/// allocations are globally unique across workers.
pub const SeqCounterRegistry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    counters: std.StringHashMapUnmanaged(*SeqCounter) = .empty,

    pub fn init(allocator: std.mem.Allocator) SeqCounterRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SeqCounterRegistry) void {
        self.mutex.lock();
        var it = self.counters.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.counters.deinit(self.allocator);
        // Unlock BEFORE poisoning `self`: a deferred unlock would run AFTER
        // `self.* = undefined` and assert on the poisoned mutex's garbage
        // locking_thread (the SIGTERM-teardown panic). deinit is single-
        // threaded teardown, so an explicit unlock here is sufficient.
        self.mutex.unlock();
        self.* = undefined;
    }

    pub fn getOrCreate(self: *SeqCounterRegistry, id: []const u8) !*SeqCounter {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.counters.get(id)) |existing| return existing;

        const counter = try self.allocator.create(SeqCounter);
        errdefer self.allocator.destroy(counter);
        counter.* = SeqCounter.init(0);

        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);

        try self.counters.put(self.allocator, id_copy, counter);
        return counter;
    }
};

// ── Standalone stack (owned by KvStore in standalone mode) ──────────

const StandaloneStack = struct {
    /// `path` is a directory under kvexp's LMDB convention (the env
    /// dir holds `data.mdb` + `lock.mdb`).
    path: [:0]u8,
    manifest: kvexp.Manifest,
};

/// LMDB mmap size cap for standalone-mode KvStores. Sparse — only
/// touched pages cost memory. Default 1 GiB is plenty for the small
/// scratch-only consumers (bootstrap.zig, deployStarterContent
/// transients, tests).
const STANDALONE_MAP_SIZE: usize = 1 * 1024 * 1024 * 1024;

/// Reserved store_id for standalone-mode KvStores. The file holds
/// exactly one store (this caller's data).
const STANDALONE_STORE_ID: u64 = 1;

/// Stable u64 derivation from a string store id (e.g., an instance id
/// or "__root__"). Wyhash is deterministic across runs and well-
/// distributed; the collision probability for 10k tenants in 2^64
/// space is ≈ 10⁻¹².
pub fn hashStoreId(id_str: []const u8) u64 {
    return std.hash.Wyhash.hash(0, id_str);
}

// Per-tenant dispatch serialization lives in kvexp now
// (`Manifest.acquire` / `tryAcquire` → `StoreLease`). Rove obtains a
// lease per batch and releases it as soon as the handler walk
// finishes — well before the raft propose. The Txn outlives the
// lease; commit/rollback runs on raft-commit/fault.

// ── KvStore ────────────────────────────────────────────────────────

pub const KvStore = struct {
    allocator: std.mem.Allocator,
    /// Pointer to the manifest backing this handle. In attached mode
    /// the manifest is borrowed (owned by Cluster or equivalent);
    /// in standalone mode it lives inside `owned.manifest`.
    manifest: *kvexp.Manifest,
    store_id: u64,
    /// Shared or owned legacy seq counter. With raft-as-WAL nothing
    /// load-bearing depends on this; preserved for API compatibility.
    counter: *SeqCounter,
    owned_counter: ?SeqCounter,
    owned: ?*StandaloneStack,
    /// In-flight TrackedTxn whose kvexp.Txn this thread should read
    /// from. Set by `TrackedTxn.ensureOpen` (registers self) and
    /// cleared by `releaseLease` / `commit` / `rollback`. Read by
    /// `KvStore.get`/`prefix` to route through the in-flight Txn
    /// (so handler reads see their own writes). Thread-local in
    /// effect: the kvexp dispatch lease guarantees one active txn
    /// per tenant at a time.
    active_txn: ?*TrackedTxn = null,

    /// Open a standalone, self-contained KvStore against `path`. The
    /// file is created if missing; a single store (id =
    /// `STANDALONE_STORE_ID`) is ensured to exist.
    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) Error!*KvStore {
        return openStandalone(allocator, path, .read_write, null);
    }

    /// Open `{data_dir}/{filename}` as a self-contained owned
    /// KvStore handle, attached to the store identified by
    /// `hashStoreId(store_name)`. Used by offline tools (seed,
    /// CLI) to access a binary's kvexp manifest without standing
    /// up a `Cluster` (and its raft node). The returned handle
    /// owns the whole kvexp stack — close tears it down. Sibling
    /// handles (via `attachSibling`) share the manifest and must
    /// close before this one.
    ///
    /// `filename` is the manifest filename inside `data_dir`.
    /// Multiple binaries sharing one `data_dir` (loop46 worker +
    /// files-server-standalone — see kv_bench_cluster.sh) MUST
    /// use distinct filenames to avoid racing on the same file
    /// (kvexp is single-process). loop46 uses "cluster.kv",
    /// files-server uses "files-server.kv", schedule-server uses
    /// "schedule-server.kv".
    pub fn openClusterOwned(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        filename: []const u8,
        store_name: []const u8,
    ) Error!*KvStore {
        std.fs.cwd().makePath(data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return Error.Io,
        };

        const path = std.fmt.allocPrintSentinel(
            allocator,
            "{s}/{s}",
            .{ data_dir, filename },
            0,
        ) catch return Error.OutOfMemory;
        defer allocator.free(path);

        const handle = try openStandaloneWithStoreId(
            allocator,
            path,
            .read_write,
            null,
            hashStoreId(store_name),
        );
        return handle;
    }

    /// Standalone open in read-only mode. The file must already
    /// exist and carry a valid kvexp manifest; the store must
    /// already exist. (No DDL is run — opening a fresh empty file
    /// in read-only mode returns `Error.NotFound` at the first
    /// access.)
    pub fn openReadOnly(allocator: std.mem.Allocator, path: [:0]const u8) Error!*KvStore {
        return openStandalone(allocator, path, .read_only, null);
    }

    /// Same as `open` but the seq counter is shared. The on-disk
    /// state has no seq column under kvexp, so the counter only
    /// matters for in-process callers that compare seqs across
    /// connections.
    pub fn openWithCounter(
        allocator: std.mem.Allocator,
        path: [:0]const u8,
        shared_counter: *SeqCounter,
    ) Error!*KvStore {
        return openStandalone(allocator, path, .read_write, shared_counter);
    }

    /// Attach a sibling handle into the same manifest as `other`.
    /// The new handle targets `store_id` (which may equal `other`'s
    /// or be a different store within the same manifest). Lifetime:
    /// the new handle must be closed before the manifest owner —
    /// in standalone mode that's `other`, in cluster mode that's
    /// the cluster's `deinit`.
    pub fn attachSibling(
        allocator: std.mem.Allocator,
        other: *KvStore,
        store_id: u64,
        shared_counter: ?*SeqCounter,
    ) Error!*KvStore {
        return attach(allocator, other.manifest, store_id, shared_counter);
    }

    /// Attach a handle to a pre-existing manifest. The caller (cluster
    /// or process-wide owner) keeps the manifest alive; `close`
    /// releases handle state only. Creates the store if it doesn't
    /// already exist.
    pub fn attach(
        allocator: std.mem.Allocator,
        manifest: *kvexp.Manifest,
        store_id: u64,
        shared_counter: ?*SeqCounter,
    ) Error!*KvStore {
        const self = allocator.create(KvStore) catch return Error.OutOfMemory;
        errdefer allocator.destroy(self);

        const exists = manifest.hasStore(store_id) catch return Error.Sqlite;
        if (!exists) {
            // Tolerate the TOCTOU race when multiple threads attach
            // the same store concurrently — one wins createStore,
            // the others observe StoreAlreadyExists and proceed.
            manifest.createStore(store_id) catch |err| switch (err) {
                error.StoreAlreadyExists => {},
                else => return Error.Sqlite,
            };
        }

        self.allocator = allocator;
        self.manifest = manifest;
        self.store_id = store_id;
        self.owned = null;
        self.active_txn = null;
        if (shared_counter) |sc| {
            self.counter = sc;
            self.owned_counter = null;
        } else {
            self.owned_counter = SeqCounter.init(0);
            self.counter = &self.owned_counter.?;
        }
        return self;
    }

    const OpenMode = enum { read_write, read_only };

    fn openStandalone(
        allocator: std.mem.Allocator,
        path: [:0]const u8,
        mode: OpenMode,
        shared_counter: ?*SeqCounter,
    ) Error!*KvStore {
        return openStandaloneWithStoreId(allocator, path, mode, shared_counter, STANDALONE_STORE_ID);
    }

    /// Standalone open with caller-chosen store_id. Used by
    /// `openClusterOwned` to land in the same store_id the
    /// in-cluster `openRoot` would use, so seed-mode writes are
    /// visible when the cluster comes up later against the same
    /// file.
    fn openStandaloneWithStoreId(
        allocator: std.mem.Allocator,
        path: [:0]const u8,
        mode: OpenMode,
        shared_counter: ?*SeqCounter,
        store_id: u64,
    ) Error!*KvStore {
        const self = allocator.create(KvStore) catch return Error.OutOfMemory;
        errdefer allocator.destroy(self);

        const stack = allocator.create(StandaloneStack) catch return Error.OutOfMemory;
        errdefer allocator.destroy(stack);

        // kvexp's LMDB env runs with MDB_NOSUBDIR — `path` is a
        // single file. Make sure the parent dir exists before
        // LMDB tries to open the file there.
        if (mode == .read_write) {
            if (std.fs.path.dirname(path)) |parent| {
                std.fs.cwd().makePath(parent) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return Error.Io,
                };
            }
        }

        const path_owned = allocator.dupeZ(u8, path) catch return Error.OutOfMemory;
        errdefer allocator.free(path_owned);
        stack.path = path_owned;
        stack.manifest.init(allocator, path_owned, .{
            .max_map_size = STANDALONE_MAP_SIZE,
        }) catch return Error.Sqlite;
        errdefer stack.manifest.deinit();

        if (mode == .read_write) {
            const exists = stack.manifest.hasStore(store_id) catch return Error.Sqlite;
            if (!exists) {
                stack.manifest.createStore(store_id) catch return Error.Sqlite;
                // durabilize so the store DBI exists on disk;
                // subsequent attach/open across processes can see it.
                // raft_idx=0 → don't touch the watermark on bootstrap.
                stack.manifest.durabilize(0) catch return Error.Io;
            }
        }

        self.allocator = allocator;
        self.manifest = &stack.manifest;
        self.store_id = store_id;
        self.owned = stack;
        self.active_txn = null;
        if (shared_counter) |sc| {
            self.counter = sc;
            self.owned_counter = null;
        } else {
            self.owned_counter = SeqCounter.init(0);
            self.counter = &self.owned_counter.?;
        }
        return self;
    }

    pub fn close(self: *KvStore) void {
        if (self.owned) |stack| {
            // Final durabilize so a clean close doesn't lose
            // overlay state. raft_idx=0 → leave watermark untouched.
            stack.manifest.durabilize(0) catch |err| std.log.warn(
                "kvstore.close: durabilize: {s}",
                .{@errorName(err)},
            );
            stack.manifest.deinit();
            self.allocator.free(stack.path);
            self.allocator.destroy(stack);
        }
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    // ── Transactions ────────────────────────────────────────────
    //
    // kvexp has per-store write locks; multiple ops on the same
    // KvStore from one thread serialize naturally. There's no
    // "begin/commit" boundary at the engine level — all mutations
    // are immediately visible in-memory and become durable at the
    // next `durabilize`. `begin`/`commit`/`rollback` are kept as
    // no-ops so legacy callers compile; a proper multi-op-atomic
    // story belongs in `TrackedTxn` (savepoint-style root revert).

    pub fn begin(self: *KvStore) Error!void {
        _ = self;
    }

    pub fn commit(self: *KvStore) Error!void {
        _ = self;
    }

    pub fn rollback(self: *KvStore) Error!void {
        _ = self;
    }

    // ── Core ops ────────────────────────────────────────────────

    pub fn get(self: *KvStore, key: []const u8) Error![]u8 {
        // If a tracked txn is open, read through it so the handler
        // sees its own pending writes. kvexp.Txn.get walks the
        // savepoint chain, then chain backward, then main_overlay,
        // then LMDB.
        if (self.active_txn) |t| {
            // Lazy batch-scoped read view: pay the LMDB read-txn
            // begin once on this batch's first kv.get, amortizing
            // across every subsequent read. Write-only batches
            // never hit this and skip the cost entirely.
            t.beginReadView();
            const leaf = t.activeLeaf();
            const v = leaf.get(self.allocator, key) catch |err| switch (err) {
                error.OutOfMemory => return Error.OutOfMemory,
                // A chain predecessor faulted mid-handler and the cascade
                // invalidated this active txn (kvexp self-abort gate). Surface
                // it distinctly so the dispatcher emits a retriable 503.
                error.TxnInvalidated => return Error.TxnInvalidated,
                else => return Error.Sqlite,
            };
            return v orelse return Error.NotFound;
        }
        // No active txn: read through a brief lease against main_overlay
        // + LMDB. In-flight chain Txns are invisible — intentional, since
        // those writes are still speculative until raft commits.
        var lease = self.manifest.acquire(self.store_id) catch return Error.Sqlite;
        defer lease.release();
        const v = lease.get(self.allocator, key) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.Sqlite,
        };
        return v orelse return Error.NotFound;
    }

    /// The store's node-local write clock — the kvexp `StoreLease
    /// .writeVersion` (effect-algebra §6.4 watch baseline). Monotonic,
    /// advanced once per write-incorporating commit (leader commit /
    /// follower apply / snapshot install). Read it immediately after
    /// incorporating a write batch and stamp the version onto that
    /// batch's kv-wake events: any read view opened before the batch
    /// carries a strictly-smaller `TrackedTxn.readVersion`, so a watch
    /// armed at that baseline fires (`matchEventsToWakes`).
    ///
    /// Non-blocking: uses `tryAcquire`, so it never stalls behind a
    /// concurrent same-tenant dispatch lease (the leader commit arm
    /// runs per write batch — it must not block). Returns `null` on
    /// contention; callers stamp that as the "fire-always" sentinel so
    /// a contended read over-fires (permitted §9.4) rather than dropping
    /// a wake. The clock itself is a lock-free atomic load behind the
    /// lease's tenant-state pin.
    pub fn writeVersion(self: *KvStore) ?u64 {
        const lease_opt = self.manifest.tryAcquire(self.store_id) catch return null;
        var lease = lease_opt orelse return null;
        defer lease.release();
        return lease.writeVersion();
    }

    /// Direct put. Acquires the per-tenant lock so the one-shot Txn
    /// is the only entry in the kvexp chain for the duration — same
    /// guarantee TrackedTxn relies on. The lock is reentrant-ish:
    /// if the current thread already owns it via a TrackedTxn, we
    /// route through that txn instead.
    pub fn put(self: *KvStore, key: []const u8, value: []const u8) Error!void {
        if (self.active_txn) |t| {
            const leaf = t.activeLeaf();
            leaf.put(key, value) catch |err| switch (err) {
                error.TxnInvalidated => return Error.TxnInvalidated,
                else => return Error.Sqlite,
            };
            return;
        }
        // Blocking acquire — direct KvStore.put is used by test/admin
        // paths where contention is rare; we don't surface Conflict.
        // Each collapse-to-Sqlite site logs the underlying kvexp error
        // first — the V2 follower-apply panic surfaced as a bare
        // `Sqlite` with the real cause swallowed here.
        var lease = self.manifest.acquire(self.store_id) catch |err| {
            std.log.warn("kvstore.put acquire store={x}: {s}", .{ self.store_id, @errorName(err) });
            return Error.Sqlite;
        };
        defer lease.release();
        var txn = lease.beginTxn() catch |err| {
            std.log.warn("kvstore.put beginTxn store={x}: {s}", .{ self.store_id, @errorName(err) });
            return Error.Sqlite;
        };
        errdefer txn.rollback();
        txn.put(key, value) catch |err| {
            std.log.warn("kvstore.put put store={x}: {s}", .{ self.store_id, @errorName(err) });
            return Error.Sqlite;
        };
        txn.commit() catch |err| {
            std.log.warn("kvstore.put commit store={x}: {s}", .{ self.store_id, @errorName(err) });
            return Error.Sqlite;
        };
    }

    /// Legacy: SQLite-era version that stamped a seq column with
    /// each row. Under kvexp seq is not persisted; this is a plain
    /// `put`.
    pub fn putSeq(self: *KvStore, key: []const u8, value: []const u8, seq: u64) Error!void {
        _ = seq;
        return self.put(key, value);
    }

    pub fn delete(self: *KvStore, key: []const u8) Error!void {
        if (self.active_txn) |t| {
            const leaf = t.activeLeaf();
            _ = leaf.delete(key) catch |err| switch (err) {
                error.OutOfMemory => return Error.OutOfMemory,
                error.TxnInvalidated => return Error.TxnInvalidated,
                else => return Error.Sqlite,
            };
            return;
        }
        var lease = self.manifest.acquire(self.store_id) catch |err| {
            std.log.warn("kvstore.delete acquire store={x}: {s}", .{ self.store_id, @errorName(err) });
            return Error.Sqlite;
        };
        defer lease.release();
        var txn = lease.beginTxn() catch |err| {
            std.log.warn("kvstore.delete beginTxn store={x}: {s}", .{ self.store_id, @errorName(err) });
            return Error.Sqlite;
        };
        errdefer txn.rollback();
        _ = txn.delete(key) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => {
                std.log.warn("kvstore.delete delete store={x}: {s}", .{ self.store_id, @errorName(err) });
                return Error.Sqlite;
            },
        };
        txn.commit() catch |err| {
            std.log.warn("kvstore.delete commit store={x}: {s}", .{ self.store_id, @errorName(err) });
            return Error.Sqlite;
        };
    }

    /// Read this *manifest*'s last *durable* raft idx — the value
    /// last stamped into LMDB by `durabilize(idx)`. In-memory state
    /// past this is in the main_overlay / open Txns and isn't
    /// covered until the next durabilize.
    pub fn lastAppliedRaftIdx(self: *KvStore) Error!u64 {
        return self.manifest.durableRaftIdx() catch return Error.Sqlite;
    }

    /// Stamp the manifest's last applied raft idx by durabilizing
    /// at `idx`. Folds main_overlay into LMDB and writes the
    /// watermark atomically. Use this instead of the pre-cutover
    /// pattern of `setLastAppliedRaftIdx` + later `durabilize` —
    /// the new API requires those to be the same call.
    pub fn setLastAppliedRaftIdx(self: *KvStore, idx: u64) Error!void {
        self.manifest.durabilize(idx) catch return Error.Sqlite;
    }

    /// Chain-BYPASSING authoritative put — the replicated-apply seam
    /// (kvexp `StoreLease.applyPut`). A follower applying a committed
    /// raft entry must never sequence behind the tenant's open
    /// speculative txn chain: the one-shot `put` path returned
    /// `NotChainHead` whenever a local read batch had a txn open/parked
    /// for the tenant (and retrying deadlocks — a parked predecessor
    /// resolves only through the apply loop stuck behind it). Writes
    /// straight into the committed overlay under the dispatch lease.
    /// ONLY for the consensus apply path; client writes go through
    /// `TrackedTxn`/`put`.
    pub fn applyPut(self: *KvStore, key: []const u8, value: []const u8) Error!void {
        var lease = self.manifest.acquire(self.store_id) catch |err| {
            std.log.warn("kvstore.applyPut acquire store={x}: {s}", .{ self.store_id, @errorName(err) });
            return Error.Sqlite;
        };
        defer lease.release();
        lease.applyPut(key, value) catch |err| {
            std.log.warn("kvstore.applyPut store={x}: {s}", .{ self.store_id, @errorName(err) });
            return Error.Sqlite;
        };
    }

    /// Chain-bypassing authoritative delete — see `applyPut`.
    pub fn applyDelete(self: *KvStore, key: []const u8) Error!void {
        var lease = self.manifest.acquire(self.store_id) catch |err| {
            std.log.warn("kvstore.applyDelete acquire store={x}: {s}", .{ self.store_id, @errorName(err) });
            return Error.Sqlite;
        };
        defer lease.release();
        lease.applyDelete(key) catch |err| {
            std.log.warn("kvstore.applyDelete store={x}: {s}", .{ self.store_id, @errorName(err) });
            return Error.Sqlite;
        };
    }

    /// Prefix scan. Keys whose bytes start with `prefix_bytes`,
    /// ordered ascending, up to `count` entries. `cursor` is the
    /// last key returned by the previous page — strictly greater
    /// keys are returned. Pass `""` to start from the beginning of
    /// the prefix.
    pub fn prefix(
        self: *KvStore,
        prefix_bytes: []const u8,
        cursor: []const u8,
        count: u32,
    ) Error!RangeResult {
        // Route through the active txn when one is open, so the
        // scan sees the handler's pending writes / tombstones.
        var list: std.ArrayList(Entry) = .empty;
        errdefer {
            for (list.items) |e| {
                self.allocator.free(e.key);
                self.allocator.free(e.value);
            }
            list.deinit(self.allocator);
        }

        if (self.active_txn) |t| {
            // Lazy batch-scoped read view (see KvStore.get).
            t.beginReadView();
            const leaf = t.activeLeaf();
            var pc = leaf.scanPrefix(prefix_bytes) catch |err| switch (err) {
                error.TxnInvalidated => return Error.TxnInvalidated,
                else => return Error.Sqlite,
            };
            defer pc.deinit();
            try collectPrefix(self.allocator, &pc, prefix_bytes, cursor, count, &list);
        } else {
            var lease = self.manifest.acquire(self.store_id) catch return Error.Sqlite;
            defer lease.release();
            var pc = lease.scanPrefix(prefix_bytes) catch return Error.Sqlite;
            defer pc.deinit();
            try collectPrefix(self.allocator, &pc, prefix_bytes, cursor, count, &list);
        }

        return .{
            .entries = list.toOwnedSlice(self.allocator) catch return Error.OutOfMemory,
            .allocator = self.allocator,
        };
    }

    // ── Legacy sequence / replication ───────────────────────────
    //
    // Under raft-as-WAL the engine doesn't carry per-write seqs.
    // Counters below are in-memory only; `delta` returns an empty
    // result. Snapshot transfer in raft_snapshot.zig still calls
    // these but the production catch-up path is `kvexp.dumpSnapshot`
    // / `loadSnapshot` — see follow-up.

    pub fn nextSeq(self: *KvStore) u64 {
        return self.counter.next();
    }

    pub fn maxSeq(self: *KvStore) u64 {
        return self.counter.current();
    }

    pub fn delta(
        self: *KvStore,
        after_seq: u64,
        through_seq: u64,
    ) Error!DeltaResult {
        _ = after_seq;
        _ = through_seq;
        const empty = self.allocator.alloc(DeltaEntry, 0) catch return Error.OutOfMemory;
        return .{ .entries = empty, .allocator = self.allocator };
    }

    // (disableAutoCheckpoint / setBusyTimeout removed 2026-05-17 —
    // no-op SQLite-knob stubs with zero callers, same dead-stub
    // class as the deleted undo machinery.)

    /// Snapshot of the underlying kvexp manifest's counters/gauges.
    /// In attached mode, every KvStore on a node shares the same
    /// `cluster.kv` manifest, so reading this from any handle yields
    /// the same node-wide totals.
    pub fn manifestMetricsSnapshot(self: *KvStore) kvexp.MetricsSnapshot {
        return self.manifest.metricsSnapshot();
    }

    /// Force a durabilize. Only meaningful in standalone mode (the
    /// KvStore owns the manifest stack). Attached-mode callers
    /// should route through the cluster's tick.
    pub fn checkpoint(self: *KvStore) Error!void {
        if (self.owned) |stack| {
            stack.manifest.durabilize(0) catch return Error.Sqlite;
        }
    }

    pub const CheckpointResult = struct {
        log_pages: u32,
        ckpt_pages: u32,
    };

    pub fn checkpointV2(self: *KvStore) Error!CheckpointResult {
        try self.checkpoint();
        return .{ .log_pages = 0, .ckpt_pages = 0 };
    }

    /// Produce a self-contained copy of this KvStore's data at
    /// `target_path` as a fresh kvexp manifest file holding one
    /// store at `STANDALONE_STORE_ID`. Receivers open it via
    /// `KvStore.open(target_path)` and see the same data as the
    /// source.
    ///
    /// The dumped bytes are filtered to this handle's `store_id`
    /// (so an attached KvStore sharing a Cluster's manifest
    /// captures only its own tenant) and the store_id is remapped
    /// to `STANDALONE_STORE_ID` in the wire format, so the target
    /// file is a single-store kvexp manifest that `KvStore.open`
    /// finds at the conventional location. `target_path` must
    /// not already exist.
    /// Produce a self-contained copy of this handle's entire
    /// manifest (every store, not just `self.store_id`) at
    /// `target_path` as a fresh kvexp file. Used by the raft
    /// peer-to-peer snapshot transfer — leader dumps cluster.kv
    /// to a tmp file, ships bytes, follower atomic-renames into
    /// place. `target_path` must not already exist.
    pub fn dumpManifestToFile(self: *KvStore, target_path: [:0]const u8) Error!void {
        // Durabilize source so the manifest tree on disk reflects
        // every in-memory write. raft_idx=0 → don't touch the
        // watermark.
        self.manifest.durabilize(0) catch return Error.Io;

        var snap = self.manifest.openSnapshot() catch return Error.Sqlite;
        defer snap.close();

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var w = buf.writer(self.allocator);
        kvexp.dumpSnapshot(&snap, &w) catch return Error.Sqlite;

        try writeManifestFile(self.allocator, target_path, buf.items);
    }

    pub fn vacuumInto(self: *KvStore, target_path: [:0]const u8) Error!void {
        // Force a durabilize so the snapshot reflects every
        // in-memory write. raft_idx=0 → don't disturb the watermark.
        self.manifest.durabilize(0) catch return Error.Io;

        var snap = self.manifest.openSnapshot() catch return Error.Sqlite;
        defer snap.close();

        // Dump just this store's records, remapped to
        // STANDALONE_STORE_ID, into an in-memory buffer.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        dumpOneStoreRemapped(
            self.allocator,
            &snap,
            self.store_id,
            STANDALONE_STORE_ID,
            &buf,
        ) catch return Error.Sqlite;

        try writeManifestFile(self.allocator, target_path, buf.items);
    }

    /// Serialize just this handle's tenant key-space into a migration
    /// bundle (kvexp `dumpTenantBundle`), returning owned bytes the
    /// caller frees. Unlike `vacuumInto`/`dumpManifestToFile` (whole-file
    /// kvexp snapshots), a bundle is the minimal shippable form of one
    /// store's committed pairs — what a tenant MOVE ships from the source
    /// cluster's `cluster.kv` to the destination's (v2-build-order
    /// §Phase 4). The bundle stamps `self.store_id`, so the destination
    /// reconstructs the same store id (both clusters hash the tenant id to
    /// the same `store_id`). Durabilize first so the snapshot reflects
    /// every in-memory write.
    pub fn dumpTenantBundle(self: *KvStore, allocator: std.mem.Allocator) Error![]u8 {
        self.manifest.durabilize(0) catch return Error.Io;

        var snap = self.manifest.openSnapshot() catch return Error.Sqlite;
        defer snap.close();

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var w = buf.writer(allocator);
        kvexp.dumpTenantBundle(&snap, self.store_id, &w) catch return Error.Sqlite;
        return buf.toOwnedSlice(allocator) catch return Error.OutOfMemory;
    }

    /// Snapshot-generation variant of `dumpTenantBundle`: serialize this
    /// store's committed pairs WITHOUT a `durabilize(0)` first, so the bundle
    /// reflects exactly the durable LMDB state (= the durabilized raft index in
    /// its header), never the in-memory overlay. This is what a raft *snapshot*
    /// needs — a consistent image at a KNOWN raft index — and, because it only
    /// opens a read snapshot (no write), it is safe to call on the raft pump
    /// thread without an extra fold (the pump's `durabilizeTick` already
    /// maintains the durable point). Caller takes the snapshot index from the
    /// matching `durabilized_idx`.
    pub fn dumpTenantBundleReadOnly(self: *KvStore, allocator: std.mem.Allocator) Error![]u8 {
        var snap = self.manifest.openSnapshot() catch return Error.Sqlite;
        defer snap.close();

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        var w = buf.writer(allocator);
        kvexp.dumpTenantBundle(&snap, self.store_id, &w) catch return Error.Sqlite;
        return buf.toOwnedSlice(allocator) catch return Error.OutOfMemory;
    }

    /// Install a raft snapshot bundle: load the pairs and stamp the durable
    /// watermark to `raft_idx` (the snapshot's index) in one fold, so on the
    /// follower the store and `lastAppliedRaftIdx` advance together to the
    /// snapshot point. Unlike `loadTenantBundle` (which uses `durabilize(0)` to
    /// leave the watermark untouched — a fresh move-destination sequence), a
    /// snapshot REPLACES state at a known raft index, so the watermark must
    /// move with it. The load + watermark stamp are one exclusive kvexp txn.
    pub fn loadSnapshotBundle(self: *KvStore, bundle: []const u8, raft_idx: u64) Error!void {
        var stream = std.io.fixedBufferStream(bundle);
        _ = kvexp.loadTenantBundle(self.manifest, stream.reader(), .{}) catch return Error.Sqlite;
        self.manifest.durabilize(raft_idx) catch return Error.Io;
    }

    /// Load a migration bundle (produced by `dumpTenantBundle` on the
    /// source) into this handle's manifest, creating the store the bundle
    /// names if absent and committing every pair in one txn. The MOVE
    /// destination calls this on the tenant's freshly-created instance
    /// store before the directory flips traffic over. `kvexp.loadTenantBundle`
    /// is hardened against malformed input (bundles cross the network) and
    /// rolls back the txn on any error, leaving the store untouched.
    pub fn loadTenantBundle(self: *KvStore, bundle: []const u8) Error!void {
        return self.loadBundleImpl(bundle, .{});
    }

    /// Insert-if-absent load (Phase 7 zero-downtime move). A key already
    /// present in the store — written by a live forward that arrived while
    /// this snapshot was streaming in — is preserved, and the bundle's
    /// (older) value for it is dropped. So the destination can take the live
    /// forward stream AND load the snapshot out-of-band without the snapshot
    /// clobbering a newer forwarded key. Loaded in one exclusive kvexp txn,
    /// so it is race-free against concurrent forward-applies (kvexp's
    /// single-writer lease serializes them). Out-of-band from raft — the
    /// bytes never enter the raft log (only the forward delta does).
    pub fn loadTenantBundleMerge(self: *KvStore, bundle: []const u8) Error!void {
        return self.loadBundleImpl(bundle, .{ .skip_existing = true });
    }

    fn loadBundleImpl(self: *KvStore, bundle: []const u8, opts: kvexp.LoadBundleOptions) Error!void {
        var stream = std.io.fixedBufferStream(bundle);
        _ = kvexp.loadTenantBundle(self.manifest, stream.reader(), opts) catch return Error.Sqlite;
        // Persist the loaded pairs; raft_idx=0 → don't disturb the
        // watermark (the destination group starts a fresh index sequence).
        self.manifest.durabilize(0) catch return Error.Io;
    }

    // ── Tracked transactions (kvexp.Txn-backed) ────────────────────
    //
    // Wraps a top-level `*kvexp.Txn` plus a stack of open savepoint
    // Txns. Writes/reads on the rove side forward to the deepest
    // open level (`activeLeaf`). `KvStore.get/put/delete/prefix`
    // route through this wrapper via the `active_txn` registration
    // so call sites unchanged.
    //
    // Lifecycle:
    //   open       — Manifest.beginTxn → top_txn; register as active_txn
    //   savepoint  — top.savepoint() (or leaf.savepoint() if nested)
    //   release    — leaf.commit() (savepoint commit folds into parent)
    //   rollbackTo — leaf.rollback() (savepoint rollback drops self)
    //   commit     — top.commit() (chain head; folds into main_overlay)
    //   rollback   — top.rollback() (cascades to chain successors)
    //
    // The per-tenant lock held by the dispatcher batch ensures only
    // one TrackedTxn per store at a time, so no rove-side sync on
    // active_txn or the savepoint stack.

    pub const TrackedTxn = struct {
        store: *KvStore,
        txn_seq: u64,
        kind: enum { normal, immediate },
        /// True from `ensureOpen` until `commit`/`rollback`. Used to
        /// short-circuit the no-op cases.
        opened: bool,
        /// kvexp dispatch lease. Held only across handler execution
        /// (open → end-of-batch). `releaseLease` drops it at the
        /// start of finalizeBatch so other workers can begin chain-
        /// tail Txns for this tenant while raft consenses this one.
        lease: ?kvexp.StoreLease = null,
        /// Top-level kvexp Txn. Created via `lease.beginTxn` at open
        /// time; survives `releaseLease` and lives until commit or
        /// rollback. Owned by kvexp's allocator until then.
        top: ?*kvexp.Txn = null,
        /// Open savepoint chain — innermost last. Reads/writes go to
        /// `savepoints.getLastOrNull() orelse top`.
        savepoints: std.ArrayListUnmanaged(*kvexp.Txn) = .empty,
        /// Set to true once `beginReadView` has opened the kvexp
        /// batch-scoped read view on `top`. Lets the read sites in
        /// `KvStore.get` / `KvStore.prefix` open the view lazily —
        /// write-only batches never pay the LMDB read-txn begin.
        /// Reset to false in `ensureOpen` so a re-opened TrackedTxn
        /// starts clean.
        read_view_opened: bool = false,
        /// Set by `park` once the txn is handed to the chain to await
        /// raft (active → parked). Non-null ⇒ commit/rollback route
        /// through `Manifest.commit`/`rollbackFrom` **by handle** under
        /// the tenant lock, never dereferencing `top` — a cross-worker
        /// rollback cascade may have freed the kvexp Txn out from under
        /// our pool entry, and by-handle resolution returns `.absent`
        /// in that case instead of UAF-ing. The handle is `{tenant,
        /// raft_seq}`; `raft_seq` is the same value rove pools the txn
        /// under and classifies against the commit/fault watermarks.
        parked_handle: ?kvexp.TxnHandle = null,

        pub fn open(self: *TrackedTxn) Error!void {
            return self.ensureOpen();
        }

        fn ensureOpen(self: *TrackedTxn) Error!void {
            if (self.opened) return;
            // tryAcquire surfaces contention as `Conflict` so the
            // dispatcher's skip-this-tick machinery picks a different
            // anchor instead of blocking on the dispatch lock.
            const lease_opt = self.store.manifest.tryAcquire(self.store.store_id) catch
                return Error.Sqlite;
            self.lease = lease_opt orelse return Error.Conflict;
            std.debug.assert(self.store.active_txn == null);
            self.txn_seq = self.store.counter.next();
            self.top = self.lease.?.beginTxn() catch {
                self.lease.?.release();
                self.lease = null;
                return Error.Sqlite;
            };
            self.store.active_txn = self;
            self.opened = true;
            self.read_view_opened = false;
        }

        /// Release the kvexp dispatch lease and clear the `active_txn`
        /// registration while the kvexp.Txn stays alive in the
        /// per-tenant chain. Called at the start of finalizeBatch —
        /// once the handler walk is done, the next worker can begin
        /// its own chain-tail Txn for this tenant immediately, even
        /// while raft is still consensing this batch. Idempotent.
        pub fn releaseLease(self: *TrackedTxn) void {
            if (self.lease == null) return;
            std.debug.assert(self.store.active_txn == self);
            self.store.active_txn = null;
            self.lease.?.release();
            self.lease = null;
        }

        /// Deepest open level — where puts/reads land. Caller must
        /// have already opened the txn (top != null).
        pub fn activeLeaf(self: *TrackedTxn) *kvexp.Txn {
            if (self.savepoints.items.len > 0) {
                return self.savepoints.items[self.savepoints.items.len - 1];
            }
            return self.top.?;
        }

        pub fn put(self: *TrackedTxn, key: []const u8, value: []const u8) Error!void {
            try self.ensureOpen();
            self.activeLeaf().put(key, value) catch |err| switch (err) {
                error.TxnInvalidated => return Error.TxnInvalidated,
                else => return Error.Sqlite,
            };
        }

        pub fn delete(self: *TrackedTxn, key: []const u8) Error!void {
            try self.ensureOpen();
            _ = self.activeLeaf().delete(key) catch |err| switch (err) {
                error.TxnInvalidated => return Error.TxnInvalidated,
                else => return Error.Sqlite,
            };
        }

        pub fn savepoint(self: *TrackedTxn) Error!void {
            try self.ensureOpen();
            const child = self.activeLeaf().savepoint() catch return Error.Sqlite;
            self.savepoints.append(self.store.allocator, child) catch
                return Error.OutOfMemory;
        }

        /// Commit the innermost savepoint: folds its writes into
        /// the level below.
        pub fn release(self: *TrackedTxn) Error!void {
            if (!self.opened) return;
            if (self.savepoints.items.len == 0) return;
            const leaf = self.savepoints.pop().?;
            leaf.commit() catch return Error.Sqlite;
        }

        /// Rollback the innermost savepoint: drops its writes.
        pub fn rollbackTo(self: *TrackedTxn) Error!void {
            if (!self.opened) return;
            if (self.savepoints.items.len == 0) return;
            const leaf = self.savepoints.pop().?;
            leaf.rollback();
        }

        /// Open a batch-scoped LMDB read view: point reads then reuse
        /// one parked MDB_RDONLY txn instead of begin/abort per `get`
        /// (the 31%-CPU `mdb_txn_begin` memset). Idempotent — called
        /// lazily from the first `KvStore.get` / `KvStore.prefix` in
        /// a batch so write-only batches don't pay for an LMDB read
        /// txn they'd never consult. Best effort: failure only
        /// forgoes the optimization (reads fall back to one-shot read
        /// txns); it must never fail the batch. kvexp tears the view
        /// down automatically on commit/rollback.
        pub fn beginReadView(self: *TrackedTxn) void {
            if (self.read_view_opened) return;
            const t = self.top orelse return;
            t.beginReadView() catch {
                // Leave `read_view_opened` false: the next reader will
                // retry. kvexp's only failure modes here are OOM /
                // already-open (already-open is impossible because we
                // gate on `read_view_opened`).
                return;
            };
            self.read_view_opened = true;
        }

        /// True iff a read in this txn crossed a chain predecessor's
        /// still-uncommitted overlay (kvexp `Txn.saw_speculation`,
        /// set by `markSawSpeculationLocked` on the top-level Txn).
        /// A read-only batch for which this is true must NOT release
        /// its response at local commit — the value it read is not
        /// durable yet (docs/proposer-audit.md Addendum, idiom-0).
        ///
        /// Read post-handler-walk on the owning worker thread; the
        /// per-tenant dispatch lease serialised every writer to this
        /// txn, and the flag is monotone (only ever set true), so an
        /// unlocked field read is stable here. False if the txn was
        /// never opened (no reads happened → no speculation).
        pub fn sawSpeculation(self: *TrackedTxn) bool {
            const top = self.top orelse return false;
            return top.saw_speculation;
        }

        /// The durable write-clock watermark this txn's reads are
        /// baselined to (kvexp `Txn.readVersion`; effect-algebra §6.4
        /// watch anchor). A kv-watch armed at this baseline fires for any
        /// write to its prefix at a version strictly greater — i.e. one
        /// that landed after the state the handler read. Capture it after
        /// the handler's reads for the tightest (least-spurious) baseline.
        /// 0 if the txn never opened (no reads → no speculative basis).
        pub fn readVersion(self: *TrackedTxn) u64 {
            const top = self.top orelse return 0;
            return top.readVersion();
        }

        /// Hand the txn to the chain to await raft (active → parked) and
        /// record its `{tenant, seq}` handle on `parked_handle`. After
        /// this, commit/rollback route by handle. Folds any still-open
        /// savepoints first — the handler is done, its writes are final,
        /// and a later by-handle commit must not see an open child. The
        /// caller passes the raft propose `seq` it pools the txn under;
        /// the same value keys the kvexp chain resolution.
        ///
        /// `error.TxnInvalidated` ⇒ a chain predecessor faulted while
        /// this batch's handler ran (active-writer cascade), so the
        /// batch's writes are built on a dead speculative basis — the
        /// caller must self-abort (rollback + retriable 5xx), not pool it.
        pub fn park(self: *TrackedTxn, seq: u64) Error!void {
            std.debug.assert(self.opened);
            std.debug.assert(self.parked_handle == null);
            while (self.savepoints.pop()) |sp| {
                sp.commit() catch |err| switch (err) {
                    error.TxnInvalidated => return Error.TxnInvalidated,
                    else => return Error.Sqlite,
                };
            }
            const top = self.top orelse return Error.Sqlite;
            self.parked_handle = top.park(seq) catch return Error.TxnInvalidated;
        }

        /// Tear down wrapper state after a by-handle commit/rollback —
        /// kvexp already freed the kvexp Txn, so `top` is stale and must
        /// not be dereferenced. The lease is normally gone (released at
        /// park), but drop it defensively.
        fn finishParked(self: *TrackedTxn) void {
            self.top = null;
            self.parked_handle = null;
            self.opened = false;
            self.savepoints.deinit(self.store.allocator);
            self.savepoints = .empty;
            if (self.lease != null) {
                self.store.active_txn = null;
                self.lease.?.release();
                self.lease = null;
            }
        }

        pub fn commit(self: *TrackedTxn) Error!void {
            if (!self.opened) return;
            // Parked (post-`park`): resolve + commit by handle under the
            // tenant lock. Never touch `top` — a cross-worker rollback
            // cascade may have freed it. `.not_head` keeps the txn parked
            // for a later-tick retry (predecessor not committed yet);
            // `.absent` means it's already gone (treat as done).
            if (self.parked_handle) |h| {
                switch (self.store.manifest.commit(h) catch return Error.Sqlite) {
                    .committed, .absent => {},
                    .not_head => return Error.Conflict,
                }
                self.finishParked();
                return;
            }
            // Active / immediate: the pointer path. Any open savepoints
            // close first (kvexp errors with SavepointStillOpen
            // otherwise). On `NotChainHead` the kvexp.Txn is unchanged
            // (still in the chain) and the caller can retry on a later
            // tick once the predecessor worker commits its own head.
            while (self.savepoints.pop()) |sp| {
                sp.commit() catch return Error.Sqlite;
            }
            const top = self.top.?;
            top.commit() catch |err| switch (err) {
                error.NotChainHead => return Error.Conflict,
                else => return Error.Sqlite,
            };
            // Commit succeeded — kvexp freed the Txn; tear down
            // local state and drop the lease if still held.
            self.top = null;
            self.opened = false;
            self.savepoints.deinit(self.store.allocator);
            self.savepoints = .empty;
            if (self.lease != null) {
                self.store.active_txn = null;
                self.lease.?.release();
                self.lease = null;
            }
        }

        pub fn rollback(self: *TrackedTxn) Error!void {
            if (!self.opened) return;
            // Parked: roll back by handle (cascades forward-dependents).
            // Idempotent + convergent across workers — `.absent` if a
            // sibling/predecessor cascade already freed it. No `top` deref.
            if (self.parked_handle) |h| {
                _ = self.store.manifest.rollbackFrom(h);
                self.finishParked();
                return;
            }
            // Active / immediate: the pointer cascade. An active txn is
            // the chain tail (the lease serialises writers), so it has no
            // successors to cascade.
            const top = self.top.?;
            self.top = null;
            self.opened = false;
            self.savepoints.deinit(self.store.allocator);
            self.savepoints = .empty;
            if (self.lease != null) {
                self.store.active_txn = null;
                self.lease.?.release();
                self.lease = null;
            }
            top.rollback();
        }
    };

    pub fn beginTracked(self: *KvStore) Error!TrackedTxn {
        // Lazy ensureOpen: registration of `active_txn` must happen
        // on the caller's stack slot, not this function's local
        // (which gets copied on return and the local pointer dies).
        // First put/delete/savepoint/get triggers ensureOpen.
        return .{
            .store = self,
            .txn_seq = 0,
            .kind = .normal,
            .opened = false,
        };
    }

    pub fn beginTrackedImmediate(self: *KvStore) Error!TrackedTxn {
        return .{
            .store = self,
            .txn_seq = 0,
            .kind = .immediate,
            .opened = false,
        };
    }

    // (Pre-kvexp `undoTxn` / `commitTxn` / `gcUndoThrough` /
    // `recoverOrphans` removed 2026-05-17 — they were SQLite
    // kv_undo-log machinery and had degenerated to no-op stubs.
    // Under kvexp the speculative overlay is volatile (→ LMDB only
    // at raft-apply), so a pre-quorum crash loses it with no
    // on-disk divergence and nothing to recover; the live rollback
    // primitive is `TrackedTxn.rollback()`. See
    // docs/proposer-audit.md.)
};

/// Collect entries from a kvexp prefix cursor into `list`, honoring
/// `cursor` (skip ≤ cursor when it sorts inside the prefix range) and
/// stopping at `count` entries. The cursor's key/value slices alias
/// kvexp-internal memory, so we copy into freshly-allocated buffers
/// owned by `allocator`.
///
/// Generic over the cursor type because `kvexp.StorePrefixCursor` and
/// `kvexp.TxnPrefixCursor` happen to be the same underlying type, but
/// callers go through different methods to obtain them.
fn collectPrefix(
    allocator: std.mem.Allocator,
    pc: anytype,
    prefix_bytes: []const u8,
    cursor: []const u8,
    count: u32,
    list: *std.ArrayList(Entry),
) Error!void {
    var collected: u32 = 0;
    while (collected < count) {
        const has = pc.next() catch return Error.Sqlite;
        if (!has) break;
        const k_slice = pc.key();
        if (cursor.len > 0 and !std.mem.lessThan(u8, cursor, prefix_bytes)) {
            const cmp = std.mem.order(u8, k_slice, cursor);
            if (cmp == .lt or cmp == .eq) continue;
        }
        const v_slice = pc.value();
        const k_copy = allocator.alloc(u8, k_slice.len) catch return Error.OutOfMemory;
        errdefer allocator.free(k_copy);
        if (k_slice.len > 0) @memcpy(k_copy, k_slice);
        const v_copy = allocator.alloc(u8, v_slice.len) catch return Error.OutOfMemory;
        errdefer allocator.free(v_copy);
        if (v_slice.len > 0) @memcpy(v_copy, v_slice);
        list.append(allocator, .{ .key = k_copy, .value = v_copy }) catch
            return Error.OutOfMemory;
        collected += 1;
    }
}

/// Build a fresh kvexp manifest at `target_path` and replay
/// `dump_bytes` (a kvexp dump-format blob) into it. Closes durabilize
/// at the end so the file is self-contained. `target_path` must not
/// already exist. Used by `vacuumInto` and `dumpManifestToFile`.
fn writeManifestFile(
    allocator: std.mem.Allocator,
    target_path: [:0]const u8,
    dump_bytes: []const u8,
) Error!void {
    // target_path is a single LMDB file (MDB_NOSUBDIR). Wipe the
    // data + lock files so the new manifest starts fresh.
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "{s}-lock", .{target_path}) catch
        return Error.Io;
    std.fs.cwd().deleteFile(target_path) catch {};
    std.fs.cwd().deleteFile(lock_path) catch {};
    if (std.fs.path.dirname(target_path)) |parent| {
        std.fs.cwd().makePath(parent) catch return Error.Io;
    }

    var target_manifest: kvexp.Manifest = undefined;
    target_manifest.init(allocator, target_path, .{
        .max_map_size = STANDALONE_MAP_SIZE,
    }) catch return Error.Sqlite;
    defer target_manifest.deinit();

    var stream = std.io.fixedBufferStream(dump_bytes);
    const restored_idx = kvexp.loadSnapshot(&target_manifest, stream.reader()) catch
        return Error.Sqlite;
    target_manifest.durabilize(restored_idx) catch return Error.Io;
}

/// Write a kvexp-format snapshot dump containing only `src_store_id`'s
/// records, with the store id rewritten to `dst_store_id` in each KV
/// record. The output is loadable via `kvexp.loadSnapshot` and
/// produces a manifest with a single store at `dst_store_id`. Used by
/// `KvStore.vacuumInto` to capture an attached handle's tenant data
/// without dragging in the rest of the cluster.
fn dumpOneStoreRemapped(
    allocator: std.mem.Allocator,
    snap: *kvexp.Snapshot,
    src_store_id: u64,
    dst_store_id: u64,
    out: *std.ArrayList(u8),
) !void {
    const SNAP_TAG_KV: u8 = kvexp.manifest.SNAP_TAG_KV;
    const SNAP_TAG_END: u8 = kvexp.manifest.SNAP_TAG_END;

    var w = out.writer(allocator);
    try w.writeInt(u32, kvexp.SNAPSHOT_MAGIC, .little);
    try w.writeByte(kvexp.SNAPSHOT_VERSION);
    // Header layout mirrors kvexp.dumpSnapshot exactly:
    //   u64 reserved (was snap_seq; now ignored on load)
    //   u64 durable raft idx (loader rehydrates it as last_applied)
    try w.writeInt(u64, 0, .little);
    try w.writeInt(u64, try snap.manifest.durableRaftIdx(), .little);

    // Iterate this store's records (returns no entries if the store
    // doesn't exist in the snapshot — same shape as the storeRoot
    // existence check that used to gate this block).
    var cursor = try snap.scanPrefix(src_store_id, "");
    defer cursor.deinit();
    while (try cursor.next()) {
        const k = cursor.key();
        const v = cursor.value();
        try w.writeByte(SNAP_TAG_KV);
        try w.writeInt(u64, dst_store_id, .little);
        try w.writeInt(u16, @intCast(k.len), .little);
        try w.writeInt(u16, @intCast(v.len), .little);
        try w.writeAll(k);
        try w.writeAll(v);
    }

    try w.writeByte(SNAP_TAG_END);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn tmpDbPath(buf: *[64]u8) [:0]const u8 {
    const ts = std.time.nanoTimestamp();
    const seed: u64 = @truncate(@as(u128, @bitCast(ts)));
    return std.fmt.bufPrintZ(buf, "/tmp/rove-kv-test-{x}.kv", .{seed}) catch unreachable;
}

fn cleanupDb(path: [:0]const u8) void {
    // LMDB (NOSUBDIR) writes `path` and `path-lock`.
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_buf, "{s}-lock", .{path}) catch return;
    std.fs.cwd().deleteFile(path) catch {};
    std.fs.cwd().deleteFile(lock_path) catch {};
}

test "open, put, get, delete" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    try kv.put("hello", "world");
    const v = try kv.get("hello");
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("world", v);

    try kv.delete("hello");
    try testing.expectError(Error.NotFound, kv.get("hello"));
}

test "get on missing key returns NotFound" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    try testing.expectError(Error.NotFound, kv.get("nope"));
}

test "binary blob round trip" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    const payload = [_]u8{ 0, 1, 2, 0xff, 0, 0xaa };
    try kv.put("bin", &payload);
    const v = try kv.get("bin");
    defer testing.allocator.free(v);
    try testing.expectEqualSlices(u8, &payload, v);
}

test "prefix scan returns only keys under the prefix" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    try kv.put("a/1", "x");
    try kv.put("a/2", "y");
    try kv.put("a/3", "z");
    try kv.put("b/1", "ignored");

    var r = try kv.prefix("a/", "", 100);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.entries.len);
    try testing.expectEqualStrings("a/1", r.entries[0].key);
    try testing.expectEqualStrings("a/2", r.entries[1].key);
    try testing.expectEqualStrings("a/3", r.entries[2].key);
    try testing.expectEqualStrings("z", r.entries[2].value);
}

test "prefix scan honors count" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    try kv.put("k/1", "a");
    try kv.put("k/2", "b");
    try kv.put("k/3", "c");

    var r = try kv.prefix("k/", "", 2);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.entries.len);
    try testing.expectEqualStrings("k/1", r.entries[0].key);
    try testing.expectEqualStrings("k/2", r.entries[1].key);
}

test "prefix scan resumes past cursor" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    try kv.put("k/a", "1");
    try kv.put("k/b", "2");
    try kv.put("k/c", "3");

    var page1 = try kv.prefix("k/", "", 2);
    defer page1.deinit();
    try testing.expectEqual(@as(usize, 2), page1.entries.len);

    var page2 = try kv.prefix("k/", page1.entries[1].key, 2);
    defer page2.deinit();
    try testing.expectEqual(@as(usize, 1), page2.entries.len);
    try testing.expectEqualStrings("k/c", page2.entries[0].key);
}

test "seq counter monotonic" {
    var c = SeqCounter.init(0);
    const s1 = c.next();
    const s2 = c.next();
    try testing.expect(s2 > s1);
    try testing.expectEqual(s2, c.current());
}

test "tracked txn rollback reverts pre_root" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    try kv.put("k", "before");

    var txn = try kv.beginTracked();
    try txn.put("k", "after");
    try testing.expect(txn.txn_seq > 0);

    // Confirm the optimistic write is visible.
    {
        const v = try kv.get("k");
        defer testing.allocator.free(v);
        try testing.expectEqualStrings("after", v);
    }

    try txn.rollback();

    {
        const v = try kv.get("k");
        defer testing.allocator.free(v);
        try testing.expectEqualStrings("before", v);
    }
}

test "tracked txn savepoint + rollbackTo" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    try kv.put("k", "pre");

    var txn = try kv.beginTracked();
    try txn.put("k", "first");
    try txn.savepoint();
    try txn.put("k", "second");

    try txn.rollbackTo();
    {
        const v = try kv.get("k");
        defer testing.allocator.free(v);
        try testing.expectEqualStrings("first", v);
    }
    try txn.commit();
}

test "attached vacuumInto round-trips data via standalone re-open" {
    // Mirrors the snapshot.zig capture+restore pattern: cluster
    // holds the manifest, attached handle calls vacuumInto, a
    // fresh standalone KvStore opens the resulting file and reads
    // the data back.
    const a = testing.allocator;

    var path_buf: [96]u8 = undefined;
    const src_path = std.fmt.bufPrintZ(&path_buf, "/tmp/rove-kv-vac-src-{x}.kv", .{
        @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())))),
    }) catch unreachable;
    defer cleanupDb(src_path);

    // Build a kvexp manifest outside any KvStore so we can attach.
    cleanupDb(src_path);
    var manifest: kvexp.Manifest = undefined;
    try manifest.init(a, src_path, .{ .max_map_size = STANDALONE_MAP_SIZE });
    defer manifest.deinit();

    const acme_id = hashStoreId("acme");
    const ks = try KvStore.attach(a, &manifest, acme_id, null);
    defer ks.close();

    try ks.put("greeting", "hello");
    try ks.put("counter", "42");

    var dump_path_buf: [96]u8 = undefined;
    const dump_path = std.fmt.bufPrintZ(&dump_path_buf, "/tmp/rove-kv-vac-dst-{x}.kv", .{
        @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())))),
    }) catch unreachable;
    defer cleanupDb(dump_path);
    try ks.vacuumInto(dump_path);

    var dst = try KvStore.open(a, dump_path);
    defer dst.close();
    const v1 = try dst.get("greeting");
    defer a.free(v1);
    try testing.expectEqualStrings("hello", v1);
    const v2 = try dst.get("counter");
    defer a.free(v2);
    try testing.expectEqualStrings("42", v2);
}

test "tenant bundle ships one store between two manifests (the move shape)" {
    // Two independent manifests stand in for two clusters' cluster.kv.
    // The same tenant id hashes to the same store_id on both, so the
    // bundle dumped from the source loads into the destination at the
    // matching id and a fresh handle reads the data back.
    const a = testing.allocator;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));

    var src_buf: [96]u8 = undefined;
    const src_path = std.fmt.bufPrintZ(&src_buf, "/tmp/rove-kv-bnd-src-{x}.kv", .{seed}) catch unreachable;
    defer cleanupDb(src_path);
    var dst_buf: [96]u8 = undefined;
    const dst_path = std.fmt.bufPrintZ(&dst_buf, "/tmp/rove-kv-bnd-dst-{x}.kv", .{seed}) catch unreachable;
    defer cleanupDb(dst_path);
    cleanupDb(src_path);
    cleanupDb(dst_path);

    var src_manifest: kvexp.Manifest = undefined;
    try src_manifest.init(a, src_path, .{ .max_map_size = STANDALONE_MAP_SIZE });
    defer src_manifest.deinit();
    var dst_manifest: kvexp.Manifest = undefined;
    try dst_manifest.init(a, dst_path, .{ .max_map_size = STANDALONE_MAP_SIZE });
    defer dst_manifest.deinit();

    const tenant_id = hashStoreId("movetenant");
    const src = try KvStore.attach(a, &src_manifest, tenant_id, null);
    defer src.close();
    try src.put("greeting", "hello");
    try src.put("counter", "42");

    const bundle = try src.dumpTenantBundle(a);
    defer a.free(bundle);

    // Destination: create the instance store, then load the bundle into it.
    const dst = try KvStore.attach(a, &dst_manifest, tenant_id, null);
    defer dst.close();
    try dst.loadTenantBundle(bundle);

    const g = try dst.get("greeting");
    defer a.free(g);
    try testing.expectEqualStrings("hello", g);
    const c = try dst.get("counter");
    defer a.free(c);
    try testing.expectEqualStrings("42", c);
}

test "lastAppliedRaftIdx round-trips through manifest" {
    var path_buf: [64]u8 = undefined;
    const path = tmpDbPath(&path_buf);
    defer cleanupDb(path);

    var kv = try KvStore.open(testing.allocator, path);
    defer kv.close();

    try testing.expectEqual(@as(u64, 0), try kv.lastAppliedRaftIdx());
    try kv.setLastAppliedRaftIdx(42);
    try testing.expectEqual(@as(u64, 42), try kv.lastAppliedRaftIdx());
}
