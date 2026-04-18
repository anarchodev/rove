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
// `rove-log-cli bundle` emits a JSON document the browser-side replay
// harness can consume. Shape:
//
//   {
//     "request_id": "...",
//     "deployment_id": N,
//     "received_ns": N,
//     "duration_ns": N,
//     "request":  { "method": "...", "path": "...", "host": "..." },
//     "response": { "status": N, "outcome": "...",
//                   "console": "...", "exception": "..." },
//     "entry_source_hash": "..." | null,
//     "modules": [ {"specifier":"...","source_hash":"..."} ],
//     "tapes": {
//       "kv":            { "entries": [...] } | null,
//       "date":          { "entries": [...] } | null,
//       "math_random":   { "entries": [...] } | null,
//       "crypto_random": { "entries": [...] } | null
//     }
//   }
//
// `entry_source_hash` is the content-addressed source blob the browser
// must fetch to run the handler. For M1 that's the `DEFAULT_HANDLER_PATH`
// entry of the deployment manifest in `files.db`; multi-module support
// will fill `modules` from the module tape later.

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |b| {
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{b}),
            else => try w.writeByte(b),
        }
    }
    try w.writeAll("\"");
}

fn writeBase64(w: *std.Io.Writer, bytes: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    const buf_len = enc.calcSize(bytes.len);
    const buf = try std.heap.page_allocator.alloc(u8, buf_len);
    defer std.heap.page_allocator.free(buf);
    _ = enc.encode(buf, bytes);
    try w.writeAll("\"");
    try w.writeAll(buf);
    try w.writeAll("\"");
}

fn emitTapeBlob(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    blob: blob_mod.BlobStore,
    hash_hex: []const u8,
    channel: tape_mod.Channel,
) !void {
    const bytes = try blob.get(hash_hex, allocator);
    defer allocator.free(bytes);

    var parsed = try tape_mod.parse(allocator, bytes);
    defer parsed.deinit();
    if (parsed.channel != channel) return error.ChannelMismatch;

    try w.print("{{\"hash\":\"{s}\",\"entries\":[", .{hash_hex});
    for (parsed.entries, 0..) |*e, i| {
        if (i > 0) try w.writeAll(",");
        switch (e.*) {
            .kv => |k| {
                try w.writeAll("{\"op\":\"");
                try w.writeAll(@tagName(k.op));
                try w.writeAll("\",\"outcome\":\"");
                try w.writeAll(@tagName(k.outcome));
                try w.writeAll("\",\"key\":");
                try writeJsonString(w, k.key);
                try w.writeAll(",\"value\":");
                try writeJsonString(w, k.value);
                try w.writeAll("}");
            },
            .date => |d| try w.print("{{\"ms\":{d}}}", .{d.ms_epoch}),
            .math_random => |m| {
                const f: f64 = @bitCast(m.bits);
                try w.print("{{\"bits\":\"{x:0>16}\",\"value\":{d}}}", .{ m.bits, f });
            },
            .crypto_random => |cr| {
                try w.writeAll("{\"bytes\":");
                try writeBase64(w, cr.bytes);
                try w.writeAll("}");
            },
            .module => |m| {
                try w.writeAll("{\"specifier\":");
                try writeJsonString(w, m.specifier);
                try w.writeAll(",\"source_hash\":");
                try writeJsonString(w, m.source_hash_hex);
                try w.writeAll("}");
            },
        }
    }
    try w.writeAll("]}");
}

fn emitTapeField(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    blob: blob_mod.BlobStore,
    field_name: []const u8,
    hash_hex: ?[64]u8,
    channel: tape_mod.Channel,
) !void {
    try w.print(",\"{s}\":", .{field_name});
    if (hash_hex) |h| {
        try emitTapeBlob(w, allocator, blob, &h, channel);
    } else {
        try w.writeAll("null");
    }
}

