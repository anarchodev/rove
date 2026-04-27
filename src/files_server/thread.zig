//! `files_server.thread` — the background-thread host for the
//! synchronous files-server operations in `root.zig`.
//!
//! The design goal is "compile does not block the worker's h2 event
//! loop." The mechanism is standard: spawn a thread that owns its own
//! rove registry + io_uring + rove-h2 server instance, binding to a
//! loopback TCP port. The worker (on a separate thread) connects as
//! an HTTP/2 client and forwards any request whose path starts with
//! `/_system/files/` here.
//!
//! Unix domain sockets would be nicer (no port, filesystem perms as
//! auth) but rove-io's connect path is currently hard-coded to
//! AF_INET. Loopback TCP on 127.0.0.1:ephemeral is equivalent for the
//! single-host case we're in, and switching to unix sockets later is
//! a rove-io extension — no changes to this module.
//!
//! ## Wire protocol
//!
//! Plain HTTP/2 (h2c), no TLS. The routes are:
//!
//!   POST /{instance_id}/upload     X-Rove-Path: <path>
//!                                  body: source bytes
//!                                  → 204 on success, 4xx/5xx on failure
//!
//!   POST /{instance_id}/deploy     → 200, body = decimal deployment id
//!
//!   GET  /{instance_id}/source/{hash}
//!                                  → 200, body = raw source bytes
//!                                  → 404 if the blob isn't present
//!
//! The instance-id-first shape lets the worker's `/_system/files/*`
//! proxy do a pure prefix strip — `/_system/files/acme/upload` maps
//! directly to `/acme/upload` without reordering segments.
//!
//! The handler path intentionally avoids JSON — the only structured
//! field the CLI needs to send is the deployment-relative file path,
//! and a header carries that cleanly. Bodies are opaque bytes.

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");
const kv = @import("rove-kv");

const files_server = @import("root.zig");
const files_mod = @import("rove-files");

/// Raft envelope type byte matching `rove-js/apply.zig`
/// `EnvelopeType.files_writeset = 3`. Duplicated here (tiny,
/// stable wire-format constant) to avoid a files-server → rove-js
/// import cycle — rove-js already depends on rove-files-server for
/// its `/_system/files/*` proxy. Keep the two in sync; the apply
/// side is the authority.
const ENVELOPE_TYPE_FILES_WRITESET: u8 = 3;
const ENVELOPE_MAX_ID_LEN: usize = 256;

fn encodeFilesWriteSetEnvelope(
    allocator: std.mem.Allocator,
    instance_id: []const u8,
    ws_bytes: []const u8,
) ![]u8 {
    if (instance_id.len > ENVELOPE_MAX_ID_LEN) return error.OutOfMemory;
    const total = 1 + 2 + instance_id.len + ws_bytes.len;
    const out = try allocator.alloc(u8, total);
    out[0] = ENVELOPE_TYPE_FILES_WRITESET;
    std.mem.writeInt(u16, out[1..3], @intCast(instance_id.len), .big);
    @memcpy(out[3 .. 3 + instance_id.len], instance_id);
    @memcpy(out[3 + instance_id.len ..], ws_bytes);
    return out;
}

const CodeH2 = h2.H2(.{});

/// Handle returned by `spawn`. The caller is expected to hold this
/// for the life of the worker process; `shutdown` tears it down.
pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    port: u16,
    /// Absolute path to `{data_dir}`. Borrowed from the caller — must
    /// outlive the handle.
    data_dir: []const u8,
    /// Raft node to propose files.db writesets through. When null,
    /// writes apply locally only — fine for single-node dev smoke
    /// tests, broken for multi-node correctness. Borrowed.
    raft: ?*kv.RaftNode,
    /// Max concurrent inbound h2c connections this server accepts.
    /// Sized from the worker count at spawn time — each worker holds
    /// one persistent client, so the cap must be `>= num_workers` or
    /// later workers get ECONNREFUSED and spin in a reconnect loop.
    max_connections: u32,
    /// Signalled by the main thread to request graceful shutdown.
    /// The thread's poll loop observes it between ticks.
    stop: std.atomic.Value(bool),
    /// Signalled by the thread once the h2 server has bound its
    /// listen socket (success or failure). The parent `spawn` waits
    /// on this before reading `port` or `bind_err`.
    ready: std.Thread.ResetEvent,
    /// Non-null if the bind or H2 create failed. Checked by the
    /// parent after `ready` fires.
    bind_err: ?anyerror,

    pub fn shutdown(self: *Handle) void {
        self.stop.store(true, .release);
        self.thread.join();
        self.allocator.destroy(self);
    }
};

