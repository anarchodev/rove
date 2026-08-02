// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Group lifecycle for the data-plane `Node` — standing up and tearing down
//! per-tenant raft groups (ensure/create/recover, the node-local group manifest,
//! and `GroupedFileStorage` handoff to the Manager). Method bodies for
//! `node_core.zig`'s `Node`, split out by concern; `node.zig` (the module root)
//! re-exports them via `Node`. Imports `node_core.zig` for the types — never
//! `node.zig` (the root-import trap; see node.zig's header).

const std = @import("std");
const raft = @import("raft_rs_zig");

const core = @import("node_core.zig");
const Node = core.Node;
const TenantSlot = core.TenantSlot;
const Error = core.Error;
const KvStore = core.KvStore;

/// Look up a tenant slot, or create its kvexp store + raft group on
/// demand and drive the group to leader (single-node: campaign +
/// pump). `id_str` is the envelope id the worker will stamp on this
/// tenant's writesets; `tenant_id` is the numeric raft group id. The
/// never-migrated birth case: epoch 0 (`createGroup`).
pub fn ensureGroup(self: *Node, tenant_id: u64, id_str: []const u8) Error!*TenantSlot {
    if (self.groups.get(tenant_id)) |slot| return slot;
    // Birth OR restart: recover any durable WAL records for this group
    // (a no-op on a never-seen group). On a restart this replays the
    // committed log back into the store.
    return self.createGroupCore(tenant_id, id_str, 0, true, false, null);
}

/// Attach a tenant group at an explicit migration fence `epoch` (the
/// move-destination path; v2-build-order §Phase 4
/// "createGroupEpoch(tenant, epoch+1) on destination"). The tenant's
/// kvexp state must already have been loaded (the bundle landed in the
/// worker's `cluster.kv` store); this just stands up the consensus
/// half — a fresh group whose epoch fences out any straggler traffic
/// from the source incarnation (moot single-node, load-bearing under
/// live overlap). `clearTombstone` first so a tenant id reused
/// after a prior `destroyGroupAndReclaim` on THIS node can re-attach.
/// Errors if the group already exists (attach is not idempotent — a
/// double attach is an orchestration bug worth surfacing).
/// `as_learner` births the group with THIS node as a non-voting learner
/// (voters = the rest), for joining an existing group safely — see
/// `createGroupCore`. The default (false) births a voter from the static
/// voter set (a move destination / a configured voter rejoining).
pub fn createGroupAtEpoch(self: *Node, tenant_id: u64, id_str: []const u8, epoch: u64, as_learner: bool, voters_override: ?[]const u64) Error!*TenantSlot {
    if (self.groups.get(tenant_id) != null) return Error.GroupExists;
    self.mgr.clearTombstone(tenant_id) catch {};
    // A migration attach is a FRESH group — its state arrives via the
    // bundle, not the WAL — so do NOT replay any (stale) recovered records
    // for this gid.
    return self.createGroupCore(tenant_id, id_str, epoch, false, as_learner, voters_override);
}

/// A group recorded in the node-local manifest (see `groups_manifest`):
/// the tenant id string + its birth/migration epoch.
pub const PersistedGroup = struct {
    id_str: []u8,
    epoch: u64,
};

/// Re-stand-up a persisted group at boot from its durable WAL state
/// (`createGroupCore(recover=true)`) at the recorded `epoch`. The rejoined
/// node is already a voter in the group's persisted confstate, so once the
/// pump starts the leader replicates the missing log tail (or ships a
/// snapshot) and the node catches up — no conf-change needed. Pre-pump,
/// single-threaded, like `ensureGroup`. Idempotent.
pub fn recoverGroup(self: *Node, tenant_id: u64, id_str: []const u8, epoch: u64) Error!*TenantSlot {
    if (self.groups.get(tenant_id)) |slot| return slot;
    return self.createGroupCore(tenant_id, id_str, epoch, true, false, null);
}

