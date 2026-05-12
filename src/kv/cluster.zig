//! Cluster — multi-store raft library.
//!
//! Owns one raft group (RaftNode) and a set of named KvStores all
//! kept in sync via that group. Applications register envelope types
//! + apply functions; the library handles consensus, log compaction,
//! snapshot tick, and per-store apply-state tracking.
//!
//! ## Why this shape
//!
//! `rove-kv`'s original framing was "one KvStore + one raft group."
//! Reality diverged: Loop46's leader services many SQLite stores
//! (per-tenant `app.db`, singleton `__root__.db`, singleton
//! `schedules.db`) under one raft group. Routing between them lived
//! in Loop46-specific code (`src/js/apply.zig`'s `ApplyCtx`),
//! leaking app concerns into the library namespace.
//!
//! This module lifts the generic pieces of that pattern into the
//! library. See `docs/raft-kv-design.md` for the design discussion.
//!
//! ## What's generic vs application-specific
//!
//! Generic (handled here):
//! - Envelope wire format + decode dispatch.
//! - Built-in writeset envelope (`registerWriteSetEnvelope`):
//!   leader-skip, snapshot-replay filter, `_apply_state` stamp.
//! - Multi-envelope wrapper (`registerMultiEnvelope`): atomic
//!   apply of N inner envelopes per raft entry.
//! - Per-store cache + lazy lifecycle (`openStore` / `getStore` /
//!   `closeStore`).
//! - In-memory `last_applied_idx` mirror per store, used by the
//!   snapshot tick (#1.1) and exposed via `lastApplied`.
//!
//! Application-specific (registered via `registerEnvelope`):
//! - Custom envelope types (e.g., Loop46's schedule envelopes
//!   8/9/10/11) and their apply functions.
//! - Routing policy (which envelope hits which store, when to open
//!   per-tenant stores).
//! - Domain-specific value encodings (apps wrap KvStore in their
//!   own typed APIs).
//!
//! ## Threading
//!
//! `Cluster` lives on the raft thread. Per-store SQLite connections
//! it opens are raft-thread-local (NOMUTEX): the raft thread is the
//! only thread that touches them. Workers / dispatch threads use
//! their own per-tenant stores (separate connections to the same
//! files; SQLite WAL handles the coexistence).

const std = @import("std");
const kvstore = @import("kvstore.zig");
const writeset_mod = @import("writeset.zig");
const raft_node_mod = @import("raft_node.zig");

pub const KvStore = kvstore.KvStore;
pub const RaftNode = raft_node_mod.RaftNode;

pub const Error = error{
    Truncated,
    UnknownEnvelopeType,
    NestedMulti,
    StoreNotOpen,
    Sqlite,
    Io,
    OutOfMemory,
};

pub const MAX_ID_LEN: usize = 256;

// ── Envelope wire format ────────────────────────────────────────────
//
// Stable, library-defined: every envelope is
//
//   [1B type][2B id_len BE][id bytes][payload]
//
// Type 0 is reserved for "writeset against the store named by `id`"
// (the most common case). Type 1 is reserved for the multi-envelope
// wrapper. Types 2-255 are application-defined; applications register
// handlers via `registerEnvelope`.
//
// Pre-#1.0 Loop46 used types 0/2/7/8/9/10/11 directly; under the
// library they collapse to a smaller set:
//   type 0  → writeset (id = store_id; library-builtin)
//   type 1  → multi (library-builtin)
//   type 2+ → app-specific (Loop46 uses 2 for root_writeset,
//             8/9/10/11 for schedule envelopes)
// Apps that ship pre-launch don't need migration; on-disk shape
// is being clean-slated as part of this refactor.

pub const ENVELOPE_TYPE_WRITESET: u8 = 0;
pub const ENVELOPE_TYPE_MULTI: u8 = 1;

pub const Envelope = struct {
    type: u8,
    /// Store id when `type == ENVELOPE_TYPE_WRITESET`. For other
    /// types, application-defined (often empty for cluster-wide
    /// stores like a singleton schedules.db).
    id: []const u8,
    payload: []const u8,
};

pub fn decodeEnvelope(bytes: []const u8) Error!Envelope {
    if (bytes.len < 3) return Error.Truncated;
    const t = bytes[0];
    const id_len = std.mem.readInt(u16, bytes[1..3], .big);
    if (bytes.len < 3 + @as(usize, id_len)) return Error.Truncated;
    return .{
        .type = t,
        .id = bytes[3 .. 3 + id_len],
        .payload = bytes[3 + id_len ..],
    };
}

