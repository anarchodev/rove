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
        defer self.mutex.unlock();
        var it = self.counters.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.counters.deinit(self.allocator);
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
    file: kvexp.PagedFile,
    pool: kvexp.BufferPool,
    cache: kvexp.PageCache,
    manifest: kvexp.Manifest,
};

/// kvexp buffer pool capacity for standalone mode. Conservative; the
/// pre-cutover SQLite default page cache was 200KB and we don't want
/// standalone-mode footprint to balloon. 256 pages × 4KB = 1 MB.
const STANDALONE_POOL_PAGES: usize = 256;

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

    /// Open a standalone, self-contained KvStore against `path`. The
    /// file is created if missing; a single store (id =
    /// `STANDALONE_STORE_ID`) is ensured to exist.
    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8) Error!*KvStore {
        return openStandalone(allocator, path, .read_write, null);
    }

    /// Open `{data_dir}/cluster.kv` as a self-contained owned
    /// KvStore handle, attached to the store identified by
    /// `hashStoreId(store_name)`. Used by offline tools (seed,
    /// CLI) to access the cluster's manifest without standing up
    /// a `Cluster` (and its raft node). The returned handle owns
    /// the whole kvexp stack — close tears it down. Sibling
    /// handles (via `attachSibling`) share the manifest and must
    /// close before this one.
    pub fn openClusterOwned(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        store_name: []const u8,
    ) Error!*KvStore {
        const CLUSTER_KV: []const u8 = "cluster.kv";

        std.fs.cwd().makePath(data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return Error.Io,
        };

        const path = std.fmt.allocPrintSentinel(
            allocator,
            "{s}/{s}",
            .{ data_dir, CLUSTER_KV },
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

        stack.file = kvexp.PagedFile.open(path, .{
            .create = mode == .read_write,
            .page_size = kvexp.PAGE_SIZE_DEFAULT,
        }) catch return Error.Io;
        errdefer stack.file.close();

        stack.pool = kvexp.BufferPool.init(
            allocator,
            kvexp.PAGE_SIZE_DEFAULT,
            STANDALONE_POOL_PAGES,
        ) catch return Error.OutOfMemory;
        errdefer stack.pool.deinit(allocator);

        stack.cache = kvexp.PageCache.init(
            allocator,
            &stack.file,
            &stack.pool,
            .{},
        ) catch return Error.OutOfMemory;
        errdefer stack.cache.deinit();

        stack.manifest.init(allocator, &stack.cache, &stack.file) catch return Error.Sqlite;
        errdefer stack.manifest.deinit();

        if (mode == .read_write) {
            const exists = stack.manifest.hasStore(store_id) catch return Error.Sqlite;
            if (!exists) {
                stack.manifest.createStore(store_id) catch return Error.Sqlite;
            }
        }

        self.allocator = allocator;
        self.manifest = &stack.manifest;
        self.store_id = store_id;
        self.owned = stack;
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
            // in-memory writes. Best-effort — if we can't fsync
            // there's nothing higher up that can do better.
            stack.manifest.durabilize() catch |err| std.log.warn(
                "kvstore.close: durabilize: {s}",
                .{@errorName(err)},
            );
            stack.manifest.deinit();
            stack.cache.deinit();
            stack.pool.deinit(self.allocator);
            stack.file.close();
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
        var store = kvexp.Store.open(self.manifest, self.store_id) catch return Error.Sqlite;
        defer store.deinit();
        const v = store.get(self.allocator, key) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.Sqlite,
        };
        return v orelse return Error.NotFound;
    }

    pub fn put(self: *KvStore, key: []const u8, value: []const u8) Error!void {
        var store = kvexp.Store.open(self.manifest, self.store_id) catch return Error.Sqlite;
        defer store.deinit();
        store.put(key, value) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.Sqlite,
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
        var store = kvexp.Store.open(self.manifest, self.store_id) catch return Error.Sqlite;
        defer store.deinit();
        _ = store.delete(key) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.Sqlite,
        };
    }

    /// Read this *manifest*'s last applied raft idx. Note this is
    /// per-manifest (cluster-wide on production loop46), not
    /// per-store — matches the kvexp model. Pre-cutover callers
    /// that read it from `__root__.db` get the same answer.
    pub fn lastAppliedRaftIdx(self: *KvStore) Error!u64 {
        return self.manifest.lastAppliedRaftIdx();
    }

    /// Stamp the manifest's last applied raft idx. Cluster-wide on
    /// production loop46.
    pub fn setLastAppliedRaftIdx(self: *KvStore, idx: u64) Error!void {
        self.manifest.setLastAppliedRaftIdx(idx);
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
        var store = kvexp.Store.open(self.manifest, self.store_id) catch return Error.Sqlite;
        defer store.deinit();
        var pc = store.scanPrefix(prefix_bytes) catch return Error.Sqlite;
        defer pc.deinit();

        var list: std.ArrayList(Entry) = .empty;
        errdefer {
            for (list.items) |e| {
                self.allocator.free(e.key);
                self.allocator.free(e.value);
            }
            list.deinit(self.allocator);
        }

        var collected: u32 = 0;
        while (collected < count) {
            const has = pc.next() catch return Error.Sqlite;
            if (!has) break;

            const k_slice = pc.key();
            // Cursor handling: skip keys ≤ cursor when a cursor is
            // supplied and it sorts at-or-above the prefix.
            if (cursor.len > 0 and !std.mem.lessThan(u8, cursor, prefix_bytes)) {
                const cmp = std.mem.order(u8, k_slice, cursor);
                if (cmp == .lt or cmp == .eq) continue;
            }

            const v_slice = pc.value();

            const k_copy = self.allocator.alloc(u8, k_slice.len) catch return Error.OutOfMemory;
            errdefer self.allocator.free(k_copy);
            if (k_slice.len > 0) @memcpy(k_copy, k_slice);

            const v_copy = self.allocator.alloc(u8, v_slice.len) catch return Error.OutOfMemory;
            errdefer self.allocator.free(v_copy);
            if (v_slice.len > 0) @memcpy(v_copy, v_slice);

            list.append(self.allocator, .{ .key = k_copy, .value = v_copy }) catch
                return Error.OutOfMemory;
            collected += 1;
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

    // ── Checkpointing ───────────────────────────────────────────

    /// No-op under kvexp. WAL auto-checkpointing was a SQLite knob;
    /// under raft-as-WAL the checkpoint cadence is owned by the
    /// raft thread's `tickSnapshot`.
    pub fn disableAutoCheckpoint(self: *KvStore) void {
        _ = self;
    }

    /// No-op under kvexp. SQLite-only knob.
    pub fn setBusyTimeout(self: *KvStore, ms: c_int) void {
        _ = self;
        _ = ms;
    }

    /// Force a durabilize. Only meaningful in standalone mode (the
    /// KvStore owns the manifest stack). Attached-mode callers
    /// should route through the cluster's tick.
    pub fn checkpoint(self: *KvStore) Error!void {
        if (self.owned) |stack| {
            stack.manifest.durabilize() catch return Error.Sqlite;
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
        // every in-memory write. Concurrent durabilize from the
        // raft thread serializes on `tree_lock`; safe but may
        // wait.
        self.manifest.durabilize() catch return Error.Io;

        var snap = self.manifest.openSnapshot() catch return Error.Sqlite;
        defer snap.close();

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var w = buf.writer(self.allocator);
        kvexp.dumpSnapshot(&snap, &w) catch return Error.Sqlite;

        try writeManifestFile(self.allocator, target_path, buf.items);
    }

    pub fn vacuumInto(self: *KvStore, target_path: [:0]const u8) Error!void {
        // Force a durabilize so the manifest tree reflects every
        // in-memory write before we open a snapshot. `Snapshot`'s
        // store-root lookups go through the on-disk manifest tree
        // (not the hot-path `store_root_cache`), so without this
        // an in-memory-only write would be invisible to the dump.
        self.manifest.durabilize() catch return Error.Io;

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

    // ── Tracked transactions (root-pointer revert) ──────────────
    //
    // kvexp's optimistic-write rollback is "capture the store's
    // root pointer before writing; on raft reject, setStoreRoot
    // back to it." This replaces the SQLite kv_undo table.
    //
    // The contract: callers must hold the per-store lock for the
    // life of the tracked txn (no other writer races). kvexp's
    // `Manifest.storeLock(id)` provides this; the dispatcher
    // already serializes per-tenant writes.

    pub const TrackedTxn = struct {
        store: *KvStore,
        /// Monotonic identifier for this txn. Used by callers as a
        /// breadcrumb (e.g., correlating raft proposals to
        /// in-flight writers). Allocated from the store's
        /// `SeqCounter` on `ensureOpen`.
        txn_seq: u64,
        kind: enum { normal, immediate },
        opened: bool,
        /// Store root captured at `ensureOpen`. `rollback` reverts
        /// the store to this root; null while the txn is closed.
        pre_root: ?u64 = null,
        /// Savepoint root for the innermost open savepoint. Single
        /// level (matches the SQLite-era usage which only ever
        /// stacked one savepoint named `h`). `null` when no
        /// savepoint is open.
        save_root: ?u64 = null,

        pub fn open(self: *TrackedTxn) Error!void {
            return self.ensureOpen();
        }

        fn ensureOpen(self: *TrackedTxn) Error!void {
            if (self.opened) return;
            const pre = self.store.manifest.storeRoot(self.store.store_id) catch
                return Error.Sqlite;
            self.pre_root = pre orelse 0;
            // Bump apply seq so subsequent writes CoW into fresh
            // pages instead of mutating pre_root's pages in place.
            // Without this, kvexp's same-apply-unit hybrid would
            // clobber the captured pre-image and `rollback` would
            // be a silent no-op.
            _ = self.store.manifest.nextApply();
            self.txn_seq = self.store.counter.next();
            self.opened = true;
        }

        pub fn put(self: *TrackedTxn, key: []const u8, value: []const u8) Error!void {
            try self.ensureOpen();
            try self.store.put(key, value);
        }

        pub fn delete(self: *TrackedTxn, key: []const u8) Error!void {
            try self.ensureOpen();
            try self.store.delete(key);
        }

        pub fn savepoint(self: *TrackedTxn) Error!void {
            try self.ensureOpen();
            const root = self.store.manifest.storeRoot(self.store.store_id) catch
                return Error.Sqlite;
            self.save_root = root orelse 0;
            // Same reason as `ensureOpen`: fresh apply seq so the
            // save_root's pages aren't clobbered by subsequent
            // in-place mutations within this txn.
            _ = self.store.manifest.nextApply();
        }

        pub fn release(self: *TrackedTxn) Error!void {
            self.save_root = null;
        }

        pub fn rollbackTo(self: *TrackedTxn) Error!void {
            const root = self.save_root orelse return;
            self.store.manifest.setStoreRoot(self.store.store_id, root) catch
                return Error.Sqlite;
            self.save_root = null;
        }

        pub fn commit(self: *TrackedTxn) Error!void {
            // No-op: kvexp commits each put/delete immediately.
            // The raft propose follows; if it rejects, the caller
            // routes to `rollback` which uses `pre_root`.
            self.opened = false;
        }

        pub fn rollback(self: *TrackedTxn) Error!void {
            if (!self.opened) return;
            const root = self.pre_root orelse 0;
            self.store.manifest.setStoreRoot(self.store.store_id, root) catch
                return Error.Sqlite;
            self.opened = false;
        }
    };

    pub fn beginTracked(self: *KvStore) Error!TrackedTxn {
        var txn: TrackedTxn = .{
            .store = self,
            .txn_seq = 0,
            .kind = .normal,
            .opened = false,
        };
        try txn.ensureOpen();
        return txn;
    }

    pub fn beginTrackedImmediate(self: *KvStore) Error!TrackedTxn {
        return .{
            .store = self,
            .txn_seq = 0,
            .kind = .immediate,
            .opened = false,
        };
    }

    /// Rollback a single tracked txn by reverting the store's root
    /// to the captured pre-image. The txn's TrackedTxn must still
    /// hold the captured pre_root; if it's been dropped this is a
    /// no-op (we can't recover what we don't remember). Returns
    /// success either way to keep callers' error-handling shape.
    pub fn undoTxn(self: *KvStore, txn_seq: u64) Error!void {
        _ = self;
        _ = txn_seq;
        // Without the TrackedTxn handle we have no captured
        // pre_root. Callers that need this should hold the
        // TrackedTxn and call `.rollback()` directly. This stub
        // exists for legacy callers; do not rely on it.
    }

    pub fn commitTxn(self: *KvStore, txn_seq: u64) Error!void {
        _ = self;
        _ = txn_seq;
    }

    pub fn gcUndoThrough(self: *KvStore, committed_seq: u64) Error!void {
        _ = self;
        _ = committed_seq;
    }

    pub fn recoverOrphans(self: *KvStore, committed_seq: u64) Error!void {
        _ = self;
        _ = committed_seq;
        // No kv_undo table to walk under kvexp. The crash-recovery
        // model is different: kvexp's slot-swap keeps the last
        // durable manifest intact; raft replay past
        // `lastAppliedRaftIdx` reconstructs the rest.
    }
};

/// Build a fresh kvexp manifest at `target_path` and replay
/// `dump_bytes` (a kvexp dump-format blob) into it. Closes durabilize
/// at the end so the file is self-contained. `target_path` must not
/// already exist. Used by `vacuumInto` and `dumpManifestToFile`.
fn writeManifestFile(
    allocator: std.mem.Allocator,
    target_path: [:0]const u8,
    dump_bytes: []const u8,
) Error!void {
    var target_file = kvexp.PagedFile.open(target_path, .{
        .create = true,
        .truncate = true,
        .page_size = kvexp.PAGE_SIZE_DEFAULT,
    }) catch return Error.Io;
    defer target_file.close();

    var target_pool = kvexp.BufferPool.init(
        allocator,
        kvexp.PAGE_SIZE_DEFAULT,
        STANDALONE_POOL_PAGES,
    ) catch return Error.OutOfMemory;
    defer target_pool.deinit(allocator);

    var target_cache = kvexp.PageCache.init(
        allocator,
        &target_file,
        &target_pool,
        .{},
    ) catch return Error.OutOfMemory;
    defer target_cache.deinit();

    var target_manifest: kvexp.Manifest = undefined;
    target_manifest.init(allocator, &target_cache, &target_file) catch
        return Error.Sqlite;
    defer target_manifest.deinit();

    var stream = std.io.fixedBufferStream(dump_bytes);
    _ = kvexp.loadSnapshot(&target_manifest, stream.reader()) catch
        return Error.Sqlite;
    target_manifest.durabilize() catch return Error.Io;
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
    try w.writeInt(u64, snap.snap_seq, .little);
    try w.writeInt(u64, snap.manifest.last_applied_raft_idx, .little);

    if (try snap.storeRoot(src_store_id) != null) {
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
    std.fs.cwd().deleteFile(path) catch {};
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

    // Build a kvexp stack outside any KvStore so we can attach.
    var file = try kvexp.PagedFile.open(src_path, .{
        .create = true,
        .page_size = kvexp.PAGE_SIZE_DEFAULT,
    });
    defer file.close();
    var pool = try kvexp.BufferPool.init(a, kvexp.PAGE_SIZE_DEFAULT, STANDALONE_POOL_PAGES);
    defer pool.deinit(a);
    var cache = try kvexp.PageCache.init(a, &file, &pool, .{});
    defer cache.deinit();
    var manifest: kvexp.Manifest = undefined;
    try manifest.init(a, &cache, &file);
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
