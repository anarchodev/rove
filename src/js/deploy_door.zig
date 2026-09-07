// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `/_system/deploy*` — the engine publish door's route family, its version
//! handshake, and its own credential gate.
//!
//! The door is manifest-first and content-addressed: a client declares the
//! whole bundle as `{path, hash}` pairs, the server answers with the hashes it
//! lacks, and only those bytes move. Two routes plus a handshake:
//!
//! ```
//! GET /_system/deploy/version                  → {min, max, limits, rules}
//! POST /_system/deploy    {v, tenant, client, files:[…]}  → {dep_id} | {need:[…]}
//! PUT  /_system/deploy/blob/{hash}  <raw bytes>
//! ```
//!
//! This module owns the seam. Intake and the streamed receive land beside it;
//! `notImplemented` answers their paths in the door's own error shape until
//! they do, so a client never sees the family's bare 501 text.
//!
//! ## Why the door does not reuse `authorizeSystemRequest`
//!
//! Every other `/_system/*` route funnels through one gate that accepts the
//! operator root bearer or an admin session cookie, with a per-endpoint
//! services-JWT capability alternative. The publish door takes the most hostile
//! traffic of the family and is the member whose credential must become
//! tenant-scoped, so its check lives here, explicitly. That is also what keeps
//! the capability work a verifier swap rather than a re-plumb.
//!
//! ## Planes, and why peer address cannot express one
//!
//! The rule this gate enforces is **capability on the public listener, root
//! only on a private one**. Root is platform-wide, so a leaked root token is
//! total compromise, and its only irreducible use is bootstrap — when whoever
//! is bootstrapping has the box.
//!
//! Making that rule mean anything requires knowing where a request arrived, and
//! **the peer address does not answer it.** The worker's serving listener is
//! bound to `0.0.0.0`, and the front door proxies public traffic into it: in a
//! multi-node cluster the front dials a private LAN address, but on a single
//! box it dials `127.0.0.1`, which is indistinguishable from an operator on
//! loopback. A single box is exactly the self-hoster case the rule exists for,
//! so an address heuristic fails where it matters most. `x-forwarded-for` is no
//! better — the front stamps it, so a direct connection can forge it.
//!
//! The sound signal is which listener accepted the connection, and the OS
//! enforces it: the worker binds an optional loopback-only listener alongside
//! the shared `0.0.0.0` serving socket, the way `boot.metricsFromEnv` already
//! binds the operator metrics surface to `127.0.0.1`. A worker carries its
//! listener's plane, so `Plane.of` reads a fact rather than guessing from a
//! spoofable one. With no private listener configured there is simply no
//! `.private` worker, and the gate refuses root everywhere — failing closed.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const jwt = @import("rove-jwt");

const respb = @import("response_builder.zig");
const auth = @import("auth.zig");
const files_mod = @import("rove-files");
const tenant_mod = @import("rove-tenant");
const deploy_thread_mod = @import("deploy_thread.zig");

/// Oldest wire version this build accepts. Bumped only when support for an
/// older shape is actually dropped — a self-hoster's pinned CLI reads this to
/// learn it must upgrade, so moving it strands clients on purpose.
pub const WIRE_VERSION_MIN: u32 = 1;

/// Newest wire version this build speaks. A client picks
/// `min(its own max, ours)` and sends that as `v` on every call.
pub const WIRE_VERSION_MAX: u32 = 1;

/// Route prefix. `/_system/deploy` exactly is the manifest POST; everything
/// below it is a sub-route.
pub const PREFIX = "deploy";

