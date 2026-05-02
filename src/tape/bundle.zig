//! Replay bundle: format a single request_id's log record + captured
//! tapes as the JSON document the browser-side replay harness consumes
//! (PLAN §10.12).
//!
//! Callers:
//!   - `examples/log_cli.zig` (the `bundle` subcommand) — operator/dev
//!     tool that opens log.db read-only and prints the bundle.
//!   - `/_system/replay/bundle/{request_id}` worker endpoint (S3 of the
//!     beta tape-replay path) — admin-scoped, accepts cookie OR a
//!     short-lived signed replay token.
//!
//! Caller responsibilities:
//!   - Open the tenant's log.db and pass `*LogStore`.
//!   - Open the tenant's `log-blobs/` and pass `BlobStore`.
//!   - Resolve the deployment's entry source hash (e.g. by reading
//!     files.db's manifest for the deployment) and pass via
//!     `entry_source_hash`. Optional — null is acceptable; the replay
//!     client falls back to a manifest lookup it does itself.
//!
//! Output JSON shape — this is the on-the-wire contract the browser
//! replay page consumes:
//!
//!   {
//!     "request_id": "<16 hex>",
//!     "deployment_id": N,
//!     "received_ns": N,
//!     "duration_ns": N,
//!     "request":  { "method", "path", "host" },
//!     "response": { "status", "outcome", "console", "exception" },
//!     "entry_source_hash": "<64 hex>" | null,
//!     "entry_source_b64":  "<base64>" | null,
//!     "modules": [ { "specifier", "source_hash" }, ... ],
//!     "tapes": {
//!       "kv":            { "hash":"<64 hex>", "entries":[...] } | null,
//!       "date":          { ... }                              | null,
//!       "math_random":   { ... }                              | null,
//!       "crypto_random": { ... }                              | null
//!     }
//!   }
//!
//! `modules` is hoisted out of the tape (instead of nested under
//! `tapes`) because the browser-side import-map setup needs the full
//! module list before any handler code runs. The other tapes are read
//! on-demand during execution.

const std = @import("std");
const log_mod = @import("rove-log");
const blob_mod = @import("rove-blob");
const tape = @import("root.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    log_store: *log_mod.LogStore,
    log_blob: blob_mod.BlobStore,
    request_id: u64,

    /// Hex-encoded source hash of the handler module the request
    /// dispatched into. Caller resolves from the deployment manifest.
    /// Null is acceptable; bundle emits null and the replay client
    /// falls back to its own manifest lookup.
    entry_source_hash: ?[64]u8 = null,

    /// Optional inlined entry source bytes (handler `.mjs` text).
    /// When present, bundle emits `entry_source_b64` alongside the
    /// hash so the replay shell can execute without a separate
    /// source-fetch round-trip. Caller resolves from the file blob
    /// store; null means the replay shell must fetch separately or
    /// fall back to a manifest-only display.
    entry_source_bytes: ?[]const u8 = null,
};

