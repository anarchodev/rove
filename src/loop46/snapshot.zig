//! Phase 5.5(c) snapshot capture orchestrator.
//!
//! Walks every tenant in the leader's `ApplyCtx.kv_stores`, runs
//! `VACUUM INTO` against each per-tenant `app.db` plus the
//! singleton `__root__.db`, content-addresses the resulting files,
//! and uploads them to a `BatchStore` (typically S3 in prod, fs in
//! dev) under `cluster/snapshots/{snap_id}/...`. Writes a
//! per-snapshot manifest JSON pointing at every uploaded file.
//!
//! Designed to run on the raft thread on the leader. No global
//! write-pause: each tenant's `VACUUM INTO` takes a brief
//! per-tenant writer lock (sub-millisecond for typical kb-sized
//! app.dbs) and concurrent writes to OTHER tenants are unaffected.
//!
//! ## What this step (#70 — step 3a) ships
//!
//! - `capture()` produces a snapshot end-to-end: VACUUM, hash,
//!   PUT to BatchStore, manifest write.
//! - Always-refreshes every tenant: even dormant ones get a fresh
//!   manifest entry with `snapshot_idx = apply_position`. That's
//!   how the eventual willemt compaction floor advances past
//!   tenants that haven't been written to in a while.
//! - Always re-VACUUMs every tenant. The "by-reference reuse"
//!   optimization (manifest entry references prior snapshot's
//!   db_key when nothing changed) lands in step 3b.
//! - **Brackets capture with `raft.beginSnapshotOpaque()` /
//!   `raft.endSnapshotOpaque()`** so willemt's `cbLogPoll` chain
//!   deletes compacted entries from `raft.log.db`, then calls
//!   `raft.compactLogPages()` to release those freed pages back to
//!   the filesystem (`PRAGMA incremental_vacuum`). Without the
//!   compactPages call, the DELETEs would just leave free pages
//!   on the freelist and the file would grow unbounded.
//!
//! ## Manifest schema
//!
//! Mirrors `docs/snapshot-plan.md` §3.1. Stable v1; future schema
//! additions go behind feature fields the decoder ignores.

const std = @import("std");
const kv = @import("rove-kv");
const apply_mod = @import("rove-js").apply;
const ls = @import("rove-log-server");

pub const VERSION: u32 = 1;

pub const Error = error{
    OutOfMemory,
    Sqlite,
    Io,
    Backend,
    InvalidManifest,
};

/// One tenant's slot in the manifest.
pub const TenantEntry = struct {
    /// Allocator-owned strings — see `Manifest.deinit`.
    instance_id: []u8,
    db_key: []u8,
    db_sha256: [64]u8,
    db_size: u64,
    /// Raft index this tenant's `_apply_state` was at when
    /// captured. Always equal to `apply_position` for the always-
    /// refresh property; future per-tenant captures may diverge.
    snapshot_idx: u64,
};

/// `__root__.db` (singleton) + same shape as `TenantEntry` minus
/// the per-tenant id. Future webhooks_db lands here too.
pub const SingletonEntry = struct {
    db_key: []u8,
    db_sha256: [64]u8,
    db_size: u64,
    snapshot_idx: u64,
};

pub const Manifest = struct {
    allocator: std.mem.Allocator,
    snap_id: []u8,
    captured_at_ms: i64,
    /// `min(snapshot_idx)` across every entry — typically equal to
    /// `apply_position` (always-refresh). The willemt compaction
    /// floor must not advance past this value.
    willemt_compaction_floor: u64,
    /// Raft term at capture time. Followers verify on load to
    /// reject snapshots from a term they haven't seen.
    willemt_term: u64,
    tenants: []TenantEntry,
    /// Null when this node has never seen a root_writeset apply
    /// (test fixtures). Production always has root.
    root_db: ?SingletonEntry,

    pub fn deinit(self: *Manifest) void {
        const a = self.allocator;
        a.free(self.snap_id);
        for (self.tenants) |*t| {
            a.free(t.instance_id);
            a.free(t.db_key);
        }
        a.free(self.tenants);
        if (self.root_db) |*r| a.free(r.db_key);
        self.* = undefined;
    }
};

/// Result of `capture` — the new snapshot's id + the bytes of the
/// manifest object that landed in the snapshot store. Caller can
/// log the id, hand the manifest to a follower, etc.
///
/// `vacuumed_count` + `reused_count` are populated for benchmark
/// + ops visibility — they answer "how much work did this pass
/// do?" Reuse rate at scale is the load-bearing scalability
/// property (see `scripts/snapshot_scalability_bench.sh`).
pub const Captured = struct {
    snap_id: []u8,
    manifest_key: []u8,
    manifest_bytes: []u8,
    /// Tenants whose db was VACUUM-INTO'd + uploaded fresh this
    /// pass (apply-idx advanced past prev snapshot_idx, OR no
    /// prev_manifest, OR prev_manifest had no entry for this id).
    vacuumed_count: u32,
    /// Tenants whose entry was reused from `prev_manifest` by
    /// reference (apply-idx unchanged since prev). The
    /// always-refresh property still bumps their `snapshot_idx`
    /// to the current `apply_position`, but the bytes don't get
    /// re-uploaded.
    reused_count: u32,
    /// Wall-clock duration of the capture pass — from the start
    /// of the per-tenant loop to the manifest PUT returning.
    /// Excludes the willemt begin/end bracket overhead.
    duration_ms: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Captured) void {
        self.allocator.free(self.snap_id);
        self.allocator.free(self.manifest_key);
        self.allocator.free(self.manifest_bytes);
        self.* = undefined;
    }
};

/// One tenant's input to `capture` — borrowed pointers; the caller
/// owns lifetime. Both `ApplyCtx`-driven and operator-trigger paths
/// build a slice of these.
pub const TenantSource = struct {
    instance_id: []const u8,
    store: *kv.KvStore,
    /// When set, capture compares against `prev_manifest`'s entry for
    /// this tenant: if `last_applied_idx <= prev.snapshot_idx`, the
    /// tenant's db is byte-identical to prev's snapshot and capture
    /// reuses the prior `db_key` / `db_sha256` / `db_size` (just
    /// bumping `snapshot_idx` to the current `apply_position` —
    /// the always-refresh-all-tenants property per
    /// `docs/snapshot-plan.md` §2.2). Null disables reuse and
    /// always re-VACUUMs (today's operator-CLI default).
    last_applied_idx: ?u64 = null,
};

