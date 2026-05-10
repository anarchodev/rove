//! `files_server.thread` — public-facing files-server, spawned by
//! loop46 alongside the worker. Browser dashboard + CLI clients hit
//! it directly at `files.{public_suffix}` over TLS; the worker is
//! NOT in the upload/deploy path (Phase 5.5 e Step F1).
//!
//! Auth: every request must carry `Authorization: Bearer <jwt>`. The
//! worker mints these JWTs at `/_system/services-token` after running
//! its existing admin-auth check (cookie or bearer). Same shared
//! HMAC-SHA256 secret on both sides — see `src/jwt/root.zig`.
//!
//! CORS: every response carries `Access-Control-Allow-Origin =
//! cfg.cors_origin` so the dashboard at `app.{public_suffix}` can
//! call cross-origin. OPTIONS preflight returns 204 with the
//! method/header allow-set.
//!
//! ## Wire protocol
//!
//! HTTP/2 (TLS-terminated by rove-h2 when `tls_config != null`).
//! Routes (unchanged from the original loopback h2c shape):
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
//!   POST /{instance_id}/blobs/check, PUT /{instance_id}/blobs/{hash},
//!   POST /{instance_id}/deployments, GET /{instance_id}/deployments/{hex_id},
//!   GET  /{instance_id}/list, GET /{instance_id}/file/{path},
//!   PUT  /{instance_id}/file/{path}
//!     — see individual handlers.
//!
//! The handler path intentionally avoids JSON — the only structured
//! field the CLI needs to send is the deployment-relative file path,
//! and a header carries that cleanly. Bodies are opaque bytes.

const std = @import("std");
const rove = @import("rove");
const rio = @import("rove-io");
const h2 = @import("rove-h2");
const blob_mod = @import("rove-blob");
const jwt = @import("rove-jwt");
const kv = @import("rove-kv");

const files_server = @import("root.zig");
const files_mod = @import("rove-files");

const CodeH2 = h2.H2(.{});

pub const Config = struct {
    allocator: std.mem.Allocator,
    /// Absolute path to `{data_dir}`. Per-tenant `{data_dir}/{id}/files.db`
    /// + `file-blobs/` open lazily on each request. Borrowed; must
    /// outlive the handle.
    data_dir: []const u8,
    /// fs / s3 picker for every per-tenant file-blobs backend the
    /// handlers open. Borrowed; must outlive the handle.
    blob_cfg: blob_mod.BackendConfig,
    /// Where to bind the h2 listener. The standalone binary
    /// (`files-server-standalone`) takes this from its `--listen`
    /// flag; smokes may pass `127.0.0.1:0` to ask the OS for an
    /// ephemeral port.
    bind_addr: std.net.Address,
    /// Optional TLS — when set, the listener does TLS termination via
    /// rove-h2's standard path (the `*TlsConfig` is shared with the
    /// worker, both built once by `loop46/main.zig::resolveTls`).
    /// Null = h2c.
    tls_config: ?*h2.TlsConfig = null,
    /// Required for any non-OPTIONS request — HMAC-SHA256 secret used
    /// to verify the JWT in `Authorization: Bearer <token>`. The
    /// worker mints these tokens at `/_system/services-token` after
    /// running its admin-auth check (cookie or bearer). When null,
    /// every request returns 401.
    jwt_secret: ?[]const u8 = null,
    /// `Access-Control-Allow-Origin` value emitted on every response.
    /// The dashboard at `https://app.{suffix}` calls the files-server
    /// at `https://files.{suffix}` cross-origin; the browser refuses
    /// the response without a matching CORS header. Null = no CORS.
    cors_origin: ?[]const u8 = null,
    /// Max concurrent inbound h2 connections this server accepts.
    /// Sized from the worker count at spawn time.
    max_connections: u32 = 64,
    /// When set, the standalone is part of a files-server raft
    /// cluster (production.md #1.4). The `/_system/leader` route
    /// reports `cluster.raft.isLeader()` so dashboards / clients
    /// know which node accepts manifest writes. Null = single-
    /// process mode (legacy, pre-#1.4); `/_system/leader` returns
    /// 501 in that case.
    cluster: ?*kv.Cluster = null,
};

