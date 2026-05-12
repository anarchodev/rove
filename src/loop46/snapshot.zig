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
const blob_mod = @import("rove-blob");
const jwt = @import("rove-jwt");

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
    //
    // Under the kvexp consolidation, an entry whose instance_id is
    // the reserved `CLUSTER_DB_ID` covers the whole node-wide
    // `cluster.kv` and is written directly under `data_dir` (not
    // a per-instance subdir). Pre-cutover entries with real
    // tenant ids still work — they land at `{data_dir}/{id}/app.db`
    // — but no new captures produce them.
    var tenants_done: usize = 0;
    for (manifest.tenants) |entry| {
        if (std.mem.eql(u8, entry.instance_id, CLUSTER_DB_ID)) {
            try restoreOneDb(
                allocator,
                snapshot_store,
                entry.db_key,
                &entry.db_sha256,
                entry.db_size,
                entry.snapshot_idx,
                stage,
                try allocator.dupe(u8, data_dir),
                "cluster.kv",
            );
        } else {
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
        }
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

/// Context for `sendSnapshotFetchOffer`. Stashed on the kv.RaftNode
/// Config's `needs_snapshot_ctx` opaque slot at init time; the
/// callback casts back to read `http_url_prefix`. Caller owns the
/// underlying string for the process lifetime — RaftNode keeps a
/// borrowed pointer.
pub const NeedsSnapshotCtx = struct {
    /// URL prefix peers should GET against this node, e.g.
    /// `https://127.0.0.1:8470`. The full fetch URL is
    /// `{http_url_prefix}/_system/raft-snapshot/{snap_id_hex}`.
    http_url_prefix: []const u8,
};

/// Phase 5.5(c) step C / production.md #1.1 step 3 — mint a snap_id
/// and send a `snap_fetch_offer` frame to the far-behind peer so it
/// can pull our app.dbs out-of-band via the URL we put in the offer.
/// Pure plumbing on this side; the HTTP handler that actually
/// streams the bytes is in `worker_dispatch.handleRaftSnapshot`, and
/// the follower-side receive/install plumbing is in `worker.zig`.
///
/// Fire-and-forget. If transport.send fails (peer unreachable,
/// queue full), willemt will retry by firing `send_snapshot` again
/// on the next heartbeat tick that observes the peer's next_idx
/// still behind the snapshot floor — no need to track delivery here.
pub fn sendSnapshotFetchOffer(
    ctx_opaque: ?*anyopaque,
    raft: *kv.RaftNode,
    peer_id: u32,
) void {
    const ctx_ptr: *NeedsSnapshotCtx = @ptrCast(@alignCast(ctx_opaque orelse {
        std.log.warn("raft: sendSnapshotFetchOffer called with null ctx — dropping offer to peer {d}", .{peer_id});
        return;
    }));
    const snap_id = raft.mintSnapId();
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "{s}/_system/raft-snapshot/{x}",
        .{ ctx_ptr.http_url_prefix, snap_id },
    ) catch return;
    raft.sendSnapshotFetchOffer(peer_id, snap_id, url) catch |err| {
        std.log.warn(
            "raft: sendSnapshotFetchOffer to peer {d} (snap_id={x}) failed: {s}",
            .{ peer_id, snap_id, @errorName(err) },
        );
        return;
    };
    std.log.info(
        "raft: sent snap_fetch_offer to peer {d} (snap_id={x} snap_last_idx={d} snap_last_term={d} url={s})",
        .{ peer_id, snap_id, raft.snapshotLastIdx(), raft.snapshotLastTerm(), url },
    );
}

// ── Follower-side receive + stage + install ───────────────────────────

/// Result of a successful staged-snapshot install at boot. Returned
/// from `installStagedSnapshotIfPresent` so the caller can pass the
/// pair to `RaftNode.loadSnapshot` after init.
pub const StagedInstall = struct {
    snap_last_idx: u64,
    snap_last_term: u64,
};