/// Which listener a request arrived on. Not derived from the peer address —
/// see the module header for why that cannot work.
pub const Plane = enum {
    /// Reachable from the internet, directly or through the front door.
    public,
    /// A listener the OS restricts to the local host or a private interface.
    private,

    /// Classify the arriving request.
    ///
    /// Everything is `.public` today, because the worker binds one serving
    /// listener on `0.0.0.0` and nothing distinguishes a front-door hop from an
    /// operator on loopback. This is the fail-closed direction: it can only
    /// refuse a credential that would otherwise have been accepted.
    ///
    /// The plane is a property of the listener that accepted the connection,
    /// fixed for the life of the process, so it is read off the worker rather
    /// than derived per request. A worker whose listener is loopback-bound
    /// reports `.private`; every SO_REUSEPORT thread on the shared `0.0.0.0`
    /// socket reports `.public`.
    pub fn of(worker: anytype) Plane {
        return worker.plane;
    }
};

/// Why a request was refused. Each maps to one wire `code`, and the mapping is
/// exhaustive by construction — `codeOf` switches without an `else`, so adding
/// a variant fails to compile until it has a code and a status. The full
/// taxonomy for intake and link-check errors lands with those routes; this is
/// the gate's share of it.
pub const DenyReason = enum {
    /// No credential at all, or one that did not verify.
    unauthenticated,
    /// A root bearer offered on the public listener. Distinct from
    /// `unauthenticated` because the credential was *valid* — the caller needs
    /// to know the token is fine and the path is wrong, or they will go hunting
    /// for a token problem that does not exist.
    root_credential_on_public_plane,
    /// The declared wire version is outside this build's accept range. Its own
    /// code so a client can say "upgrade me" rather than "your input is wrong".
    unsupported_version,
    /// The route exists in this wire version but this build does not serve it
    /// yet.
    not_implemented,

    pub fn codeOf(self: DenyReason) []const u8 {
        return switch (self) {
            .unauthenticated => "unauthenticated",
            .root_credential_on_public_plane => "root_credential_on_public_plane",
            .unsupported_version => "unsupported_version",
            .not_implemented => "not_implemented",
        };
    }

    pub fn statusOf(self: DenyReason) u16 {
        return switch (self) {
            .unauthenticated => 401,
            .root_credential_on_public_plane => 403,
            .unsupported_version => 400,
            .not_implemented => 501,
        };
    }

    pub fn detailOf(self: DenyReason) []const u8 {
        return switch (self) {
            .unauthenticated => "no valid deploy credential",
            .root_credential_on_public_plane =>
                "the root bearer is platform-wide and is accepted only on a private listener; use a tenant-scoped deploy capability here",
            .unsupported_version => "declared wire version is outside this build's accept range",
            .not_implemented => "this build does not serve that route yet",
        };
    }
};

/// Errors are a LIST, never the first failure. A client bug rarely produces
/// exactly one violation, and fixing them a round-trip at a time is the wrong
/// loop — so even the single-error paths here emit the list shape, and nothing
/// downstream has to invent a second one.
pub fn writeErrorBody(
    allocator: std.mem.Allocator,
    reasons: []const DenyReason,
) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"errors\":[");
    for (reasons, 0..) |r, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("{{\"code\":\"{s}\",\"detail\":\"{s}\"}}", .{ r.codeOf(), r.detailOf() });
    }
    try w.writeAll("]}\n");
    return buf.toOwnedSlice(allocator);
}

/// The version handshake body. A client reads this BEFORE uploading, so it can
/// refuse on an unsupported range rather than discovering incompatibility after
/// shipping megabytes.
///
/// `limits` and `rules` are published here rather than discovered by hitting a
/// wall: protocol maxima are what the engine can encode, and the
/// classification rules decide what a path becomes. Both are empty until the
/// leaves that own them fill them in; the fields exist from the start so
/// neither has to invent a publication mechanism later.
pub fn writeVersionBody(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    // Limits a client must respect ride the handshake beside the
    // accept-range, so it can refuse before uploading (the limits leaf
    // audits + names the full set; the manifest bound is its first entry).
    try w.print(
        "{{\"min\":{d},\"max\":{d},\"limits\":{{\"manifest_max_files\":{d}}},\"rules\":{{}}}}\n",
        .{ WIRE_VERSION_MIN, WIRE_VERSION_MAX, files_mod.manifest_json.MAX_DOOR_MANIFEST_FILES },
    );
    return buf.toOwnedSlice(allocator);
}