/// Handle returned by `spawn`. The caller is expected to hold this
/// for the life of the worker process; `shutdown` tears it down.
pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    port: u16,
    config: Config,
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
pub fn spawn(config: Config) !*Handle {
    const h = try config.allocator.create(Handle);
    errdefer config.allocator.destroy(h);

    h.* = .{
        .allocator = config.allocator,
        .thread = undefined,
        .port = 0,
        .config = config,
        .stop = .{ .raw = false },
        .ready = .{},
        .bind_err = null,
    };

    h.thread = try std.Thread.spawn(.{}, threadMain, .{h});
    h.ready.wait();

    if (h.bind_err) |err| {
        h.thread.join();
        config.allocator.destroy(h);
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

    const server = CodeH2.create(&reg, allocator, h.config.bind_addr, .{
        .max_connections = h.config.max_connections,
        .buf_count = 64,
        .buf_size = 64 * 1024,
    }, .{
        .tls_config = h.config.tls_config,
    }) catch |err| {
        h.bind_err = err;
        h.ready.set();
        return;
    };
    defer server.destroy();

    h.port = try resolveBoundPort(server);
    h.ready.set();

    if (h.config.tls_config != null) {
        std.log.info(
            "rove-files-server thread listening on port {d} (TLS) data_dir={s}",
            .{ h.port, h.config.data_dir },
        );
    } else {
        std.log.info(
            "rove-files-server thread listening on 127.0.0.1:{d} (h2c) data_dir={s}",
            .{ h.port, h.config.data_dir },
        );
    }

    while (!h.stop.load(.acquire)) {
        try server.pollWithTimeout(100 * std.time.ns_per_ms);
        try processRequests(server, allocator, &h.config);
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
    cfg: *const Config,
) !void {
    const entities = server.request_out.entitySlice();
    const sids = server.request_out.column(h2.StreamId);
    const sessions = server.request_out.column(h2.Session);
    const req_hdrs = server.request_out.column(h2.ReqHeaders);
    const req_bodies = server.request_out.column(h2.ReqBody);

    for (entities, sids, sessions, req_hdrs, req_bodies) |ent, sid, sess, rh, rb| {
        handleOne(server, allocator, cfg, ent, sid, sess, rh, rb) catch |err| {
            std.log.warn("files-server: handler error: {s}", .{@errorName(err)});
            setResponse(server, cfg, ent, sid, sess, 500, null, "internal error\n") catch |se| std.log.err(
                "files-server: failed to write 500 response after handler error: {s} (entity may be stuck in request_out)",
                .{@errorName(se)},
            );
        };
    }
}

fn handleOne(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    rh: h2.ReqHeaders,
    rb: h2.ReqBody,
) !void {
    var method: []const u8 = "";
    var path: []const u8 = "";
    var x_rove_path: []const u8 = "";
    var content_type: []const u8 = "";
    var authz: []const u8 = "";
    if (rh.fields != null) {
        const fields = rh.fields.?[0..rh.count];
        for (fields) |f| {
            const name = f.name[0..f.name_len];
            const value = f.value[0..f.value_len];
            if (std.mem.eql(u8, name, ":method")) method = value;
            if (std.mem.eql(u8, name, ":path")) path = value;
            if (std.mem.eql(u8, name, "x-rove-path")) x_rove_path = value;
            if (std.mem.eql(u8, name, "content-type")) content_type = value;
            if (std.mem.eql(u8, name, "authorization")) authz = value;
        }
    }

    // CORS preflight from the dashboard's cross-origin fetch. Browser
    // sends OPTIONS before any non-simple method (PUT/POST) or any
    // request that carries a custom header (Authorization counts).
    if (std.mem.eql(u8, method, "OPTIONS")) {
        try setPreflight(server, cfg, ent, sid, sess);
        return;
    }

    // JWT gate. The worker mints these at /_system/services-token
    // after admin auth (cookie or bearer); the standalone trusts the
    // signed `exp` and otherwise treats every token as authorized for
    // every tenant. Per-tenant scoping moves into the token in a
    // future revision.
    if (cfg.jwt_secret) |secret| {
        if (!std.mem.startsWith(u8, authz, "Bearer ")) {
            try setResponse(server, cfg, ent, sid, sess, 401, null, "missing bearer token\n");
            return;
        }
        const token = authz["Bearer ".len..];
        const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
        _ = jwt.verify(secret, token, now_ms) catch |err| {
            const msg = switch (err) {
                jwt.Error.Expired => "token expired\n",
                jwt.Error.BadSignature => "bad signature\n",
                jwt.Error.Malformed, jwt.Error.UnsupportedAlg => "malformed token\n",
                jwt.Error.MissingCap, jwt.Error.InvalidCap => "missing required capability\n",
                jwt.Error.OutOfMemory => "out of memory\n",
            };
            try setResponse(server, cfg, ent, sid, sess, 401, null, msg);
            return;
        };
    } else {
        try setResponse(server, cfg, ent, sid, sess, 401, null, "auth not configured\n");
        return;
    }

    // /_system/* routes are platform-internal — handled separately
    // from the per-tenant route shape below.
    if (std.mem.eql(u8, path, "/_system/leader") and std.mem.eql(u8, method, "GET")) {
        if (cfg.cluster) |c| {
            if (c.raft.isLeader()) {
                try setResponse(server, cfg, ent, sid, sess, 200, null, "leader\n");
            } else {
                try setResponse(server, cfg, ent, sid, sess, 503, null, "not leader; retry against the cluster leader\n");
            }
        } else {
            // Pre-#1.4 / single-process mode. Tools that probe this
            // endpoint should treat 501 as "this build of files-server
            // doesn't have raft, treat all writes as accepted by the
            // single instance."
            try setResponse(server, cfg, ent, sid, sess, 501, null, "raft not enabled on this files-server\n");
        }
        return;
    }

    // Debug endpoint — exercises the propose-and-wait path end-to-
    // end so the smoke can validate raft replication without having
    // to migrate the real deploy paths first. Body is a JSON object
    // `{"store":"<store_id>", "key":"<key>", "value":"<value>"}`
    // (all utf-8). Builds a WriteSet, wraps in the application's
    // writeset envelope (`ENVELOPE_FILES_WRITESET`), proposes,
    // waits for raft commit. Returns 200 with the committed seq on
    // success, 503 on followers, 400 on bad input.
    //
    // This is platform-internal and is NOT part of the customer-
    // facing API. Real manifest writes (deployManifest etc.) get
    // migrated to use the same proposeAndWait primitive in
    // subsequent commits.
    if (std.mem.eql(u8, path, "/_system/cluster-put") and std.mem.eql(u8, method, "POST")) {
        const cluster = cfg.cluster orelse {
            try setResponse(server, cfg, ent, sid, sess, 501, null, "raft not enabled on this files-server\n");
            return;
        };
        if (!cluster.raft.isLeader()) {
            try setResponse(server, cfg, ent, sid, sess, 503, null, "not leader; retry against the cluster leader\n");
            return;
        }
        try handleClusterPut(server, allocator, cfg, ent, sid, sess, cluster, rb);
        return;
    }

    // Debug companion — fetches a kv row from the LOCAL cluster
    // store (no raft round-trip; just reads what's been replicated
    // here). Path: `/_system/cluster-get/<store>/<key>`. Returns
    // the value bytes verbatim or 404. Used by the smoke to verify
    // a `/_system/cluster-put` on the leader replicates to every
    // follower's local store.
    if (std.mem.startsWith(u8, path, "/_system/cluster-get/") and std.mem.eql(u8, method, "GET")) {
        const cluster = cfg.cluster orelse {
            try setResponse(server, cfg, ent, sid, sess, 501, null, "raft not enabled on this files-server\n");
            return;
        };
        try handleClusterGet(server, allocator, cfg, ent, sid, sess, cluster, path);
        return;
    }

    // All other routes share the shape `/{instance_id}/{op}[/{tail...}]`.
    if (path.len == 0 or path[0] != '/') {
        try setResponse(server, cfg, ent, sid, sess, 404, null, "not found\n");
        return;
    }
    const after_slash = path[1..];
    const slash_idx = std.mem.indexOfScalar(u8, after_slash, '/') orelse {
        try setResponse(server, cfg, ent, sid, sess, 404, null, "not found\n");
        return;
    };
    const instance_id = after_slash[0..slash_idx];
    const remainder = after_slash[slash_idx + 1 ..];
    if (instance_id.len == 0) {
        try setResponse(server, cfg, ent, sid, sess, 400, null, "missing instance id\n");
        return;
    }

    if (std.mem.eql(u8, remainder, "upload") and std.mem.eql(u8, method, "POST")) {
        try handleUpload(server, allocator, cfg, ent, sid, sess, instance_id, x_rove_path, rb);
    } else if (std.mem.eql(u8, remainder, "deploy") and std.mem.eql(u8, method, "POST")) {
        try handleDeploy(server, allocator, cfg, ent, sid, sess, instance_id);
    } else if (std.mem.startsWith(u8, remainder, "source/") and std.mem.eql(u8, method, "GET")) {
        const hash = remainder["source/".len..];
        try handleSource(server, allocator, cfg, ent, sid, sess, instance_id, hash);
    } else if (std.mem.eql(u8, remainder, "list") and std.mem.eql(u8, method, "GET")) {
        try handleList(server, allocator, cfg, ent, sid, sess, instance_id);
    } else if (std.mem.startsWith(u8, remainder, "file/") and std.mem.eql(u8, method, "GET")) {
        const file_path = remainder["file/".len..];
        try handleGetFile(server, allocator, cfg, ent, sid, sess, instance_id, file_path);
    } else if (std.mem.startsWith(u8, remainder, "file/") and std.mem.eql(u8, method, "PUT")) {
        const file_path = remainder["file/".len..];
        try handlePutFile(server, allocator, cfg, ent, sid, sess, instance_id, file_path, content_type, rb);
    } else if (std.mem.eql(u8, remainder, "blobs/check") and std.mem.eql(u8, method, "POST")) {
        try handleBlobsCheck(server, allocator, cfg, ent, sid, sess, instance_id, rb);
    } else if (std.mem.startsWith(u8, remainder, "blobs/") and std.mem.eql(u8, method, "PUT")) {
        const hash = remainder["blobs/".len..];
        try handlePutBlob(server, allocator, cfg, ent, sid, sess, instance_id, hash, rb);
    } else if (std.mem.eql(u8, remainder, "deployments") and std.mem.eql(u8, method, "POST")) {
        try handleDeployments(server, allocator, cfg, ent, sid, sess, instance_id, rb);
    } else if (std.mem.startsWith(u8, remainder, "deployments/") and std.mem.eql(u8, method, "GET")) {
        const id_str = remainder["deployments/".len..];
        try handleGetDeployment(server, allocator, cfg, ent, sid, sess, instance_id, id_str);
    } else {
        try setResponse(server, cfg, ent, sid, sess, 404, null, "not found\n");
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
/// it reached us on. We never emit a host, so the admin UI and a
/// direct-to-files-server CLI both work.
fn handleBlobsCheck(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    cfg: *const Config,
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
        try setResponse(server, cfg, ent, sid, sess, 400, null, "bad request body\n");
        return;
    };
    defer parsed.deinit();

    var check = files_server.checkBlobs(
        allocator,
        cfg.data_dir,
        cfg.blob_cfg,
        instance_id,
        parsed.value.hashes,
    ) catch |err| {
        const code: u16 = switch (err) {
            files_server.Error.InvalidInstanceId, files_server.Error.InvalidManifest => 400,
            else => 500,
        };
        const msg = try std.fmt.allocPrint(allocator, "check failed: {s}\n", .{@errorName(err)});
        try setResponse(server, cfg, ent, sid, sess, code, msg.ptr, msg);
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
    try setResponse(server, cfg, ent, sid, sess, 200, out.ptr, out);
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
    cfg: *const Config,
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
        try setResponse(server, cfg, ent, sid, sess, 400, null, "bad request body\n");
        return;
    };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try setResponse(server, cfg, ent, sid, sess, 400, null, "body must be a JSON object\n");
            return;
        },
    };

    // Parse `parent_id` if present. Absent = skip CAS.
    var expected_parent: ?u64 = null;
    if (root_obj.get("parent_id")) |pid_val| switch (pid_val) {
        .string => |s| expected_parent = std.fmt.parseInt(u64, s, 16) catch {
            try setResponse(server, cfg, ent, sid, sess, 400, null, "invalid parent_id hex\n");
            return;
        },
        .null => {},
        else => {
            try setResponse(server, cfg, ent, sid, sess, 400, null, "parent_id must be a hex string\n");
            return;
        },
    };

    const files_obj = switch (root_obj.get("files") orelse .null) {
        .object => |o| o,
        else => {
            try setResponse(server, cfg, ent, sid, sess, 400, null, "`files` must be a JSON object\n");
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
                try setResponse(server, cfg, ent, sid, sess, 400, null, "file entry must be a JSON object\n");
                return;
            },
        };
        const hash = switch (entry_obj.get("hash") orelse .null) {
            .string => |s| s,
            else => {
                try setResponse(server, cfg, ent, sid, sess, 400, null, "file entry missing hash\n");
                return;
            },
        };
        const kind_str = switch (entry_obj.get("kind") orelse .null) {
            .string => |s| s,
            else => {
                try setResponse(server, cfg, ent, sid, sess, 400, null, "file entry missing kind\n");
                return;
            },
        };
        const kind: files_mod.Kind = if (std.mem.eql(u8, kind_str, "handler"))
            .handler
        else if (std.mem.eql(u8, kind_str, "static"))
            .static
        else {
            try setResponse(server, cfg, ent, sid, sess, 400, null, "kind must be \"handler\" or \"static\"\n");
            return;
        };
        const content_type: []const u8 = switch (entry_obj.get("content_type") orelse .null) {
            .string => |s| s,
            .null => "",
            else => {
                try setResponse(server, cfg, ent, sid, sess, 400, null, "content_type must be a string\n");
                return;
            },
        };

        entries.append(allocator, .{
            .path = kv_pair.key_ptr.*,
            .hash = hash,
            .kind = kind,
            .content_type = content_type,
        }) catch {
            try setResponse(server, cfg, ent, sid, sess, 500, null, "oom\n");
            return;
        };
    }

    const result = files_server.deployManifest(
        allocator,
        cfg.data_dir,
        cfg.blob_cfg,
        instance_id,
        entries.items,
        expected_parent,
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
        try setResponse(server, cfg, ent, sid, sess, code, msg.ptr, msg);
        return;
    };

    const body_out = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{x:0>16}\",\"parent_id\":\"{x:0>16}\"}}\n",
        .{ result.id, result.parent_id },
    );
    try setResponse(server, cfg, ent, sid, sess, 201, body_out.ptr, body_out);
}