/// Capture a snapshot end-to-end. The caller threads the
/// just-promoted `apply_position` (current willemt commit idx) and
/// `willemt_term`; both end up in the manifest so a follower's
/// load path can reject mismatches and the compaction floor is
/// recorded. `tenants` is a borrowed slice of (id, store) pairs;
/// `root_store` is null on test fixtures that don't have a root
/// (production always passes one).
///
/// `tmp_dir` is where intermediate VACUUM outputs land before
/// upload. Caller picks (typically `{data_dir}/.snapshot-stage/`);
/// each capture creates a per-snap_id subdir inside, deletes it
/// at the end. Files there must NOT collide across concurrent
/// captures — the snap_id namespace gives that property.
///
/// `prev_manifest` enables by-reference reuse for unchanged
/// tenants per `docs/snapshot-plan.md` §2.2. When set, each
/// `TenantSource` whose `last_applied_idx <= prev_manifest's
/// entry's snapshot_idx` skips the VACUUM + upload and reuses the
/// prior `db_key` (the bytes are byte-identical, so referencing
/// the same S3 object is correct). Same property for `root_db`
/// driven by `root_last_applied`. Pass `null` to always re-VACUUM
/// every tenant (the operator-CLI default; correctness is
/// trivially the same — just more expensive).
pub fn capture(
    allocator: std.mem.Allocator,
    tenants_in: []const TenantSource,
    root_store: ?*kv.KvStore,
    root_last_applied: ?u64,
    prev_manifest: ?*const Manifest,
    snapshot_store: ls.batch_store.BatchStore,
    tmp_dir: []const u8,
    apply_position: u64,
    willemt_term: u64,
) !Captured {
    const start_ns = std.time.nanoTimestamp();

    const snap_id = try mintSnapId(allocator);
    errdefer allocator.free(snap_id);

    const stage = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, snap_id });
    defer allocator.free(stage);
    std.fs.cwd().makePath(stage) catch return Error.Io;
    defer std.fs.cwd().deleteTree(stage) catch {};

    var tenants: std.ArrayListUnmanaged(TenantEntry) = .empty;
    errdefer freeTenantList(allocator, &tenants);

    var vacuumed_count: u32 = 0;
    var reused_count: u32 = 0;

    // ── Per-tenant captures ─────────────────────────────────────
    for (tenants_in) |t| {
        // By-reference reuse: when prev_manifest has an entry for
        // this tenant AND no apply has touched it since prev was
        // captured, reference prev's db_key directly. The bytes are
        // byte-identical (no apply → no kv writes → no VACUUM
        // delta), so any object reachable by prev's db_key is also
        // a correct snapshot for this tenant at the current
        // apply_position. Manifest entry snapshot_idx is bumped to
        // current apply_position regardless — that's the
        // always-refresh-all property that lets the willemt
        // compaction floor advance every pass without per-tenant
        // activity gating.
        if (t.last_applied_idx) |last| {
            if (prev_manifest) |prev| {
                if (findTenantInManifest(prev, t.instance_id)) |prev_entry| {
                    if (last <= prev_entry.snapshot_idx) {
                        const id_copy = try allocator.dupe(u8, t.instance_id);
                        errdefer allocator.free(id_copy);
                        const key_copy = try allocator.dupe(u8, prev_entry.db_key);
                        errdefer allocator.free(key_copy);
                        try tenants.append(allocator, .{
                            .instance_id = id_copy,
                            .db_key = key_copy,
                            .db_sha256 = prev_entry.db_sha256,
                            .db_size = prev_entry.db_size,
                            .snapshot_idx = apply_position,
                        });
                        reused_count += 1;
                        continue;
                    }
                }
            }
        }
        vacuumed_count += 1;

        const tmp_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/{s}.db",
            .{ stage, t.instance_id },
            0,
        );
        defer allocator.free(tmp_path);

        // Stamp _apply_state to apply_position before VACUUM. On
        // the leader, the apply path skips writing this stamp from
        // the raft thread to avoid contending with the worker's
        // TrackedTxn writer. We pay it here once per snapshot pass:
        // a single tx that updates one row, on the same raft thread
        // that's already paused for capture. Brief window where the
        // worker has new pending commits not reflected in
        // tenant_apply_idx is fine — those entries are still in the
        // raft log past `apply_position`, replay will pick them up.
        if (t.last_applied_idx) |idx| {
            t.store.setLastAppliedRaftIdx(idx) catch return Error.Sqlite;
        }

        t.store.vacuumInto(tmp_path) catch return Error.Sqlite;

        const captured = try uploadDbFile(
            allocator,
            snapshot_store,
            tmp_path,
            try snapshotKey(allocator, snap_id, t.instance_id),
        );

        const id_copy = try allocator.dupe(u8, t.instance_id);
        errdefer allocator.free(id_copy);
        try tenants.append(allocator, .{
            .instance_id = id_copy,
            .db_key = captured.key,
            .db_sha256 = captured.sha256_hex,
            .db_size = captured.size,
            .snapshot_idx = apply_position,
        });
    }

    // ── Root db (singleton) ─────────────────────────────────────
    var root_entry: ?SingletonEntry = null;
    errdefer if (root_entry) |*r| allocator.free(r.db_key);
    if (root_store) |rs| {
        // Same reuse property as per-tenant: when the root db's
        // last apply hasn't advanced past the prior snapshot's
        // root snapshot_idx, reuse prev_manifest's root entry.
        const can_reuse_root = blk: {
            const last = root_last_applied orelse break :blk false;
            const prev = prev_manifest orelse break :blk false;
            const prev_root = prev.root_db orelse break :blk false;
            break :blk last <= prev_root.snapshot_idx;
        };

        if (can_reuse_root) {
            const prev_root = prev_manifest.?.root_db.?;
            const key_copy = try allocator.dupe(u8, prev_root.db_key);
            errdefer allocator.free(key_copy);
            root_entry = .{
                .db_key = key_copy,
                .db_sha256 = prev_root.db_sha256,
                .db_size = prev_root.db_size,
                .snapshot_idx = apply_position,
            };
            reused_count += 1;
        } else {
            vacuumed_count += 1;
            const tmp_path = try std.fmt.allocPrintSentinel(
                allocator,
                "{s}/__root__.db",
                .{stage},
                0,
            );
            defer allocator.free(tmp_path);

            // Same lazy-stamp story as per-tenant: on the leader,
            // `applyRootWriteSet` doesn't write `_apply_state` from
            // the raft thread (avoids contending with the worker's
            // root-write connection). One targeted stamp here per
            // snapshot pass keeps the captured bytes consistent.
            if (root_last_applied) |idx| {
                rs.setLastAppliedRaftIdx(idx) catch return Error.Sqlite;
            }

            rs.vacuumInto(tmp_path) catch return Error.Sqlite;

            const root_key = try std.fmt.allocPrint(
                allocator,
                "cluster/snapshots/{s}/__root__.db",
                .{snap_id},
            );
            const captured = try uploadDbFile(
                allocator,
                snapshot_store,
                tmp_path,
                root_key,
            );
            root_entry = .{
                .db_key = captured.key,
                .db_sha256 = captured.sha256_hex,
                .db_size = captured.size,
                .snapshot_idx = apply_position,
            };
        }
    }

    // ── Manifest ────────────────────────────────────────────────
    const captured_at_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
    const tenant_slice = try tenants.toOwnedSlice(allocator);
    var manifest = Manifest{
        .allocator = allocator,
        .snap_id = try allocator.dupe(u8, snap_id),
        .captured_at_ms = captured_at_ms,
        .willemt_compaction_floor = apply_position,
        .willemt_term = willemt_term,
        .tenants = tenant_slice,
        .root_db = root_entry,
    };
    defer manifest.deinit();

    const manifest_bytes = try encodeManifest(allocator, &manifest);
    errdefer allocator.free(manifest_bytes);

    const manifest_key = try std.fmt.allocPrint(
        allocator,
        "cluster/snapshots/{s}/manifest.json",
        .{snap_id},
    );
    errdefer allocator.free(manifest_key);

    snapshot_store.put(manifest_key, manifest_bytes) catch return Error.Backend;

    const elapsed_ns = std.time.nanoTimestamp() - start_ns;
    const duration_ms: u64 = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));

    return .{
        .allocator = allocator,
        .snap_id = snap_id,
        .manifest_key = manifest_key,
        .manifest_bytes = manifest_bytes,
        .vacuumed_count = vacuumed_count,
        .reused_count = reused_count,
        .duration_ms = duration_ms,
    };
}

/// Result of `restore` — bookkeeping the caller can log + use to
/// initialize willemt's state via `raft_begin_load_snapshot` /
/// `raft_end_load_snapshot` (step 4b wiring).
pub const Restored = struct {
    /// The manifest that was loaded; caller must `deinit`.
    manifest: Manifest,
    /// Number of tenant dbs successfully written + sha-verified.
    tenants_restored: usize,
    /// True if the manifest had a root_db entry that was applied.
    root_restored: bool,
};