pub fn encodeEnvelope(
    allocator: std.mem.Allocator,
    t: u8,
    id: []const u8,
    payload: []const u8,
) ![]u8 {
    if (id.len > MAX_ID_LEN) return error.OutOfMemory;
    const total = 1 + 2 + id.len + payload.len;
    const out = try allocator.alloc(u8, total);
    out[0] = t;
    std.mem.writeInt(u16, out[1..3], @intCast(id.len), .big);
    @memcpy(out[3 .. 3 + id.len], id);
    @memcpy(out[3 + id.len ..], payload);
    return out;
}

/// Multi-envelope wrapper payload format:
///   `[u8 count][u32 inner_len LE][inner_envelope_bytes]{count}`
/// Each inner envelope is a complete `[type][id_len][id][payload]`
/// blob. Inner envelopes apply in order; nesting (a `multi` inside
/// a `multi`) panics. The outer envelope's `id` is empty.
pub fn encodeMulti(
    allocator: std.mem.Allocator,
    inner: []const []const u8,
) ![]u8 {
    if (inner.len > 0xff) return error.OutOfMemory;
    var inner_total: usize = 0;
    for (inner) |b| inner_total += 4 + b.len;
    const payload_len = 1 + inner_total;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    payload[0] = @intCast(inner.len);
    var pos: usize = 1;
    for (inner) |b| {
        std.mem.writeInt(u32, payload[pos..][0..4], @intCast(b.len), .little);
        pos += 4;
        @memcpy(payload[pos..][0..b.len], b);
        pos += b.len;
    }
    // encodeEnvelope copies `payload` into the returned buffer.
    return encodeEnvelope(allocator, ENVELOPE_TYPE_MULTI, "", payload);
}

/// Decode the inner-envelope byte slices from a multi-envelope's
/// payload. Slices alias the input buffer; do not free individually.
pub fn decodeMultiInner(
    allocator: std.mem.Allocator,
    payload: []const u8,
) Error![][]const u8 {
    if (payload.len < 1) return Error.Truncated;
    const count = payload[0];
    const out = allocator.alloc([]const u8, count) catch return Error.OutOfMemory;
    errdefer allocator.free(out);
    var pos: usize = 1;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (payload.len < pos + 4) return Error.Truncated;
        const len = std.mem.readInt(u32, payload[pos..][0..4], .little);
        pos += 4;
        if (payload.len < pos + len) return Error.Truncated;
        out[i] = payload[pos .. pos + len];
        pos += len;
    }
    return out;
}

// ── Store layout ───────────────────────────────────────────────────
//
// Each store lives at `{data_dir}/{store_id}/store.db`. Per-tenant
// stores have id = the tenant id; singleton stores (root, schedules)
// have a chosen-by-the-application id. The library doesn't
// distinguish between the two — they're all stores under a path.

fn storePath(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    store_id: []const u8,
    filename: []const u8,
) ![:0]u8 {
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, store_id });
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, filename }, 0);
}

// ── Envelope registration ──────────────────────────────────────────

pub const ApplyError = error{
    InvalidEnvelope,
    StoreNotOpen,
    Sqlite,
    OutOfMemory,
    Io,
};

/// Application-provided apply function for an envelope type.
/// `entry_idx` is the raft log index of the committed entry.
/// `inside_multi` indicates the envelope was unwrapped from a
/// multi-envelope; handlers can use this to reject multi-only or
/// top-level-only envelopes if needed.
pub const ApplyFn = *const fn (
    cluster: *Cluster,
    env: Envelope,
    entry_idx: u64,
    inside_multi: bool,
    user_ctx: ?*anyopaque,
) ApplyError!void;

pub const EnvelopeRegistration = struct {
    apply: ApplyFn,
    /// When true, the apply function is skipped on the leader —
    /// the worker's `LeaderTxn` already wrote locally before
    /// proposing. Used for the writeset envelope; rare for app
    /// types. The library still bumps the in-memory
    /// `last_applied_idx` mirror on the leader so snapshot tick
    /// works.
    leader_skip: bool = false,
};

// ── Cluster ────────────────────────────────────────────────────────