/// Record (or update) a group in the node-local recovery manifest, then
/// DURABILIZE it (fold the manifest's kvexp overlay into LMDB). Best-effort:
/// a manifest failure is logged, never propagated — the live group already
/// exists; recovery is a resilience feature, not a gate. Pump-thread (group
/// lifecycle).
///
/// The durabilize is load-bearing: `KvStore.put` commits only to the kvexp
/// VOLATILE overlay (like a tenant write before `durabilizeTick` folds it).
/// The manifest store is never on the `dirty` durabilize path, so without an
/// explicit fold here a hard crash (SIGKILL) loses every non-genesis group's
/// record — on restart `recoverGroups` reads an empty manifest and the node
/// silently drops that tenant's raft messages ("unknown group") forever. The
/// fold is an fsync, but group create/move is rare, so the cost is fine.
pub fn recordGroup(self: *Node, id_str: []const u8, epoch: u64) void {
    var buf: [24]u8 = undefined;
    const ep = std.fmt.bufPrint(&buf, "{d}", .{epoch}) catch return;
    self.groups_manifest.put(id_str, ep) catch |err| {
        std.log.warn("v2 node: group manifest record {s} failed: {s}", .{ id_str, @errorName(err) });
        return;
    };
    self.groups_manifest.checkpoint() catch |err| std.log.warn(
        "v2 node: group manifest durabilize {s} failed: {s} (record may not survive a crash)",
        .{ id_str, @errorName(err) },
    );
}

/// Remove a group from the recovery manifest (move-out) + durabilize the
/// delete (so a crash can't resurrect a moved-out group's record). Best-effort.
pub fn forgetGroup(self: *Node, id_str: []const u8) void {
    self.groups_manifest.delete(id_str) catch |err| {
        std.log.warn("v2 node: group manifest forget {s} failed: {s}", .{ id_str, @errorName(err) });
        return;
    };
    self.groups_manifest.checkpoint() catch |err| std.log.warn(
        "v2 node: group manifest durabilize (forget {s}) failed: {s}",
        .{ id_str, @errorName(err) },
    );
}