/// Phase 5.5(c) snapshot step 4 — pull a snapshot down from a
/// `BatchStore` (fs in dev, S3 in prod) and install it into a
/// fresh `data_dir`. Used by:
///
/// - `loop46 restore-from-snapshot` admin CLI for disaster
///   recovery (a node lost its disk; restore from S3).
/// - The follower-side load path triggered by willemt's
///   `send_snapshot` callback (step 4b wires that — for now this
///   function is the building block).
///
/// Flow per `docs/snapshot-plan.md` §5.2:
///
///   1. GET `cluster/snapshots/{snap_id}/manifest.json`
///   2. For each tenant in manifest:
///      - GET the db bytes, verify sha256 against the manifest,
///        write to `{tmp_dir}/{snap_id}/{tenant}/app.db`
///      - mkdir `{data_dir}/{tenant}/`, atomic-rename the staged
///        file into `{data_dir}/{tenant}/app.db`
///      - Open it, stamp `_apply_state.last_applied_raft_idx =
///        snapshot_idx` so subsequent raft entries replay through
///        `applyOne`'s filter without re-applying anything in the
///        snapshot.
///   3. Same for `__root__.db` when the manifest carries one.
///
/// Caller owns + must `deinit` the returned `Restored.manifest`.
pub fn restore(
    allocator: std.mem.Allocator,
    snapshot_store: ls.batch_store.BatchStore,
    snap_id: []const u8,
    data_dir: []const u8,
    tmp_dir: []const u8,
) !Restored {
    // Stage area for atomic-rename. Per-snap_id subdir so a crash
    // mid-restore leaves an isolated tree the next run can clean.
    const stage = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, snap_id });
    defer allocator.free(stage);
    std.fs.cwd().makePath(stage) catch return Error.Io;
    defer std.fs.cwd().deleteTree(stage) catch {};

    // ── Pull + decode the manifest ──────────────────────────────
    const manifest_key = try std.fmt.allocPrint(
        allocator,
        "cluster/snapshots/{s}/manifest.json",
        .{snap_id},
    );
    defer allocator.free(manifest_key);

    const manifest_bytes = snapshot_store.get(manifest_key, allocator) catch
        return Error.Backend;
    defer allocator.free(manifest_bytes);

    var manifest = try decodeManifest(allocator, manifest_bytes);
    errdefer manifest.deinit();

    // ── Per-tenant restore ──────────────────────────────────────
    var tenants_done: usize = 0;
    for (manifest.tenants) |entry| {
        try restoreOneDb(
            allocator,
            snapshot_store,
            entry.db_key,
            &entry.db_sha256,
            entry.db_size,
            entry.snapshot_idx,
            stage,
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, entry.instance_id }),
            "app.db",
        );
        tenants_done += 1;
    }

    // ── Root db (singleton) ─────────────────────────────────────
    var root_done: bool = false;
    if (manifest.root_db) |r| {
        try restoreOneDb(
            allocator,
            snapshot_store,
            r.db_key,
            &r.db_sha256,
            r.db_size,
            r.snapshot_idx,
            stage,
            try allocator.dupe(u8, data_dir),
            "__root__.db",
        );
        root_done = true;
    }

    return .{
        .manifest = manifest,
        .tenants_restored = tenants_done,
        .root_restored = root_done,
    };
}

/// Pull one db from the snapshot store, verify sha + size, atomic-
/// rename into `target_dir/file_name`, and stamp
/// `_apply_state.last_applied_raft_idx = snapshot_idx` so subsequent
/// raft-applied entries replay correctly past the snapshot floor.
///
/// `target_dir` is owned by this fn (will be freed before return).
fn restoreOneDb(
    allocator: std.mem.Allocator,
    snapshot_store: ls.batch_store.BatchStore,
    db_key: []const u8,
    expected_sha256_hex: *const [64]u8,
    expected_size: u64,
    snapshot_idx: u64,
    stage_dir: []const u8,
    target_dir: []u8,
    file_name: []const u8,
) !void {
    defer allocator.free(target_dir);

    const bytes = snapshot_store.get(db_key, allocator) catch return Error.Backend;
    defer allocator.free(bytes);

    if (bytes.len != expected_size) return Error.InvalidManifest;
    var actual_sha: [64]u8 = undefined;
    sha256Hex(bytes, &actual_sha);
    if (!std.mem.eql(u8, &actual_sha, expected_sha256_hex)) return Error.InvalidManifest;

    // Stage path is keyed by the basename (file_name) — collisions
    // across multiple tenants restoring concurrently from one
    // `restore` call are impossible because we serialize, but using
    // file_name keeps the stage tree mirror-shaped to the data dir.
    const stage_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ stage_dir, file_name },
    );
    defer allocator.free(stage_path);

    {
        const f = std.fs.cwd().createFile(stage_path, .{ .mode = 0o600 }) catch
            return Error.Io;
        defer f.close();
        f.writeAll(bytes) catch return Error.Io;
    }

    std.fs.cwd().makePath(target_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return Error.Io,
    };

    const final_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ target_dir, file_name },
    );
    defer allocator.free(final_path);

    // Drop any prior copy + WAL/SHM sidecars that would otherwise
    // race with the fresh open below. SQLite re-creates them.
    deleteIfPresent(final_path);
    deleteWithSuffix(allocator, final_path, "-wal");
    deleteWithSuffix(allocator, final_path, "-shm");

    std.fs.cwd().rename(stage_path, final_path) catch return Error.Io;

    // Stamp `_apply_state` so the apply path's per-entry filter
    // skips everything ≤ snapshot_idx without falling for it.
    const final_path_z = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}",
        .{final_path},
        0,
    );
    defer allocator.free(final_path_z);
    const ks = kv.KvStore.open(allocator, final_path_z) catch return Error.Sqlite;
    defer ks.close();
    ks.setLastAppliedRaftIdx(snapshot_idx) catch return Error.Sqlite;
}

fn deleteIfPresent(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
}

fn deleteWithSuffix(allocator: std.mem.Allocator, path: []const u8, suffix: []const u8) void {
    const buf = std.fmt.allocPrint(allocator, "{s}{s}", .{ path, suffix }) catch return;
    defer allocator.free(buf);
    std.fs.cwd().deleteFile(buf) catch {};
}

/// Phase 5.5(c) step C — operator-actionable warning when willemt
/// asks the leader to ship a snapshot to a far-behind follower
/// (`raft.cb.send_snapshot`). The current minimum logs the
/// recovery action: which peer is behind, what willemt's most
/// recent snapshot is, and the exact `loop46 restore-from-snapshot`
/// command the operator should run on that node.
///
/// Future iteration: send a SNAP_OFFER RPC carrying the snap_id;
/// follower auto-runs the restore. That needs follower-side
/// download + restore plumbing on the raft thread, which lands
/// alongside the multi-node smoke harness it requires.
pub fn logNeedsSnapshot(
    ctx: ?*anyopaque,
    raft: *kv.RaftNode,
    peer_id: u32,
) void {
    _ = ctx;
    const idx = raft.snapshotLastIdx();
    const term = raft.currentTerm();
    std.log.warn(
        "raft: peer {d} needs snapshot (snap_last_idx={d}, term={d}). " ++
            "Run `loop46 restore-from-snapshot --snap-id <latest>` on that " ++
            "node, then restart the worker. Future automation: SNAP_OFFER RPC.",
        .{ peer_id, idx, term },
    );
}

/// Result of a successful `tickRaftCapture` pass — the snapshot
/// floor we advanced to + counts for ops visibility. Replaces
/// the `Captured` struct for the periodic-loop path; operator CLI
/// captures still go through `capture()` and return `Captured`.
pub const TickResult = struct {
    /// The willemt apply position we just compacted past. Equal
    /// to `commit_idx_at_begin_snapshot`.
    apply_position: u64,
    /// Tenants whose `_apply_state` we stamped this pass.
    /// Equal to `apply_ctx.tenant_apply_idx.count()` minus any
    /// individual stamp failures (logged but not fatal).
    stamped_tenants: u32,
    /// True if `__root__.db` was stamped successfully this pass.
    /// False on a node that's never seen a root_writeset apply.
    stamped_root: bool,
    /// Wall-clock duration of the stamp loop + willemt
    /// begin/end. Excludes the elapsed-time gate.
    duration_ms: u64,
};

