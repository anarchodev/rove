//! Standalone log-server (Phase 5.5 a, step 2) — combines the
//! background indexer thread + an h2 query API in one process.
//!
//! Loopback-only at this stage (no public TLS); step 6 of the
//! migration moves it to `logs.{public_suffix}` with TLS + JWT
//! handoff. The wire shape follows `docs/logs-plan.md` §5:
//!
//!   GET /v1/{tenant_id}/list
//!         ?limit=N&after_received_ns=X&after_request_id=Y
//!       → 200 application/json
//!         {"records":[...],"next_cursor":{"received_ns":...,
//!                                          "request_id":...}}
//!
//!   GET /v1/{tenant_id}/show/{request_id_decimal}
//!       → 200 application/json (the full record line as captured
//!         in the .ndjson payload)
//!       → 404 if the request id isn't indexed
//!
//!   GET /v1/{tenant_id}/count                       (Phase 5.5 a, A2)
//!       → 200 text/plain (decimal record count for the tenant)
//!
//!   GET /v1/{tenant_id}/blob/{hash}                 (Phase 5.5 a, A1)
//!       → 200 application/octet-stream (raw blob bytes)
//!       → 404 if the blob isn't in the per-tenant `log-blobs/` store
//!       → 501 if the server wasn't started with a blob backend
//!
//! For step 2 the binary spawns one indexer + one h2 server, both
//! against a `BatchStore` / `IndexDb` the caller wires up. Step 3
//! added the worker-side flush path (`log.backend = s3`) so real
//! traffic populates the bucket. A1 adds the blob endpoint so the
//! replay UI can fetch tape body / tape blobs from the same shared
//! S3 store the worker writes to.

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");
const blob_mod = @import("rove-blob");

const batch_store_mod = @import("batch_store.zig");
const index_db_mod = @import("index_db.zig");
const indexer_mod = @import("indexer.zig");

const LogH2 = h2.H2(.{});

pub const Config = struct {
    allocator: std.mem.Allocator,
    /// Where the indexer reads sidecars + ndjson from (and where
    /// /show range-reads the payload).
    store: batch_store_mod.BatchStore,
    /// Local SQLite index. The indexer thread + the h2 server share
    /// one connection — WAL would let us split, but a single thread
    /// owning both is simpler and matches the actual workload (one
    /// indexer + one event loop).
    db: *index_db_mod.IndexDb,
    /// Where to bind the h2 listener. Pass `0` for an ephemeral
    /// port; the resolved port is written to `Handle.port`.
    bind_addr: std.net.Address,
    /// Indexer cadence. Tests override to ~50ms.
    poll_interval_ms: u32 = 5_000,
    /// h2 connection cap.
    max_connections: u32 = 64,
    /// Optional per-tenant blob backend used by `/v1/{tenant}/blob/{hash}`.
    /// Null disables the blob route (returns 501). When non-null, the
    /// backend must point at the same store the worker writes tape
    /// blobs to — same `BLOB_BACKEND` config the worker uses, so
    /// `key_prefix_base` (s3) or the on-disk layout (fs) lines up.
    /// The standalone server lazily opens one backend per tenant on
    /// first blob request; backends live for the server's lifetime.
    blob_backend_cfg: ?blob_mod.BackendConfig = null,
    /// Required when `blob_backend_cfg == .fs` — root directory the
    /// worker writes tape blobs under (`{fs_data_dir}/{tenant}/log-blobs/`).
    /// Ignored for `.s3` (key_prefix_base does the per-tenant scoping).
    /// Loop46 passes its `--data-dir`; the standalone binary doesn't
    /// expose this because it's S3-only.
    fs_data_dir: ?[]const u8 = null,
};