/// Read the recovery manifest into a freshly-allocated slice (caller owns:
/// free each `id_str`, then the slice via `freePersistedGroups`). Read once
/// at boot by `Bridge.recoverGroups`. Empty on a fresh data dir.
pub fn persistedGroups(self: *Node, allocator: std.mem.Allocator) Error![]PersistedGroup {
    var out: std.ArrayListUnmanaged(PersistedGroup) = .empty;
    errdefer {
        for (out.items) |g| allocator.free(g.id_str);
        out.deinit(allocator);
    }
    var cursor_buf: ?[]u8 = null;
    defer if (cursor_buf) |c| allocator.free(c);
    while (true) {
        const cursor: []const u8 = cursor_buf orelse "";
        var page = self.groups_manifest.prefix("", cursor, 256) catch return Error.Io;
        defer page.deinit();
        if (page.entries.len == 0) break;
        for (page.entries) |e| {
            const epoch = std.fmt.parseInt(u64, e.value, 10) catch 0;
            const id_dup = allocator.dupe(u8, e.key) catch return Error.OutOfMemory;
            out.append(allocator, .{ .id_str = id_dup, .epoch = epoch }) catch {
                allocator.free(id_dup);
                return Error.OutOfMemory;
            };
        }
        const last = page.entries[page.entries.len - 1].key;
        const new_cursor = allocator.dupe(u8, last) catch return Error.OutOfMemory;
        if (cursor_buf) |c| allocator.free(c);
        cursor_buf = new_cursor;
        if (page.entries.len < 256) break;
    }
    return out.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

/// Free a `persistedGroups` result.
pub fn freePersistedGroups(allocator: std.mem.Allocator, groups: []PersistedGroup) void {
    for (groups) |g| allocator.free(g.id_str);
    allocator.free(groups);
}

/// Shared group-birth core for `ensureGroup` (epoch 0) and
/// `createGroupAtEpoch` (migration epoch): open the tenant's kvexp
/// store, stand up a `GroupedFileStorage` over the shared WAL, create
/// the raft group at `epoch`, register the slot, and drive it to
/// leader (single-node campaign). Caller has already verified the
/// group does not exist.
/// `voters_override`: the initial voter set a FRESH group is born with,
/// supplied by the control plane (the cluster's node set, the single source
/// of truth) instead of this node's static `REWIND_VOTERS` env. Null → fall
/// back to `self.voters`. Ignored on the `recover` path (a rejoining group
/// restores its membership from the WAL) and immaterial under a baseline
/// (the baseline's ConfState overwrites the born membership).
pub fn createGroupCore(self: *Node, tenant_id: u64, id_str: []const u8, epoch: u64, recover: bool, as_learner: bool, voters_override: ?[]const u64) Error!*TenantSlot {
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
    // Whatever was already durabilized into LMDB (a prior incarnation's
    // checkpoint) is the starting watermark — don't re-durabilize or
    // re-compact below it.
    const durable_idx = store.lastAppliedRaftIdx() catch 0;

    // GroupedFileStorage over the shared WAL. raft-rs takes ownership
    // via the vtable userdata slot and frees it when the group is
    // destroyed — do NOT free it here. `initRecover` replays this group's
    // records that `SharedWal.open` recovered (a no-op when none were —
    // identical to `init`); `init` ignores any recovered records (the
    // migration-attach case wants a fresh group from the bundle).
    // Born-as-learner: a node being ADDED to an existing group must join as
    // a non-voting learner. A learner never campaigns, so it follows the
    // leader and catches up; a born-VOTER (the default, ConfState from the
    // static voter set) would campaign past a high-term leader's term and
    // deadlock — it rejects the leader's lower-term appends forever (the
    // __admin__ wall). Split self out of the voter set into a sole learner.
    // Fresh-group only: `recover` restores the persisted membership from the
    // WAL, so a rejoining node keeps whatever role it last held.
    // The born ConfState's voter set: the CP-supplied cluster node set when
    // given (the single source of truth), else this node's static `REWIND_VOTERS`.
    const base_voters = voters_override orelse self.voters;
    if (!recover) std.log.info(
        "v2 node: gid={d} born voters={any} source={s}",
        .{ tenant_id, base_voters, if (voters_override != null) "cp-ssot" else "rewind_voters" },
    );
    var voters_scratch: [64]u64 = undefined;
    const learner_self = [_]u64{self.node_id};
    var voters_slice: []const u64 = base_voters;
    var learners_slice: []const u64 = &.{};
    if (as_learner and !recover) {
        var n: usize = 0;
        for (base_voters) |v| {
            if (v != self.node_id and n < voters_scratch.len) {
                voters_scratch[n] = v;
                n += 1;
            }
        }
        voters_slice = voters_scratch[0..n];
        learners_slice = &learner_self;
    }
    const gfs = if (recover)
        raft.GroupedFileStorage.initRecover(self.allocator, self.voters, self.wal, tenant_id) catch return Error.Io
    else
        raft.GroupedFileStorage.initWithLearners(self.allocator, voters_slice, learners_slice, self.wal, tenant_id) catch return Error.Io;
    // Ownership of `gfs` once it is handed to `createGroupEpoch` below. A bare
    // `errdefer gfs.deinit()` here was a DOUBLE-FREE — the SIGABRT (GP fault in
    // raft-rs storage deinit iterating already-freed entries):
    //   • SUCCESS — the manager owns `gfs` and frees it on `destroyGroup`; a
    //     plain errdefer would free it AGAIN on any later failure here.
    //   • FAILURE — `createGroupEpoch` failing for THIS caller means raft-rs's
    //     `RawNode::new` REJECTED the config (the FFI returns -3). The Rust side
    //     has ALREADY taken `gfs` into an `FfiStorage` whose `Drop` calls the
    //     `destroy` vtable — so the FFI freed it; a Zig-side deinit double-frees.
    //     (The FFI's other failure returns, where it does NOT free — group
    //     exists / tombstoned / null args — are all pre-empted by the Zig
    //     guards above: the `self.groups`/`GroupExists` check, `clearTombstone`,
    //     and a non-zero `self.node_id`. So a failure HERE is only ever the
    //     RawNode rejection, which freed.)
    // Either way the manager owns `gfs` from the call onward, so arm the deinit
    // ONLY for failures BEFORE the handoff (the slot/id_dup allocs below).
    var gfs_owned_by_mgr = false;
    errdefer if (!gfs_owned_by_mgr) gfs.deinit();

    const slot = self.allocator.create(TenantSlot) catch return Error.OutOfMemory;
    errdefer self.allocator.destroy(slot);
    const id_dup = self.allocator.dupe(u8, id_str) catch return Error.OutOfMemory;
    errdefer self.allocator.free(id_dup);
    slot.* = .{
        .tenant_id = tenant_id,
        .id_str = id_dup,
        .store = store,
        .gfs = gfs,
        .applied_idx = durable_idx,
        .durabilized_idx = durable_idx,
    };

    // Hand `gfs` to the manager. Disarm the local deinit FIRST: from this call
    // onward the FFI owns `gfs` on BOTH outcomes (success → freed on
    // `destroyGroup`; RawNode rejection → freed by `FfiStorage::drop`), so the
    // local errdefer must never free it again.
    gfs_owned_by_mgr = true;
    try self.mgr.createGroupEpoch(
        tenant_id,
        self.node_id,
        epoch,
        raft.manager.grouped_file_storage_vtable,
        gfs,
        &core.group_raft_config,
    );
    // Success: a later failure below rolls the group back through the manager
    // (which frees gfs) — a single free, no double-free.
    errdefer self.mgr.destroyGroup(tenant_id) catch {};

    self.groups.put(self.allocator, tenant_id, slot) catch return Error.OutOfMemory;
    errdefer _ = self.groups.remove(tenant_id);
    // Record in the node-local manifest so a restart can recover this
    // group (see `groups_manifest`). Best-effort + idempotent: re-recording
    // the same (id_str → epoch) on a recovery-path create is a no-op write;
    // a manifest failure must not abort a working group (recovery is a
    // resilience feature, not a correctness gate for the live group).
    self.recordGroup(id_str, epoch);
    // Formation is activity: a fresh group must tick to elect (multi-node)
    // or campaign-to-leader (single-node). It hibernates once idle.
    try self.bumpActive(tenant_id);
    errdefer self.dropActive(tenant_id);
    try self.growReadyBuf();

    // Campaign-to-leader at birth when this node is the group's SOLE voter —
    // either a single-node node (no transport) OR a multi-node node birthing
    // a group as `{self}` (consensus-and-storage.md "Cluster genesis &
    // membership": genesis
    // groups are born single-voter and grown by conf-change). A sole-voter
    // group has no peers to elect from and no race — no other node shares
    // this membership — so it leads immediately. A born-MULTI group still
    // elects via ticks; campaigning here would race the peers that have not
    // yet created the group. (`as_learner` splits self out of `voters_slice`,
    // so a learner is never sole-self and never campaigns.)
    const born_sole_self = !recover and voters_slice.len == 1 and voters_slice[0] == self.node_id;
    if (self.isSingleNode() or born_sole_self) {
        try self.mgr.campaign(tenant_id);
        var spins: u32 = 0;
        while (!self.mgr.isLeader(tenant_id) and spins < 100) : (spins += 1) {
            _ = try self.pump();
        }
        if (!self.mgr.isLeader(tenant_id)) return Error.NotCommitted;

        // Recovery: drain the replayed committed entries into the store
        // before returning, so a reader (e.g. the CP's pre-pump store
        // scan) sees the recovered state. The fresh leader commits a
        // no-op then re-delivers the recovered committed log. Drain until
        // the group's applied index stops advancing for a few consecutive
        // cycles — robust against `pump()` returning a non-empty Ready for
        // soft-state with nothing left to apply (which `!pump()` would
        // busy-loop on). Bounded so a pathological log can't spin forever.
        // (Multi-node recovers via ticks + the apply path after the pump
        // thread starts, so no inline drain there.)
        if (recover) {
            // Force the store write during replay (`worker_overlay` leaders
            // normally skip it because the worker's txn wrote it — but at
            // restart there is no worker, so the pump must write).
            self.recovering = true;
            defer self.recovering = false;
            const slot_ptr = self.groups.get(tenant_id) orelse return Error.UnknownGroup;
            var last_applied: u64 = slot_ptr.applied_idx;
            var stable: u32 = 0;
            var drain: u32 = 0;
            while (drain < 100_000 and stable < 3) : (drain += 1) {
                _ = try self.pump();
                if (slot_ptr.applied_idx == last_applied) {
                    stable += 1;
                } else {
                    stable = 0;
                    last_applied = slot_ptr.applied_idx;
                }
            }
        }
    }

    return slot;
}


/// Tear down a tenant's raft group and reclaim its WAL segments (the
/// move-source cleanup; v2-build-order §Phase 4
/// "destroyGroup + noteGroupDestroyed on source"). `destroyGroup`
/// frees the group's `GroupedFileStorage` (and tombstones the id so a
/// stray later create is rejected); `noteGroupDestroyed` lets the
/// shared WAL drop this group's segments. Then close + free the slot's
/// (leader-skip, unwritten) kvexp store and drop it from the active
/// set. No-op if the group is unknown (idempotent under retried
/// orchestration). The tenant's durable state is NOT here — it lives
/// in the worker's `cluster.kv` and is dropped separately by the move
/// orchestration (`deleteInstance`).
pub fn destroyGroupAndReclaim(self: *Node, tenant_id: u64) Error!void {
    const slot = self.groups.get(tenant_id) orelse return;
    self.mgr.destroyGroup(tenant_id) catch return Error.DestroyGroupFailed;
    self.wal.noteGroupDestroyed(tenant_id);
    self.dropActive(tenant_id);
    // Drop from the recovery manifest BEFORE freeing the slot (we need its
    // `id_str`): a tenant moved off this node must not be re-stood-up on the
    // next restart.
    self.forgetGroup(slot.id_str);
    _ = self.groups.remove(tenant_id);
    slot.store.close();
    self.allocator.free(slot.id_str);
    self.allocator.destroy(slot);
}


