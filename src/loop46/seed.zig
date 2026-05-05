//! `loop46 seed` subcommand — manifest-driven offline tenant
//! provisioning. One-shot: reads a JSON manifest, opens
//! `<data-dir>/__root__.db`, registers each tenant + its domains,
//! deploys the listed files via the same content-addressed pipeline
//! customers use, and seeds optional KV. Run before `loop46 worker`.

const std = @import("std");
const kv = @import("rove-kv");
const tenant_mod = @import("rove-tenant");

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

        var deploy_files: std.ArrayList(main_mod.DeployFile) = .empty;
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

        try main_mod.bootstrapHandler(allocator, dd, blob_owned.cfg, t.id, deploy_files.items);

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