/// Lazy per-tenant `BlobBackend` cache for the blob read path.
/// Single-thread owned (the h2 server thread); no locking. Each
/// entry opens against the configured backend with `subdir =
/// "log-blobs"` and `instance_id = tenant_id`, mirroring the
/// `TenantLog` open path on the worker side so leader and standalone
/// hit identical S3 keys.
const BlobCache = struct {
    allocator: std.mem.Allocator,
    cfg: blob_mod.BackendConfig,
    /// Required for `.fs`. Empty for `.s3`.
    fs_data_dir: []const u8,
    map: std.StringHashMapUnmanaged(*blob_mod.BlobBackend),

    fn init(allocator: std.mem.Allocator, cfg: blob_mod.BackendConfig, fs_data_dir: []const u8) BlobCache {
        return .{ .allocator = allocator, .cfg = cfg, .fs_data_dir = fs_data_dir, .map = .empty };
    }

    fn deinit(self: *BlobCache) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            const ptr = e.value_ptr.*;
            ptr.deinit();
            self.allocator.destroy(ptr);
        }
        self.map.deinit(self.allocator);
    }

    fn getOrOpen(self: *BlobCache, tenant_id: []const u8) !*blob_mod.BlobBackend {
        if (self.map.get(tenant_id)) |existing| return existing;

        // Build the per-tenant fs path lazily; harmless for s3 (the
        // openPerTenant switch ignores it).
        const fs_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/log-blobs",
            .{ self.fs_data_dir, tenant_id },
        );
        defer self.allocator.free(fs_path);

        const backend = try self.allocator.create(blob_mod.BlobBackend);
        errdefer self.allocator.destroy(backend);
        backend.* = try blob_mod.BlobBackend.openPerTenant(
            self.allocator,
            self.cfg,
            fs_path,
            tenant_id,
            "log-blobs",
        );
        errdefer backend.deinit();

        const id_copy = try self.allocator.dupe(u8, tenant_id);
        errdefer self.allocator.free(id_copy);

        try self.map.put(self.allocator, id_copy, backend);
        return backend;
    }
};

pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    indexer: *indexer_mod.Handle,
    port: u16,
    stop: std.atomic.Value(bool),
    ready: std.Thread.ResetEvent,
    bind_err: ?anyerror,
    config: Config,

    pub fn shutdown(self: *Handle) void {
        self.stop.store(true, .release);
        self.indexer.signalStop();
        self.thread.join();
        self.indexer.join();
        self.allocator.destroy(self);
    }
};

pub fn spawn(config: Config) !*Handle {
    const indexer_handle = try indexer_mod.spawn(.{
        .allocator = config.allocator,
        .store = config.store,
        .db = config.db,
        .poll_interval_ms = config.poll_interval_ms,
    });
    errdefer {
        indexer_handle.signalStop();
        indexer_handle.join();
    }

    const h = try config.allocator.create(Handle);
    errdefer config.allocator.destroy(h);
    h.* = .{
        .allocator = config.allocator,
        .thread = undefined,
        .indexer = indexer_handle,
        .port = 0,
        .stop = .init(false),
        .ready = .{},
        .bind_err = null,
        .config = config,
    };
    h.thread = try std.Thread.spawn(.{}, threadMain, .{h});
    h.ready.wait();
    if (h.bind_err) |err| {
        h.indexer.signalStop();
        h.thread.join();
        h.indexer.join();
        config.allocator.destroy(h);
        return err;
    }
    return h;
}

fn threadMain(h: *Handle) void {
    runThread(h) catch |err| {
        std.log.err("log-server-standalone: thread exited: {s}", .{@errorName(err)});
    };
}

fn runThread(h: *Handle) !void {
    const allocator = h.allocator;

    var reg = rove.Registry.init(allocator, .{
        .max_entities = 1024,
        .deferred_queue_capacity = 256,
    }) catch |err| {
        h.bind_err = err;
        h.ready.set();
        return;
    };
    defer reg.deinit();

    const server = LogH2.create(&reg, allocator, h.config.bind_addr, .{
        .max_connections = h.config.max_connections,
        .buf_count = 64,
        .buf_size = 64 * 1024,
    }, .{}) catch |err| {
        h.bind_err = err;
        h.ready.set();
        return;
    };
    defer server.destroy();

    h.port = try resolveBoundPort(server);
    h.ready.set();

    std.log.info("log-server-standalone: h2c on 127.0.0.1:{d}", .{h.port});

    var blob_cache: ?BlobCache = if (h.config.blob_backend_cfg) |cfg|
        BlobCache.init(allocator, cfg, h.config.fs_data_dir orelse "")
    else
        null;
    defer if (blob_cache) |*c| c.deinit();

    while (!h.stop.load(.acquire)) {
        try server.pollWithTimeout(100 * std.time.ns_per_ms);
        try processRequests(
            server,
            allocator,
            h.config.store,
            h.config.db,
            if (blob_cache) |*c| c else null,
        );
        try reg.flush();
        try cleanupResponses(server);
        try reg.flush();
    }
}

