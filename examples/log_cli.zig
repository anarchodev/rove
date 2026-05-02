//! `rove-log-cli` — query the per-tenant log store written by the
//! worker. Read-only; opens `{data_dir}/{instance}/log.db` directly.
//!
//! Subcommands:
//!
//!     rove-log-cli list  --data-dir <root> --instance <id> [--limit N]
//!     rove-log-cli show  --data-dir <root> --instance <id> --request-id <hex>
//!     rove-log-cli count --data-dir <root> --instance <id>
//!
//! The `list` subcommand walks the `req-desc/` secondary index (newest
//! first) and prints one summary line per record. `show` prints a full
//! record as pretty-ish JSON. `count` returns the total number of
//! records (useful for smoke tests).

const std = @import("std");
const kv = @import("rove-kv");
const blob_mod = @import("rove-blob");
const log_mod = @import("rove-log");
const files_mod = @import("rove-files");
const tape_mod = @import("rove-tape");

const Cmd = enum { list, show, count, bundle };

const Args = struct {
    cmd: Cmd,
    data_dir: []const u8,
    instance: []const u8,
    limit: u32 = 50,
    request_id: ?u64 = null,
};

fn parseArgs(argv: [][:0]u8) !Args {
    if (argv.len < 2) return error.Usage;
    const cmd: Cmd = if (std.mem.eql(u8, argv[1], "list"))
        .list
    else if (std.mem.eql(u8, argv[1], "show"))
        .show
    else if (std.mem.eql(u8, argv[1], "count"))
        .count
    else if (std.mem.eql(u8, argv[1], "bundle"))
        .bundle
    else
        return error.Usage;

    var data_dir: ?[]const u8 = null;
    var instance: ?[]const u8 = null;
    var limit: u32 = 50;
    var request_id: ?u64 = null;

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            data_dir = argv[i];
        } else if (std.mem.eql(u8, a, "--instance")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            instance = argv[i];
        } else if (std.mem.eql(u8, a, "--limit")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            limit = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--request-id")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            request_id = try std.fmt.parseInt(u64, argv[i], 16);
        } else {
            return error.Usage;
        }
    }

    if (data_dir == null or instance == null) return error.Usage;
    if ((cmd == .show or cmd == .bundle) and request_id == null) return error.Usage;

    return .{
        .cmd = cmd,
        .data_dir = data_dir.?,
        .instance = instance.?,
        .limit = limit,
        .request_id = request_id,
    };
}

fn usage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\usage: rove-log-cli <cmd> --data-dir <path> --instance <id> [opts]
        \\  list                 [--limit N]   list recent records (newest first)
        \\  show --request-id H              show one record by hex id
        \\  count                            print record count
        \\  bundle --request-id H            emit replay bundle JSON to stdout
        \\
    );
    try w.flush();
}

fn outcomeName(o: log_mod.Outcome) []const u8 {
    return switch (o) {
        .ok => "ok",
        .fault => "fault",
        .timeout => "timeout",
        .handler_error => "handler_error",
        .kv_error => "kv_error",
        .no_deployment => "no_deployment",
        .unknown_domain => "unknown_domain",
    };
}

fn runList(allocator: std.mem.Allocator, store: *log_mod.LogStore, limit: u32) !void {
    var result = try store.list(.{ .limit = limit });
    defer result.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    const w = &sw.interface;

    try w.print("# {d} record(s)\n", .{result.records.len});
    for (result.records) |*r| {
        try w.print(
            "{x:0>16}  dep={d}  {d:>3}  {s:<14}  {s:<6} {s} (host={s}, dur={d}ns)\n",
            .{
                r.request_id,
                r.deployment_id,
                r.status,
                outcomeName(r.outcome),
                r.method,
                r.path,
                r.host,
                r.duration_ns,
            },
        );
    }
    try w.flush();
    _ = allocator;
}

fn runShow(allocator: std.mem.Allocator, store: *log_mod.LogStore, request_id: u64) !void {
    var rec = (try store.get(request_id)) orelse {
        var stderr_buf: [256]u8 = undefined;
        var sw = std.fs.File.stderr().writer(&stderr_buf);
        try sw.interface.print("rove-log-cli: no record with request_id={x}\n", .{request_id});
        try sw.interface.flush();
        std.process.exit(1);
    };
    defer rec.deinit(allocator);

    var stdout_buf: [4096]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    const w = &sw.interface;
    try w.print(
        \\{{
        \\  "request_id": "{x:0>16}",
        \\  "deployment_id": {d},
        \\  "received_ns": {d},
        \\  "duration_ns": {d},
        \\  "method": "{s}",
        \\  "path": "{s}",
        \\  "host": "{s}",
        \\  "status": {d},
        \\  "outcome": "{s}",
        \\  "console_len": {d},
        \\  "exception_len": {d}
        \\}}
        \\
    , .{
        rec.request_id,
        rec.deployment_id,
        rec.received_ns,
        rec.duration_ns,
        rec.method,
        rec.path,
        rec.host,
        rec.status,
        outcomeName(rec.outcome),
        rec.console.len,
        rec.exception.len,
    });
    if (rec.console.len > 0) {
        try w.print("--- console ---\n{s}", .{rec.console});
    }
    try w.flush();
}