/// PUT /{instance}/blobs/{hash} — body is the raw bytes. Server
/// hashes on arrival; rejects 400 if the claimed hash doesn't
/// match what we computed.
fn handlePutBlob(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    hash: []const u8,
    rb: h2.ReqBody,
) !void {
    const body: []const u8 = if (rb.data != null) rb.data.?[0..rb.len] else "";

    files_server.putBlobByHash(allocator, cfg.data_dir, cfg.blob_cfg, instance_id, hash, body) catch |err| {
        const code: u16 = switch (err) {
            files_server.Error.InvalidInstanceId, files_server.Error.InvalidManifest => 400,
            else => 500,
        };
        const msg = try std.fmt.allocPrint(allocator, "putBlob failed: {s}\n", .{@errorName(err)});
        try setResponse(server, cfg, ent, sid, sess, code, msg.ptr, msg);
        return;
    };
    try setResponse(server, cfg, ent, sid, sess, 204, null, "");
}

fn handleUpload(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    x_rove_path: []const u8,
    rb: h2.ReqBody,
) !void {
    if (x_rove_path.len == 0) {
        try setResponse(server, cfg, ent, sid, sess, 400, null, "missing X-Rove-Path header\n");
        return;
    }
    const source: []const u8 = if (rb.data != null) rb.data.?[0..rb.len] else "";

    files_server.uploadFile(allocator, cfg.data_dir, cfg.blob_cfg, instance_id, x_rove_path, source) catch |err| {
        std.log.warn("files-server: uploadFile failed: {s}", .{@errorName(err)});
        const msg = try std.fmt.allocPrint(
            allocator,
            "upload failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponse(server, cfg, ent, sid, sess, 500, msg.ptr, msg);
        return;
    };
    try setResponse(server, cfg, ent, sid, sess, 204, null, "");
}

fn handleDeploy(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
) !void {
    const dep_id = files_server.deploy(allocator, cfg.data_dir, cfg.blob_cfg, instance_id) catch |err| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "deploy failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponse(server, cfg, ent, sid, sess, 500, msg.ptr, msg);
        return;
    };
    const body = try std.fmt.allocPrint(allocator, "{d}\n", .{dep_id});
    try setResponse(server, cfg, ent, sid, sess, 200, body.ptr, body);
}