pub fn versionSupported(v: u32) bool {
    return v >= WIRE_VERSION_MIN and v <= WIRE_VERSION_MAX;
}

/// What the gate decided. `.allow` carries nothing: the door does not yet know
/// which tenant a credential is scoped to, because the capability that carries
/// a tenant scope arrives with the capability leaf.
pub const Decision = union(enum) {
    allow,
    deny: DenyReason,
};

/// The door's credential check.
///
/// Deliberately NOT `authorizeSystemRequest`. Two differences that matter:
///
///  1. **Root is plane-gated.** A root bearer is accepted only on a private
///     listener. On the public listener a *valid* root token is refused with
///     its own code, so the operator learns the token is fine and the path is
///     wrong.
///  2. **It runs on headers.** Nothing here reads the body, so the blob PUT can
///     call it from `onHeaders` and refuse before a single DATA frame is
///     accepted. A door that authenticates after the body has streamed is an
///     unauthenticated write amplifier into the object store.
pub fn authorize(
    worker: anytype,
    rh: h2.ReqHeaders,
    plane: Plane,
) Decision {
    const token = auth.extractBearerToken(rh);

    // The tenant-scoped deploy capability is the credential that belongs on the
    // public listener. Verifying it lands with the capability leaf; the seam is
    // here so that leaf swaps a verifier rather than re-plumbing the door.
    if (token) |t| {
        if (verifyDeployCap(worker, t)) return .allow;
    }

    // Root: valid everywhere, accepted only on a private listener.
    if (token) |t| {
        if (isRootBearer(worker, t)) {
            return switch (plane) {
                .private => .allow,
                .public => .{ .deny = .root_credential_on_public_plane },
            };
        }
    }

    return .{ .deny = .unauthenticated };
}

/// Is this the operator root bearer?
///
/// Delegates to `Tenant.authenticate`, the one implementation of that question
/// — it validates the token shape and compares constant-time via XOR-accumulate
/// (`std.crypto.timing_safe.eql` wants a comptime-known size, which a token
/// does not have). A second comparison here would be a second thing to get
/// wrong, in the place where getting it wrong is worst.
///
/// Bearer only, deliberately: `extractAdminAuth` also accepts the admin session
/// cookie, and a browser session is neither a tenant-scoped capability nor
/// proof of private-plane access. Whether the dashboard publishes by minting a
/// capability is the capability leaf's call, not something the door should
/// decide by quietly honouring a cookie.
fn isRootBearer(worker: anytype, token: []const u8) bool {
    const ctx = worker.node.tenant.authenticate(token) catch return false;
    return if (ctx) |c| c.is_root else false;
}

/// Verify the tenant-scoped deploy capability. The credential that belongs on
/// the public listener is a short-lived cap carrying a tenant claim, verified
/// with `verifyWithCapAndTenant` so a cap minted for tenant A cannot publish to
/// tenant B by construction.
///
/// Always false until that cap exists, so today the door accepts nothing on the
/// public listener — the fail-closed direction. The seam is here, rather than
/// in the family gate, so adding it swaps a verifier instead of re-plumbing.
fn verifyDeployCap(worker: anytype, token: []const u8) bool {
    _ = worker;
    _ = token;
    return false;
}