fn resolveBoundPort(server: *LogH2) !u16 {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(@TypeOf(storage));
    try std.posix.getsockname(server.io.listen_fd, @ptrCast(&storage), &len);
    const addr = std.net.Address.initPosix(@alignCast(@ptrCast(&storage)));
    return addr.getPort();
}

fn cleanupResponses(server: *LogH2) !void {
    const entities = server.response_out.entitySlice();
    for (entities) |ent| try server.reg.destroy(ent);
}

// ── Request routing ───────────────────────────────────────────────

fn processRequests(
    server: *LogH2,
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    db: *index_db_mod.IndexDb,
    blob_cache: ?*BlobCache,
) !void {
    const entities = server.request_out.entitySlice();
    const sids = server.request_out.column(h2.StreamId);
    const sessions = server.request_out.column(h2.Session);
    const req_hdrs = server.request_out.column(h2.ReqHeaders);

    for (entities, sids, sessions, req_hdrs) |ent, sid, sess, rh| {
        handleOne(server, allocator, store, db, blob_cache, ent, sid, sess, rh) catch |err| {
            std.log.warn("log-server-standalone: handler error: {s}", .{@errorName(err)});
            setResponse(server, ent, sid, sess, 500, "internal error\n") catch |se| std.log.err(
                "log-server-standalone: 500 write failed: {s}",
                .{@errorName(se)},
            );
        };
    }
}

fn handleOne(
    server: *LogH2,
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    db: *index_db_mod.IndexDb,
    blob_cache: ?*BlobCache,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    rh: h2.ReqHeaders,
) !void {
    var method: []const u8 = "";
    var path: []const u8 = "";
    if (rh.fields != null) {
        const fields = rh.fields.?[0..rh.count];
        for (fields) |f| {
            const name = f.name[0..f.name_len];
            const value = f.value[0..f.value_len];
            if (std.mem.eql(u8, name, ":method")) method = value;
            if (std.mem.eql(u8, name, ":path")) path = value;
        }
    }
    if (!std.mem.eql(u8, method, "GET")) {
        try setResponse(server, ent, sid, sess, 405, "method not allowed\n");
        return;
    }

    const route = parseRoute(path) orelse {
        try setResponse(server, ent, sid, sess, 404, "not found\n");
        return;
    };
    switch (route.kind) {
        .list => try handleList(server, allocator, db, ent, sid, sess, route.tenant_id, route.query),
        .show => try handleShow(server, allocator, store, db, ent, sid, sess, route.tenant_id, route.tail),
        .blob => try handleBlob(server, allocator, blob_cache, ent, sid, sess, route.tenant_id, route.tail),
        .count => try handleCount(server, allocator, db, ent, sid, sess, route.tenant_id),
    }
}

const RouteKind = enum { list, show, blob, count };

const ParsedRoute = struct {
    kind: RouteKind,
    tenant_id: []const u8,
    /// For `show`: the request_id segment. Empty otherwise.
    tail: []const u8,
    /// Raw query string (after `?`). Empty if absent.
    query: []const u8,
};