fn runBundle(
    allocator: std.mem.Allocator,
    store: *log_mod.LogStore,
    log_blob: blob_mod.BlobStore,
    data_dir: []const u8,
    instance: []const u8,
    request_id: u64,
) !void {
    var rec = (try store.get(request_id)) orelse {
        var stderr_buf: [256]u8 = undefined;
        var sw = std.fs.File.stderr().writer(&stderr_buf);
        try sw.interface.print("rove-log-cli: no record with request_id={x}\n", .{request_id});
        try sw.interface.flush();
        std.process.exit(1);
    };
    defer rec.deinit(allocator);

    // Open the tenant's files.db read-only to resolve the deployment's
    // entry source hash. Optional — if it fails (tenant has no code
    // store yet, or deployment was GC'd) we emit null and let the
    // browser fall back to whatever source cache it has.
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

    var entry_source_hash_buf: [64]u8 = undefined;
    var entry_source_hash: ?[]const u8 = null;
    const files_kv = kv.KvStore.openReadOnly(allocator, files_db_path) catch null;
    defer if (files_kv) |ck| ck.close();

    if (files_kv) |ck| {
        var files_blob = try blob_mod.FilesystemBlobStore.open(allocator, files_blob_dir);
        defer files_blob.deinit();
        var files_store = files_mod.FileStore.init(allocator, ck, files_blob.blobStore(), noopCompile, null);
        var manifest = files_store.loadDeployment(rec.deployment_id) catch null;
        if (manifest) |*m| {
            defer m.deinit();
            for (m.entries) |e| {
                if (std.mem.eql(u8, e.path, "index.js")) {
                    @memcpy(&entry_source_hash_buf, &e.source_hex);
                    entry_source_hash = &entry_source_hash_buf;
                    break;
                }
            }
            // No `index.js`? Take the first entry as the entrypoint.
            if (entry_source_hash == null and m.entries.len > 0) {
                @memcpy(&entry_source_hash_buf, &m.entries[0].source_hex);
                entry_source_hash = &entry_source_hash_buf;
            }
        }
    }

    var stdout_buf: [4096]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    const w = &sw.interface;

    try w.print(
        "{{\"request_id\":\"{x:0>16}\",\"deployment_id\":{d}," ++
            "\"received_ns\":{d},\"duration_ns\":{d},",
        .{ rec.request_id, rec.deployment_id, rec.received_ns, rec.duration_ns },
    );
    try w.writeAll("\"request\":{\"method\":");
    try writeJsonString(w, rec.method);
    try w.writeAll(",\"path\":");
    try writeJsonString(w, rec.path);
    try w.writeAll(",\"host\":");
    try writeJsonString(w, rec.host);
    try w.writeAll("},\"response\":{\"status\":");
    try w.print("{d},\"outcome\":\"{s}\",\"console\":", .{ rec.status, outcomeName(rec.outcome) });
    try writeJsonString(w, rec.console);
    try w.writeAll(",\"exception\":");
    try writeJsonString(w, rec.exception);
    try w.writeAll("},");

    if (entry_source_hash) |h| {
        try w.writeAll("\"entry_source_hash\":");
        try writeJsonString(w, h);
    } else {
        try w.writeAll("\"entry_source_hash\":null");
    }
    try w.writeAll(",\"modules\":[],\"tapes\":{");

    // First field has no leading comma — emit it without `emitTapeField`.
    try w.writeAll("\"kv\":");
    if (rec.tape_refs.kv_tape_hex) |h| {
        try emitTapeBlob(w, allocator, log_blob, &h, .kv);
    } else {
        try w.writeAll("null");
    }
    try emitTapeField(w, allocator, log_blob, "date", rec.tape_refs.date_tape_hex, .date);
    try emitTapeField(w, allocator, log_blob, "math_random", rec.tape_refs.math_random_tape_hex, .math_random);
    try emitTapeField(w, allocator, log_blob, "crypto_random", rec.tape_refs.crypto_random_tape_hex, .crypto_random);
    try w.writeAll("}}\n");
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