/// Scan `{data_dir}/.snap-in-*/` for staged-but-uninstalled snapshot
/// bundles (`SnapReceiver` wrote these and exited; this boot picks
/// them up). When found:
///
///   1. Pick the staged dir with the highest `snap_last_idx` from
///      its `_install_meta.json`. Stale partial drops without that
///      file are deleted.
///   2. For each staged file, rename it into place inside
///      `data_dir/`. Mapping: `__root__.db` / `schedules.db` go to
///      top-level; `<tenant>__app.db` goes to `data_dir/<tenant>/app.db`
///      (with `makePath` creating the parent dir if needed).
///   3. Delete the now-empty staged dir.
///   4. Return the (snap_last_idx, snap_last_term) the caller should
///      pass to `RaftNode.loadSnapshot` after raft init.
///
/// Returns null when no staged dir is present (the normal cold-start
/// case). Returns an error only on filesystem failures — a malformed
/// staged dir (missing meta, unparseable JSON) is treated as a no-op
/// and logged loudly so the operator sees the lossage.
pub fn installStagedSnapshotIfPresent(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
) !?StagedInstall {
    var dir = std.fs.cwd().openDir(data_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    // Find the highest-idx staged dir among `.snap-in-*` entries with
    // an `_install_meta.json`. We don't sort dir entries (Zig iterates
    // unsorted on Linux); a single linear pass keeps the running max.
    var best_name_buf: [128]u8 = undefined;
    var best_name_len: usize = 0;
    var best_idx: u64 = 0;
    var best_term: u64 = 0;

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, ".snap-in-")) continue;

        // Stage dirs that never got `_install_meta.json` are partial.
        // Sweep them so they don't pile up across boots.
        const stage_path = try std.fs.path.join(allocator, &.{ data_dir, entry.name });
        defer allocator.free(stage_path);
        const meta_path = try std.fs.path.join(allocator, &.{ stage_path, "_install_meta.json" });
        defer allocator.free(meta_path);

        const meta_bytes = std.fs.cwd().readFileAlloc(allocator, meta_path, 1024) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.warn(
                    "loop46: staged dir {s} is partial (no _install_meta.json); deleting",
                    .{stage_path},
                );
                std.fs.cwd().deleteTree(stage_path) catch {};
                continue;
            },
            else => return err,
        };
        defer allocator.free(meta_bytes);

        const idx = parseJsonU64(meta_bytes, "\"snap_last_idx\"") orelse {
            std.log.warn(
                "loop46: staged dir {s} _install_meta.json missing snap_last_idx; deleting",
                .{stage_path},
            );
            std.fs.cwd().deleteTree(stage_path) catch {};
            continue;
        };
        const term = parseJsonU64(meta_bytes, "\"snap_last_term\"") orelse {
            std.log.warn(
                "loop46: staged dir {s} _install_meta.json missing snap_last_term; deleting",
                .{stage_path},
            );
            std.fs.cwd().deleteTree(stage_path) catch {};
            continue;
        };

        if (idx > best_idx) {
            if (entry.name.len > best_name_buf.len) continue; // too long, skip
            @memcpy(best_name_buf[0..entry.name.len], entry.name);
            best_name_len = entry.name.len;
            best_idx = idx;
            best_term = term;
        } else {
            // Older than what we already have — discard.
            std.log.info(
                "loop46: discarding older staged dir {s} (snap_last_idx={d} < best={d})",
                .{ stage_path, idx, best_idx },
            );
            std.fs.cwd().deleteTree(stage_path) catch {};
        }
    }

    if (best_name_len == 0) return null;

    const best_name = best_name_buf[0..best_name_len];
    const stage_path = try std.fs.path.join(allocator, &.{ data_dir, best_name });
    defer allocator.free(stage_path);

    std.log.info(
        "loop46: installing staged snapshot from {s} (snap_last_idx={d} snap_last_term={d})",
        .{ stage_path, best_idx, best_term },
    );

    // Walk the staged dir; rename each non-meta file into place.
    // Under the kvexp consolidation the bundle ships a single
    // `cluster.kv` entry — it lands at `{data_dir}/cluster.kv`.
    // The legacy per-tenant `{tenant}__app.db` + `__root__.db` +
    // `schedules.db` shape is gone; any such files in a stage
    // dir came from a pre-cutover sender and are skipped with a
    // warning (raft replay will re-derive their state).
    var stage_dir = try std.fs.cwd().openDir(stage_path, .{ .iterate = true });
    defer stage_dir.close();

    var sit = stage_dir.iterate();
    while (try sit.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, "_install_meta.json")) continue;

        const src = try std.fs.path.join(allocator, &.{ stage_path, entry.name });
        defer allocator.free(src);

        if (!std.mem.eql(u8, entry.name, "cluster.kv")) {
            std.log.warn(
                "loop46: staged file {s} is not cluster.kv — skipping (pre-cutover bundle?)",
                .{src},
            );
            continue;
        }

        const dst = try std.fs.path.join(allocator, &.{ data_dir, "cluster.kv" });
        defer allocator.free(dst);

        // Atomic rename within the same filesystem.
        try std.fs.cwd().rename(src, dst);
    }

    // Clean up: meta file + the now-empty stage dir.
    std.fs.cwd().deleteTree(stage_path) catch |err| {
        std.log.warn("loop46: cleanup of {s} failed: {s}", .{ stage_path, @errorName(err) });
    };

    return .{ .snap_last_idx = best_idx, .snap_last_term = best_term };
}