/// `/v1/{tenant_id}/list[?...]` or `/v1/{tenant_id}/show/{request_id}`.
/// Returns null on shape mismatch (caller responds 404).
fn parseRoute(path: []const u8) ?ParsedRoute {
    const q_idx = std.mem.indexOfScalar(u8, path, '?');
    const path_no_query = if (q_idx) |i| path[0..i] else path;
    const query = if (q_idx) |i| path[i + 1 ..] else "";

    const v1_prefix = "/v1/";
    if (!std.mem.startsWith(u8, path_no_query, v1_prefix)) return null;
    const after_v1 = path_no_query[v1_prefix.len..];
    const slash = std.mem.indexOfScalar(u8, after_v1, '/') orelse return null;
    const tenant_id = after_v1[0..slash];
    if (tenant_id.len == 0) return null;
    const remainder = after_v1[slash + 1 ..];

    if (std.mem.eql(u8, remainder, "list")) {
        return .{ .kind = .list, .tenant_id = tenant_id, .tail = "", .query = query };
    }
    if (std.mem.eql(u8, remainder, "count")) {
        return .{ .kind = .count, .tenant_id = tenant_id, .tail = "", .query = query };
    }
    if (std.mem.startsWith(u8, remainder, "show/")) {
        const tail = remainder["show/".len..];
        if (tail.len == 0) return null;
        return .{ .kind = .show, .tenant_id = tenant_id, .tail = tail, .query = query };
    }
    if (std.mem.startsWith(u8, remainder, "blob/")) {
        const tail = remainder["blob/".len..];
        if (tail.len == 0) return null;
        return .{ .kind = .blob, .tenant_id = tenant_id, .tail = tail, .query = query };
    }
    return null;
}

// ── Handlers ──────────────────────────────────────────────────────

fn handleList(
    server: *LogH2,
    allocator: std.mem.Allocator,
    db: *index_db_mod.IndexDb,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tenant_id: []const u8,
    query: []const u8,
) !void {
    const limit = parseUint(u32, query, "limit", 100);
    const after_received_ns = parseInt(i64, query, "after_received_ns", 0);
    const after_request_id = parseUint(u64, query, "after_request_id", 0);

    var list = db.queryList(tenant_id, after_received_ns, after_request_id, limit) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "list failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg);
        return;
    };
    defer list.deinit();

    const json = try renderListJson(allocator, list.rows);
    try setResponseOwned(server, ent, sid, sess, 200, json);
}

fn handleShow(
    server: *LogH2,
    allocator: std.mem.Allocator,
    store: batch_store_mod.BatchStore,
    db: *index_db_mod.IndexDb,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tenant_id: []const u8,
    request_id_str: []const u8,
) !void {
    const request_id = std.fmt.parseInt(u64, request_id_str, 10) catch {
        try setResponse(server, ent, sid, sess, 400, "invalid request id (want decimal u64)\n");
        return;
    };
    var maybe = db.queryShow(tenant_id, request_id) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "show failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg);
        return;
    };
    if (maybe == null) {
        try setResponse(server, ent, sid, sess, 404, "record not found\n");
        return;
    }
    defer maybe.?.deinit(allocator);
    const row = maybe.?;

    // Range-read the matching ndjson line out of the batch payload.
    const payload = store.getRange(row.ndjson_key, row.offset, row.length, allocator) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "payload fetch failed for {s}: {s}\n",
            .{ row.ndjson_key, @errorName(err) },
        );
        try setResponseOwned(server, ent, sid, sess, 500, msg);
        return;
    };
    // Strip trailing newline if present so the JSON we hand back is
    // exactly one record's bytes (the ndjson layout puts `\n` at the
    // tail of every line).
    const trimmed = if (payload.len > 0 and payload[payload.len - 1] == '\n')
        payload[0 .. payload.len - 1]
    else
        payload;

    // Wrap in `{record: ...}` so callers can branch on shape later
    // (e.g. error responses). Slightly redundant for the happy path
    // but cheaper than re-parsing the line at the consumer.
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"record\":");
    try buf.appendSlice(allocator, trimmed);
    try buf.appendSlice(allocator, "}\n");
    allocator.free(payload);
    const out = try buf.toOwnedSlice(allocator);
    try setResponseOwned(server, ent, sid, sess, 200, out);
}

