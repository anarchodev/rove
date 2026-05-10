//! `loop46 seed` subcommand — manifest-driven offline tenant
//! provisioning. One-shot: reads a JSON manifest, opens
//! `<data-dir>/__root__.db`, registers each tenant + its domains,
//! deploys the listed files via the same content-addressed pipeline
//! customers use, and seeds optional KV. Run before `loop46 worker`.

const std = @import("std");
const kv = @import("rove-kv");
const blob_mod = @import("rove-blob");
const tenant_mod = @import("rove-tenant");
const files_server = @import("rove-files-server");
const config_mirror = @import("rove-js").config_mirror;

const main_mod = @import("main.zig");

/// Schema for `loop46-demo-tenants.json`-style manifests. `source`
/// paths are interpreted relative to the manifest file's parent
/// directory so the manifest stays portable.
const SeedManifest = struct {
    tenants: []SeedTenant,
};
const SeedTenant = struct {
    id: []const u8,
    domains: []const []const u8 = &.{},
    files: []const SeedFile = &.{},
    /// Optional initial KV rows written directly into the tenant's
    /// `app.db` before any worker opens it. Used by readonly-style
    /// benchmarks that need pre-seeded state.
    seed_kv: ?std.json.ArrayHashMap([]const u8) = null,
};
const SeedFile = struct {
    /// Path inside the tenant's deployment (e.g. `index.mjs`,
    /// `api/index.mjs`, `_static/foo.html`).
    path: []const u8,
    /// File on disk to read bytes from. Resolved relative to the
    /// manifest file's parent directory.
    source: []const u8,
    /// Non-null marks this entry as a STATIC file served verbatim
    /// with the given content-type — paired with a `_static/`
    /// path. Null (or omitted) means handler source compiled to
    /// bytecode at deploy time.
    content_type: ?[]const u8 = null,
};

/// Drive `loop46 seed --data-dir <dir> --manifest <path>`. The data
/// dir is left ready for `loop46 worker` to start against.
pub fn runSeed(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    var data_dir: ?[]const u8 = null;
    var manifest_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            data_dir = args[i];
        } else if (std.mem.eql(u8, a, "--manifest")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            manifest_path = args[i];
        } else {
            return error.Usage;
        }
    }
    const dd = data_dir orelse return error.Usage;
    const mf = manifest_path orelse return error.Usage;

    try std.fs.cwd().makePath(dd);

    // Pick fs vs s3 from env so seed-time bootstraps land in the same
    // backend the worker will read from. Strings live for the function
    // body only; bootstrapHandler dupes them on use.
    var blob_owned = try main_mod.loadBlobBackend(allocator);
    defer blob_owned.deinit(allocator);

    // Resolve manifest dir so relative file paths inside the manifest
    // are interpreted against the manifest file's directory, not cwd.
    const manifest_dir = std.fs.path.dirname(mf) orelse ".";

    const mf_bytes = try std.fs.cwd().readFileAlloc(allocator, mf, 1 << 20);
    defer allocator.free(mf_bytes);

    var parsed = try std.json.parseFromSlice(
        SeedManifest,
        allocator,
        mf_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const root_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/__root__.db",
        .{dd},
        0,
    );
    defer allocator.free(root_path);
    const root_kv = try kv.KvStore.open(allocator, root_path);
    defer root_kv.close();

    const tenant = try tenant_mod.Tenant.create(allocator, root_kv, dd);
    defer tenant.destroy();

    for (parsed.value.tenants) |t| {
        try tenant.createInstance(t.id);
        for (t.domains) |dom| {
            try tenant.assignDomain(dom, t.id);
        }

        var deploy_files: std.ArrayList(files_server.bootstrap.DeployFile) = .empty;
        defer {
            for (deploy_files.items) |f| allocator.free(f.content);
            deploy_files.deinit(allocator);
        }

        for (t.files) |entry| {
            const full = try std.fs.path.join(allocator, &.{ manifest_dir, entry.source });
            defer allocator.free(full);
            const bytes = try std.fs.cwd().readFileAlloc(allocator, full, 1 << 20);
            errdefer allocator.free(bytes);
            try deploy_files.append(allocator, .{
                .path = entry.path,
                .content = bytes,
                .content_type = entry.content_type,
            });
        }

        // Deploy the tenant's bundle to S3 via files-server's
        // bootstrapTenant. seed is offline (runs before any cluster
        // is up) so the per-node `_deploy/current` write that
        // files-server normally pushes via raft instead lands here
        // as a direct app.db write — same shape as old
        // bootstrapHandler did, just with the deploy half outsourced.
        const dep_id = try files_server.bootstrap.bootstrapTenant(
            allocator,
            blob_owned.cfg,
            dd,
            t.id,
            deploy_files.items,
        );
        try writeLocalDeployCurrent(allocator, dd, t.id, dep_id);
        try mirrorConfigFromManifest(allocator, blob_owned.cfg, dd, t.id, dep_id);

        if (t.seed_kv) |kvs| {
            const inst_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dd, t.id });
            defer allocator.free(inst_dir);
            try std.fs.cwd().makePath(inst_dir);
            const app_db_path = try std.fmt.allocPrintSentinel(
                allocator,
                "{s}/app.db",
                .{inst_dir},
                0,
            );
            defer allocator.free(app_db_path);
            const app_kv = try kv.KvStore.open(allocator, app_db_path);
            defer app_kv.close();
            var it = kvs.map.iterator();
            while (it.next()) |entry| {
                try app_kv.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    std.debug.print("seed: provisioned {d} tenant(s) into {s}\n", .{ parsed.value.tenants.len, dd });
}