/// Subset of `RaftNode.Config` fields the application controls.
/// Cluster fills in the `apply` callback (so the chicken-and-egg
/// `cluster→raft→cluster` dependency stays inside the library).
pub const RaftBootConfig = struct {
    node_id: u32,
    peers: []const raft_node_mod.PeerAddr,
    listen_addr: std.net.Address,
    raft_log_path: ?[:0]const u8 = null,
    election_timeout_ms: u32 = 1000,
    request_timeout_ms: u32 = 200,
    propose_linger_ns: u64 = 0,
    propose_linger_max_batch: usize = 128,
    needs_snapshot: ?raft_node_mod.NeedsSnapshotFn = null,
    needs_snapshot_ctx: ?*anyopaque = null,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    /// Root directory for all per-store data. Each store gets its
    /// own subdir at `{data_dir}/{store_id}/`. The raft log lives
    /// at `{data_dir}/raft.log.db`.
    data_dir: []const u8,
    /// Filename used inside each per-store subdir. Default
    /// `store.db` matches the library's own convention; loop46
    /// passes `app.db` to keep its pre-Cluster on-disk layout
    /// stable through the migration. Borrowed for the cluster's
    /// lifetime — typically a string literal.
    store_filename: []const u8 = "store.db",
    /// Raft consensus parameters. Cluster owns the resulting
    /// `RaftNode` and destroys it on `deinit`. App accesses via
    /// `cluster.raft`. (Use `initWithExternalRaft` if you need
    /// to share an externally-owned raft node, e.g. inside a
    /// test harness.)
    raft: RaftBootConfig,
    /// Optional user-supplied context pointer threaded through
    /// every `ApplyFn` call. Apps stash their auxiliary state
    /// here (Loop46: schedules_store, schedule_wake, etc.).
    user_ctx: ?*anyopaque = null,
};