/// Launch the files-server thread. Returns once the thread has bound
/// its listen socket (or failed trying). The returned `Handle.port`
/// is the concrete port the caller should connect to — 0 is never
/// returned (OS picks an ephemeral port for us).
pub fn spawn(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    max_connections: u32,
    raft: ?*kv.RaftNode,
) !*Handle {
    const h = try allocator.create(Handle);
    errdefer allocator.destroy(h);

    h.* = .{
        .allocator = allocator,
        .thread = undefined,
        .port = 0,
        .data_dir = data_dir,
        .max_connections = max_connections,
        .stop = .{ .raw = false },
        .ready = .{},
        .bind_err = null,
        .raft = raft,
    };

    h.thread = try std.Thread.spawn(.{}, threadMain, .{h});
    h.ready.wait();

    if (h.bind_err) |err| {
        h.thread.join();
        allocator.destroy(h);
        return err;
    }
    return h;
}

fn threadMain(h: *Handle) void {
    runThread(h) catch |err| {
        std.log.err("rove-files-server thread exited: {s}", .{@errorName(err)});
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

    // Bind to port 0 — OS picks one. After `H2.create` returns we'll
    // read it back off the listen_fd with getsockname. Same pattern
    // most test servers use.
    const bind_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const server = CodeH2.create(&reg, allocator, bind_addr, .{
        .max_connections = h.max_connections,
        .buf_count = 64,
        .buf_size = 64 * 1024,
    }, .{}) catch |err| {
        h.bind_err = err;
        h.ready.set();
        return;
    };
    defer server.destroy();

    // Read the actual bound port via getsockname(listen_fd).
    h.port = try resolveBoundPort(server);

    // Signal readiness — parent spawn() returns after this.
    h.ready.set();

    std.log.info(
        "rove-files-server thread listening on 127.0.0.1:{d} (h2c) data_dir={s}",
        .{ h.port, h.data_dir },
    );

    while (!h.stop.load(.acquire)) {
        try server.pollWithTimeout(100 * std.time.ns_per_ms);
        try processRequests(server, allocator, h.data_dir, h.raft);
        try reg.flush();
        try cleanupResponses(server);
        try reg.flush();
    }
}

fn resolveBoundPort(server: *CodeH2) !u16 {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(@TypeOf(storage));
    try std.posix.getsockname(server.io.listen_fd, @ptrCast(&storage), &len);
    const addr = std.net.Address.initPosix(@alignCast(@ptrCast(&storage)));
    return addr.getPort();
}

// ── Request processing ────────────────────────────────────────────────

fn processRequests(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    raft: ?*kv.RaftNode,
) !void {
    const entities = server.request_out.entitySlice();
    const sids = server.request_out.column(h2.StreamId);
    const sessions = server.request_out.column(h2.Session);
    const req_hdrs = server.request_out.column(h2.ReqHeaders);
    const req_bodies = server.request_out.column(h2.ReqBody);

    for (entities, sids, sessions, req_hdrs, req_bodies) |ent, sid, sess, rh, rb| {
        handleOne(server, allocator, data_dir, raft, ent, sid, sess, rh, rb) catch |err| {
            std.log.warn("files-server: handler error: {s}", .{@errorName(err)});
            setResponse(server, ent, sid, sess, 500, null, "internal error\n") catch |se| std.log.err(
                "files-server: failed to write 500 response after handler error: {s} (entity may be stuck in request_out)",
                .{@errorName(se)},
            );
        };
    }
}

fn handleOne(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    raft: ?*kv.RaftNode,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    rh: h2.ReqHeaders,
    rb: h2.ReqBody,
) !void {
    // Extract `:method` and `:path` from the request headers. We
    // don't route by anything else — no content-type negotiation, no
    // query strings except on /source where the hash is a path
    // segment.
    var method: []const u8 = "";
    var path: []const u8 = "";
    var x_rove_path: []const u8 = "";
    var content_type: []const u8 = "";
    if (rh.fields != null) {
        const fields = rh.fields.?[0..rh.count];
        for (fields) |f| {
            const name = f.name[0..f.name_len];
            const value = f.value[0..f.value_len];
            if (std.mem.eql(u8, name, ":method")) method = value;
            if (std.mem.eql(u8, name, ":path")) path = value;
            if (std.mem.eql(u8, name, "x-rove-path")) x_rove_path = value;
            if (std.mem.eql(u8, name, "content-type")) content_type = value;
        }
    }

    // All routes share the shape `/{instance_id}/{op}[/{tail...}]`.
    // Split once to get the instance id and remainder, then dispatch
    // on the remainder.
    if (path.len == 0 or path[0] != '/') {
        try setResponse(server, ent, sid, sess, 404, null, "not found\n");
        return;
    }
    const after_slash = path[1..];
    const slash_idx = std.mem.indexOfScalar(u8, after_slash, '/') orelse {
        try setResponse(server, ent, sid, sess, 404, null, "not found\n");
        return;
    };
    const instance_id = after_slash[0..slash_idx];
    const remainder = after_slash[slash_idx + 1 ..]; // "upload", "deploy", "source/abc..."
    if (instance_id.len == 0) {
        try setResponse(server, ent, sid, sess, 400, null, "missing instance id\n");
        return;
    }

    if (std.mem.eql(u8, remainder, "upload") and std.mem.eql(u8, method, "POST")) {
        try handleUpload(server, allocator, data_dir, ent, sid, sess, instance_id, x_rove_path, rb);
    } else if (std.mem.eql(u8, remainder, "deploy") and std.mem.eql(u8, method, "POST")) {
        try handleDeploy(server, allocator, data_dir, ent, sid, sess, instance_id);
    } else if (std.mem.startsWith(u8, remainder, "source/") and std.mem.eql(u8, method, "GET")) {
        const hash = remainder["source/".len..];
        try handleSource(server, allocator, data_dir, ent, sid, sess, instance_id, hash);
    } else if (std.mem.eql(u8, remainder, "list") and std.mem.eql(u8, method, "GET")) {
        try handleList(server, allocator, data_dir, ent, sid, sess, instance_id);
    } else if (std.mem.startsWith(u8, remainder, "file/") and std.mem.eql(u8, method, "GET")) {
        const file_path = remainder["file/".len..];
        try handleGetFile(server, allocator, data_dir, ent, sid, sess, instance_id, file_path);
    } else if (std.mem.startsWith(u8, remainder, "file/") and std.mem.eql(u8, method, "PUT")) {
        const file_path = remainder["file/".len..];
        try handlePutFile(server, allocator, data_dir, raft, ent, sid, sess, instance_id, file_path, content_type, rb);
    } else if (std.mem.eql(u8, remainder, "blobs/check") and std.mem.eql(u8, method, "POST")) {
        try handleBlobsCheck(server, allocator, data_dir, ent, sid, sess, instance_id, rb);
    } else if (std.mem.startsWith(u8, remainder, "blobs/") and std.mem.eql(u8, method, "PUT")) {
        const hash = remainder["blobs/".len..];
        try handlePutBlob(server, allocator, data_dir, ent, sid, sess, instance_id, hash, rb);
    } else if (std.mem.eql(u8, remainder, "deployments") and std.mem.eql(u8, method, "POST")) {
        try handleDeployments(server, allocator, data_dir, raft, ent, sid, sess, instance_id, rb);
    } else {
        try setResponse(server, ent, sid, sess, 404, null, "not found\n");
    }
}

/// POST /{instance}/blobs/check — body is JSON `{"hashes":[...]}`,
/// response is JSON `{"missing":[...], "uploads": {hash: {url,method,
/// expires_in}}}`. `uploads.{hash}.url` points back at the
/// `PUT /{instance}/blobs/{hash}` route on this same files-server —
/// the client follows whatever URL we hand it, which keeps the FS
/// backend and (eventually) the S3 backend behind the same client
/// flow.
///
/// URLs are path-only; the client resolves against whichever origin
/// it reached us on (directly or via the worker's `/_system/files/*`
/// proxy). We never emit a host, so the admin UI and a direct-to-
/// files-server CLI both work.
fn handleBlobsCheck(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    rb: h2.ReqBody,
) !void {
    const body: []const u8 = if (rb.data != null) rb.data.?[0..rb.len] else "";
    const BodyShape = struct { hashes: [][]const u8 };

    var parsed = std.json.parseFromSlice(BodyShape, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch {
        try setResponse(server, ent, sid, sess, 400, null, "bad request body\n");
        return;
    };
    defer parsed.deinit();

    var check = files_server.checkBlobs(
        allocator,
        data_dir,
        instance_id,
        parsed.value.hashes,
    ) catch |err| {
        const code: u16 = switch (err) {
            files_server.Error.InvalidInstanceId, files_server.Error.InvalidManifest => 400,
            else => 500,
        };
        const msg = try std.fmt.allocPrint(allocator, "check failed: {s}\n", .{@errorName(err)});
        try setResponse(server, ent, sid, sess, code, msg.ptr, msg);
        return;
    };
    defer check.deinit();

    // Build response JSON. Owned allocation — `setResponse` takes
    // ownership of the backing bytes via `body_ptr` + `body`.
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);

    try w.writeAll("{\"missing\":[");
    for (check.missing, 0..) |h, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('"');
        try w.writeAll(h);
        try w.writeByte('"');
    }
    try w.writeAll("],\"uploads\":{");
    // The uploads object carries a URL the client PUTs to, the
    // method, and a TTL hint (S3-parity — locally unused but nice
    // for the client to have a consistent contract).
    for (check.missing, 0..) |h, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('"');
        try w.writeAll(h);
        try w.writeAll("\":{\"url\":\"/v1/instances/");
        try w.writeAll(instance_id);
        try w.writeAll("/blobs/");
        try w.writeAll(h);
        try w.writeAll("\",\"method\":\"PUT\",\"expires_in\":300}");
    }
    try w.writeAll("}}");

    const out = try buf.toOwnedSlice(allocator);
    try setResponse(server, ent, sid, sess, 200, out.ptr, out);
}

