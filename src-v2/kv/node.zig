//! V2 data-plane core — the per-tenant pump (single node).
//!
//! docs/v2-build-order.md §Phase 1: "the heart of the rewrite." A
//! `Node` owns one `SharedWal` + one raft-rs `Manager`, and a pump that
//! drives the active set of per-tenant raft groups:
//!
//!     tickGroups(active) → pollReady → processReady (decode a committed
//!     entry → apply it to the tenant's kvexp store) → flush the shared
//!     WAL once → takeMessages → release
//!
//! One raft group per tenant (`group_id == tenant_id`), each with its
//! own `GroupedFileStorage` over the shared per-node WAL — the
//! single-fsync-per-cycle constraint that makes multi-tenant raft viable
//! (multiraft-scaling-learnings §3.2). The committed-entry apply path
//! reuses the limbs unchanged: the `envelope` codec, `writeset.applyEncoded`,
//! and `kvexp` via `KvStore` as the per-tenant state engine.
//!
//! Scope boundaries for Phase 1, deliberately deferred to later phases:
//!   - **single node, single voter** — no cross-node transport, so
//!     `takeMessages` drains to nowhere. Multi-node is Phase 5.
//!   - **no HTTP / JS** — propose + read are called directly. The
//!     worker-dispatch seam swap is Phase 2.
//!   - **no hibernation** — the active set only grows (every created
//!     group is ticked every cycle). Fine at Phase-1 tenant counts;
//!     the active-set/hibernation machinery is Phase 6
//!     (multiraft-scaling-learnings §3.1).
//!   - **no migration / epoch fence** — `createGroup` (birth epoch 0);
//!     detach/attach is Phase 4.
//!   - **no speculative overlay** — entries apply on commit (both the
//!     proposer and any follower run the same apply). The `TrackedTxn`
//!     pre-write-then-propose latency optimization belongs to the
//!     Phase-2 request path.
//!
//! Structural reference: rewind2's `multi_dispatcher.zig` (the
//! multi-node, multi-pump-worker, migration-capable superset this is the
//! single-node kernel of).

const std = @import("std");
const raft = @import("raft_rs_zig");
const kvlimbs = @import("kvlimbs");
const kvstore = kvlimbs.kvstore;
const writeset = kvlimbs.writeset;
const envelope = @import("envelope.zig");

pub const KvStore = kvstore.KvStore;
pub const WriteSet = writeset.WriteSet;
pub const Envelope = envelope.Envelope;

/// Fired once per committed *real* entry (writeset / multi / root —
/// not the leader's empty election no-op), AFTER it has applied, with
/// the entry's raft index. The bridge (`bridge.zig`) uses this to bind
/// per-tenant raft commit order to the per-tenant propose seq it handed
/// the worker (the seq → commit-order binding behind the per-tenant
/// watermark; docs/v2-build-order.md §Phase 2). `null` in the Phase-1
/// unit tests, which drive the pump directly and read inline.
pub const CommitHook = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, group_id: u64, raft_index: u64) void,
};

/// How committed entries apply to the tenant store (docs/v2-build-order.md
/// §Phase 2 leader-skip + the speculative overlay).
pub const ApplyMode = enum {
    /// Decode a committed writeset and write it to the tenant's kvexp
    /// store. The Phase-1 default and the future FOLLOWER role (Phase 5):
    /// followers have no speculative overlay, so apply IS the write.
    apply_on_commit,
    /// Single-node LEADER: the worker already wrote the entry into its own
    /// `TrackedTxn` speculative overlay before proposing and commits that
    /// overlay when the watermark advances — so the pump must NOT re-write
    /// the store (it would double-apply on a second handle). The pump only
    /// validates the envelope + advances the commit watermark.
    leader_skip,
};

pub const Error = error{
    /// A committed entry named a group with no live tenant slot — an
    /// invariant violation (we only apply entries for groups we created).
    UnknownGroup,
    /// A proposed write did not commit + apply within the pump budget.
    NotCommitted,
    OutOfMemory,
} || envelope.Error || raft.Error || kvstore.Error || writeset.DecodeError;