pub const Cluster = struct {
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    /// Per-store filename — see `Config.store_filename`. Borrowed.
    store_filename: []const u8,
    /// Owned by the cluster (via `init`) OR borrowed (via
    /// `initWithExternalRaft` for test harnesses). `raft_owned`
    /// tracks which.
    raft: *RaftNode,
    raft_owned: bool = true,
    user_ctx: ?*anyopaque,

    /// Lazy per-store cache (store_id → *KvStore). Keys are
    /// allocator-owned copies. Connections are raft-thread-local;
    /// see module docs.
    stores: std.StringHashMapUnmanaged(*KvStore) = .empty,

    /// Cluster-wide apply position. Raft idx is globally ordered,
    /// so one counter answers "have we already applied entry X?"
    /// without per-store bookkeeping. Persisted in `__root__.db`
    /// on each snapshot tick; seeded from there at startup.
    /// Advanced by every `applyOne` (regardless of envelope type
    /// or target store).
    global_apply_idx: u64 = 0,

    /// `__root__.db` handle. Opens lazily on first apply or first
    /// snapshot tick — whichever comes first. Holds the
    /// persistent `global_apply_idx` row + serves as the
    /// platform's `__root__.db` store for app-defined root
    /// writesets.
    root_store: ?*KvStore = null,

    /// Envelope-type → handler dispatch table. 256 entries (one
    /// per byte). Library populates entries 0 + 1 in `init`
    /// (writeset + multi); applications register the rest via
    /// `registerEnvelope`.
    handlers: [256]?EnvelopeRegistration = [_]?EnvelopeRegistration{null} ** 256,

    /// Standard init: cluster owns its RaftNode. The raft node's
    /// apply ctx points back at this cluster, so apply callbacks
    /// route through `applyCallback` automatically.
    pub fn init(cfg: Config) !*Cluster {
        const self = try cfg.allocator.create(Cluster);
        errdefer cfg.allocator.destroy(self);
        self.initFields(cfg.allocator, cfg.data_dir, cfg.store_filename, cfg.user_ctx);

        // Now create the raft node with this cluster as ctx. The
        // chicken-and-egg dependency is resolved here: `self` is
        // a stable pointer, the raft node's apply callback uses
        // it as opaque ctx, but apply doesn't fire until raft.tick
        // runs (after this function returns).
        const raft = try RaftNode.init(cfg.allocator, .{
            .node_id = cfg.raft.node_id,
            .peers = cfg.raft.peers,
            .listen_addr = cfg.raft.listen_addr,
            .raft_log_path = cfg.raft.raft_log_path,
            .election_timeout_ms = cfg.raft.election_timeout_ms,
            .request_timeout_ms = cfg.raft.request_timeout_ms,
            .propose_linger_ns = cfg.raft.propose_linger_ns,
            .propose_linger_max_batch = cfg.raft.propose_linger_max_batch,
            .needs_snapshot = cfg.raft.needs_snapshot,
            .needs_snapshot_ctx = cfg.raft.needs_snapshot_ctx,
            .apply = .{ .opaque_bytes = .{
                .apply_fn = applyCallback,
                .ctx = self,
            } },
        });
        self.raft = raft;
        self.raft_owned = true;
        return self;
    }

    /// Test-only: cluster borrows an externally-owned raft node.
    /// Caller must arrange for the raft node's apply callback to
    /// reach `applyCallback(... ctx = self ...)` somehow (or never
    /// fire). Used by smokes and unit tests that mock raft.
    pub fn initWithExternalRaft(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        raft: *RaftNode,
        user_ctx: ?*anyopaque,
    ) !*Cluster {
        const self = try allocator.create(Cluster);
        errdefer allocator.destroy(self);
        self.initFields(allocator, data_dir, "store.db", user_ctx);
        self.raft = raft;
        self.raft_owned = false;
        return self;
    }

    fn initFields(
        self: *Cluster,
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        store_filename: []const u8,
        user_ctx: ?*anyopaque,
    ) void {
        self.* = .{
            .allocator = allocator,
            .data_dir = data_dir,
            .store_filename = store_filename,
            .raft = undefined,
            .raft_owned = false,
            .user_ctx = user_ctx,
            .stores = .empty,
            .global_apply_idx = 0,
            .root_store = null,
            .handlers = [_]?EnvelopeRegistration{null} ** 256,
        };
        // Built-in handlers.
        self.handlers[ENVELOPE_TYPE_WRITESET] = .{
            .apply = applyWriteSet,
            .leader_skip = true,
        };
        self.handlers[ENVELOPE_TYPE_MULTI] = .{
            .apply = applyMulti,
            .leader_skip = false,
        };
    }

    pub fn deinit(self: *Cluster) void {
        if (self.raft_owned) self.raft.deinit();

        if (self.root_store) |s| s.close();

        var s_it = self.stores.iterator();
        while (s_it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.*.close();
        }
        self.stores.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Register an apply handler for an envelope type byte. Types
    /// 0 (writeset) and 1 (multi) ship with library defaults
    /// (`Cluster.applyWriteSet` / `applyMulti`); passing them here
    /// replaces the default. Custom handlers for type 0 are the
    /// loop46 pattern — they call `Cluster.applyWriteSet` to chain
    /// to the default behavior, then layer in app-specific post-
    /// processing (e.g., follower-side deployment loader enqueue
    /// on a `_deploy/current` write).
    pub fn registerEnvelope(
        self: *Cluster,
        type_byte: u8,
        registration: EnvelopeRegistration,
    ) !void {
        self.handlers[type_byte] = registration;
    }

    // ── Store lifecycle ────────────────────────────────────────

    /// Lazily open a store. Idempotent: subsequent calls return the
    /// cached pointer. Pointer is stable for the cluster's lifetime
    /// (until `closeStore` or `deinit`).
    pub fn openStore(self: *Cluster, store_id: []const u8) !*KvStore {
        if (self.stores.get(store_id)) |existing| return existing;

        const path = try storePath(self.allocator, self.data_dir, store_id, self.store_filename);
        defer self.allocator.free(path);

        const store = try KvStore.open(self.allocator, path);
        errdefer store.close();

        const id_copy = try self.allocator.dupe(u8, store_id);
        errdefer self.allocator.free(id_copy);
        try self.stores.put(self.allocator, id_copy, store);

        return store;
    }

    pub fn getStore(self: *Cluster, store_id: []const u8) ?*KvStore {
        return self.stores.get(store_id);
    }

    pub fn closeStore(self: *Cluster, store_id: []const u8) void {
        if (self.stores.fetchRemove(store_id)) |kv| {
            self.allocator.free(kv.key);
            kv.value.close();
        }
    }

    /// Lazily open `{data_dir}/__root__.db`. First-open seeds
    /// `global_apply_idx` from the row stored there (`0` on a
    /// fresh data dir, the persisted floor on a restart).
    pub fn openRoot(self: *Cluster) !*KvStore {
        if (self.root_store) |existing| return existing;
        const path = try std.fmt.allocPrintSentinel(
            self.allocator,
            "{s}/__root__.db",
            .{self.data_dir},
            0,
        );
        defer self.allocator.free(path);

        const store = try KvStore.open(self.allocator, path);
        errdefer store.close();
        self.root_store = store;
        if (self.global_apply_idx == 0) {
            self.global_apply_idx = store.lastAppliedRaftIdx() catch 0;
        }
        return store;
    }

    // ── Apply-state tracking ───────────────────────────────────

    /// Read the in-memory global apply idx.
    pub fn lastApplied(self: *const Cluster) u64 {
        return self.global_apply_idx;
    }

    /// Bump the global apply idx. Monotonic — silently keeps the
    /// higher value on stale callers.
    fn noteApplied(self: *Cluster, idx: u64) void {
        if (idx > self.global_apply_idx) self.global_apply_idx = idx;
    }

    // ── Apply dispatch ─────────────────────────────────────────

    /// Hand-off function for `RaftNode.opaque_bytes` apply mode.
    /// Wire the pointer to your raft init's `apply.opaque_bytes
    /// .apply_fn`; the cluster pointer goes in `apply.opaque_bytes
    /// .ctx`.
    pub fn applyCallback(
        entry_idx: u64,
        bytes: []const u8,
        ctx_opaque: ?*anyopaque,
    ) void {
        const self: *Cluster = @ptrCast(@alignCast(ctx_opaque.?));
        self.applyOne(entry_idx, bytes) catch |err| {
            // Apply errors are programming bugs (envelope decode,
            // missing handler, etc.) — escalate, don't silently
            // swallow. Apps with more nuanced error categorization
            // can wrap their handlers and panic from inside.
            std.debug.panic("cluster.applyOne: {s}", .{@errorName(err)});
        };
    }

    pub fn applyOne(self: *Cluster, entry_idx: u64, bytes: []const u8) !void {
        // Global apply filter — replaces the per-store
        // `_apply_state` lookup that used to live inside each
        // envelope's handler. Raft idx is totally ordered, so
        // one counter answers the question for the entire
        // cluster.
        if (entry_idx <= self.global_apply_idx) return;
        defer self.noteApplied(entry_idx);

        const env = try decodeEnvelope(bytes);
        try self.dispatch(env, entry_idx, false);
    }

    fn dispatch(
        self: *Cluster,
        env: Envelope,
        entry_idx: u64,
        inside_multi: bool,
    ) !void {
        const reg = self.handlers[env.type] orelse return Error.UnknownEnvelopeType;
        if (reg.leader_skip and self.raft.isLeader()) {
            // Leader-side fast path: the app already wrote
            // locally via its own connection; we don't want a
            // second writer. The outer `applyOne` already
            // advanced the global counter.
            return;
        }
        try reg.apply(self, env, entry_idx, inside_multi, self.user_ctx);
    }

    // ── Snapshot tick (stamp-and-compact) ─────────────────────
    //
    // Same shape as `loop46/snapshot.zig::tickRaftCapture` but
    // generic across whatever stores are registered. Caller
    // invokes from the raft thread on a periodic timer. See
    // `docs/production.md` #1.1 for design + bench numbers.

    pub const TickResult = struct {
        /// willemt commit_idx at the moment of the tick.
        apply_position: u64,
        /// Wall-clock duration of the tick (stamp __root__.db +
        /// willemt begin/end + page compaction).
        duration_ms: u64,
    };

    pub const TickConfig = struct {
        /// Minimum interval between ticks. Pass 0 to fire on
        /// every call (typically the caller's own loop already
        /// rate-limits via this field).
        interval_ns: i64 = 0,
    };

    /// Periodic state used by `tickSnapshot`. Caller owns; pass
    /// the same instance on every tick so the elapsed-time gate
    /// works.
    pub const TickState = struct {
        last_attempt_ns: i64 = 0,
    };

    /// O(1) snapshot tick: one stamp in `__root__.db` records the
    /// new compaction floor, then willemt advances + page-level
    /// log compaction runs. No per-store work — raft idx is
    /// globally ordered, so the single counter answers the apply
    /// filter cluster-wide. See `docs/production.md` #1.5.
    ///
    /// Returns null if the tick was skipped (not leader, interval
    /// not elapsed, or willemt has nothing to snapshot).
    pub fn tickSnapshot(
        self: *Cluster,
        state: *TickState,
        cfg: TickConfig,
        now_ns: i64,
    ) !?TickResult {
        if (cfg.interval_ns > 0 and now_ns - state.last_attempt_ns < cfg.interval_ns) return null;
        state.last_attempt_ns = now_ns;

        if (!self.raft.isLeader()) return null;
        if (!self.raft.beginSnapshotOpaque()) return null;
        errdefer self.raft.endSnapshotOpaque();

        const start_ns = std.time.nanoTimestamp();
        const apply_position = self.raft.snapshotLastIdx();

        // One stamp: persist the global apply idx to __root__.db
        // so a restart resumes from this floor. Cost is one row
        // update + WAL append + fsync, regardless of how many
        // stores exist on this node.
        const root = self.openRoot() catch |err| {
            std.log.warn(
                "cluster.tickSnapshot: openRoot failed: {s}",
                .{@errorName(err)},
            );
            return null;
        };
        root.setLastAppliedRaftIdx(apply_position) catch |err| {
            std.log.warn(
                "cluster.tickSnapshot: setLastAppliedRaftIdx __root__ failed: {s}",
                .{@errorName(err)},
            );
            return null;
        };

        self.raft.endSnapshotOpaque();
        self.raft.compactLogPages() catch |err| {
            std.log.warn(
                "cluster.tickSnapshot: compactLogPages failed: {s}",
                .{@errorName(err)},
            );
        };

        const elapsed_ns = std.time.nanoTimestamp() - start_ns;
        const duration_ms: u64 = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));

        return .{
            .apply_position = apply_position,
            .duration_ms = duration_ms,
        };
    }

    // ── Propose path ──────────────────────────────────────────

    pub const ProposeError = error{
        NotLeader,
        ShuttingDown,
        QueueFull,
        OutOfMemory,
        ProposalTimedOut,
    };

    /// Propose a fully-encoded envelope and block until raft
    /// commits it (or fails). Returns the raft seq the proposal
    /// committed at on success.
    ///
    /// Caller waits via spinning on `committedSeq()`. For deploy-
    /// shaped workloads (low-frequency, sub-second commit latency)
    /// this is fine; for high-throughput hot-path writers, use
    /// the per-worker watermark protocol on RaftNode directly.
    pub fn proposeAndWait(
        self: *Cluster,
        envelope_bytes: []const u8,
        timeout_ns: u64,
    ) ProposeError!u64 {
        if (!self.raft.isLeader()) return ProposeError.NotLeader;

        const seq = self.raft.highWatermark() + 1;
        self.raft.propose(seq, envelope_bytes) catch |err| switch (err) {
            error.NotLeader => return ProposeError.NotLeader,
            error.ShuttingDown => return ProposeError.ShuttingDown,
            error.QueueFull => return ProposeError.QueueFull,
            error.OutOfMemory => return ProposeError.OutOfMemory,
        };

        const start_ns = std.time.nanoTimestamp();
        while (true) {
            if (self.raft.committedSeq() >= seq) return seq;
            // Faulted seq advances when leadership is lost mid-commit
            // — the proposal's writeset is logically rolled back.
            if (self.raft.faultedSeq() >= seq) return ProposeError.NotLeader;

            const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start_ns);
            if (elapsed >= timeout_ns) return ProposeError.ProposalTimedOut;

            std.Thread.sleep(100 * std.time.ns_per_us);
        }
    }

    // ── Built-in: writeset envelope ────────────────────────────
    //
    // Public so applications can register a non-leader-skip
    // variant of the writeset envelope. files-server does this:
    // its deploy commit runs through propose-then-apply on every
    // node (simpler than loop46's pre-write-via-TrackedTxn pattern,
    // because deploy throughput doesn't justify the optimization).

    pub fn applyWriteSet(
        cluster: *Cluster,
        env: Envelope,
        entry_idx: u64,
        inside_multi: bool,
        _: ?*anyopaque,
    ) ApplyError!void {
        _ = inside_multi;
        _ = entry_idx; // global filter already ran in dispatch

        const store = cluster.openStore(env.id) catch |err| switch (err) {
            error.OutOfMemory => return ApplyError.OutOfMemory,
            else => return ApplyError.Sqlite,
        };

        writeset_mod.applyEncoded(store, 0, env.payload) catch
            return ApplyError.Sqlite;
    }

    // ── Built-in: multi-envelope wrapper ──────────────────────

    fn applyMulti(
        cluster: *Cluster,
        env: Envelope,
        entry_idx: u64,
        inside_multi: bool,
        _: ?*anyopaque,
    ) ApplyError!void {
        if (inside_multi) {
            // Nested multi-envelope. Caller's responsibility to
            // never produce one; library refuses.
            return ApplyError.InvalidEnvelope;
        }
        const inner = decodeMultiInner(cluster.allocator, env.payload) catch {
            return ApplyError.InvalidEnvelope;
        };
        defer cluster.allocator.free(inner);

        for (inner) |inner_bytes| {
            const inner_env = decodeEnvelope(inner_bytes) catch
                return ApplyError.InvalidEnvelope;
            cluster.dispatch(inner_env, entry_idx, true) catch |err| switch (err) {
                // ApplyError variants pass through unchanged.
                error.OutOfMemory => return ApplyError.OutOfMemory,
                error.Sqlite => return ApplyError.Sqlite,
                error.Io => return ApplyError.Io,
                error.StoreNotOpen => return ApplyError.StoreNotOpen,
                error.InvalidEnvelope => return ApplyError.InvalidEnvelope,
                // Library errors (Truncated, UnknownEnvelopeType,
                // NestedMulti) coerce to InvalidEnvelope.
                error.Truncated,
                error.UnknownEnvelopeType,
                error.NestedMulti,
                => return ApplyError.InvalidEnvelope,
            };
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "envelope encode + decode round-trips" {
    const out = try encodeEnvelope(testing.allocator, 7, "acme", "hello");
    defer testing.allocator.free(out);

    const env = try decodeEnvelope(out);
    try testing.expectEqual(@as(u8, 7), env.type);
    try testing.expectEqualStrings("acme", env.id);
    try testing.expectEqualStrings("hello", env.payload);
}

test "envelope decode rejects truncated payload" {
    try testing.expectError(Error.Truncated, decodeEnvelope(&[_]u8{0}));
    try testing.expectError(Error.Truncated, decodeEnvelope(&[_]u8{ 0, 0, 5 }));
}

test "multi encode + decode round-trips" {
    const e1 = try encodeEnvelope(testing.allocator, 0, "tenant_a", "payload_a");
    defer testing.allocator.free(e1);
    const e2 = try encodeEnvelope(testing.allocator, 5, "", "payload_b");
    defer testing.allocator.free(e2);

    const inners = [_][]const u8{ e1, e2 };
    const wrapped = try encodeMulti(testing.allocator, &inners);
    defer testing.allocator.free(wrapped);

    const outer = try decodeEnvelope(wrapped);
    try testing.expectEqual(@as(u8, ENVELOPE_TYPE_MULTI), outer.type);
    try testing.expectEqualStrings("", outer.id);

    const decoded = try decodeMultiInner(testing.allocator, outer.payload);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 2), decoded.len);
    try testing.expectEqualSlices(u8, e1, decoded[0]);
    try testing.expectEqualSlices(u8, e2, decoded[1]);
}