/// POST /{instance}/deployments — body JSON:
///   { "files": {"path": {"hash": "...", "kind": "handler"|"static",
///                         "content_type": "..."}}, ...},
///     "parent_id": "000000000000000N",   // optional hex, CAS
///     "comment": "..." }                  // optional, not stored yet
///
/// Stamps the manifest from the file map: every path gets a
/// `file/{path}` entry pointing at the referenced blob's hash;
/// handlers are compiled server-side from their source blobs. All
/// index writes collect into a files writeset and propose through
/// raft so followers' files.db converges.
fn handleDeployments(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    raft: ?*kv.RaftNode,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    rb: h2.ReqBody,
) !void {
    const body: []const u8 = if (rb.data != null) rb.data.?[0..rb.len] else "";

    // Parse the body as a generic json.Value so we can iterate the
    // string-keyed `files` object without pre-declaring a Zig struct
    // for it (a `std.StringHashMap`-flavored Zig type for parseInto
    // doesn't work ergonomically with arbitrary per-entry shapes).
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
    }) catch {
        try setResponse(server, ent, sid, sess, 400, null, "bad request body\n");
        return;
    };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try setResponse(server, ent, sid, sess, 400, null, "body must be a JSON object\n");
            return;
        },
    };

    // Parse `parent_id` if present. Absent = skip CAS.
    var expected_parent: ?u64 = null;
    if (root_obj.get("parent_id")) |pid_val| switch (pid_val) {
        .string => |s| expected_parent = std.fmt.parseInt(u64, s, 16) catch {
            try setResponse(server, ent, sid, sess, 400, null, "invalid parent_id hex\n");
            return;
        },
        .null => {},
        else => {
            try setResponse(server, ent, sid, sess, 400, null, "parent_id must be a hex string\n");
            return;
        },
    };

    const files_obj = switch (root_obj.get("files") orelse .null) {
        .object => |o| o,
        else => {
            try setResponse(server, ent, sid, sess, 400, null, "`files` must be a JSON object\n");
            return;
        },
    };

    // Flatten `files` into a DeployEntry slice. We validate kind
    // strings here so `deployManifest` only sees well-formed input.
    var entries: std.ArrayList(files_server.DeployEntry) = .empty;
    defer entries.deinit(allocator);
    var it = files_obj.iterator();
    while (it.next()) |kv_pair| {
        const entry_obj = switch (kv_pair.value_ptr.*) {
            .object => |o| o,
            else => {
                try setResponse(server, ent, sid, sess, 400, null, "file entry must be a JSON object\n");
                return;
            },
        };
        const hash = switch (entry_obj.get("hash") orelse .null) {
            .string => |s| s,
            else => {
                try setResponse(server, ent, sid, sess, 400, null, "file entry missing hash\n");
                return;
            },
        };
        const kind_str = switch (entry_obj.get("kind") orelse .null) {
            .string => |s| s,
            else => {
                try setResponse(server, ent, sid, sess, 400, null, "file entry missing kind\n");
                return;
            },
        };
        const kind: files_mod.Kind = if (std.mem.eql(u8, kind_str, "handler"))
            .handler
        else if (std.mem.eql(u8, kind_str, "static"))
            .static
        else {
            try setResponse(server, ent, sid, sess, 400, null, "kind must be \"handler\" or \"static\"\n");
            return;
        };
        const content_type: []const u8 = switch (entry_obj.get("content_type") orelse .null) {
            .string => |s| s,
            .null => "",
            else => {
                try setResponse(server, ent, sid, sess, 400, null, "content_type must be a string\n");
                return;
            },
        };

        entries.append(allocator, .{
            .path = kv_pair.key_ptr.*,
            .hash = hash,
            .kind = kind,
            .content_type = content_type,
        }) catch {
            try setResponse(server, ent, sid, sess, 500, null, "oom\n");
            return;
        };
    }

    // Collect writes into a files writeset; propose through raft if
    // the caller wired one. Deploy failures never propose (we clean
    // up the writeset on any early return).
    var files_ws = kv.WriteSet.init(allocator);
    defer files_ws.deinit();

    const result = files_server.deployManifest(
        allocator,
        data_dir,
        instance_id,
        entries.items,
        expected_parent,
        &files_ws,
    ) catch |err| {
        const code: u16 = switch (err) {
            files_server.Error.InvalidInstanceId,
            files_server.Error.InvalidManifest,
            files_server.Error.InvalidPath,
            files_server.Error.CompileFailed,
            => 400,
            files_server.Error.NotFound => 400, // client referenced a blob they didn't upload
            files_server.Error.CasConflict => 409,
            else => 500,
        };
        const msg = try std.fmt.allocPrint(allocator, "deploy failed: {s}\n", .{@errorName(err)});
        try setResponse(server, ent, sid, sess, code, msg.ptr, msg);
        return;
    };

    // Replicate to followers. Leader-local writes are already in
    // files.db; this is the raft-side of the same thing.
    if (raft) |r| {
        if (files_ws.ops.items.len > 0) {
            const ws_bytes = try files_ws.encode(allocator);
            defer allocator.free(ws_bytes);
            const envelope = try encodeFilesWriteSetEnvelope(allocator, instance_id, ws_bytes);
            defer allocator.free(envelope);
            const seq = r.highWatermark() + 1;
            r.propose(seq, envelope) catch |err| {
                std.log.warn(
                    "rove-files-server: propose files writeset for {s} failed: {s} (leader deployed, followers may diverge)",
                    .{ instance_id, @errorName(err) },
                );
            };
        }
    }

    const body_out = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{x:0>16}\",\"parent_id\":\"{x:0>16}\"}}\n",
        .{ result.id, result.parent_id },
    );
    try setResponse(server, ent, sid, sess, 201, body_out.ptr, body_out);
}