/// In-process periodic log compaction for the raft thread.
///
/// **No byte capture, no S3, no manifest.** Per
/// `docs/production.md` #1.1: log compaction only needs an
/// assertion that "this node's tenant state is consistent through
/// idx N" — the on-disk app.db files plus their
/// `_apply_state.last_applied_raft_idx` stamp are exactly that
/// assertion, and no separate byte copy is required.
///
/// What this pass does:
///
///   1. willemt begin_snapshot at current commit_idx.
///   2. Stamp `_apply_state[T] = commit_idx` for every tenant T
///      in `apply_ctx.tenant_apply_idx` (always-refresh-all so
///      dormant tenants don't pin willemt's compaction floor).
///   3. Same for `__root__.db`.
///   4. willemt end_snapshot → cbLogPoll truncates raft.log.db
///      past the new floor. compactLogPages releases freed
///      pages back to the filesystem.
///
/// Falls-behind followers + new-node bootstrap go through
/// willemt's `send_snapshot` callback (separate item — currently
/// the `logNeedsSnapshot` warning), NOT through this path.
///
/// Returns null when we skipped this tick (interval not elapsed,
/// not leader, willemt has nothing to snapshot). Otherwise
/// returns counts + duration for ops visibility.
pub fn tickRaftCapture(
    state: *RaftCaptureState,
    now_ns: i64,
    raft: *kv.RaftNode,
    apply_ctx: *apply_mod.ApplyCtx,
) !?TickResult {
    if (state.interval_ns == 0) return null;
    if (!raft.isLeader()) return null;
    if (now_ns - state.last_attempt_ns < state.interval_ns) return null;
    state.last_attempt_ns = now_ns;

    // willemt's begin returns false when there's nothing to
    // snapshot (commit_idx <= snap_last, no log entries past the
    // floor) — completely fine, just means no progress since the
    // last pass.
    if (!raft.beginSnapshotOpaque()) return null;
    errdefer raft.endSnapshotOpaque();

    const start_ns = std.time.nanoTimestamp();
    const apply_position = raft.snapshotLastIdx();

    // Per-tenant stamp loop. Each stamp is one prepared-statement
    // step → small WAL append → fsync (in synchronous=FULL mode).
    // ~1ms per tenant in fs backend, similar in WAL-mode SQLite.
    // For dense clusters (10k tenants) this could push >1s; we
    // accept that for v1 — it's still 100× faster than the prior
    // VACUUM-INTO + S3 path and operator-tunable via
    // --snapshot-interval-ms. A dedicated raft-thread budget
    // optimization (chunked stamping with willemt yield points)
    // is a future item if needed.
    var stamped: u32 = 0;
    var idx_it = apply_ctx.tenant_apply_idx.iterator();
    while (idx_it.next()) |entry| {
        const id = entry.key_ptr.*;
        const store = apply_ctx.getKv(id) catch |err| {
            std.log.warn(
                "snapshot: tickRaftCapture: getKv {s} failed: {s} (tenant skipped)",
                .{ id, @errorName(err) },
            );
            continue;
        };
        store.setLastAppliedRaftIdx(apply_position) catch |err| {
            std.log.warn(
                "snapshot: tickRaftCapture: setLastAppliedRaftIdx for {s} failed: {s}",
                .{ id, @errorName(err) },
            );
            continue;
        };
        stamped += 1;
    }

    // Same for __root__.db (singleton). On nodes that have never
    // seen a root_writeset apply, getRootKv returns no error but
    // root_apply_idx stays 0; we still stamp to apply_position so
    // the file's _apply_state matches the snapshot floor.
    var stamped_root = false;
    const root_store = apply_ctx.getRootKv() catch null;
    if (root_store) |rs| {
        rs.setLastAppliedRaftIdx(apply_position) catch |err| {
            std.log.warn(
                "snapshot: tickRaftCapture: setLastAppliedRaftIdx for __root__ failed: {s}",
                .{@errorName(err)},
            );
        };
        stamped_root = true;
    }

    raft.endSnapshotOpaque();

    // Release pages freed by willemt's `cbLogPoll` chain. Without
    // this, `truncateBefore`'s DELETEs leave the pages on the
    // freelist and `raft.log.db` grows unbounded.
    raft.compactLogPages() catch |err| {
        std.log.warn(
            "snapshot: compactLogPages failed: {s} (raft.log.db will not shrink this pass)",
            .{@errorName(err)},
        );
    };

    const elapsed_ns = std.time.nanoTimestamp() - start_ns;
    const duration_ms: u64 = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));

    return .{
        .apply_position = apply_position,
        .stamped_tenants = stamped,
        .stamped_root = stamped_root,
        .duration_ms = duration_ms,
    };
}

/// Per-raft-node state the periodic compaction ticker carries.
/// Owned by the caller (typically loop46/main); passed by mutable
/// reference into `tickRaftCapture`.
///
/// Stores only the elapsed-time gate. The pre-#1.1 design also
/// cached a prior manifest here for by-reference reuse; under
/// stamp-and-compact there's nothing to reuse and nothing to
/// cache. Kept as a struct (not just a u64) so future
/// observability fields (per-pass histograms, last-success-ns,
/// etc.) have somewhere to live without churning the public API.
pub const RaftCaptureState = struct {
    interval_ns: i64,
    last_attempt_ns: i64 = 0,

    pub fn deinit(self: *RaftCaptureState) void {
        _ = self;
    }
};

/// Build a `[]TenantSource` slice from an already-warmed
/// `ApplyCtx`, lazy-opening per-tenant `app.db` connections for
/// any tenant present in `tenant_apply_idx` but not yet in
/// `kv_stores`. The leader path is the motivating case: its
/// `applyWriteSet` populates only the in-memory mirror (avoiding
/// a second SQLite writer per apply); snapshot capture pays the
/// open cost once, here.
///
/// Borrows the keys + store pointers; caller frees the returned
/// slice with `allocator.free`. Use this from the raft thread
/// (which owns the connections) — not from a worker, since
/// SQLite NOMUTEX connections aren't shareable.
///
/// Each `TenantSource.last_applied_idx` is populated from
/// `ApplyCtx.tenant_apply_idx` so `capture` can do by-reference
/// reuse (§2.2 always-refresh-all).
pub fn tenantSourcesFromApplyCtx(
    allocator: std.mem.Allocator,
    apply_ctx: *apply_mod.ApplyCtx,
) ![]TenantSource {
    var list: std.ArrayListUnmanaged(TenantSource) = .empty;
    errdefer list.deinit(allocator);

    var idx_it = apply_ctx.tenant_apply_idx.iterator();
    while (idx_it.next()) |entry| {
        const id = entry.key_ptr.*;
        // Lazy-open: getKv idempotently opens the kv_store and
        // returns a pointer to the cached one. On the leader this
        // is where we pay the open cost (once per tenant for the
        // process lifetime, since kv_stores caches). On the
        // follower we pay it inside `applyWriteSet` instead.
        const store = apply_ctx.getKv(id) catch continue;
        try list.append(allocator, .{
            .instance_id = id,
            .store = store,
            .last_applied_idx = entry.value_ptr.*,
        });
    }
    return list.toOwnedSlice(allocator);
}

/// Capture a snapshot from the on-disk data dir, opening fresh
/// per-tenant SQLite connections instead of reusing the
/// raft-thread or worker-thread caches. Designed for the dedicated
/// snapshot thread the periodic capture loop spawns: it has no
/// share of the worker / raft NOMUTEX connections, so any access
/// it makes has to be via its own opens.
///
/// Walks `{data_dir}/*` for tenant subdirectories (each containing
/// `app.db`) and includes `{data_dir}/__root__.db` when present.
/// Skips subdirs that don't have `app.db` — they're either
/// half-bootstrapped tenants, scratch dirs, or the `.snapshots/`
/// store itself.
pub fn captureFromDataDir(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    snapshot_store: ls.batch_store.BatchStore,
    tmp_dir: []const u8,
    apply_position: u64,
    willemt_term: u64,
) !Captured {
    var sources: std.ArrayListUnmanaged(TenantSource) = .empty;
    defer {
        for (sources.items) |t| {
            allocator.free(t.instance_id);
            t.store.close();
        }
        sources.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(data_dir, .{ .iterate = true }) catch
        return Error.Io;
    defer dir.close();

    var root_store: ?*kv.KvStore = null;
    defer if (root_store) |s| s.close();

    var it = dir.iterate();
    while (it.next() catch return Error.Io) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, entry.name, "__root__.db")) {
            const path = try std.fmt.allocPrintSentinel(
                allocator,
                "{s}/__root__.db",
                .{data_dir},
                0,
            );
            defer allocator.free(path);
            root_store = kv.KvStore.open(allocator, path) catch return Error.Sqlite;
            continue;
        }
        if (entry.kind != .directory) continue;
        // Skip dot-dirs (e.g. `.snapshots`, `.stage`) and any subdir
        // without an `app.db`.
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const app_db_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/{s}/app.db",
            .{ data_dir, entry.name },
            0,
        );
        defer allocator.free(app_db_path);
        std.fs.cwd().access(app_db_path, .{}) catch continue;

        const ks = kv.KvStore.open(allocator, app_db_path) catch return Error.Sqlite;
        const id_copy = try allocator.dupe(u8, entry.name);
        errdefer {
            ks.close();
            allocator.free(id_copy);
        }
        try sources.append(allocator, .{ .instance_id = id_copy, .store = ks });
    }

    // Operator CLI default: no in-memory `tenant_apply_idx` state,
    // so we can't tell which tenants are unchanged since a prior
    // snapshot. Pass `prev_manifest = null` and `last_applied_idx`
    // null on every TenantSource — capture re-VACUUMs everything
    // (correct, just more expensive). This is acceptable for
    // operator-driven one-shot DR captures; the periodic
    // raft-thread loop has the apply-idx mirror and uses the
    // reuse path.
    return capture(
        allocator,
        sources.items,
        root_store,
        null,
        null,
        snapshot_store,
        tmp_dir,
        apply_position,
        willemt_term,
    );
}

