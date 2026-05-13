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
    // Production.md #1.4 step 4 — when set, seed skips the
    // S3-bound bootstrapTenant call entirely. The per-tenant dir
    // gets created and `_deploy/current` is written, but the
    // manifest itself is expected to live in the files-server's
    // cluster store (a separate seed step writes it via
    // `PUT /{tenant}/deployments/{N:hex}/manifest.bin`). For use
    // with the cluster-backed manifest architecture; without it,
    // the worker's first deploy fetch returns NoDeployment and
    // logs a warning.
    var no_files_bootstrap = false;
    // Deploy id to record in `_deploy/current` when
    // `--no-files-bootstrap` is set. The bench harness pairs this
    // with a manifest-PUT against files-server using the same id.
    var deploy_id: u64 = 1;
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
        } else if (std.mem.eql(u8, a, "--no-files-bootstrap")) {
            no_files_bootstrap = true;
        } else if (std.mem.eql(u8, a, "--deploy-id")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            deploy_id = try std.fmt.parseInt(u64, args[i], 10);
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

    // Seed runs offline (before any cluster is up). Open the
    // cluster's `cluster.kv` manifest directly via the same hashed
    // store ids the live Cluster will use — that way the data we
    // write here is visible when `loop46 worker` boots and the
    // Cluster opens the same file.
    const root_kv = try kv.KvStore.openClusterOwned(allocator, dd, "cluster.kv", "__root__");
    defer root_kv.close();

    const tenant = try tenant_mod.Tenant.create(allocator, root_kv, dd);
    defer tenant.destroy();

    if (no_files_bootstrap) {
        // Cluster-backed manifest mode: skip the S3 bootstrap, just
        // create per-tenant dirs, register in __root__.db, and
        // stamp `_deploy/current = deploy_id`. The bench (or
        // operator) is responsible for getting the manifest into
        // files-server's cluster store via the
        // `PUT /{tenant}/deployments/{N:hex}/manifest.bin` route
        // before any worker request hits this tenant.
        for (parsed.value.tenants) |t| {
            try tenant.createInstance(t.id);
            for (t.domains) |dom| try tenant.assignDomain(dom, t.id);
            try writeLocalDeployCurrent(tenant, t.id, deploy_id);
            if (t.seed_kv) |kvs| try seedAppKv(tenant, t.id, kvs);
        }
        std.debug.print(
            "seed: provisioned {d} tenant(s) into {s} (no-files-bootstrap; deploy_id={d})\n",
            .{ parsed.value.tenants.len, dd, deploy_id },
        );
        return;
    }

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
        // Offline path — no running cluster, so cluster=null. The
        // S3 PUT is the only durable write here.
        const dep_id = try files_server.bootstrap.bootstrapTenant(
            allocator,
            blob_owned.cfg,
            dd,
            t.id,
            deploy_files.items,
            null,
        );
        try writeLocalDeployCurrent(tenant, t.id, dep_id);
        try mirrorConfigFromManifest(allocator, tenant, blob_owned.cfg, t.id, dep_id);

        if (t.seed_kv) |kvs| try seedAppKv(tenant, t.id, kvs);
    }

    std.debug.print("seed: provisioned {d} tenant(s) into {s}\n", .{ parsed.value.tenants.len, dd });
}

fn seedAppKv(
    tenant: *tenant_mod.Tenant,
    instance_id: []const u8,
    kvs: std.json.ArrayHashMap([]const u8),
) !void {
    // Tenant.createInstance has already attached this instance's
    // store into the cluster's manifest. Write directly through
    // that handle.
    const inst = tenant.instances.get(instance_id) orelse return error.UnknownInstance;
    var it = kvs.map.iterator();
    while (it.next()) |entry| {
        try inst.kv.put(entry.key_ptr.*, entry.value_ptr.*);
    }
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
    tenant: *tenant_mod.Tenant,
    blob_cfg: blob_mod.BackendConfig,
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

    // Write through the tenant's instance handle — same kvexp
    // manifest the cluster will use at boot.
    const inst = tenant.instances.get(instance_id) orelse return error.UnknownInstance;
    const app_kv = inst.kv;

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
    try txn.commit();
    // No raft yet, so the writeset is discarded; followers
    // re-derive identical state from their own seed pass.
}

/// Write `_deploy/current = {dep_id:016x}` to `<dd>/<id>/app.db`.
/// Used by `seed` to publish the deployment that
/// `files_server.bootstrap.bootstrapTenant` just uploaded. Direct
/// per-node SQLite write — `seed` is offline, before any worker /
/// raft cluster exists. (Live-cluster deploys use `/_system/release`
/// instead, which routes through raft so every node sees the same
/// pointer.)
fn writeLocalDeployCurrent(
    tenant: *tenant_mod.Tenant,
    instance_id: []const u8,
    dep_id: u64,
) !void {
    const inst = tenant.instances.get(instance_id) orelse return error.UnknownInstance;
    var hex_buf: [16]u8 = undefined;
    const hex = try std.fmt.bufPrint(&hex_buf, "{x:0>16}", .{dep_id});
    try inst.kv.put("_deploy/current", hex);
}