/// Total record count for a tenant (Phase 5.5 a, A2). Plain decimal
/// body (`{count}\n`) so a shell pipeline can `wc`/`grep` it without
/// pulling in jq. Backed by `IndexDb.queryCount` — covering scan on
/// the (tenant_id, received_ns) primary index, cheap.
fn handleCount(
    server: *LogH2,
    allocator: std.mem.Allocator,
    db: *index_db_mod.IndexDb,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tenant_id: []const u8,
) !void {
    const total = db.queryCount(tenant_id) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "count failed: {s}\n", .{@errorName(err)});
        try setResponseOwned(server, ent, sid, sess, 500, msg);
        return;
    };
    const body = try std.fmt.allocPrint(allocator, "{d}\n", .{total});
    try setResponseOwned(server, ent, sid, sess, 200, body);
}

/// Tape blob fetch (Phase 5.5 a, A1). Reads from the per-tenant
/// `log-blobs` BlobStore, opened lazily on first request and cached.
/// Returns 200 + raw bytes (no content-type — replay clients sniff
/// or know the encoding from the calling tape ref). 404 when the
/// hash isn't in the store, 501 when the server has no blob backend
/// configured (operator hasn't wired the env vars).
fn handleBlob(
    server: *LogH2,
    allocator: std.mem.Allocator,
    blob_cache: ?*BlobCache,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    tenant_id: []const u8,
    hash: []const u8,
) !void {
    const cache = blob_cache orelse {
        try setResponse(server, ent, sid, sess, 501, "blob backend not configured\n");
        return;
    };

    // Tape blob hashes are 64-char lowercase hex. The BlobStore's
    // `validateKey` already rejects `/`, `..`, control chars, and
    // empty keys, but we tighten further so a bogus path-y hash
    // doesn't burn an S3 round-trip just to learn it's NotFound.
    if (hash.len != 64 or !isHex(hash)) {
        try setResponse(server, ent, sid, sess, 400, "invalid hash (want 64 lowercase hex)\n");
        return;
    }

    const backend = cache.getOrOpen(tenant_id) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "blob open failed for {s}: {s}\n",
            .{ tenant_id, @errorName(err) },
        );
        try setResponseOwned(server, ent, sid, sess, 500, msg);
        return;
    };

    const bytes = backend.blobStore().get(hash, allocator) catch |err| {
        const code: u16 = if (err == blob_mod.Error.NotFound) 404 else 500;
        const msg = try std.fmt.allocPrint(
            allocator,
            "blob fetch failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponseOwned(server, ent, sid, sess, code, msg);
        return;
    };
    try setResponseOwned(server, ent, sid, sess, 200, bytes);
}

fn isHex(s: []const u8) bool {
    for (s) |b| switch (b) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

// ── JSON rendering ─────────────────────────────────────────────────

fn renderListJson(
    allocator: std.mem.Allocator,
    rows: []index_db_mod.IndexDb.ListRow,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"records\":[");
    for (rows, 0..) |r, i| {
        if (i > 0) try buf.append(allocator, ',');
        try writeRowJson(allocator, &buf, &r);
    }
    if (rows.len == 0) {
        try buf.appendSlice(allocator, "],\"next_cursor\":null}\n");
    } else {
        const last = &rows[rows.len - 1];
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = aw.toArrayList();
        try aw.writer.print(
            "],\"next_cursor\":{{\"received_ns\":{d},\"request_id\":{d}}}}}\n",
            .{ last.received_ns, last.request_id },
        );
    }
    return buf.toOwnedSlice(allocator);
}

fn writeRowJson(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    r: *const index_db_mod.IndexDb.ListRow,
) !void {
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, buf);
    defer buf.* = aw.toArrayList();
    try aw.writer.print(
        "{{\"request_id\":{d},\"received_ns\":{d},\"duration_ns\":{d},\"status\":{d},\"deployment_id\":{d},\"method\":",
        .{ r.request_id, r.received_ns, r.duration_ns, r.status, r.deployment_id },
    );
    try writeJsonString(&aw.writer, r.method);
    try aw.writer.writeAll(",\"path\":");
    try writeJsonString(&aw.writer, r.path);
    try aw.writer.writeAll(",\"host\":");
    try writeJsonString(&aw.writer, r.host);
    try aw.writer.writeAll(",\"outcome\":");
    try writeJsonString(&aw.writer, r.outcome);
    try aw.writer.writeAll("}");
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{b}),
        else => try w.writeByte(b),
    };
    try w.writeByte('"');
}