/// Hand-rolled u64 extractor for the install-meta JSON. We don't
/// want to depend on std.json here — the schema is two fields, and a
/// substring search keyed to the field name is enough. Returns null
/// on any malformation (caller decides whether to skip or fail).
fn parseJsonU64(json: []const u8, field: []const u8) ?u64 {
    const idx = std.mem.indexOf(u8, json, field) orelse return null;
    var i = idx + field.len;
    while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t')) i += 1;
    const start = i;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(u64, json[start..i], 10) catch null;
}

// ── Follower-side receive + stage ─────────────────────────────────────

/// Bundle magic the leader's `handleRaftSnapshot` writes at the head
/// of the response body. Receiver rejects anything that doesn't lead
/// with these 8 bytes.
const SNAP_BUNDLE_MAGIC = "ROVSNAP1";

/// Per-receiver state. One instance per loop46 process; the raft
/// thread invokes `onSnapFetchOffer` via the kv.RaftNode callback
/// and the heavy lifting (HTTP fetch + bundle write to disk)
/// happens on a detached fetcher thread so the raft heartbeat clock
/// is never blocked. Lives for the process lifetime; no shutdown
/// dance — the worker process exits to clean up.
///
/// Production.md #1.1 step 3, follower half. This commit lands the
/// staging path only: bytes land in `{data_dir}/.snap-in-{snap_id}/`
/// and the receiver logs "ready to install." The live install
/// (drain, close DBs, atomic-rename, `raft_load_snapshot`) is a
/// separate follow-up because the surgery has to coordinate with
/// the worker threads.
pub const SnapReceiver = struct {
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    /// Shared services-JWT secret. Required: without it the
    /// receiver can't mint the bearer token the leader's HTTP
    /// handler will accept. When null, incoming offers are logged
    /// and dropped.
    services_jwt_secret: ?[]const u8,

    /// Raft callback: invoked when a `snap_fetch_offer` arrives.
    /// Copies the borrowed fetch_path, spawns a detached fetcher
    /// thread, returns immediately. Runs on the raft thread —
    /// must stay fast.
    pub fn onSnapFetchOffer(
        ctx_opaque: ?*anyopaque,
        raft: *kv.RaftNode,
        from_id: u32,
        snap_last_term: u64,
        snap_last_idx: u64,
        snap_id: u64,
        fetch_path: []const u8,
    ) void {
        _ = raft;
        const self: *SnapReceiver = @ptrCast(@alignCast(ctx_opaque orelse {
            std.log.warn(
                "raft: on_snap_fetch_offer called with null ctx — dropping offer (peer={d} snap_id={x})",
                .{ from_id, snap_id },
            );
            return;
        }));

        if (self.services_jwt_secret == null) {
            std.log.warn(
                "raft: snap_fetch_offer ignored (peer={d} snap_id={x}) — LOOP46_SERVICES_JWT_SECRET is unset; can't mint the bearer token to fetch the bundle",
                .{ from_id, snap_id },
            );
            return;
        }

        const args = self.allocator.create(FetcherArgs) catch return;
        const path_copy = self.allocator.dupe(u8, fetch_path) catch {
            self.allocator.destroy(args);
            return;
        };
        args.* = .{
            .receiver = self,
            .from_id = from_id,
            .snap_last_term = snap_last_term,
            .snap_last_idx = snap_last_idx,
            .snap_id = snap_id,
            .fetch_path = path_copy,
        };

        const thread = std.Thread.spawn(.{}, fetcherThreadMain, .{args}) catch |err| {
            std.log.warn(
                "raft: snap_fetch_offer (peer={d} snap_id={x}) — thread spawn failed: {s}",
                .{ from_id, snap_id, @errorName(err) },
            );
            self.allocator.free(args.fetch_path);
            self.allocator.destroy(args);
            return;
        };
        thread.detach();

        std.log.info(
            "raft: received snap_fetch_offer (peer={d} snap_id={x} snap_last_idx={d} snap_last_term={d}) — fetcher thread dispatched",
            .{ from_id, snap_id, snap_last_idx, snap_last_term },
        );
    }
};