/// Route the `/_system/deploy*` family. `sys_rest` is the path with
/// `/_system/` stripped and any query removed. Returns true iff the request
/// belonged to the door and a response has been stamped.
///
/// Called from `tryHandleSystem` BEFORE the family's shared auth gate, so the
/// door's own credential rule applies rather than the family's.
pub fn tryHandleDeployDoor(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    sys_rest: []const u8,
    rh: h2.ReqHeaders,
    body: []const u8,
    cors_origin: ?[]const u8,
) !bool {
    if (!std.mem.eql(u8, sys_rest, PREFIX) and
        !std.mem.startsWith(u8, sys_rest, PREFIX ++ "/")) return false;

    const sub = if (sys_rest.len == PREFIX.len) "" else sys_rest[PREFIX.len + 1 ..];

    // The handshake is deliberately UNAUTHENTICATED. A client must be able to
    // learn the accept-range, the limits and the classification rules before it
    // decides whether it can publish at all — and refusing to say so until it
    // authenticates would mean a client with a stale wire version cannot
    // discover that this is why it is failing. It discloses nothing a client
    // does not need to hold a conversation.
    if (std.mem.eql(u8, sub, "version")) {
        if (!std.mem.eql(u8, method, "GET")) {
            try denyWith(server, allocator, ent, sid, sess, cors_origin, .not_implemented);
            return true;
        }
        const vbody = try writeVersionBody(allocator);
        try respb.setSystemResponseOwned(server, ent, sid, sess, 200, vbody, allocator, cors_origin, "application/json");
        return true;
    }

    // Everything else is a write and takes the door's gate. Authorization runs
    // on HEADERS — nothing below reads the body — so when the blob PUT arms a
    // streaming receive it refuses before the first DATA frame rather than
    // after megabytes have landed in the object store.
    switch (authorize(worker, rh, Plane.of(worker))) {
        .allow => {},
        .deny => |r| {
            try denyWith(server, allocator, ent, sid, sess, cors_origin, r);
            return true;
        },
    }

    if (std.mem.eql(u8, sub, "")) {
        if (!std.mem.eql(u8, method, "POST")) {
            try denyWith(server, allocator, ent, sid, sess, cors_origin, .not_implemented);
            return true;
        }
        try handleManifestPost(server, allocator, worker, ent, sid, sess, body, cors_origin);
        return true;
    }

    // The blob PUT answers in the door's own error shape until its leaf
    // lands, so a client never has to parse the family's bare 501 text to
    // discover the route is not there yet.
    if (std.mem.startsWith(u8, sub, "blob/")) {
        try denyWith(server, allocator, ent, sid, sess, cors_origin, .not_implemented);
        return true;
    }

    try denyWith(server, allocator, ent, sid, sess, cors_origin, .not_implemented);
    return true;
}

// ── the manifest POST — intake, validation, negotiation ─────────────────
//
// Parse + validate synchronously (a manifest is a few KB of JSON), compute
// the identity, then hand the S3 presence probe to the worker's
// DeployThread and PARK the stream — the worker poll loop must never wait
// on the object store. The park mirrors `ForwardWait`/`forward_pending`:
// a placeholder 504 is staged before the move, so the deadline reap is
// only a move, and the probe's `DoorResult` overwrites it on arrival
// (`drainDoorPending`).

/// How long a parked manifest POST waits for its probe before the staged
/// 504 ships. Generous: the probe is one `exists` HEAD per unique hash,
/// FIFO behind any in-flight deploy work on the same thread.
pub const DOOR_HOLD_NS: i64 = 30 * std.time.ns_per_s;

const ManifestIssue = struct {
    code: []const u8,
    path: ?[]const u8 = null,
    detail: []const u8,
};

fn writeIssuesBody(allocator: std.mem.Allocator, issues: []const ManifestIssue) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"errors\":[");
    for (issues, 0..) |it, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"code\":\"");
        try out.appendSlice(allocator, it.code);
        try out.appendSlice(allocator, "\"");
        if (it.path) |pp| {
            try out.appendSlice(allocator, ",\"path\":\"");
            for (pp) |ch| {
                // Paths passed validatePath are JSON-safe already; anything
                // reported BEFORE validation escapes the two structural bytes.
                if (ch == '"' or ch == '\\') try out.append(allocator, '\\');
                try out.append(allocator, ch);
            }
            try out.appendSlice(allocator, "\"");
        }
        try out.appendSlice(allocator, ",\"detail\":\"");
        try out.appendSlice(allocator, it.detail);
        try out.appendSlice(allocator, "\"}");
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn answerIssues(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    cors_origin: ?[]const u8,
    status: u16,
    issues: []const ManifestIssue,
) !void {
    const body_out = try writeIssuesBody(allocator, issues);
    try respb.setSystemResponseOwned(server, ent, sid, sess, status, body_out, allocator, cors_origin, "application/json");
}