fn handleList(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
) !void {
    var manifest = files_server.loadCurrentManifest(allocator, cfg.data_dir, cfg.blob_cfg, instance_id) catch |err| {
        if (err == files_server.Error.NotFound) {
            // No deployment yet — empty list, not an error.
            const empty = try std.fmt.allocPrint(
                allocator,
                "{{\"deployment_id\":0,\"entries\":[]}}",
                .{},
            );
            try setResponse(server, cfg, ent, sid, sess, 200, empty.ptr, empty);
            return;
        }
        const msg = try std.fmt.allocPrint(
            allocator,
            "list failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponse(server, cfg, ent, sid, sess, 500, msg.ptr, msg);
        return;
    };
    defer manifest.deinit();

    const body = try encodeListJson(allocator, &manifest);
    try setResponse(server, cfg, ent, sid, sess, 200, body.ptr, body);
}

/// `GET /{instance}/deployments/{id}` — read-only manifest fetch by
/// id. Used by the dashboard's replay-bundle composer to load the
/// HISTORICAL manifest a request was dispatched against, instead of
/// the current one. Without this, replays of older requests load
/// current source — silently wrong when the deployment changed
/// between the original request and the replay click.
///
/// `{id}` is a hex-encoded u64 (matches the `deployment/current`
/// storage shape and the `id` POST /deployments returns). 400 on
/// non-hex input; 404 when the id was never deployed (e.g. cleaned
/// up by retention) or the instance has no deploys yet.
fn handleGetDeployment(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    id_str: []const u8,
) !void {
    if (id_str.len == 0) {
        try setResponse(server, cfg, ent, sid, sess, 400, null, "missing deployment id\n");
        return;
    }
    const deployment_id = std.fmt.parseInt(u64, id_str, 16) catch {
        try setResponse(server, cfg, ent, sid, sess, 400, null, "invalid deployment id (want hex)\n");
        return;
    };

    var manifest = files_server.loadDeployment(allocator, cfg.blob_cfg, instance_id, deployment_id) catch |err| {
        const code: u16 = switch (err) {
            files_server.Error.NotFound => 404,
            else => 500,
        };
        const msg = try std.fmt.allocPrint(
            allocator,
            "loadDeployment failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponse(server, cfg, ent, sid, sess, code, msg.ptr, msg);
        return;
    };
    defer manifest.deinit();

    const body = try encodeListJson(allocator, &manifest);
    try setResponse(server, cfg, ent, sid, sess, 200, body.ptr, body);
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
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    file_path: []const u8,
) !void {
    if (file_path.len == 0) {
        try setResponse(server, cfg, ent, sid, sess, 400, null, "empty file path\n");
        return;
    }

    var content = files_server.readFileByPath(allocator, cfg.data_dir, cfg.blob_cfg, instance_id, file_path) catch |err| {
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
        try setResponse(server, cfg, ent, sid, sess, code, msg.ptr, msg);
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
    try setResponse(server, cfg, ent, sid, sess, 200, body.ptr, body);
}

fn handlePutFile(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    file_path: []const u8,
    content_type: []const u8,
    rb: h2.ReqBody,
) !void {
    if (file_path.len == 0) {
        try setResponse(server, cfg, ent, sid, sess, 400, null, "empty file path\n");
        return;
    }
    const body: []const u8 = if (rb.data != null) rb.data.?[0..rb.len] else "";

    const dep_id = files_server.putFileAndDeploy(
        allocator,
        cfg.data_dir,
        cfg.blob_cfg,
        instance_id,
        file_path,
        body,
        content_type,
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
        try setResponse(server, cfg, ent, sid, sess, code, msg.ptr, msg);
        return;
    };

    const body_out = try std.fmt.allocPrint(allocator, "{d}\n", .{dep_id});
    try setResponse(server, cfg, ent, sid, sess, 201, body_out.ptr, body_out);
}

fn handleSource(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    instance_id: []const u8,
    hash: []const u8,
) !void {
    if (hash.len == 0) {
        try setResponse(server, cfg, ent, sid, sess, 400, null, "missing hash\n");
        return;
    }

    const bytes = files_server.getSourceByHash(allocator, cfg.blob_cfg, instance_id, hash) catch |err| {
        const code: u16 = if (err == files_server.Error.NotFound) 404 else 500;
        const msg = try std.fmt.allocPrint(
            allocator,
            "source fetch failed: {s}\n",
            .{@errorName(err)},
        );
        try setResponse(server, cfg, ent, sid, sess, code, msg.ptr, msg);
        return;
    };
    try setResponse(server, cfg, ent, sid, sess, 200, bytes.ptr, bytes);
}

/// Application-defined envelope type for files-server's manifest
/// writeset. Library reserves 0 (writeset, leader-skip) and 1
/// (multi); files-server uses 2 with `leader_skip = false` so the
/// leader applies the writeset same as followers — simpler than
/// loop46's TrackedTxn pre-write pattern, fits deploy-shaped
/// workloads where commit latency dominates anyway.
pub const ENVELOPE_FILES_WRITESET: u8 = 2;

/// Default timeout for `proposeAndWait` calls from request handlers.
/// Deploy commits are bounded by raft commit latency (sub-second
/// typical, multi-second on bursty clusters); 10s leaves lots of
/// headroom while still bounding the request handler's wait.
const PROPOSE_TIMEOUT_NS: u64 = 10 * std.time.ns_per_s;

/// Tiny, robust JSON-object pull-parser for the small handful of
/// debug-endpoint payloads. Looks for `"<key>":"<value>"` and
/// returns the unquoted value bytes (no escape handling — caller
/// passes plain ASCII). Returns null when the key isn't present.
fn jsonStringField(body: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, needle) orelse return null;
    const value_start = start + needle.len;
    const end = std.mem.indexOfScalarPos(u8, body, value_start, '"') orelse return null;
    return body[value_start..end];
}

/// `POST /_system/cluster-put` — debug helper. Body is JSON
/// `{"store":..., "key":..., "value":...}`. Builds a WriteSet,
/// wraps in `ENVELOPE_FILES_WRITESET`, proposes through raft,
/// waits for commit. Smoke verifies the value lands in every
/// node's local cluster store.
fn handleClusterPut(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    cluster: *kv.Cluster,
    rb: h2.ReqBody,
) !void {
    const body = if (rb.data) |d| d[0..rb.len] else "";
    const store_id = jsonStringField(body, "store") orelse {
        try setResponse(server, cfg, ent, sid, sess, 400, null, "missing 'store' field\n");
        return;
    };
    const key = jsonStringField(body, "key") orelse {
        try setResponse(server, cfg, ent, sid, sess, 400, null, "missing 'key' field\n");
        return;
    };
    const value = jsonStringField(body, "value") orelse {
        try setResponse(server, cfg, ent, sid, sess, 400, null, "missing 'value' field\n");
        return;
    };

    var ws = kv.WriteSet.init(allocator);
    defer ws.deinit();
    ws.addPut(key, value) catch {
        try setResponse(server, cfg, ent, sid, sess, 500, null, "writeset alloc failed\n");
        return;
    };

    const ws_bytes = ws.encode(allocator) catch {
        try setResponse(server, cfg, ent, sid, sess, 500, null, "writeset encode failed\n");
        return;
    };
    defer allocator.free(ws_bytes);

    const env = kv.encodeEnvelope(allocator, ENVELOPE_FILES_WRITESET, store_id, ws_bytes) catch {
        try setResponse(server, cfg, ent, sid, sess, 500, null, "envelope encode failed\n");
        return;
    };
    defer allocator.free(env);

    const seq = cluster.proposeAndWait(env, PROPOSE_TIMEOUT_NS) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NotLeader => "not leader\n",
            error.ShuttingDown => "shutting down\n",
            error.QueueFull => "raft queue full\n",
            error.ProposalTimedOut => "proposal timed out\n",
            error.OutOfMemory => "out of memory\n",
        };
        try setResponse(server, cfg, ent, sid, sess, 503, null, msg);
        return;
    };

    var line_buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "committed at seq={d}\n", .{seq}) catch unreachable;
    const out = try allocator.alloc(u8, line.len);
    @memcpy(out, line);
    try setResponse(server, cfg, ent, sid, sess, 200, out.ptr, out);
}