/// PUT /{instance}/blobs/{hash} — body is the raw bytes. Server
/// hashes on arrival; rejects 400 if the claimed hash doesn't
/// match what we computed.
fn handlePutBlob(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    hash: []const u8,
    rb: h2.ReqBody,
) !void {
    const body: []const u8 = if (rb.data != null) rb.data.?[0..rb.len] else "";

    files_server.putBlobByHash(allocator, data_dir, instance_id, hash, body) catch |err| {
        const code: u16 = switch (err) {
            files_server.Error.InvalidInstanceId, files_server.Error.InvalidManifest => 400,
            else => 500,
        };
        const msg = try std.fmt.allocPrint(allocator, "putBlob failed: {s}\n", .{@errorName(err)});
        try setResponse(server, ent, sid, sess, code, msg.ptr, msg);
        return;
    };
    try setResponse(server, ent, sid, sess, 204, null, "");
}

fn handleUpload(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    x_rove_path: []const u8,
    rb: h2.ReqBody,
) !void {
    if (x_rove_path.len == 0) {
        try setResponse(server, ent, sid, sess, 400, null, "missing X-Rove-Path header\n");
        return;
    }
    const source: []const u8 = if (rb.data != null) rb.data.?[0..rb.len] else "";

    files_server.uploadFile(allocator, data_dir, instance_id, x_rove_path, source) catch |err| {
        std.log.warn("files-server: uploadFile failed: {s}", .{@errorName(err)});
        const msg = try std.fmt.allocPrint(
            allocator,
            "upload failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponse(server, ent, sid, sess, 500, msg.ptr, msg);
        return;
    };
    try setResponse(server, ent, sid, sess, 204, null, "");
}

fn handleDeploy(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
) !void {
    const dep_id = files_server.deploy(allocator, data_dir, instance_id) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "deploy failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponse(server, ent, sid, sess, 500, msg.ptr, msg);
        return;
    };
    const body = try std.fmt.allocPrint(allocator, "{d}\n", .{dep_id});
    try setResponse(server, ent, sid, sess, 200, body.ptr, body);
}