/// 26-char ULID-ish stamp: `{ms_since_epoch_hex:0>14}{random_hex:12}`.
/// Sortable by creation time, unique under concurrent calls. Caller
/// frees.
fn mintSnapId(allocator: std.mem.Allocator) ![]u8 {
    const ms_now: u64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
    const r: u64 = std.crypto.random.int(u64);
    return std.fmt.allocPrint(allocator, "{x:0>14}{x:0>12}", .{ ms_now, r & 0xFFFFFFFFFFFF });
}

fn snapshotKey(
    allocator: std.mem.Allocator,
    snap_id: []const u8,
    instance_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "cluster/snapshots/{s}/{s}/app.db",
        .{ snap_id, instance_id },
    );
}

const UploadResult = struct {
    key: []u8,
    sha256_hex: [64]u8,
    size: u64,
};

/// Read the file at `tmp_path`, sha256-hash + size + PUT to the
/// snapshot store at `key`. The caller-supplied `key` is moved
/// into the result (caller frees on success / errdefer on
/// failure). The on-disk file isn't deleted here — the per-snap
/// stage directory is deleted as a unit by `capture`'s defer.
fn uploadDbFile(
    allocator: std.mem.Allocator,
    snapshot_store: ls.batch_store.BatchStore,
    tmp_path: [:0]const u8,
    key: []u8,
) !UploadResult {
    errdefer allocator.free(key);

    const bytes = std.fs.cwd().readFileAlloc(allocator, tmp_path, std.math.maxInt(usize)) catch
        return Error.Io;
    defer allocator.free(bytes);

    snapshot_store.put(key, bytes) catch return Error.Backend;

    var sha_hex: [64]u8 = undefined;
    sha256Hex(bytes, &sha_hex);

    return .{ .key = key, .sha256_hex = sha_hex, .size = bytes.len };
}

fn sha256Hex(bytes: []const u8, out: *[64]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

fn freeTenantList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(TenantEntry)) void {
    for (list.items) |*t| {
        allocator.free(t.instance_id);
        allocator.free(t.db_key);
    }
    list.deinit(allocator);
}

/// Linear scan over `manifest.tenants` for the named id. Tenant
/// counts are bounded by node density (hundreds, not millions) and
/// this fires once per tenant per capture pass — well within
/// the budget of an O(N) scan. A hashmap index would be premature.
fn findTenantInManifest(manifest: *const Manifest, instance_id: []const u8) ?TenantEntry {
    for (manifest.tenants) |t| {
        if (std.mem.eql(u8, t.instance_id, instance_id)) return t;
    }
    return null;
}

// ── Manifest JSON ──────────────────────────────────────────────────

pub fn encodeManifest(
    allocator: std.mem.Allocator,
    m: *const Manifest,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);

    try w.print(
        "{{\"v\":{d},\"snap_id\":\"{s}\",\"captured_at_ms\":{d},\"willemt_compaction_floor\":{d},\"willemt_term\":{d},",
        .{ VERSION, m.snap_id, m.captured_at_ms, m.willemt_compaction_floor, m.willemt_term },
    );
    try w.writeAll("\"tenants\":{");
    for (m.tenants, 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(&w, t.instance_id);
        try w.print(
            ":{{\"db_key\":\"{s}\",\"db_sha256\":\"{s}\",\"db_size\":{d},\"snapshot_idx\":{d}}}",
            .{ t.db_key, t.db_sha256, t.db_size, t.snapshot_idx },
        );
    }
    try w.writeAll("}");
    if (m.root_db) |r| {
        try w.print(
            ",\"root_db\":{{\"db_key\":\"{s}\",\"db_sha256\":\"{s}\",\"db_size\":{d},\"snapshot_idx\":{d}}}",
            .{ r.db_key, r.db_sha256, r.db_size, r.snapshot_idx },
        );
    }
    try w.writeByte('}');
    return buf.toOwnedSlice(allocator);
}

pub fn decodeManifest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!Manifest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return Error.InvalidManifest;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return Error.InvalidManifest,
    };

    const v = jsonInt(obj.get("v")) orelse return Error.InvalidManifest;
    if (v != @as(i64, @intCast(VERSION))) return Error.InvalidManifest;

    const snap_id_str = jsonString(obj.get("snap_id")) orelse return Error.InvalidManifest;
    const snap_id = try allocator.dupe(u8, snap_id_str);
    errdefer allocator.free(snap_id);

    const captured_at_ms = jsonInt(obj.get("captured_at_ms")) orelse return Error.InvalidManifest;
    const floor = jsonInt(obj.get("willemt_compaction_floor")) orelse return Error.InvalidManifest;
    const term = jsonInt(obj.get("willemt_term")) orelse return Error.InvalidManifest;
    if (floor < 0 or term < 0) return Error.InvalidManifest;

    const tenants_val = obj.get("tenants") orelse return Error.InvalidManifest;
    const tenants_obj = switch (tenants_val) {
        .object => |o| o,
        else => return Error.InvalidManifest,
    };

    var tenants: std.ArrayListUnmanaged(TenantEntry) = .empty;
    errdefer freeTenantList(allocator, &tenants);
    var t_it = tenants_obj.iterator();
    while (t_it.next()) |kv_pair| {
        const id_copy = try allocator.dupe(u8, kv_pair.key_ptr.*);
        errdefer allocator.free(id_copy);
        const e = try parseEntry(allocator, kv_pair.value_ptr.*);
        try tenants.append(allocator, .{
            .instance_id = id_copy,
            .db_key = e.db_key,
            .db_sha256 = e.db_sha256,
            .db_size = e.db_size,
            .snapshot_idx = e.snapshot_idx,
        });
    }

    var root_db: ?SingletonEntry = null;
    if (obj.get("root_db")) |rv| {
        const e = try parseEntry(allocator, rv);
        root_db = .{
            .db_key = e.db_key,
            .db_sha256 = e.db_sha256,
            .db_size = e.db_size,
            .snapshot_idx = e.snapshot_idx,
        };
    }

    return .{
        .allocator = allocator,
        .snap_id = snap_id,
        .captured_at_ms = captured_at_ms,
        .willemt_compaction_floor = @intCast(floor),
        .willemt_term = @intCast(term),
        .tenants = try tenants.toOwnedSlice(allocator),
        .root_db = root_db,
    };
}

const ParsedEntry = struct {
    db_key: []u8,
    db_sha256: [64]u8,
    db_size: u64,
    snapshot_idx: u64,
};

fn parseEntry(allocator: std.mem.Allocator, val: std.json.Value) Error!ParsedEntry {
    const o = switch (val) {
        .object => |o| o,
        else => return Error.InvalidManifest,
    };
    const key = jsonString(o.get("db_key")) orelse return Error.InvalidManifest;
    const sha = jsonString(o.get("db_sha256")) orelse return Error.InvalidManifest;
    const size = jsonInt(o.get("db_size")) orelse return Error.InvalidManifest;
    const idx = jsonInt(o.get("snapshot_idx")) orelse return Error.InvalidManifest;
    if (sha.len != 64 or size < 0 or idx < 0) return Error.InvalidManifest;

    const key_copy = try allocator.dupe(u8, key);
    errdefer allocator.free(key_copy);
    var sha_arr: [64]u8 = undefined;
    @memcpy(&sha_arr, sha[0..64]);
    return .{
        .db_key = key_copy,
        .db_sha256 = sha_arr,
        .db_size = @intCast(size),
        .snapshot_idx = @intCast(idx),
    };
}