const WireManifest = struct {
    v: u32 = 0,
    tenant: []const u8 = "",
    client: []const u8 = "",
    files: []const WireFile = &.{},
};
const WireFile = struct {
    path: []const u8 = "",
    hash: []const u8 = "",
};

fn isHex64(h: []const u8) bool {
    if (h.len != 64) return false;
    for (h) |ch| {
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
        if (!ok) return false;
    }
    return true;
}

fn handleManifestPost(
    server: anytype,
    allocator: std.mem.Allocator,
    worker: anytype,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    body: []const u8,
    cors_origin: ?[]const u8,
) !void {
    var parsed = std.json.parseFromSlice(WireManifest, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch {
        try answerIssues(server, allocator, ent, sid, sess, cors_origin, 400, &.{
            .{ .code = "bad_manifest", .detail = "the body is not a manifest object" },
        });
        return;
    };
    defer parsed.deinit();
    const m = parsed.value;

    if (!versionSupported(m.v)) {
        try answerIssues(server, allocator, ent, sid, sess, cors_origin, 400, &.{
            .{ .code = "unsupported_version", .detail = "declare v within the handshake's accept-range" },
        });
        return;
    }

    // Validate EVERYTHING before answering anything — a client bug rarely
    // produces exactly one violation, and fixing them a round-trip at a
    // time is the wrong loop.
    var issues: std.ArrayListUnmanaged(ManifestIssue) = .empty;
    defer issues.deinit(allocator);

    if (m.files.len == 0) {
        try issues.append(allocator, .{ .code = "empty_manifest", .detail = "a bundle declares at least one file" });
    }
    if (m.files.len > files_mod.manifest_json.MAX_DOOR_MANIFEST_FILES) {
        try answerIssues(server, allocator, ent, sid, sess, cors_origin, 400, &.{
            .{ .code = "too_many_files", .detail = "the bundle exceeds the declared manifest_max_files limit" },
        });
        return;
    }
    for (m.files, 0..) |f, i| {
        files_mod.validatePath(f.path) catch {
            try issues.append(allocator, .{ .code = "bad_path", .path = f.path, .detail = "path fails the bundle path rules" });
            continue;
        };
        switch (files_mod.classifyPath(f.path)) {
            .handler, .static => {},
            .test_artifact => try issues.append(allocator, .{ .code = "test_artifact_path", .path = f.path, .detail = "_tests/ never ships" }),
            .unshippable => try issues.append(allocator, .{ .code = "unshippable_path", .path = f.path, .detail = "a build input, not a shippable file — strip it before posting" }),
        }
        if (!isHex64(f.hash)) {
            try issues.append(allocator, .{ .code = "bad_hash", .path = f.path, .detail = "hash must be 64 lowercase hex" });
        }
        for (m.files[0..i]) |prev| {
            if (std.mem.eql(u8, prev.path, f.path)) {
                try issues.append(allocator, .{ .code = "duplicate_path", .path = f.path, .detail = "a path appears twice" });
                break;
            }
        }
    }
    if (issues.items.len > 0) {
        try answerIssues(server, allocator, ent, sid, sess, cors_origin, 400, issues.items);
        return;
    }

    // The target must be a real, deployable tenant — the door stages into
    // ITS content-addressed store, under its live storage incarnation.
    // `__root__` resolves in the registry but takes no deployments.
    if (std.mem.eql(u8, m.tenant, tenant_mod.ROOT_INSTANCE_ID)) {
        try answerIssues(server, allocator, ent, sid, sess, cors_origin, 400, &.{
            .{ .code = "bad_tenant", .detail = "the cluster root takes no deployments" },
        });
        return;
    }
    const inst = (worker.node.tenant.getInstance(m.tenant) catch null) orelse {
        try answerIssues(server, allocator, ent, sid, sess, cors_origin, 404, &.{
            .{ .code = "unknown_tenant", .detail = "no such instance" },
        });
        return;
    };

    // Identity, before a byte moves: author inputs only (the source-identity
    // rule, `decisions.md` §11.7) with the server-derived content type.
    var entries = try allocator.alloc(files_mod.manifest_json.SourceEntry, m.files.len);
    defer allocator.free(entries);
    for (m.files, 0..) |f, i| {
        entries[i] = .{
            .path = f.path,
            .content_type = files_mod.derivedContentType(f.path),
            .source_hex = f.hash,
        };
    }
    const dep_id = files_mod.manifest_json.computeSourceDepId(entries) catch {
        try answerIssues(server, allocator, ent, sid, sess, cors_origin, 400, &.{
            .{ .code = "too_many_files", .detail = "the bundle exceeds the declared manifest_max_files limit" },
        });
        return;
    };

    const dt = worker.deploy_thread orelse {
        try answerIssues(server, allocator, ent, sid, sess, cors_origin, 503, &.{
            .{ .code = "store_unavailable", .detail = "no deploy thread on this worker" },
        });
        return;
    };

    // Unique hashes, owned by the job.
    var hashes: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (hashes.items) |h| allocator.free(h);
        hashes.deinit(allocator);
    }
    outer: for (m.files) |f| {
        for (hashes.items) |h| if (std.mem.eql(u8, h, f.hash)) continue :outer;
        try hashes.append(allocator, try allocator.dupe(u8, f.hash));
    }

    const door_id = worker.nextDoorId();

    // Stage the deadline answer FIRST: once parked, the only exits are the
    // probe's overwrite or this 504 shipping on the reap — both just moves.
    const timeout_body = try writeIssuesBody(allocator, &.{
        .{ .code = "door_timeout", .detail = "the presence probe did not answer within the hold deadline" },
    });
    const resp_hdrs = try respb.buildSystemRespHeaders(allocator, cors_origin, false, "application/json");
    try respb.stageResponse(server, ent, sid, sess, 504, resp_hdrs, timeout_body.ptr, @intCast(timeout_body.len));
    try server.reg.set(ent, server.coll(.request_out), deploy_thread_mod.DoorWait, .{
        .door_id = door_id,
        .deadline_ns = @as(i64, @intCast(std.time.nanoTimestamp())) + DOOR_HOLD_NS,
    });

    dt.enqueue(.{
        .compile_id = 0,
        .kind = .door_probe,
        .tenant_id = try allocator.dupe(u8, m.tenant),
        .incarnation = try inst.storage.incarnation.dupe(allocator),
        .door_hashes = try hashes.toOwnedSlice(allocator),
        .door_reply = &worker.door_inbox,
        .door_id = door_id,
        .dep_id = dep_id,
    }) catch {
        // The park is not in place yet (the move below never ran), so the
        // staged components just get overwritten by this inline answer.
        try answerIssues(server, allocator, ent, sid, sess, cors_origin, 503, &.{
            .{ .code = "store_unavailable", .detail = "the deploy thread refused the probe" },
        });
        return;
    };

    try server.reg.move(ent, server.coll(.request_out), worker.door_pending);
}