test "register envelope rejects reserved types" {
    // Stub Cluster — raft can stay undefined because we only test
    // the handler registration table. initFields populates the
    // built-in writeset + multi handlers.
    var c = Cluster{
        .allocator = testing.allocator,
        .data_dir = "",
        .raft = undefined,
        .raft_owned = false,
        .user_ctx = null,
    };
    c.handlers[ENVELOPE_TYPE_WRITESET] = .{ .apply = Cluster.applyWriteSet, .leader_skip = true };
    c.handlers[ENVELOPE_TYPE_MULTI] = .{ .apply = Cluster.applyMulti, .leader_skip = false };

    const fake_handler: ApplyFn = struct {
        fn f(_: *Cluster, _: Envelope, _: u64, _: bool, _: ?*anyopaque) ApplyError!void {}
    }.f;

    try testing.expectError(error.OutOfMemory, c.registerEnvelope(
        ENVELOPE_TYPE_WRITESET,
        .{ .apply = fake_handler },
    ));
    try testing.expectError(error.OutOfMemory, c.registerEnvelope(
        ENVELOPE_TYPE_MULTI,
        .{ .apply = fake_handler },
    ));
    // Non-reserved type is fine.
    try c.registerEnvelope(42, .{ .apply = fake_handler });
    try testing.expect(c.handlers[42] != null);
}