fn jsonInt(v: ?std.json.Value) ?i64 {
    if (v == null) return null;
    return switch (v.?) {
        .integer => |i| i,
        else => null,
    };
}

fn jsonString(v: ?std.json.Value) ?[]const u8 {
    if (v == null) return null;
    return switch (v.?) {
        .string => |s| s,
        else => null,
    };
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |b| {
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{b}),
            else => try w.writeByte(b),
        }
    }
    try w.writeByte('"');
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn tmpPath(buf: *[96]u8, tag: []const u8) []const u8 {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    return std.fmt.bufPrint(buf, "/tmp/rove-snap-{s}-{x}", .{ tag, seed }) catch unreachable;
}

fn noopApply(_: u64, _: []const u8, _: ?*anyopaque) void {}

test "capture + restore: round-trips tenant + root state into a fresh data_dir" {
    const allocator = testing.allocator;

    var path_buf: [96]u8 = undefined;
    const root_path = tmpPath(&path_buf, "rt");
    defer std.fs.cwd().deleteTree(root_path) catch {};
    try std.fs.cwd().makePath(root_path);

    // ── Source state: __root__.db + tenant `acme`/app.db ───────
    {
        const root_db_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/__root__.db",
            .{root_path},
            0,
        );
        defer allocator.free(root_db_path);
        const root_kv = try kv.KvStore.open(allocator, root_db_path);
        defer root_kv.close();
        try root_kv.put("tenant/acme", "{}");
        try root_kv.setLastAppliedRaftIdx(50);
    }

    const acme_dir = try std.fmt.allocPrint(allocator, "{s}/acme", .{root_path});
    defer allocator.free(acme_dir);
    try std.fs.cwd().makePath(acme_dir);
    const acme_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/app.db",
        .{acme_dir},
        0,
    );
    defer allocator.free(acme_db_path);
    {
        const acme_kv = try kv.KvStore.open(allocator, acme_db_path);
        defer acme_kv.close();
        try acme_kv.put("greeting", "hello");
        try acme_kv.put("counter", "42");
        try acme_kv.setLastAppliedRaftIdx(99);
    }

    // ── Stand up a raft node + ApplyCtx for the source side ────
    const raft_log_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/raft.log.db",
        .{root_path},
        0,
    );
    defer allocator.free(raft_log_path);
    const peers = [_]kv.RaftPeerAddr{.{ .host = "127.0.0.1", .port = 39801 }};
    const node = try kv.RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39801),
        .apply = .{ .opaque_bytes = .{ .apply_fn = noopApply, .ctx = null } },
        .raft_log_path = raft_log_path,
    });
    defer node.deinit();

    var apply_ctx = apply_mod.ApplyCtx.init(allocator, root_path, node);
    defer apply_ctx.deinit();
    _ = try apply_ctx.getKv("acme");
    _ = try apply_ctx.getRootKv();

    // ── Capture into an FsBatchStore ────────────────────────────
    const store_dir = try std.fmt.allocPrint(allocator, "{s}/.snapshots", .{root_path});
    defer allocator.free(store_dir);
    const stage_dir = try std.fmt.allocPrint(allocator, "{s}/.stage", .{root_path});
    defer allocator.free(stage_dir);

    const store = try ls.batch_store_fs.FsBatchStore.init(allocator, store_dir);
    defer store.deinit();

    const sources = try tenantSourcesFromApplyCtx(allocator, &apply_ctx);
    defer allocator.free(sources);

    var captured = try capture(
        allocator,
        sources,
        apply_ctx.root_store,
        null,
        null,
        store.batchStore(),
        stage_dir,
        100,
        7,
    );
    defer captured.deinit();

    // ── Restore into a fresh data_dir ───────────────────────────
    const restore_dir = try std.fmt.allocPrint(allocator, "{s}-restored", .{root_path});
    defer std.fs.cwd().deleteTree(restore_dir) catch {};
    defer allocator.free(restore_dir);
    try std.fs.cwd().makePath(restore_dir);

    const restore_stage = try std.fmt.allocPrint(allocator, "{s}/.stage", .{restore_dir});
    defer allocator.free(restore_stage);

    var restored = try restore(
        allocator,
        store.batchStore(),
        captured.snap_id,
        restore_dir,
        restore_stage,
    );
    defer restored.manifest.deinit();

    try testing.expectEqual(@as(usize, 1), restored.tenants_restored);
    try testing.expect(restored.root_restored);

    // ── Verify the restored state matches the source ───────────
    const restored_acme = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/acme/app.db",
        .{restore_dir},
        0,
    );
    defer allocator.free(restored_acme);
    {
        const ks = try kv.KvStore.open(allocator, restored_acme);
        defer ks.close();
        const v = try ks.get("greeting");
        defer allocator.free(v);
        try testing.expectEqualStrings("hello", v);
        const c = try ks.get("counter");
        defer allocator.free(c);
        try testing.expectEqualStrings("42", c);
        try testing.expectEqual(@as(u64, 100), try ks.lastAppliedRaftIdx());
    }

    const restored_root = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/__root__.db",
        .{restore_dir},
        0,
    );
    defer allocator.free(restored_root);
    {
        const ks = try kv.KvStore.open(allocator, restored_root);
        defer ks.close();
        const v = try ks.get("tenant/acme");
        defer allocator.free(v);
        try testing.expectEqualStrings("{}", v);
        try testing.expectEqual(@as(u64, 100), try ks.lastAppliedRaftIdx());
    }
}

test "restore: rejects sha256 mismatch" {
    const allocator = testing.allocator;

    var path_buf: [96]u8 = undefined;
    const root_path = tmpPath(&path_buf, "tamper");
    defer std.fs.cwd().deleteTree(root_path) catch {};
    try std.fs.cwd().makePath(root_path);

    const store_dir = try std.fmt.allocPrint(allocator, "{s}/store", .{root_path});
    defer allocator.free(store_dir);
    const store = try ls.batch_store_fs.FsBatchStore.init(allocator, store_dir);
    defer store.deinit();

    // Hand-craft a manifest pointing at a bad-sha db key.
    try store.batchStore().put(
        "cluster/snapshots/AAAA/acme/app.db",
        "this isn't a valid sqlite db, doesn't matter",
    );
    try store.batchStore().put(
        "cluster/snapshots/AAAA/manifest.json",
        \\{"v":1,"snap_id":"AAAA","captured_at_ms":1,"willemt_compaction_floor":0,"willemt_term":0,
        \\"tenants":{"acme":{"db_key":"cluster/snapshots/AAAA/acme/app.db",
        \\"db_sha256":"00000000000000000000000000000000000000000000000000000000deadbeef",
        \\"db_size":99,"snapshot_idx":0}}}
        ,
    );

    const stage_dir = try std.fmt.allocPrint(allocator, "{s}/stage", .{root_path});
    defer allocator.free(stage_dir);
    try testing.expectError(Error.InvalidManifest, restore(
        allocator,
        store.batchStore(),
        "AAAA",
        root_path,
        stage_dir,
    ));
}

test "encode + decode manifest round-trips with one tenant" {
    var m = Manifest{
        .allocator = testing.allocator,
        .snap_id = try testing.allocator.dupe(u8, "0123456789abcdef0123456789ab"),
        .captured_at_ms = 1700000000000,
        .willemt_compaction_floor = 42,
        .willemt_term = 7,
        .tenants = blk: {
            var slice = try testing.allocator.alloc(TenantEntry, 1);
            slice[0] = .{
                .instance_id = try testing.allocator.dupe(u8, "acme"),
                .db_key = try testing.allocator.dupe(u8, "cluster/snapshots/X/acme/app.db"),
                .db_sha256 = @splat('a'),
                .db_size = 1024,
                .snapshot_idx = 42,
            };
            break :blk slice;
        },
        .root_db = .{
            .db_key = try testing.allocator.dupe(u8, "cluster/snapshots/X/__root__.db"),
            .db_sha256 = @splat('b'),
            .db_size = 2048,
            .snapshot_idx = 42,
        },
    };
    defer m.deinit();

    const bytes = try encodeManifest(testing.allocator, &m);
    defer testing.allocator.free(bytes);

    var back = try decodeManifest(testing.allocator, bytes);
    defer back.deinit();

    try testing.expectEqualStrings(m.snap_id, back.snap_id);
    try testing.expectEqual(@as(u64, 42), back.willemt_compaction_floor);
    try testing.expectEqual(@as(u64, 7), back.willemt_term);
    try testing.expectEqual(@as(usize, 1), back.tenants.len);
    try testing.expectEqualStrings("acme", back.tenants[0].instance_id);
    try testing.expectEqual(@as(u64, 1024), back.tenants[0].db_size);
    try testing.expect(back.root_db != null);
    try testing.expectEqual(@as(u64, 2048), back.root_db.?.db_size);
}