/// Render the bundle for `ctx.request_id` as JSON to `w`. Returns
/// `error.NotFound` when the request_id is unknown; otherwise the
/// error union is the union of rove-log + rove-blob + rove-tape +
/// writer + allocator errors. Does not flush or append a trailing
/// newline — caller decides framing.
pub fn writeBundle(w: *std.Io.Writer, ctx: Context) !void {
    var rec = (try ctx.log_store.get(ctx.request_id)) orelse return error.NotFound;
    defer rec.deinit(ctx.allocator);

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

    if (ctx.entry_source_hash) |h| {
        try w.writeAll("\"entry_source_hash\":");
        try writeJsonString(w, &h);
    } else {
        try w.writeAll("\"entry_source_hash\":null");
    }

    try w.writeAll(",\"entry_source_b64\":");
    if (ctx.entry_source_bytes) |bytes| {
        try writeBase64(w, ctx.allocator, bytes);
    } else {
        try w.writeAll("null");
    }

    try w.writeAll(",\"modules\":");
    try emitModules(w, ctx.allocator, ctx.log_blob, rec.tape_refs.module_tree_hex);

    try w.writeAll(",\"tapes\":{\"kv\":");
    if (rec.tape_refs.kv_tape_hex) |h| {
        try emitTapeBlob(w, ctx.allocator, ctx.log_blob, &h, .kv);
    } else {
        try w.writeAll("null");
    }
    try emitTapeField(w, ctx.allocator, ctx.log_blob, "date", rec.tape_refs.date_tape_hex, .date);
    try emitTapeField(w, ctx.allocator, ctx.log_blob, "math_random", rec.tape_refs.math_random_tape_hex, .math_random);
    try emitTapeField(w, ctx.allocator, ctx.log_blob, "crypto_random", rec.tape_refs.crypto_random_tape_hex, .crypto_random);
    try w.writeAll("}}");
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

fn writeBase64(w: *std.Io.Writer, allocator: std.mem.Allocator, bytes: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    const buf_len = enc.calcSize(bytes.len);
    const buf = try allocator.alloc(u8, buf_len);
    defer allocator.free(buf);
    _ = enc.encode(buf, bytes);
    try w.writeAll("\"");
    try w.writeAll(buf);
    try w.writeAll("\"");
}

/// Fetch a tape blob, parse it, emit `{"hash":"...","entries":[...]}`.
/// `expected_channel` guards against a tape blob being filed under the
/// wrong slot — that'd be a corruption signal worth surfacing as an
/// error rather than silently emitting mismatched entries.
fn emitTapeBlob(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    blob: blob_mod.BlobStore,
    hash_hex: []const u8,
    expected_channel: tape.Channel,
) !void {
    const bytes = try blob.get(hash_hex, allocator);
    defer allocator.free(bytes);

    var parsed = try tape.parse(allocator, bytes);
    defer parsed.deinit();
    if (parsed.channel != expected_channel) return error.ChannelMismatch;

    try w.print("{{\"hash\":\"{s}\",\"entries\":[", .{hash_hex});
    for (parsed.entries, 0..) |*e, i| {
        if (i > 0) try w.writeAll(",");
        try emitEntry(w, allocator, e);
    }
    try w.writeAll("]}");
}

fn emitEntry(w: *std.Io.Writer, allocator: std.mem.Allocator, e: *const tape.Entry) !void {
    switch (e.*) {
        .kv => |k| {
            try w.writeAll("{\"op\":\"");
            try w.writeAll(@tagName(k.op));
            try w.writeAll("\",\"outcome\":\"");
            try w.writeAll(@tagName(k.outcome));
            try w.writeAll("\",\"key\":");
            try writeJsonString(w, k.key);
            if (k.op == .prefix) {
                try w.writeAll(",\"cursor\":");
                try writeJsonString(w, k.cursor);
                try w.print(",\"limit\":{d}", .{k.limit});
                try w.writeAll(",\"results\":[");
                for (k.results, 0..) |p, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.writeAll("{\"key\":");
                    try writeJsonString(w, p.key);
                    try w.writeAll(",\"value\":");
                    try writeJsonString(w, p.value);
                    try w.writeAll("}");
                }
                try w.writeAll("]");
            } else {
                try w.writeAll(",\"value\":");
                try writeJsonString(w, k.value);
            }
            try w.writeAll("}");
        },
        .date => |d| try w.print("{{\"ms\":{d}}}", .{d.ms_epoch}),
        .math_random => |m| {
            const f: f64 = @bitCast(m.bits);
            try w.print("{{\"bits\":\"{x:0>16}\",\"value\":{d}}}", .{ m.bits, f });
        },
        .crypto_random => |cr| {
            try w.writeAll("{\"bytes\":");
            try writeBase64(w, allocator, cr.bytes);
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

fn emitTapeField(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    blob: blob_mod.BlobStore,
    field_name: []const u8,
    hash_hex: ?[64]u8,
    expected_channel: tape.Channel,
) !void {
    try w.print(",\"{s}\":", .{field_name});
    if (hash_hex) |h| {
        try emitTapeBlob(w, allocator, blob, &h, expected_channel);
    } else {
        try w.writeAll("null");
    }
}

/// Hoist module entries from the module tape into a top-level array
/// the replay page consumes before running any handler code (it needs
/// the full module list to build an import map). When the module tape
/// is absent — single-file handlers, or handlers compiled before
/// `appendModule` callers landed — emit `[]` and let the replay client
/// fall back to entry-source-only loading.
fn emitModules(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    blob: blob_mod.BlobStore,
    hash_hex: ?[64]u8,
) !void {
    const h = hash_hex orelse {
        try w.writeAll("[]");
        return;
    };
    const bytes = try blob.get(&h, allocator);
    defer allocator.free(bytes);

    var parsed = try tape.parse(allocator, bytes);
    defer parsed.deinit();
    if (parsed.channel != .module) return error.ChannelMismatch;

    try w.writeAll("[");
    for (parsed.entries, 0..) |*e, i| {
        if (i > 0) try w.writeAll(",");
        switch (e.*) {
            .module => |m| {
                try w.writeAll("{\"specifier\":");
                try writeJsonString(w, m.specifier);
                try w.writeAll(",\"source_hash\":");
                try writeJsonString(w, m.source_hash_hex);
                try w.writeAll("}");
            },
            else => return error.ChannelMismatch,
        }
    }
    try w.writeAll("]");
}

// ── tests ───────────────────────────────────────────────────────────

test "writeBundle: not_found returns error" {
    const allocator = std.testing.allocator;
    const kv_mod = @import("rove-kv");
    const tmp_dir = try std.testing.tmpDir(.{}).dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_dir);

    const log_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/log.db",
        .{tmp_dir},
        0,
    );
    defer allocator.free(log_db_path);
    const blob_dir = try std.fmt.allocPrint(allocator, "{s}/log-blobs", .{tmp_dir});
    defer allocator.free(blob_dir);

    const log_kv = try kv_mod.KvStore.open(allocator, log_db_path);
    defer log_kv.close();
    var blob_backend = try blob_mod.FilesystemBlobStore.open(allocator, blob_dir);
    defer blob_backend.deinit();
    var store = try log_mod.LogStore.init(allocator, log_kv, blob_backend.blobStore(), 0);
    defer store.deinit();

    var buf: [256]u8 = undefined;
    var fbw: std.Io.Writer.Fixed = .init(&buf);
    const result = writeBundle(&fbw.interface, .{
        .allocator = allocator,
        .log_store = &store,
        .log_blob = blob_backend.blobStore(),
        .request_id = 0xdeadbeef,
    });
    try std.testing.expectError(error.NotFound, result);
}

test "writeBundle: minimal record without tapes" {
    const allocator = std.testing.allocator;
    const kv_mod = @import("rove-kv");
    const tmp = std.testing.tmpDir(.{});
    const tmp_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_dir);

    const log_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/log.db",
        .{tmp_dir},
        0,
    );
    defer allocator.free(log_db_path);
    const blob_dir = try std.fmt.allocPrint(allocator, "{s}/log-blobs", .{tmp_dir});
    defer allocator.free(blob_dir);

    const log_kv = try kv_mod.KvStore.open(allocator, log_db_path);
    defer log_kv.close();
    var blob_backend = try blob_mod.FilesystemBlobStore.open(allocator, blob_dir);
    defer blob_backend.deinit();
    var store = try log_mod.LogStore.init(allocator, log_kv, blob_backend.blobStore(), 0);
    defer store.deinit();

    // Insert a record via a synthetic batch.
    const rec: log_mod.LogRecord = .{
        .request_id = 0x1234567890abcdef,
        .deployment_id = 7,
        .received_ns = 1_000_000_000,
        .duration_ns = 250_000,
        .method = "GET",
        .path = "/foo",
        .host = "example.com",
        .status = 200,
        .outcome = .ok,
        .console = "",
        .exception = "",
        .tape_refs = .{},
    };
    var batch: [1]log_mod.LogRecord = .{rec};
    try store.applyBatch(&batch);

    var buf: [1024]u8 = undefined;
    var fbw: std.Io.Writer.Fixed = .init(&buf);
    try writeBundle(&fbw.interface, .{
        .allocator = allocator,
        .log_store = &store,
        .log_blob = blob_backend.blobStore(),
        .request_id = 0x1234567890abcdef,
    });
    const out = fbw.buffered();

    // Spot-check the shape — full byte equality is fragile across
    // log_mod field reordering, but these substrings are part of the
    // PLAN §10.12 wire contract.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"request_id\":\"1234567890abcdef\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"deployment_id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"method\":\"GET\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"path\":\"/foo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"status\":200") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"outcome\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"entry_source_hash\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"modules\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kv\":null") != null);
}