/// Heap-allocated payload handed to the fetcher thread. Owns the
/// `fetch_path` copy; freed in `fetcherThreadMain`'s defer.
const FetcherArgs = struct {
    receiver: *SnapReceiver,
    from_id: u32,
    snap_last_term: u64,
    snap_last_idx: u64,
    snap_id: u64,
    fetch_path: []const u8,
};

fn fetcherThreadMain(args: *FetcherArgs) void {
    const receiver = args.receiver;
    const alloc = receiver.allocator;
    defer {
        alloc.free(args.fetch_path);
        alloc.destroy(args);
    }
    fetcherRun(args) catch |err| {
        std.log.warn(
            "raft: snap fetcher (peer={d} snap_id={x}) failed: {s}",
            .{ args.from_id, args.snap_id, @errorName(err) },
        );
    };
}

fn fetcherRun(args: *FetcherArgs) !void {
    const receiver = args.receiver;
    const alloc = receiver.allocator;
    const secret = receiver.services_jwt_secret orelse return error.MissingSecret;

    // Mint a 5-minute services JWT carrying the raft-snapshot cap.
    const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
    const token = try jwt.mint(alloc, secret, .{
        .exp_ms = now_ms + 5 * 60 * 1000,
        .caps = &.{jwt.Cap.RAFT_SNAPSHOT},
    });
    defer alloc.free(token);

    // Build the Authorization header.
    const auth_value = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
    defer alloc.free(auth_value);

    blob_mod.curl.globalInit();
    var easy = try blob_mod.curl.Easy.init(alloc);
    defer easy.deinit();

    // Insecure TLS — inter-peer fetches in a self-signed dev /
    // private-network production deployment are authenticated via
    // the cap-gated JWT; TLS is here for encryption only. Mirrors
    // the `--files-internal-insecure-tls` precedent.
    const resp = try easy.request(alloc, .{
        .method = .GET,
        .url = args.fetch_path,
        .headers = &.{.{ .name = "Authorization", .value = auth_value }},
        .timeout_ms = 600_000, // 10 min — large bundles take real time
        .verify_tls = false,
    });
    var resp_mut = resp;
    defer resp_mut.deinit(alloc);

    if (resp.status != 200) {
        std.log.warn(
            "raft: snap fetch (peer={d} snap_id={x}) HTTP {d}: {s}",
            .{ args.from_id, args.snap_id, resp.status, if (resp.body) |b| b else "" },
        );
        return error.HttpStatus;
    }
    const body = resp.body orelse return error.EmptyBody;

    if (body.len < SNAP_BUNDLE_MAGIC.len or !std.mem.eql(u8, body[0..SNAP_BUNDLE_MAGIC.len], SNAP_BUNDLE_MAGIC)) {
        std.log.warn(
            "raft: snap fetch (peer={d} snap_id={x}) — bad magic, got {x}",
            .{ args.from_id, args.snap_id, body[0..@min(body.len, 8)] },
        );
        return error.BadMagic;
    }

    // Stage the unbundled files under `{data_dir}/.snap-in-{snap_id}/`.
    var stage_buf: [256]u8 = undefined;
    const stage_rel = std.fmt.bufPrint(&stage_buf, ".snap-in-{x}", .{args.snap_id}) catch return error.PathBuf;
    const stage_dir = try std.fs.path.join(alloc, &.{ receiver.data_dir, stage_rel });
    defer alloc.free(stage_dir);
    std.fs.cwd().deleteTree(stage_dir) catch {};
    try std.fs.cwd().makePath(stage_dir);
    errdefer std.fs.cwd().deleteTree(stage_dir) catch {};

    var pos: usize = SNAP_BUNDLE_MAGIC.len;
    if (body.len < pos + 4) return error.Truncated;
    const file_count = std.mem.readInt(u32, body[pos..][0..4], .big);
    pos += 4;

    var i: u32 = 0;
    while (i < file_count) : (i += 1) {
        if (body.len < pos + 2) return error.Truncated;
        const name_len = std.mem.readInt(u16, body[pos..][0..2], .big);
        pos += 2;
        if (body.len < pos + name_len) return error.Truncated;
        const name = body[pos .. pos + name_len];
        pos += name_len;
        if (body.len < pos + 8) return error.Truncated;
        const file_size = std.mem.readInt(u64, body[pos..][0..8], .big);
        pos += 8;
        if (body.len < pos + file_size) return error.Truncated;
        const file_bytes = body[pos .. pos + file_size];
        pos += file_size;

        // Reject name shapes that could escape stage_dir.
        if (std.mem.indexOfScalar(u8, name, '/') != null or
            std.mem.indexOfScalar(u8, name, '\\') != null or
            std.mem.startsWith(u8, name, "."))
        {
            return error.UnsafeName;
        }

        const out_path = try std.fs.path.join(alloc, &.{ stage_dir, name });
        defer alloc.free(out_path);
        const f = try std.fs.cwd().createFile(out_path, .{});
        defer f.close();
        try f.writeAll(file_bytes);
    }

    if (pos != body.len) {
        std.log.warn(
            "raft: snap fetch (peer={d} snap_id={x}) — bundle leftover bytes (consumed={d} total={d})",
            .{ args.from_id, args.snap_id, pos, body.len },
        );
    }

    // Stamp the install metadata. Boot-time install reads this to
    // know the raft idx/term to call `raft_load_snapshot` at. The
    // file's presence is ALSO the "complete + ready to install"
    // marker — a partially-downloaded stage dir won't have it, so
    // boot-time scan skips it.
    const meta_path = try std.fs.path.join(alloc, &.{ stage_dir, "_install_meta.json" });
    defer alloc.free(meta_path);
    const meta_body = try std.fmt.allocPrint(
        alloc,
        "{{\"snap_last_idx\":{d},\"snap_last_term\":{d},\"from_peer_id\":{d}}}\n",
        .{ args.snap_last_idx, args.snap_last_term, args.from_id },
    );
    defer alloc.free(meta_body);
    {
        const f = try std.fs.cwd().createFile(meta_path, .{});
        defer f.close();
        try f.writeAll(meta_body);
    }

    std.log.info(
        "raft: snap fetch (peer={d} snap_id={x}) staged {d} files under {s} — exiting for boot-time install",
        .{ args.from_id, args.snap_id, file_count, stage_dir },
    );

    // Trigger a process restart. The supervisor (systemd, k8s, or
    // the bash wrapper used in smoke) is expected to bring us back
    // up; on the next boot, the install path in `main.zig` detects
    // the staged dir, atomic-renames the DBs into place, and calls
    // `raft_load_snapshot(snap_last_idx, snap_last_term)` before
    // workers start serving.
    //
    // Using `std.process.exit(0)` (not abort) so the supervisor
    // sees a normal exit — abort would log a stack trace + core
    // dump on every catchup, which is noise. The exit happens on
    // the fetcher thread; that's fine, `exit(0)` is process-wide.
    std.process.exit(0);
}