test "decode rejects wrong version" {
    const bad = "{\"v\":99,\"snap_id\":\"x\",\"captured_at_ms\":1,\"willemt_compaction_floor\":0,\"willemt_term\":0,\"tenants\":{}}";
    try testing.expectError(Error.InvalidManifest, decodeManifest(testing.allocator, bad));
}

test "capture: end-to-end against FsBatchStore round-trips a tenant db" {
    const allocator = testing.allocator;

    var path_buf: [96]u8 = undefined;
    const root_path = tmpPath(&path_buf, "ctx");
    defer std.fs.cwd().deleteTree(root_path) catch {};
    try std.fs.cwd().makePath(root_path);

    // Plant a `__root__.db` so ApplyCtx can lazy-open it.
    {
        const root_db_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/__root__.db",
            .{root_path},
            0,
        );
        defer allocator.free(root_db_path);
        const root_kv = try kv.KvStore.open(allocator, root_db_path);
        root_kv.close();
    }

    // Stand up a minimal raft node so ApplyCtx.init has something
    // to point at.
    const raft_log_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/raft.log.db",
        .{root_path},
        0,
    );
    defer allocator.free(raft_log_path);
    const peers = [_]kv.RaftPeerAddr{.{ .host = "127.0.0.1", .port = 39800 }};
    const node = try kv.RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39800),
        .apply = .{ .opaque_bytes = .{ .apply_fn = noopApply, .ctx = null } },
        .raft_log_path = raft_log_path,
    });
    defer node.deinit();

    // Tenant `acme` with one row.
    const acme_dir = try std.fmt.allocPrint(allocator, "{s}/acme", .{root_path});
    defer allocator.free(acme_dir);
    try std.fs.cwd().makePath(acme_dir);
    const acme_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/app.db",
        .{acme_dir},
        0,
    );
    defer allocator.free(acme_db_path);
    {
        const acme_kv = try kv.KvStore.open(allocator, acme_db_path);
        defer acme_kv.close();
        try acme_kv.put("hello", "world");
        try acme_kv.setLastAppliedRaftIdx(99);
    }

    var apply_ctx = apply_mod.ApplyCtx.init(allocator, root_path, node);
    defer apply_ctx.deinit();
    // Trigger lazy-open so kv_stores has acme + root_store is set.
    _ = try apply_ctx.getKv("acme");
    _ = try apply_ctx.getRootKv();

    // Snapshot store + tmp stage dir.
    const store_dir = try std.fmt.allocPrint(allocator, "{s}/.snapshots", .{root_path});
    defer allocator.free(store_dir);
    const stage_dir = try std.fmt.allocPrint(allocator, "{s}/.stage", .{root_path});
    defer allocator.free(stage_dir);

    const store = try ls.batch_store_fs.FsBatchStore.init(allocator, store_dir);
    defer store.deinit();

    // Build the (id, store) slice from the warmed ApplyCtx caches.
    const sources = try tenantSourcesFromApplyCtx(allocator, &apply_ctx);
    defer allocator.free(sources);

    var captured = try capture(
        allocator,
        sources,
        apply_ctx.root_store,
        null,
        null,
        store.batchStore(),
        stage_dir,
        100,
        7,
    );
    defer captured.deinit();

    // Manifest landed under the right key + parses as expected.
    const fetched = try store.batchStore().get(captured.manifest_key, allocator);
    defer allocator.free(fetched);
    var m = try decodeManifest(allocator, fetched);
    defer m.deinit();
    try testing.expectEqual(@as(u64, 100), m.willemt_compaction_floor);
    try testing.expectEqual(@as(u64, 7), m.willemt_term);
    try testing.expectEqual(@as(usize, 1), m.tenants.len);
    try testing.expectEqualStrings("acme", m.tenants[0].instance_id);
    try testing.expectEqual(@as(u64, 100), m.tenants[0].snapshot_idx);
    try testing.expect(m.root_db != null);

    // The acme db file was actually uploaded to the store and is a
    // valid SQLite db with the row we inserted.
    const acme_bytes = try store.batchStore().get(m.tenants[0].db_key, allocator);
    defer allocator.free(acme_bytes);
    try testing.expect(acme_bytes.len > 0);
    try testing.expectEqual(m.tenants[0].db_size, acme_bytes.len);

    // Re-open the captured bytes (write to a temp file, open as
    // KvStore, verify the row survived VACUUM INTO).
    const restore_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/restore.db",
        .{root_path},
        0,
    );
    defer allocator.free(restore_path);
    {
        const f = try std.fs.cwd().createFile(restore_path, .{ .mode = 0o600 });
        defer f.close();
        try f.writeAll(acme_bytes);
    }
    const restored = try kv.KvStore.open(allocator, restore_path);
    defer restored.close();
    const v = try restored.get("hello");
    defer allocator.free(v);
    try testing.expectEqualStrings("world", v);
    try testing.expectEqual(@as(u64, 99), try restored.lastAppliedRaftIdx());
}