/// `GET /_system/cluster-get/<store>/<key>` — debug helper.
/// Reads from the local cluster store (no raft round-trip). The
/// store is opened lazily on first read; if no apply has ever
/// happened for this store on this node, the store doesn't exist
/// and we return 404 (the kv miss path).
fn handleClusterGet(
    server: *CodeH2,
    allocator: std.mem.Allocator,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    cluster: *kv.Cluster,
    path: []const u8,
) !void {
    // Strip prefix.
    const tail = path["/_system/cluster-get/".len..];
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse {
        try setResponse(server, cfg, ent, sid, sess, 400, null, "want path /_system/cluster-get/<store>/<key>\n");
        return;
    };
    const store_id = tail[0..slash];
    const key = tail[slash + 1 ..];
    if (store_id.len == 0 or key.len == 0) {
        try setResponse(server, cfg, ent, sid, sess, 400, null, "empty store or key\n");
        return;
    }

    const store = cluster.openStore(store_id) catch {
        try setResponse(server, cfg, ent, sid, sess, 500, null, "store open failed\n");
        return;
    };
    const value = store.get(key) catch |err| switch (err) {
        error.NotFound => {
            try setResponse(server, cfg, ent, sid, sess, 404, null, "key not found\n");
            return;
        },
        else => {
            try setResponse(server, cfg, ent, sid, sess, 500, null, "store read failed\n");
            return;
        },
    };
    // KvStore.get returns allocator-owned bytes; transfer to the
    // response buffer + free the original.
    const out = try allocator.alloc(u8, value.len);
    @memcpy(out, value);
    allocator.free(value);
    try setResponse(server, cfg, ent, sid, sess, 200, out.ptr, out);
}