fn handleList(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
) !void {
    var manifest = files_server.loadCurrentManifest(allocator, data_dir, instance_id) catch |err| {
        if (err == files_server.Error.NotFound) {
            // No deployment yet — empty list, not an error.
            const empty = try std.fmt.allocPrint(
                allocator,
                "{{\"deployment_id\":0,\"entries\":[]}}",
                .{},
            );
            try setResponse(server, ent, sid, sess, 200, empty.ptr, empty);
            return;
        }
        const msg = try std.fmt.allocPrint(
            allocator,
            "list failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponse(server, ent, sid, sess, 500, msg.ptr, msg);
        return;
    };
    defer manifest.deinit();

    const body = try encodeListJson(allocator, &manifest);
    try setResponse(server, ent, sid, sess, 200, body.ptr, body);
}

fn encodeListJson(
    allocator: std.mem.Allocator,
    manifest: *const files_mod.FileStore.Manifest,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);
    try w.print("{{\"deployment_id\":{d},\"entries\":[", .{manifest.id});
    for (manifest.entries, 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        const kind_str: []const u8 = if (e.kind == .handler) "handler" else "static";
        try w.writeAll("{\"path\":");
        try writeJsonString(&w, e.path);
        try w.print(",\"kind\":\"{s}\",\"content_type\":", .{kind_str});
        try writeJsonString(&w, e.content_type);
        try w.print(",\"hash\":\"{s}\"}}", .{e.source_hex});
    }
    try w.writeAll("]}");
    return buf.toOwnedSlice(allocator);
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
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                try w.print("\\u{x:0>4}", .{b});
            },
            else => try w.writeByte(b),
        }
    }
    try w.writeByte('"');
}