test "capture: by-reference reuse for unchanged tenants" {
    // Two-tenant cluster. Snapshot 1 captures both fresh. Snapshot 2
    // happens after a write to acme but not beta:
    //
    //   - acme MUST be re-VACUUMed (its bytes changed)
    //   - beta MUST reuse snapshot 1's db_key (no apply touched it)
    //
    // The reuse path is what makes always-refresh-all-tenants
    // affordable at density — verify the bytes-on-store side of
    // that contract.
    const allocator = testing.allocator;

    var path_buf: [96]u8 = undefined;
    const root_path = tmpPath(&path_buf, "reuse");
    defer std.fs.cwd().deleteTree(root_path) catch {};
    try std.fs.cwd().makePath(root_path);

    // Plant __root__.db so ApplyCtx.getRootKv works.
    {
        const root_db_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/__root__.db",
            .{root_path},
            0,
        );
        defer allocator.free(root_db_path);
        const root_kv = try kv.KvStore.open(allocator, root_db_path);
        root_kv.close();
    }

    // Stand up a minimal raft node so ApplyCtx.init has a target.
    const raft_log_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/raft.log.db",
        .{root_path},
        0,
    );
    defer allocator.free(raft_log_path);
    const peers = [_]kv.RaftPeerAddr{.{ .host = "127.0.0.1", .port = 39810 }};
    const node = try kv.RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39810),
        .apply = .{ .opaque_bytes = .{ .apply_fn = noopApply, .ctx = null } },
        .raft_log_path = raft_log_path,
    });
    defer node.deinit();

    // Plant `acme` and `beta` tenants, each with one row, both
    // stamped at last_applied_raft_idx = 50.
    inline for (.{ "acme", "beta" }) |id| {
        const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_path, id });
        defer allocator.free(dir);
        try std.fs.cwd().makePath(dir);
        const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/app.db", .{dir}, 0);
        defer allocator.free(db_path);
        const ks = try kv.KvStore.open(allocator, db_path);
        defer ks.close();
        try ks.put(id ++ "-key", id ++ "-value-snapshot1");
        try ks.setLastAppliedRaftIdx(50);
    }

    var apply_ctx = apply_mod.ApplyCtx.init(allocator, root_path, node);
    defer apply_ctx.deinit();
    _ = try apply_ctx.getKv("acme");
    _ = try apply_ctx.getKv("beta");
    _ = try apply_ctx.getRootKv();

    const store_dir = try std.fmt.allocPrint(allocator, "{s}/.snapshots", .{root_path});
    defer allocator.free(store_dir);
    const stage_dir = try std.fmt.allocPrint(allocator, "{s}/.stage", .{root_path});
    defer allocator.free(stage_dir);
    const store = try ls.batch_store_fs.FsBatchStore.init(allocator, store_dir);
    defer store.deinit();

    // ── Snapshot 1: fresh capture of both tenants ───────────────
    const sources_1 = try tenantSourcesFromApplyCtx(allocator, &apply_ctx);
    defer allocator.free(sources_1);

    var captured_1 = try capture(
        allocator,
        sources_1,
        apply_ctx.root_store,
        apply_ctx.rootLastApplied(),
        null, // no prev — every tenant gets re-VACUUMed
        store.batchStore(),
        stage_dir,
        100,
        7,
    );
    defer captured_1.deinit();

    var manifest_1 = try decodeManifest(allocator, captured_1.manifest_bytes);
    defer manifest_1.deinit();
    try testing.expectEqual(@as(usize, 2), manifest_1.tenants.len);

    // Sort manifest_1 entries so the assertions don't depend on
    // ApplyCtx's hash-iteration order.
    const acme_1 = findTenantInManifest(&manifest_1, "acme") orelse return error.TestFail;
    const beta_1 = findTenantInManifest(&manifest_1, "beta") orelse return error.TestFail;

    // Both tenants should reference snap_1's directory in their db_key.
    try testing.expect(std.mem.indexOf(u8, acme_1.db_key, manifest_1.snap_id) != null);
    try testing.expect(std.mem.indexOf(u8, beta_1.db_key, manifest_1.snap_id) != null);

    // ── Apply something to acme but not beta. Bumps acme's
    //    in-memory tenant_apply_idx past beta's; this is what
    //    drives the reuse decision in snapshot 2.
    {
        const acme_kv = try apply_ctx.getKv("acme");
        try acme_kv.put("acme-key", "acme-value-snapshot2");
    }
    apply_ctx.tenant_apply_idx.put(allocator, "acme", 150) catch unreachable;
    // beta's tenant_apply_idx stays at the seeded value (50, from disk).

    // ── Snapshot 2: should reuse beta, fresh-capture acme ───────
    const sources_2 = try tenantSourcesFromApplyCtx(allocator, &apply_ctx);
    defer allocator.free(sources_2);

    var captured_2 = try capture(
        allocator,
        sources_2,
        apply_ctx.root_store,
        apply_ctx.rootLastApplied(),
        &manifest_1,
        store.batchStore(),
        stage_dir,
        200,
        7,
    );
    defer captured_2.deinit();

    var manifest_2 = try decodeManifest(allocator, captured_2.manifest_bytes);
    defer manifest_2.deinit();

    const acme_2 = findTenantInManifest(&manifest_2, "acme") orelse return error.TestFail;
    const beta_2 = findTenantInManifest(&manifest_2, "beta") orelse return error.TestFail;

    // acme: changed, must be re-captured under snap_2's directory
    // with a new sha256 (the new value changed the bytes).
    try testing.expect(std.mem.indexOf(u8, acme_2.db_key, manifest_2.snap_id) != null);
    try testing.expect(!std.mem.eql(u8, &acme_1.db_sha256, &acme_2.db_sha256));

    // beta: unchanged → must reuse snap_1's db_key BYTE-FOR-BYTE.
    // Same hash, same size, same key.
    try testing.expectEqualStrings(beta_1.db_key, beta_2.db_key);
    try testing.expectEqualSlices(u8, &beta_1.db_sha256, &beta_2.db_sha256);
    try testing.expectEqual(beta_1.db_size, beta_2.db_size);

    // BOTH entries' snapshot_idx is bumped to apply_position even
    // though beta's bytes are unchanged — that's the always-refresh
    // property that lets the willemt compaction floor advance every
    // pass without per-tenant activity gating.
    try testing.expectEqual(@as(u64, 200), acme_2.snapshot_idx);
    try testing.expectEqual(@as(u64, 200), beta_2.snapshot_idx);
    try testing.expectEqual(@as(u64, 200), manifest_2.willemt_compaction_floor);

    // Sanity: beta's reused db_key actually still resolves to bytes
    // on the store. Restore-from-snap_2 will need this to work.
    const beta_bytes = try store.batchStore().get(beta_2.db_key, allocator);
    defer allocator.free(beta_bytes);
    try testing.expect(beta_bytes.len > 0);
}

test "capture: prev_manifest with different tenant set" {
    // Edge: prev_manifest exists, but contains tenants we no
    // longer have AND lacks tenants we just added. Must capture
    // the new tenant fresh; no manifest entry for the dropped one.
    const allocator = testing.allocator;

    var path_buf: [96]u8 = undefined;
    const root_path = tmpPath(&path_buf, "newtenant");
    defer std.fs.cwd().deleteTree(root_path) catch {};
    try std.fs.cwd().makePath(root_path);

    {
        const root_db_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/__root__.db",
            .{root_path},
            0,
        );
        defer allocator.free(root_db_path);
        const root_kv = try kv.KvStore.open(allocator, root_db_path);
        root_kv.close();
    }

    const raft_log_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/raft.log.db",
        .{root_path},
        0,
    );
    defer allocator.free(raft_log_path);
    const peers = [_]kv.RaftPeerAddr{.{ .host = "127.0.0.1", .port = 39811 }};
    const node = try kv.RaftNode.init(allocator, .{
        .node_id = 0,
        .peers = &peers,
        .listen_addr = try std.net.Address.parseIp("127.0.0.1", 39811),
        .apply = .{ .opaque_bytes = .{ .apply_fn = noopApply, .ctx = null } },
        .raft_log_path = raft_log_path,
    });
    defer node.deinit();

    // Plant only `gamma`, no acme or beta.
    {
        const dir = try std.fmt.allocPrint(allocator, "{s}/gamma", .{root_path});
        defer allocator.free(dir);
        try std.fs.cwd().makePath(dir);
        const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/app.db", .{dir}, 0);
        defer allocator.free(db_path);
        const ks = try kv.KvStore.open(allocator, db_path);
        defer ks.close();
        try ks.put("g", "v");
    }

    var apply_ctx = apply_mod.ApplyCtx.init(allocator, root_path, node);
    defer apply_ctx.deinit();
    _ = try apply_ctx.getKv("gamma");
    _ = try apply_ctx.getRootKv();

    // Build a synthetic prev_manifest naming acme/beta with stale
    // snapshot_idx 50. This simulates "previous snapshot covered a
    // different tenant set."
    var prev_tenants = try allocator.alloc(TenantEntry, 1);
    prev_tenants[0] = .{
        .instance_id = try allocator.dupe(u8, "acme"),
        .db_key = try allocator.dupe(u8, "cluster/snapshots/old/acme/app.db"),
        .db_sha256 = [_]u8{'a'} ** 64,
        .db_size = 4096,
        .snapshot_idx = 50,
    };
    var prev_manifest = Manifest{
        .allocator = allocator,
        .snap_id = try allocator.dupe(u8, "old"),
        .captured_at_ms = 0,
        .willemt_compaction_floor = 50,
        .willemt_term = 1,
        .tenants = prev_tenants,
        .root_db = null,
    };
    defer prev_manifest.deinit();

    const store_dir = try std.fmt.allocPrint(allocator, "{s}/.snapshots", .{root_path});
    defer allocator.free(store_dir);
    const stage_dir = try std.fmt.allocPrint(allocator, "{s}/.stage", .{root_path});
    defer allocator.free(stage_dir);
    const store = try ls.batch_store_fs.FsBatchStore.init(allocator, store_dir);
    defer store.deinit();

    const sources = try tenantSourcesFromApplyCtx(allocator, &apply_ctx);
    defer allocator.free(sources);

    var captured = try capture(
        allocator,
        sources,
        apply_ctx.root_store,
        apply_ctx.rootLastApplied(),
        &prev_manifest,
        store.batchStore(),
        stage_dir,
        300,
        7,
    );
    defer captured.deinit();

    var manifest = try decodeManifest(allocator, captured.manifest_bytes);
    defer manifest.deinit();

    // Only gamma in the new manifest — acme isn't in our tenant set.
    try testing.expectEqual(@as(usize, 1), manifest.tenants.len);
    try testing.expectEqualStrings("gamma", manifest.tenants[0].instance_id);

    // gamma was captured fresh (under the new snap_id, NOT prev's "old").
    try testing.expect(std.mem.indexOf(u8, manifest.tenants[0].db_key, manifest.snap_id) != null);
    try testing.expect(std.mem.indexOf(u8, manifest.tenants[0].db_key, "old") == null);
}