/// Stamp a Status + RespBody + friends onto the entity and move it
/// from request_out to response_in. The body bytes are transferred
/// into the RespBody component; ownership passes to rove-h2 which
/// frees them after sending. Passing `body_ptr = null` is fine for
/// empty responses. CORS allow-origin (when configured) is added.
fn setResponse(
    server: *CodeH2,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    status: u16,
    body_ptr: ?[*]u8,
    body_slice: []const u8,
) !void {
    const headers = try buildResponseHeaders(server.reg.allocator, cfg, .normal);
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = status });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, headers);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{
        .data = body_ptr,
        .len = @intCast(body_slice.len),
    });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

/// CORS preflight response — 204 with the full allow-set so the
/// browser caches the policy for `max-age` seconds.
fn setPreflight(
    server: *CodeH2,
    cfg: *const Config,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
) !void {
    const headers = try buildResponseHeaders(server.reg.allocator, cfg, .preflight);
    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 204 });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, headers);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = null, .len = 0 });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
}

const ResponseKind = enum { normal, preflight };

const HdrPair = struct { name: []const u8, value: []const u8 };

fn buildResponseHeaders(allocator: std.mem.Allocator, cfg: *const Config, kind: ResponseKind) !h2.RespHeaders {
    const origin = cfg.cors_origin orelse return .{ .fields = null, .count = 0 };
    var pairs: [5]HdrPair = undefined;
    var n: usize = 0;
    pairs[n] = .{ .name = "access-control-allow-origin", .value = origin };
    n += 1;
    pairs[n] = .{ .name = "vary", .value = "origin" };
    n += 1;
    if (kind == .preflight) {
        pairs[n] = .{ .name = "access-control-allow-methods", .value = "GET, POST, PUT, DELETE, OPTIONS" };
        n += 1;
        pairs[n] = .{ .name = "access-control-allow-headers", .value = "authorization, content-type, x-rove-path" };
        n += 1;
        pairs[n] = .{ .name = "access-control-max-age", .value = "600" };
        n += 1;
    }
    return packHeaders(allocator, pairs[0..n]);
}