/// Legacy operator-actionable warning. Retained for callers that
/// don't have a wired offer-send path yet (e.g. files-server's
/// kv.Cluster bootstrap when the multi-node smoke isn't exercising
/// the auto-catchup flow). Workers default to `sendSnapshotFetchOffer`
/// per `main.zig::workerMain`.
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
            "node, then restart the worker.",
        .{ peer_id, idx, term },
    );
}

/// Result of a successful `tickRaftCapture` pass. Replaces the
/// `Captured` struct for the periodic-loop path; operator CLI
/// captures still go through `capture()` and return `Captured`.
pub const TickResult = struct {
    /// The willemt apply position we just compacted past. Equal
    /// to `commit_idx_at_begin_snapshot`.
    apply_position: u64,
    /// Wall-clock duration of the tick (single __root__.db stamp
    /// + willemt begin/end + page-level log compaction).
    /// Excludes the elapsed-time gate.
    duration_ms: u64,
};

/// In-process periodic log compaction for the raft thread. O(1):
/// one row update in `__root__.db._apply_state` records the new
/// compaction floor, then willemt advances + compactLogPages
/// reclaims pages from the raft log.
///
/// Per `docs/production.md` #1.5: raft idx is globally ordered, so
/// one cluster-wide apply counter answers the apply filter for
/// every store. No per-tenant `_apply_state` row to write,
/// regardless of how many stores live on this node.
///
/// Falls-behind followers + new-node bootstrap go through
/// willemt's `send_snapshot` callback (separate item — currently
/// the `logNeedsSnapshot` warning), NOT through this path.
///
/// Returns null when we skipped this tick (interval not elapsed,
/// not leader, willemt has nothing to snapshot).
pub fn tickRaftCapture(
    state: *RaftCaptureState,
    now_ns: i64,
    cluster: *kv.Cluster,
) !?TickResult {
    if (state.interval_ns == 0) return null;
    const raft = cluster.raft;
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

    // Stamp the manifest watermark + durabilize. One fsync
    // persists every dirty page across every store inside
    // cluster.kv; intermediate page versions are elided as
    // orphans (kvexp PLAN §7.3). Cost is O(dirty pages),
    // independent of tenant count.
    cluster.kvexp_manifest.setLastAppliedRaftIdx(apply_position) catch |err| {
        std.log.warn(
            "snapshot: tickRaftCapture: setLastAppliedRaftIdx failed: {s}",
            .{@errorName(err)},
        );
        return null;
    };
    cluster.kvexp_manifest.durabilize() catch |err| {
        std.log.warn(
            "snapshot: tickRaftCapture: durabilize failed: {s}",
            .{@errorName(err)},
        );
        return null;
    };

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

/// Build a `[]TenantSource` slice from a warmed `Cluster`,
/// surfacing every store the library opened lazily during apply.
/// Borrows keys + store pointers; caller frees the returned slice
/// with `allocator.free`. Use from the raft thread (which owns
/// the connections) — workers can't share NOMUTEX SQLite handles.
///
/// `last_applied_idx` populates from `cluster.global_apply_idx`
/// so `capture` can do by-reference reuse against a prior snapshot.
pub fn tenantSourcesFromCluster(
    allocator: std.mem.Allocator,
    cluster: *kv.Cluster,
) ![]TenantSource {
    var list: std.ArrayListUnmanaged(TenantSource) = .empty;
    errdefer list.deinit(allocator);

    var it = cluster.stores.iterator();
    while (it.next()) |entry| {
        try list.append(allocator, .{
            .instance_id = entry.key_ptr.*,
            .store = entry.value_ptr.*,
            .last_applied_idx = cluster.global_apply_idx,
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
    // Under the kvexp consolidation the data dir holds one
    // `cluster.kv` file. Bypass the per-store `capture` loop and
    // ship the whole manifest via `dumpManifestToFile` — that
    // preserves every store_id (the per-store `vacuumInto` would
    // remap them to STANDALONE_STORE_ID, which mismatches what
    // `KvStore.openClusterOwned` expects on the receive side).
    //
    // The manifest carries a single `tenants[]` entry under the
    // reserved `CLUSTER_DB_ID`; restore writes the bytes to
    // `{data_dir}/cluster.kv` rather than per-tenant paths.
    const start_ns = std.time.nanoTimestamp();

    const snap_id = try mintSnapId(allocator);
    errdefer allocator.free(snap_id);

    const stage = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, snap_id });
    defer allocator.free(stage);
    std.fs.cwd().makePath(stage) catch return Error.Io;
    defer std.fs.cwd().deleteTree(stage) catch {};

    // Open cluster.kv just long enough to durabilize + dump.
    const ks = kv.KvStore.openClusterOwned(allocator, data_dir, "cluster.kv", "__root__") catch
        return Error.Sqlite;
    defer ks.close();

    ks.setLastAppliedRaftIdx(apply_position) catch return Error.Sqlite;

    const tmp_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/cluster.kv",
        .{stage},
        0,
    );
    defer allocator.free(tmp_path);
    ks.dumpManifestToFile(tmp_path) catch return Error.Sqlite;

    // Upload + hash + size.
    const db_key_base = try snapshotKey(allocator, snap_id, CLUSTER_DB_ID);
    const uploaded = try uploadDbFile(allocator, snapshot_store, tmp_path, db_key_base);

    // Manifest: one tenant entry under the reserved CLUSTER_DB_ID.
    var tenants = try allocator.alloc(TenantEntry, 1);
    errdefer allocator.free(tenants);
    tenants[0] = .{
        .instance_id = try allocator.dupe(u8, CLUSTER_DB_ID),
        .db_key = uploaded.key,
        .db_sha256 = uploaded.sha256_hex,
        .db_size = uploaded.size,
        .snapshot_idx = apply_position,
    };

    const manifest = Manifest{
        .allocator = allocator,
        .snap_id = snap_id,
        .captured_at_ms = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms)),
        .willemt_compaction_floor = apply_position,
        .willemt_term = willemt_term,
        .tenants = tenants,
        .root_db = null,
    };
    const manifest_bytes = try encodeManifest(allocator, &manifest);
    errdefer allocator.free(manifest_bytes);

    const manifest_key = try std.fmt.allocPrint(
        allocator,
        "cluster/snapshots/{s}/manifest.json",
        .{snap_id},
    );
    errdefer allocator.free(manifest_key);
    snapshot_store.put(manifest_key, manifest_bytes) catch return Error.Backend;

    // Free the working tenants slice — manifest.deinit isn't
    // called here (we don't own it as a fresh Manifest, we
    // hand-rolled it inline).
    allocator.free(tenants[0].instance_id);
    allocator.free(tenants[0].db_key);
    allocator.free(tenants);

    const elapsed_ns = std.time.nanoTimestamp() - start_ns;
    const duration_ms: u64 = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));

    return .{
        .snap_id = snap_id,
        .manifest_key = manifest_key,
        .manifest_bytes = manifest_bytes,
        .vacuumed_count = 1,
        .reused_count = 0,
        .duration_ms = duration_ms,
        .allocator = allocator,
    };
}