fn handleGetFile(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    file_path: []const u8,
) !void {
    if (file_path.len == 0) {
        try setResponse(server, ent, sid, sess, 400, null, "empty file path\n");
        return;
    }

    var content = files_server.readFileByPath(allocator, data_dir, instance_id, file_path) catch |err| {
        const code: u16 = switch (err) {
            files_server.Error.NotFound => 404,
            files_server.Error.InvalidPath, files_server.Error.InvalidInstanceId => 400,
            else => 500,
        };
        const msg = try std.fmt.allocPrint(
            allocator,
            "getFile failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponse(server, ent, sid, sess, code, msg.ptr, msg);
        return;
    };
    defer content.deinit();

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);
    const kind_str: []const u8 = if (content.kind == .handler) "handler" else "static";
    try w.print("{{\"path\":", .{});
    try writeJsonString(&w, file_path);
    try w.print(",\"kind\":\"{s}\",\"content_type\":", .{kind_str});
    try writeJsonString(&w, content.content_type);
    try w.writeAll(",\"content\":");
    try writeJsonString(&w, content.bytes);
    try w.writeByte('}');

    const body = try buf.toOwnedSlice(allocator);
    try setResponse(server, ent, sid, sess, 200, body.ptr, body);
}

fn handlePutFile(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    raft: ?*kv.RaftNode,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    file_path: []const u8,
    content_type: []const u8,
    rb: h2.ReqBody,
) !void {
    if (file_path.len == 0) {
        try setResponse(server, ent, sid, sess, 400, null, "empty file path\n");
        return;
    }
    const body: []const u8 = if (rb.data != null) rb.data.?[0..rb.len] else "";

    var files_ws = kv.WriteSet.init(allocator);
    defer files_ws.deinit();

    const dep_id = files_server.putFileAndDeploy(
        allocator,
        data_dir,
        instance_id,
        file_path,
        body,
        content_type,
        &files_ws,
    ) catch |err| {
        const code: u16 = switch (err) {
            files_server.Error.InvalidPath => 400,
            files_server.Error.CompileFailed => 400,
            files_server.Error.InvalidInstanceId => 400,
            else => 500,
        };
        const msg = try std.fmt.allocPrint(
            allocator,
            "putFile failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponse(server, ent, sid, sess, code, msg.ptr, msg);
        return;
    };

    // Replicate the files.db writes to followers so their copy of
    // `{id}/files.db` lines up with this deployment. Blob bytes live
    // in the shared BlobStore backend; only the manifest rows need
    // the raft hop. On propose failure the leader's files.db still
    // has the deployment locally — at-least-once semantics match
    // the outbox + root paths.
    if (raft) |r| {
        if (files_ws.ops.items.len > 0) {
            const ws_bytes = try files_ws.encode(allocator);
            defer allocator.free(ws_bytes);
            const envelope = try encodeFilesWriteSetEnvelope(allocator, instance_id, ws_bytes);
            defer allocator.free(envelope);
            const seq = r.highWatermark() + 1;
            r.propose(seq, envelope) catch |err| {
                std.log.warn(
                    "rove-files-server: propose files writeset for {s} failed: {s} (leader has the deploy, followers may diverge)",
                    .{ instance_id, @errorName(err) },
                );
            };
        }
    }

    const body_out = try std.fmt.allocPrint(allocator, "{d}\n", .{dep_id});
    try setResponse(server, ent, sid, sess, 201, body_out.ptr, body_out);
}

fn handleSource(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    hash: []const u8,
) !void {
    if (hash.len == 0) {
        try setResponse(server, ent, sid, sess, 400, null, "missing hash\n");
        return;
    }

    const bytes = files_server.getSourceByHash(allocator, data_dir, instance_id, hash) catch |err| {
        const code: u16 = if (err == files_server.Error.NotFound) 404 else 500;
        const msg = try std.fmt.allocPrint(
            allocator,
            "source fetch failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponse(server, ent, sid, sess, code, msg.ptr, msg);
        return;
    };
    try setResponse(server, ent, sid, sess, 200, bytes.ptr, bytes);
}

/// Stamp a Status + RespBody + friends onto the entity and move it
/// from request_out to response_in. The body bytes are transferred
/// into the RespBody component; ownership passes to rove-h2 which
/// frees them after sending. Passing `body_ptr = null` is fine for
/// empty responses.
fn setResponse(
    server: *CodeH2,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status: u16,
    body_ptr: ?[*]u8,
    body_slice: []const u8,
) !void {
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{
        .fields = null,
        .count = 0,
    });
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = body_ptr,
        .len = @intCast(body_slice.len),
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

fn cleanupResponses(server: *CodeH2) !void {
    const entities = server.response_out.entitySlice();
    for (entities) |ent| {
        try server.reg.destroy(ent);
    }
}