fn packHeaders(allocator: std.mem.Allocator, pairs: []const HdrPair) !h2.RespHeaders {
    if (pairs.len == 0) return .{ .fields = null, .count = 0 };
    const fields_size = pairs.len * @sizeOf(h2.HeaderField);
    var str_size: usize = 0;
    for (pairs) |p| str_size += p.name.len + p.value.len;

    const buf = try allocator.alloc(u8, fields_size + str_size);
    errdefer allocator.free(buf);
    const fields_ptr: [*]h2.HeaderField = @ptrCast(@alignCast(buf.ptr));
    var off: usize = fields_size;
    for (pairs, 0..) |p, i| {
        const name_start = off;
        @memcpy(buf[off..][0..p.name.len], p.name);
        off += p.name.len;
        const value_start = off;
        @memcpy(buf[off..][0..p.value.len], p.value);
        off += p.value.len;
        fields_ptr[i] = .{
            .name = buf[name_start..].ptr,
            .name_len = @intCast(p.name.len),
            .value = buf[value_start..].ptr,
            .value_len = @intCast(p.value.len),
        };
    }
    return .{ .fields = fields_ptr, .count = @intCast(pairs.len) };
}

fn cleanupResponses(server: *CodeH2) !void {
    const entities = server.response_out.entitySlice();
    for (entities) |ent| {
        try server.reg.destroy(ent);
    }
}