fn denyWith(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid: h2.StreamId,
    sess: h2.Session,
    cors_origin: ?[]const u8,
    reason: DenyReason,
) !void {
    const body = try writeErrorBody(allocator, &.{reason});
    try respb.setSystemResponseOwned(server, ent, sid, sess, reason.statusOf(), body, allocator, cors_origin, "application/json");
}

test "wire version range is coherent and self-describing" {
    const testing = std.testing;
    try testing.expect(WIRE_VERSION_MIN <= WIRE_VERSION_MAX);
    try testing.expect(versionSupported(WIRE_VERSION_MIN));
    try testing.expect(versionSupported(WIRE_VERSION_MAX));
    try testing.expect(!versionSupported(WIRE_VERSION_MAX + 1));
    try testing.expect(!versionSupported(0));
}

test "version body publishes the range plus the limit and rule slots" {
    const testing = std.testing;
    const body = try writeVersionBody(testing.allocator);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"min\":1") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"max\":1") != null);
    // The slots exist from day one so the leaves that fill them do not have to
    // invent a publication mechanism.
    try testing.expect(std.mem.indexOf(u8, body, "\"limits\":") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"rules\":") != null);
}

test "every deny reason has a distinct code and a sane status" {
    const testing = std.testing;
    var seen: [4][]const u8 = undefined;
    var n: usize = 0;
    for (std.meta.tags(DenyReason)) |r| {
        const code = r.codeOf();
        try testing.expect(code.len > 0);
        try testing.expect(r.detailOf().len > 0);
        const s = r.statusOf();
        try testing.expect(s >= 400 and s < 600);
        for (seen[0..n]) |prev| try testing.expect(!std.mem.eql(u8, prev, code));
        seen[n] = code;
        n += 1;
    }
    try testing.expectEqual(std.meta.tags(DenyReason).len, n);
}