/// Per-tenant state: the kvexp store (the limb) plus bookkeeping. The
/// `GroupedFileStorage` for this tenant's group is owned by raft-rs once
/// `createGroup` is called (freed via the storage destroy-vtable when
/// the group is destroyed / on `Manager.deinit`), so it is not held here.
pub const TenantSlot = struct {
    tenant_id: u64,
    /// Borrowed slice into `Node`'s arena-free duped id string; the
    /// envelope `id` the worker stamps. Owned by the slot.
    id_str: []const u8,
    store: *KvStore,
    /// Highest raft index whose committed entry has been applied to
    /// `store`. 0 until the first apply.
    applied_idx: u64 = 0,
};

/// One V2 node: a `Manager` of per-tenant raft groups over one shared
/// WAL, plus the per-tenant kvexp stores the committed entries apply to.
pub const Node = struct {
    allocator: std.mem.Allocator,
    /// Owned dup. Per-tenant stores live at `{data_dir}/{tenant}/app.db`;
    /// the shared WAL at `{data_dir}/raft-wal`.
    data_dir: []const u8,
    /// This node's voter id within every group (single-node: 1).
    node_id: u64,
    /// Owned dup of the group voter set (single-node: `{node_id}`).
    voters: []const u64,

    mgr: raft.Manager,
    wal: *raft.SharedWal,

    /// tenant_id → slot. Iterated on deinit; looked up in the apply
    /// callback by `group_id`.
    groups: std.AutoHashMapUnmanaged(u64, *TenantSlot) = .empty,
    /// Group ids ticked every pump cycle. Phase 1: every created group
    /// (no hibernation). Index-aligned with nothing; just the tick list.
    active: std.ArrayListUnmanaged(u64) = .empty,
    /// `pollReady` scratch, grown to `groups.count()` as groups are added.
    ready_buf: []u64 = &.{},

    /// First error raised by the apply callback during the current
    /// `processReady` round (the C-ABI callback can't return one).
    /// Checked + cleared by `pump` after the round.
    apply_err: ?Error = null,

    /// Optional per-committed-entry notification (see `CommitHook`).
    /// Set by the bridge; left null by the Phase-1 inline tests.
    commit_hook: ?CommitHook = null,

    /// Whether committed entries write the store (`apply_on_commit`,
    /// default) or only advance the watermark (`leader_skip`). The bridge
    /// flips this to `leader_skip` when it fronts a worker that owns the
    /// speculative overlay; the Phase-1 tests + the 2a bridge tests keep
    /// the default so a read after commit sees the pump's write.
    apply_mode: ApplyMode = .apply_on_commit,

    /// Stand up a single-node node (voter id 1, voter set `{1}`).
    pub fn initSingleNode(allocator: std.mem.Allocator, data_dir: []const u8) Error!*Node {
        return Node.init(allocator, data_dir, 1, &.{1});
    }

    pub fn init(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        node_id: u64,
        voters: []const u64,
    ) Error!*Node {
        std.fs.cwd().makePath(data_dir) catch return Error.Io;

        const self = allocator.create(Node) catch return Error.OutOfMemory;
        errdefer allocator.destroy(self);

        const dir_dup = allocator.dupe(u8, data_dir) catch return Error.OutOfMemory;
        errdefer allocator.free(dir_dup);
        const voters_dup = allocator.dupe(u64, voters) catch return Error.OutOfMemory;
        errdefer allocator.free(voters_dup);

        const wal_path = std.fmt.allocPrint(allocator, "{s}/raft-wal", .{data_dir}) catch
            return Error.OutOfMemory;
        defer allocator.free(wal_path);
        const wal = raft.SharedWal.init(allocator, wal_path) catch return Error.Io;
        errdefer wal.deinit();

        var mgr = try raft.Manager.init();
        errdefer mgr.deinit();

        self.* = .{
            .allocator = allocator,
            .data_dir = dir_dup,
            .node_id = node_id,
            .voters = voters_dup,
            .mgr = mgr,
            .wal = wal,
        };
        return self;
    }

    pub fn deinit(self: *Node) void {
        const a = self.allocator;
        // Destroy groups first — `Manager.deinit` frees each group's
        // `GroupedFileStorage` via its destroy-vtable. The WAL is
        // borrowed by those storages, so it must outlive them: tear the
        // manager down before the WAL.
        self.mgr.deinit();
        self.wal.deinit();

        var it = self.groups.valueIterator();
        while (it.next()) |slot_ptr| {
            const slot = slot_ptr.*;
            slot.store.close();
            a.free(slot.id_str);
            a.destroy(slot);
        }
        self.groups.deinit(a);
        self.active.deinit(a);
        a.free(self.ready_buf);
        a.free(self.voters);
        a.free(self.data_dir);
        a.destroy(self);
    }

    /// Look up a tenant slot, or create its kvexp store + raft group on
    /// demand and drive the group to leader (single-node: campaign +
    /// pump). `id_str` is the envelope id the worker will stamp on this
    /// tenant's writesets; `tenant_id` is the numeric raft group id.
    pub fn ensureGroup(self: *Node, tenant_id: u64, id_str: []const u8) Error!*TenantSlot {
        if (self.groups.get(tenant_id)) |slot| return slot;

        // {data_dir}/{tenant_id}/app.db
        const dir = std.fmt.allocPrint(self.allocator, "{s}/{d}", .{ self.data_dir, tenant_id }) catch
            return Error.OutOfMemory;
        defer self.allocator.free(dir);
        std.fs.cwd().makePath(dir) catch return Error.Io;
        const path = std.fmt.allocPrintSentinel(self.allocator, "{s}/app.db", .{dir}, 0) catch
            return Error.OutOfMemory;
        defer self.allocator.free(path);

        const store = try KvStore.open(self.allocator, path);
        errdefer store.close();

        const slot = self.allocator.create(TenantSlot) catch return Error.OutOfMemory;
        errdefer self.allocator.destroy(slot);
        const id_dup = self.allocator.dupe(u8, id_str) catch return Error.OutOfMemory;
        errdefer self.allocator.free(id_dup);
        slot.* = .{ .tenant_id = tenant_id, .id_str = id_dup, .store = store };

        // GroupedFileStorage over the shared WAL. raft-rs takes ownership
        // via the vtable userdata slot and frees it when the group is
        // destroyed — do NOT free it here.
        const gfs = raft.GroupedFileStorage.init(self.allocator, self.voters, self.wal, tenant_id) catch
            return Error.Io;
        errdefer gfs.deinit();

        try self.mgr.createGroup(
            tenant_id,
            self.node_id,
            raft.manager.grouped_file_storage_vtable,
            gfs,
        );
        // After createGroup succeeds the manager owns `gfs`; cancel the
        // local errdefer so a later failure in this fn doesn't double-free.
        errdefer self.mgr.destroyGroup(tenant_id) catch {};

        self.groups.put(self.allocator, tenant_id, slot) catch return Error.OutOfMemory;
        errdefer _ = self.groups.remove(tenant_id);
        try self.active.append(self.allocator, tenant_id);
        errdefer _ = self.active.pop();
        try self.growReadyBuf();

        // Single-node: force this group to leader so proposes commit
        // immediately (no peers to elect from). Multi-node lets the
        // election fire via ticks (Phase 5).
        try self.mgr.campaign(tenant_id);
        var spins: u32 = 0;
        while (!self.mgr.isLeader(tenant_id) and spins < 100) : (spins += 1) {
            _ = try self.pump();
        }
        if (!self.mgr.isLeader(tenant_id)) return Error.NotCommitted;

        return slot;
    }

    fn growReadyBuf(self: *Node) Error!void {
        const need = self.groups.count();
        if (self.ready_buf.len >= need) return;
        const grown = self.allocator.realloc(self.ready_buf, need) catch return Error.OutOfMemory;
        self.ready_buf = grown;
    }

    /// Propose a raw raft-log entry to `tenant_id`'s group. Returns once
    /// the entry is staged in raft-rs's pending list — NOT once applied.
    /// Drive `pump` to commit + apply it.
    pub fn propose(self: *Node, tenant_id: u64, entry: []const u8) Error!void {
        try self.mgr.propose(tenant_id, entry);
    }

    /// Build a type-0 writeset envelope from `ws` and propose it, then
    /// pump until it commits + applies to the tenant's store (or the
    /// budget is exhausted → `NotCommitted`). Returns the applied index.
    pub fn proposeWriteSet(self: *Node, tenant_id: u64, id_str: []const u8, ws: *const WriteSet) Error!u64 {
        const slot = try self.ensureGroup(tenant_id, id_str);
        const before = slot.applied_idx;

        const ws_bytes = ws.encode(self.allocator) catch return Error.OutOfMemory;
        defer self.allocator.free(ws_bytes);
        const env = try envelope.encodeWriteSet(self.allocator, id_str, ws_bytes);
        defer self.allocator.free(env);

        try self.propose(tenant_id, env);

        var spins: u32 = 0;
        while (slot.applied_idx == before and spins < 200) : (spins += 1) {
            _ = try self.pump();
        }
        if (slot.applied_idx == before) return Error.NotCommitted;
        return slot.applied_idx;
    }

    /// Drive one ready cycle across the active set. Returns true if any
    /// group had committed entries to apply this cycle.
    ///
    /// Mirrors rewind2's `pumpNode`: tick the active set, process every
    /// ready group's committed entries, ONE `wal.flush()` for the whole
    /// cycle (the load-bearing single-fsync constraint), then drain each
    /// ready group's outbox and release it. Single-node has no peers, so
    /// `takeMessages` drains to a no-op sink — but the drain+release is
    /// still required to honour the pollReady/release pairing invariant.
    pub fn pump(self: *Node) Error!bool {
        _ = self.mgr.tickGroups(self.active.items);
        const ready = self.mgr.pollReady(self.ready_buf);
        if (ready.len == 0) return false;

        self.apply_err = null;
        for (ready) |g| {
            self.mgr.processReady(g, applyCb, self) catch |e| {
                self.apply_err = self.apply_err orelse mapRaftErr(e);
            };
        }

        // ONE fsync per cycle regardless of how many groups committed.
        self.wal.flush() catch {
            self.apply_err = self.apply_err orelse Error.Io;
        };

        for (ready) |g| {
            self.mgr.takeMessages(g, dropMsgCb, null) catch {};
            self.mgr.release(g);
        }

        if (self.apply_err) |e| {
            self.apply_err = null;
            return e;
        }
        return true;
    }

    /// Read a committed key from a tenant's store. Caller owns the
    /// returned bytes (`allocator.free`). `Error.NotFound` if absent.
    pub fn get(self: *Node, tenant_id: u64, key: []const u8) Error![]u8 {
        const slot = self.groups.get(tenant_id) orelse return Error.UnknownGroup;
        return slot.store.get(key);
    }

    // ── apply path ──────────────────────────────────────────────────

    /// C-ABI apply callback: fires once per committed entry during
    /// `processReady`. Decodes the envelope and routes it to the
    /// tenant's store. Errors are stashed in `self.apply_err` (the
    /// callback can't return one) and checked by `pump`.
    fn applyCb(
        ud: ?*anyopaque,
        group_id: u64,
        index: u64,
        term: u64,
        data: [*c]const u8,
        len: usize,
    ) callconv(.c) void {
        _ = term;
        const self: *Node = @ptrCast(@alignCast(ud.?));
        if (self.apply_err != null) return; // already failed this round
        // raft-rs emits empty entries (e.g. the leader's no-op on
        // election). Nothing to apply.
        if (len == 0) return;
        const bytes = data[0..len];
        self.applyEntry(group_id, index, bytes) catch |e| {
            self.apply_err = e;
            return;
        };
        // The entry committed + applied cleanly: notify the bridge so it
        // can advance the tenant's committed_seq watermark. Fires only on
        // the success path, so the leader's empty election no-op (len==0,
        // returned above) and any undecodable entry (apply_err, returned
        // above) never advance a tenant's watermark.
        if (self.commit_hook) |h| h.func(h.ctx, group_id, index);
    }

    fn applyEntry(self: *Node, group_id: u64, index: u64, bytes: []const u8) Error!void {
        const env = try envelope.decode(bytes);
        if (self.apply_mode == .leader_skip) {
            // Leader: the worker's TrackedTxn.commit is the durable write.
            // We still decode (above) so a stale/unknown envelope type
            // surfaces loudly, and bump applied_idx — but we do NOT touch
            // the store. Root writesets (no per-tenant group) are a no-op
            // here too; their durable write also rode the worker's txn.
            if (self.groups.get(group_id)) |slot| slot.applied_idx = index;
            return;
        }
        switch (env.type) {
            .writeset => {
                const slot = self.groups.get(group_id) orelse return Error.UnknownGroup;
                try writeset.applyEncoded(slot.store, index, env.payload);
                slot.applied_idx = index;
            },
            .multi => {
                const inner = try envelope.decodeMultiInner(self.allocator, env.payload);
                defer self.allocator.free(inner);
                for (inner) |inner_bytes| {
                    const ie = try envelope.decode(inner_bytes);
                    switch (ie.type) {
                        .writeset => {
                            // Inner writesets may target any tenant; in
                            // Phase 1 the only stores that exist are this
                            // node's, so route by the same group's slot.
                            const slot = self.groups.get(group_id) orelse return Error.UnknownGroup;
                            try writeset.applyEncoded(slot.store, index, ie.payload);
                            slot.applied_idx = index;
                        },
                        .multi => return envelope.Error.NestedMulti,
                        // root_writeset inside a multi: Phase 2+ (control
                        // plane). No root store in the Phase-1 pump.
                        .root_writeset => return Error.UnknownGroup,
                    }
                }
            },
            // The root store + its producer (provisionInstance / admin)
            // arrive in Phase 2+. The Phase-1 pump has per-tenant stores
            // only, so a stray root_writeset is an invariant violation.
            .root_writeset => return Error.UnknownGroup,
        }
    }

    fn dropMsgCb(
        _: ?*anyopaque,
        _: u64,
        _: [*c]const u8,
        _: usize,
    ) callconv(.c) void {}
};

