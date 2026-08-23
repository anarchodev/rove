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
//! The sound signal is which listener accepted the connection, the way
//! `boot.metricsFromEnv` already binds the operator metrics surface to
//! `127.0.0.1` and lets the OS enforce it. Until the worker binds such a
//! listener, `Plane.of` reports `.public` for everything and the
//! gate refuses root — failing closed, so no deployment can quietly accept a
//! platform-wide credential from the internet on the strength of a heuristic.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const jwt = @import("rove-jwt");

const respb = @import("response_builder.zig");
const auth = @import("auth.zig");

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
    /// When the worker binds a private listener and threads its plane through
    /// `WorkerCtx` → `Worker`, this reports the accepting listener's own plane
    /// instead of a constant. Until both that listener and the tenant-scoped
    /// deploy capability exist, the door deliberately authenticates nobody.
    /// That is the safe direction to be incomplete in.
    pub fn of(_: anytype) Plane {
        return .public;
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
    try w.print(
        "{{\"min\":{d},\"max\":{d},\"limits\":{{}},\"rules\":{{}}}}\n",
        .{ WIRE_VERSION_MIN, WIRE_VERSION_MAX },
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
        const body = try writeVersionBody(allocator);
        try respb.setSystemResponseOwned(server, ent, sid, sess, 200, body, allocator, cors_origin, "application/json");
        return true;
    }

    // Everything else is a write and takes the door's gate. Authorization runs
    // on HEADERS — nothing below reads the body — so when the blob PUT arms a
    // streaming receive it refuses before the first DATA frame rather than
    // after megabytes have landed in the object store.
    switch (authorize(worker, rh, Plane.of(sess))) {
        .allow => {},
        .deny => |r| {
            try denyWith(server, allocator, ent, sid, sess, cors_origin, r);
            return true;
        },
    }

    // The manifest POST and the blob PUT answer in the door's own error shape
    // until their leaves land, so a client never has to parse the family's bare
    // 501 text to discover a route is not there yet.
    if (std.mem.eql(u8, sub, "") or std.mem.startsWith(u8, sub, "blob/")) {
        try denyWith(server, allocator, ent, sid, sess, cors_origin, .not_implemented);
        return true;
    }

    try denyWith(server, allocator, ent, sid, sess, cors_origin, .not_implemented);
    return true;
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

test "the plane is fail-closed while no private listener exists" {
    const testing = std.testing;
    // Documents the current derivation rather than asserting a permanent truth:
    // when the worker binds a private listener, this test changes with it.
    try testing.expectEqual(Plane.public, Plane.of({}));
}