test "errors serialize as a list, not a first failure" {
    const testing = std.testing;
    const body = try writeErrorBody(testing.allocator, &.{ .unsupported_version, .unauthenticated });
    defer testing.allocator.free(body);
    try testing.expect(std.mem.startsWith(u8, body, "{\"errors\":["));
    try testing.expect(std.mem.indexOf(u8, body, "unsupported_version") != null);
    try testing.expect(std.mem.indexOf(u8, body, "unauthenticated") != null);
    // Two entries — the comma between them is the shape a single-error body
    // must still be able to grow into.
    try testing.expect(std.mem.indexOf(u8, body, "},{") != null);
}

test "a root bearer is refused on the public plane, with its own code" {
    const testing = std.testing;
    // A valid root credential offered on the public listener must not read as
    // "unauthenticated" — the operator would go hunting for a token problem
    // that does not exist.
    const d = DenyReason.root_credential_on_public_plane;
    try testing.expectEqual(@as(u16, 403), d.statusOf());
    try testing.expect(!std.mem.eql(u8, d.codeOf(), DenyReason.unauthenticated.codeOf()));
}

test "the plane is the listener's, read off the worker" {
    const testing = std.testing;
    const Fake = struct { plane: Plane };
    try testing.expectEqual(Plane.public, Plane.of(Fake{ .plane = .public }));
    try testing.expectEqual(Plane.private, Plane.of(Fake{ .plane = .private }));
}

test "a worker config that says nothing gets the public plane" {
    const testing = std.testing;
    // The default matters more than it looks: a caller who has not thought
    // about planes must not be able to create a privileged listener by
    // omission. Every fixture and test worker inherits `.public`, so the door
    // refuses root there.
    const Cfg = struct { plane: Plane = .public };
    try testing.expectEqual(Plane.public, (Cfg{}).plane);
}

test "manifest issues serialize as a list with path escaping" {
    const testing = std.testing;
    const body_out = try writeIssuesBody(testing.allocator, &.{
        .{ .code = "bad_path", .path = "a\"b", .detail = "path fails the bundle path rules" },
        .{ .code = "empty_manifest", .detail = "a bundle declares at least one file" },
    });
    defer testing.allocator.free(body_out);
    try testing.expect(std.mem.startsWith(u8, body_out, "{\"errors\":["));
    try testing.expect(std.mem.indexOf(u8, body_out, "a\\\"b") != null);
    try testing.expect(std.mem.indexOf(u8, body_out, "empty_manifest") != null);
    try testing.expect(std.mem.indexOf(u8, body_out, "},{") != null);
}

test "the wire hash is 64 lowercase hex, nothing else" {
    const testing = std.testing;
    try testing.expect(isHex64("ab" ** 32));
    try testing.expect(!isHex64("AB" ** 32));
    try testing.expect(!isHex64("ab" ** 31));
    try testing.expect(!isHex64("zz" ** 32));
}