/// Narrow a raft-rs error to the node's `Error` set (they overlap, but
/// the union above already includes `raft.Error`, so this is identity —
/// kept as a seam for when the two sets diverge).
fn mapRaftErr(e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.ProcessReadyFailed,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "Phase 1 exit: propose a writeset, it commits + applies, a read sees it" {
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const node = try Node.initSingleNode(a, dir);
    defer node.deinit();

    const tenant: u64 = 42;
    const id = "tenant-42";

    var ws = WriteSet.init(a);
    defer ws.deinit();
    try ws.addPut("greeting", "hello-v2");
    try ws.addPut("count", "1");

    const applied = try node.proposeWriteSet(tenant, id, &ws);
    try testing.expect(applied > 0);

    const got = try node.get(tenant, "greeting");
    defer a.free(got);
    try testing.expectEqualStrings("hello-v2", got);

    const got2 = try node.get(tenant, "count");
    defer a.free(got2);
    try testing.expectEqualStrings("1", got2);
}

test "a delete in a later writeset removes the key" {
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const node = try Node.initSingleNode(a, dir);
    defer node.deinit();

    const tenant: u64 = 7;
    const id = "t7";

    var ws1 = WriteSet.init(a);
    defer ws1.deinit();
    try ws1.addPut("k", "v");
    _ = try node.proposeWriteSet(tenant, id, &ws1);

    const got = try node.get(tenant, "k");
    a.free(got);

    var ws2 = WriteSet.init(a);
    defer ws2.deinit();
    try ws2.addDelete("k");
    const idx2 = try node.proposeWriteSet(tenant, id, &ws2);
    try testing.expect(idx2 > 0);

    try testing.expectError(Error.NotFound, node.get(tenant, "k"));
}

test "two tenants get independent stores on the same node" {
    const a = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const node = try Node.initSingleNode(a, dir);
    defer node.deinit();

    var ws_a = WriteSet.init(a);
    defer ws_a.deinit();
    try ws_a.addPut("who", "alice");
    _ = try node.proposeWriteSet(1, "t1", &ws_a);

    var ws_b = WriteSet.init(a);
    defer ws_b.deinit();
    try ws_b.addPut("who", "bob");
    _ = try node.proposeWriteSet(2, "t2", &ws_b);

    const a_who = try node.get(1, "who");
    defer a.free(a_who);
    try testing.expectEqualStrings("alice", a_who);

    const b_who = try node.get(2, "who");
    defer a.free(b_who);
    try testing.expectEqualStrings("bob", b_who);
}