/// Reserved tenant id used in the snapshot manifest to denote the
/// consolidated `cluster.kv` file. Both the capture (single-source
/// case) and restore paths recognize it.
pub const CLUSTER_DB_ID: []const u8 = "__cluster__";

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

    // ── Stand up a raft node + cluster (kvexp manifest at
    // {root_path}/cluster.kv) ──
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

    const cluster = try kv.Cluster.initWithExternalRaft(allocator, root_path, node, null);
    defer cluster.deinit();

    // ── Write source state through the cluster's stores ────────
    const root_kv = try cluster.openRoot();
    try root_kv.put("tenant/acme", "{}");
    const acme_kv = try cluster.openStore("acme");
    try acme_kv.put("greeting", "hello");
    try acme_kv.put("counter", "42");

    // ── Capture into an FsBatchStore ────────────────────────────
    const store_dir = try std.fmt.allocPrint(allocator, "{s}/.snapshots", .{root_path});
    defer allocator.free(store_dir);
    const stage_dir = try std.fmt.allocPrint(allocator, "{s}/.stage", .{root_path});
    defer allocator.free(stage_dir);

    const store = try ls.batch_store_fs.FsBatchStore.init(allocator, store_dir);
    defer store.deinit();

    const sources = try tenantSourcesFromCluster(allocator, cluster);
    defer allocator.free(sources);

    var captured = try capture(
        allocator,
        sources,
        cluster.root_store,
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

    // Stand up a minimal raft node so the cluster has something
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

    const cluster = try kv.Cluster.initWithExternalRaft(allocator, root_path, node, null);
    defer cluster.deinit();

    // Tenant `acme` with one row, written via the cluster.
    const acme_kv = try cluster.openStore("acme");
    try acme_kv.put("hello", "world");
    _ = try cluster.openRoot();

    // Snapshot store + tmp stage dir.
    const store_dir = try std.fmt.allocPrint(allocator, "{s}/.snapshots", .{root_path});
    defer allocator.free(store_dir);
    const stage_dir = try std.fmt.allocPrint(allocator, "{s}/.stage", .{root_path});
    defer allocator.free(stage_dir);

    const store = try ls.batch_store_fs.FsBatchStore.init(allocator, store_dir);
    defer store.deinit();

    // Build the (id, store) slice from the warmed cluster caches.
    const sources = try tenantSourcesFromCluster(allocator, cluster);
    defer allocator.free(sources);

    var captured = try capture(
        allocator,
        sources,
        cluster.root_store,
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
    // Per-tenant `_apply_state.last_applied_raft_idx` retired in
    // #1.5 — global apply idx lives in __root__.db. The legacy
    // byte-capture path no longer carries per-tenant idx, so the
    // restored per-tenant row stays at 0 (unset). The kv data
    // itself round-trips as before.
}

test "capture: by-reference reuse for unchanged tenants — RETIRED #1.5" {
    // Per-tenant apply-idx tracking is gone. The by-reference
    // reuse path picked unchanged tenants by comparing
    // source.last_applied_idx to prev_manifest's snapshot_idx
    // per-tenant. With the global apply idx model, every source
    // has the same idx in any given pass, so the heuristic can
    // no longer distinguish changed from unchanged. The operator-
    // CLI byte-capture path now re-captures every tenant on
    // every pass; minor efficiency regression for that one path,
    // pre-launch so no prior captures to preserve.
    return error.SkipZigTest;
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

    const cluster = try kv.Cluster.initWithExternalRaft(allocator, root_path, node, null);
    defer cluster.deinit();

    // Plant only `gamma`, no acme or beta — through the cluster.
    const gamma_kv = try cluster.openStore("gamma");
    try gamma_kv.put("g", "v");
    _ = try cluster.openRoot();

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

    const sources = try tenantSourcesFromCluster(allocator, cluster);
    defer allocator.free(sources);

    var captured = try capture(
        allocator,
        sources,
        cluster.root_store,
        cluster.global_apply_idx,
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

test "captureFromDataDir + restore round-trips cluster.kv" {
    // CLI-shaped scenario: an operator runs `loop46 snapshot
    // --data-dir D` (`captureFromDataDir`) followed by
    // `loop46 restore --data-dir D'` (`restore`). Under the
    // kvexp consolidation the snapshot covers `cluster.kv` as a
    // single reserved entry under `CLUSTER_DB_ID`.
    const allocator = testing.allocator;

    var path_buf: [96]u8 = undefined;
    const source_dir = tmpPath(&path_buf, "cdd-src");
    defer std.fs.cwd().deleteTree(source_dir) catch {};
    try std.fs.cwd().makePath(source_dir);

    // Seed cluster.kv via the offline open path (same shape
    // `loop46 seed` uses).
    {
        const root_kv = try kv.KvStore.openClusterOwned(allocator, source_dir, "cluster.kv", "__root__");
        defer root_kv.close();
        try root_kv.put("hello", "from-cluster");
    }

    const store_dir = try std.fmt.allocPrint(allocator, "{s}/.snapshots", .{source_dir});
    defer allocator.free(store_dir);
    const stage_dir = try std.fmt.allocPrint(allocator, "{s}/.stage", .{source_dir});
    defer allocator.free(stage_dir);

    const store = try ls.batch_store_fs.FsBatchStore.init(allocator, store_dir);
    defer store.deinit();

    var captured = try captureFromDataDir(
        allocator,
        source_dir,
        store.batchStore(),
        stage_dir,
        100,
        7,
    );
    defer captured.deinit();

    var manifest = try decodeManifest(allocator, captured.manifest_bytes);
    defer manifest.deinit();
    try testing.expectEqual(@as(usize, 1), manifest.tenants.len);
    try testing.expectEqualStrings(CLUSTER_DB_ID, manifest.tenants[0].instance_id);

    // Restore into a fresh data dir.
    const restore_dir = try std.fmt.allocPrint(allocator, "{s}-restored", .{source_dir});
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

    // Read the restored cluster.kv back via the standard open
    // path — confirms it's a valid kvexp file with the data
    // intact under the same root-store id.
    {
        const ks = try kv.KvStore.openClusterOwned(allocator, restore_dir, "cluster.kv", "__root__");
        defer ks.close();
        const v = try ks.get("hello");
        defer allocator.free(v);
        try testing.expectEqualStrings("from-cluster", v);
    }
}