// ── Helpers ───────────────────────────────────────────────────────

/// Stamp a response without allocator-owned body bytes. The h2
/// `RespBody.deinit` frees `data` when non-null, so static literal
/// bodies must be sent with `data = null` (and a non-zero `len`
/// recorded for observability — actual bytes are not framed). This
/// mirrors `src/log_server/thread.zig`'s null-data convention for
/// short error strings.
fn setResponse(
    server: *LogH2,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status: u16,
    body_static: []const u8,
) !void {
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = null,
        .len = @intCast(body_static.len),
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

fn setResponseOwned(
    server: *LogH2,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status: u16,
    body_owned: []u8,
) !void {
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = body_owned.ptr,
        .len = @intCast(body_owned.len),
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

fn parseUint(comptime T: type, query: []const u8, key: []const u8, default: T) T {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        return std.fmt.parseInt(T, pair[eq + 1 ..], 10) catch default;
    }
    return default;
}

fn parseInt(comptime T: type, query: []const u8, key: []const u8, default: T) T {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        return std.fmt.parseInt(T, pair[eq + 1 ..], 10) catch default;
    }
    return default;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "parseRoute matches /v1/{tenant}/list" {
    const r = parseRoute("/v1/acme/list?limit=10").?;
    try testing.expectEqual(RouteKind.list, r.kind);
    try testing.expectEqualStrings("acme", r.tenant_id);
    try testing.expectEqualStrings("limit=10", r.query);
}

test "parseRoute matches /v1/{tenant}/show/{id}" {
    const r = parseRoute("/v1/acme/show/12345").?;
    try testing.expectEqual(RouteKind.show, r.kind);
    try testing.expectEqualStrings("acme", r.tenant_id);
    try testing.expectEqualStrings("12345", r.tail);
}

test "parseRoute matches /v1/{tenant}/blob/{hash}" {
    const r = parseRoute("/v1/acme/blob/deadbeef").?;
    try testing.expectEqual(RouteKind.blob, r.kind);
    try testing.expectEqualStrings("acme", r.tenant_id);
    try testing.expectEqualStrings("deadbeef", r.tail);
}

test "parseRoute matches /v1/{tenant}/count" {
    const r = parseRoute("/v1/acme/count").?;
    try testing.expectEqual(RouteKind.count, r.kind);
    try testing.expectEqualStrings("acme", r.tenant_id);
    try testing.expectEqualStrings("", r.tail);
}

test "parseRoute rejects bad shapes" {
    try testing.expect(parseRoute("/") == null);
    try testing.expect(parseRoute("/v1/") == null);
    try testing.expect(parseRoute("/v1/acme") == null);
    try testing.expect(parseRoute("/v1/acme/unknown") == null);
    try testing.expect(parseRoute("/v1//list") == null);
    try testing.expect(parseRoute("/v1/acme/show/") == null);
    try testing.expect(parseRoute("/v1/acme/blob/") == null);
    try testing.expect(parseRoute("/v2/acme/list") == null);
}

test "isHex accepts 64 lowercase hex chars" {
    try testing.expect(isHex("0123456789abcdef"));
    try testing.expect(isHex(""));
    try testing.expect(!isHex("ABCDEF"));
    try testing.expect(!isHex("g"));
    try testing.expect(!isHex("0/1"));
    try testing.expect(!isHex("0.1"));
}

test "parseUint reads ?limit= or returns default" {
    try testing.expectEqual(@as(u32, 10), parseUint(u32, "limit=10", "limit", 100));
    try testing.expectEqual(@as(u32, 100), parseUint(u32, "", "limit", 100));
    try testing.expectEqual(@as(u32, 100), parseUint(u32, "after=5", "limit", 100));
    try testing.expectEqual(@as(u32, 7), parseUint(u32, "after=5&limit=7", "limit", 100));
}