fn runCount(allocator: std.mem.Allocator, store: *log_mod.LogStore) !void {
    var result = try store.list(.{ .limit = std.math.maxInt(u32) });
    defer result.deinit();

    var stdout_buf: [64]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    try sw.interface.print("{d}\n", .{result.records.len});
    try sw.interface.flush();
    _ = allocator;
}

// No-op compile hook — the bundle reader never compiles anything; it
// only calls `loadDeployment` on the code store. Providing a stub lets
// us reuse `FileStore.init` without pulling in the qjs build.
fn noopCompile(
    _: ?*anyopaque,
    _: []const u8,
    _: [:0]const u8,
    _: std.mem.Allocator,
) anyerror![]u8 {
    return error.NotSupported;
}

// ── bundle ─────────────────────────────────────────────────────────────
//
// `rove-log-cli bundle` resolves the deployment's entry-source hash
// (CLI's concern — files.db lives next to log.db on disk) and delegates
// the actual JSON formatting to `rove-tape`'s `bundle` module so the
// same code path serves the worker's `/_system/replay/bundle/{id}`
// endpoint. Wire shape lives in `src/tape/bundle.zig`.

fn resolveEntrySourceHash(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance: []const u8,
    deployment_id: u64,
) !?[64]u8 {
    const files_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}/files.db",
        .{ data_dir, instance },
        0,
    );
    defer allocator.free(files_db_path);
    const files_blob_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/file-blobs",
        .{ data_dir, instance },
    );
    defer allocator.free(files_blob_dir);

    const files_kv = kv.KvStore.openReadOnly(allocator, files_db_path) catch return null;
    defer files_kv.close();

    var files_blob = try blob_mod.FilesystemBlobStore.open(allocator, files_blob_dir);
    defer files_blob.deinit();
    var files_store = files_mod.FileStore.init(allocator, files_kv, files_blob.blobStore(), noopCompile, null);
    var manifest = files_store.loadDeployment(deployment_id) catch return null;
    defer manifest.deinit();

    for (manifest.entries) |e| {
        if (std.mem.eql(u8, e.path, "index.js")) return e.source_hex;
    }
    if (manifest.entries.len > 0) return manifest.entries[0].source_hex;
    return null;
}

fn runBundle(
    allocator: std.mem.Allocator,
    store: *log_mod.LogStore,
    log_blob: blob_mod.BlobStore,
    data_dir: []const u8,
    instance: []const u8,
    request_id: u64,
) !void {
    // Peek at the record once to (a) surface NotFound as exit-1 with a
    // stderr message and (b) grab `deployment_id` to resolve the entry
    // source hash before delegating the JSON emit. `writeBundle` will
    // re-read the record itself; the per-record cost is negligible vs.
    // the SQL+blob work involved in tape decoding.
    const dep_id = blk: {
        var rec = (try store.get(request_id)) orelse {
            var stderr_buf: [256]u8 = undefined;
            var sw = std.fs.File.stderr().writer(&stderr_buf);
            try sw.interface.print("rove-log-cli: no record with request_id={x}\n", .{request_id});
            try sw.interface.flush();
            std.process.exit(1);
        };
        defer rec.deinit(allocator);
        break :blk rec.deployment_id;
    };

    const entry_hash = resolveEntrySourceHash(allocator, data_dir, instance, dep_id) catch null;

    var stdout_buf: [4096]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    const w = &sw.interface;

    try tape_mod.bundle.writeBundle(w, .{
        .allocator = allocator,
        .log_store = store,
        .log_blob = log_blob,
        .request_id = request_id,
        .entry_source_hash = entry_hash,
    });
    try w.writeAll("\n");
    try w.flush();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var stderr_buf: [1024]u8 = undefined;
    var sw = std.fs.File.stderr().writer(&stderr_buf);

    const args = parseArgs(argv) catch {
        try usage(&sw.interface);
        std.process.exit(2);
    };

    // Build {data_dir}/{instance}/log.db + log-blobs paths.
    const log_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}/log.db",
        .{ args.data_dir, args.instance },
        0,
    );
    defer allocator.free(log_db_path);

    const log_blob_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/log-blobs",
        .{ args.data_dir, args.instance },
    );
    defer allocator.free(log_blob_dir);

    // Open in read-only mode so we don't conflict with a running
    // worker. WAL mode allows concurrent readers + one writer; read-
    // only avoids the write lock entirely.
    const log_kv = try kv.KvStore.openReadOnly(allocator, log_db_path);
    defer log_kv.close();

    var blob_backend = try blob_mod.FilesystemBlobStore.open(allocator, log_blob_dir);
    defer blob_backend.deinit();

    var store = try log_mod.LogStore.init(allocator, log_kv, blob_backend.blobStore(), 0);
    defer store.deinit();

    switch (args.cmd) {
        .list => try runList(allocator, &store, args.limit),
        .show => try runShow(allocator, &store, args.request_id.?),
        .count => try runCount(allocator, &store),
        .bundle => try runBundle(
            allocator,
            &store,
            blob_backend.blobStore(),
            args.data_dir,
            args.instance,
            args.request_id.?,
        ),
    }
}