/// Run the same `_config/` → kv mirror on this node's app.db that
/// the live release path runs (worker_dispatch.handleRelease). Seed
/// is offline (no raft yet, runs once per node), so the writeset
/// gets discarded — followers re-derive identical state from their
/// own seed pass. Skipped silently when the manifest can't be
/// loaded (no config files in this deploy → empty manifest is fine,
/// but a real load failure logs).
fn mirrorConfigFromManifest(
    allocator: std.mem.Allocator,
    blob_cfg: blob_mod.BackendConfig,
    dd: []const u8,
    instance_id: []const u8,
    dep_id: u64,
) !void {
    var manifest = files_server.loadDeployment(allocator, blob_cfg, instance_id, dep_id) catch |err| {
        std.log.warn("seed: skipping config mirror for {s}/{x:0>16} — manifest load failed: {s}", .{ instance_id, dep_id, @errorName(err) });
        return;
    };
    defer manifest.deinit();

    var file_blobs = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        instance_id,
        "file-blobs",
    );
    defer file_blobs.deinit();

    const inst_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dd, instance_id });
    defer allocator.free(inst_dir);
    try std.fs.cwd().makePath(inst_dir);
    const app_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/app.db", .{inst_dir}, 0);
    defer allocator.free(app_db_path);
    const app_kv = try kv.KvStore.open(allocator, app_db_path);
    defer app_kv.close();

    var txn = try app_kv.beginTrackedImmediate();
    errdefer txn.rollback() catch {};
    var ws = kv.WriteSet.init(allocator);
    defer ws.deinit();
    _ = try config_mirror.mirrorConfigToKv(
        allocator,
        manifest,
        file_blobs.blobStore(),
        app_kv,
        &txn,
        &ws,
    );
    const txn_seq = txn.txn_seq;
    try txn.commit();
    // Clear the undo row — seed is offline (no raft to confirm
    // durability), so without this the worker's recoverOrphans
    // sweep at startup would treat the write as uncommitted and
    // roll it back. ws is discarded for the same reason: no raft
    // to propose to. Followers re-derive identical state from
    // their own seed pass.
    if (txn_seq != 0) try app_kv.commitTxn(txn_seq);
}

/// Write `_deploy/current = {dep_id:016x}` to `<dd>/<id>/app.db`.
/// Used by `seed` to publish the deployment that
/// `files_server.bootstrap.bootstrapTenant` just uploaded. Direct
/// per-node SQLite write — `seed` is offline, before any worker /
/// raft cluster exists. (Live-cluster deploys use `/_system/release`
/// instead, which routes through raft so every node sees the same
/// pointer.)
fn writeLocalDeployCurrent(
    allocator: std.mem.Allocator,
    dd: []const u8,
    instance_id: []const u8,
    dep_id: u64,
) !void {
    const inst_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dd, instance_id });
    defer allocator.free(inst_dir);
    try std.fs.cwd().makePath(inst_dir);
    const app_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/app.db", .{inst_dir}, 0);
    defer allocator.free(app_db_path);
    const app_kv = try kv.KvStore.open(allocator, app_db_path);
    defer app_kv.close();
    var hex_buf: [16]u8 = undefined;
    const hex = try std.fmt.bufPrint(&hex_buf, "{x:0>16}", .{dep_id});
    try app_kv.put("_deploy/current", hex);
}
