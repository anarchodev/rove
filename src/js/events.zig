//! SSE caps + plan-tier defaults + the `/_events` endpoint carve-out.
//! See docs/sse-plan.md §2.12 / §11d-f.
//!
//! This module owns the shape of the events subsystem's per-tenant
//! configuration and the front-door routing. The pump (the system
//! that actually drives connected EventSource streams from
//! `_events/{sid}/...` rows) lives in worker.zig as a phase, not
//! here — same shape as `flushLogs`, `dispatchCallbacks`, etc.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");

const respb = @import("response_builder.zig");
const session_mod = @import("session.zig");

/// Per-account plan tier. Lives here for now until the platform-wide
/// `tenant.PlanTier` lands in Phase 10 (PLAN §3 / §2.4 account model).
/// Switch to `tenant.PlanTier` once it exists; the values below are
/// the slice we need for SSE.
pub const PlanTier = enum { free, paid };

/// Per-instance / per-session caps for the SSE subsystem. Sized by
/// `eventsCapsForPlan(plan)` against PLAN §2.12's free / paid table.
/// One struct of fields keeps growing easy — adding a new cap is one
/// field plus one defaulting line per tier.
pub const EventsCaps = struct {
    // ── Hard ceilings ─────────────────────────────────────────
    /// Max simultaneous SSE connections one tenant may hold open.
    /// Above this, `/_events` returns 503.
    max_concurrent_connections_per_instance: u32,
    /// Max simultaneous EventSource connections one session may hold.
    /// Multi-tab sanity guard, not plan-tiered. Above this, the
    /// newest connect is refused 503.
    max_concurrent_connections_per_session: u32,
    /// Max `events.emit` calls per handler invocation. Customer JS
    /// gets `Error{code: "events_cap_exceeded"}` on the (cap+1)th call.
    max_emits_per_request: u32,
    /// Retention window for `_events/{sid}/...` rows. The pump's
    /// catch-up scan won't find rows older than this; the retention
    /// sweep removes them.
    retention_seconds: u32,
    /// Slow-consumer defense: if a single session has more rows than
    /// this in retention, oldest are dropped.
    max_events_per_session_in_retention: u32,
    /// Max envelope size (the JSON serialization of one emit). Customer
    /// JS gets `Error{code: "events_cap_exceeded"}` on oversize.
    max_event_payload_bytes: u32,

    // ── Rate-shape (token-bucket on RateLimiter) ─────────────
    /// `events_emit` token bucket fill rate (tokens/s).
    emit_rate_per_sec: u32,
    /// `events_emit` bucket size (burst capacity).
    emit_rate_burst: u32,
    /// `events_connect` token bucket fill rate.
    connect_rate_per_sec: u32,
    /// `events_connect` bucket size.
    connect_rate_burst: u32,
    /// `events_bytes_out` token bucket fill rate (bytes/s). Pump
    /// consumes from this before each wire write; empty bucket =
    /// pump skips that connection this tick (events stay in
    /// retention, deliver next tick).
    bytes_out_per_sec: u32,
    /// `events_bytes_out` bucket size.
    bytes_out_burst: u32,
};

/// Free-tier defaults. See PLAN §2.12 + sse-plan.md §4.2.
pub const FREE: EventsCaps = .{
    .max_concurrent_connections_per_instance = 100,
    .max_concurrent_connections_per_session = 16,
    .max_emits_per_request = 100,
    .retention_seconds = 300,
    .max_events_per_session_in_retention = 100,
    .max_event_payload_bytes = 64 * 1024,

    .emit_rate_per_sec = 100,
    .emit_rate_burst = 200,
    .connect_rate_per_sec = 5,
    .connect_rate_burst = 20,
    .bytes_out_per_sec = 64 * 1024,
    .bytes_out_burst = 256 * 1024,
};

/// Paid-tier defaults.
pub const PAID: EventsCaps = .{
    .max_concurrent_connections_per_instance = 10_000,
    .max_concurrent_connections_per_session = 16,
    .max_emits_per_request = 1_000,
    .retention_seconds = 3_600,
    .max_events_per_session_in_retention = 1_000,
    .max_event_payload_bytes = 256 * 1024,

    .emit_rate_per_sec = 10_000,
    .emit_rate_burst = 20_000,
    .connect_rate_per_sec = 100,
    .connect_rate_burst = 500,
    .bytes_out_per_sec = 4 * 1024 * 1024,
    .bytes_out_burst = 16 * 1024 * 1024,
};

/// Per-plan caps. v1 has free + paid only; same shape extends to
/// trial / enterprise tiers without touching call sites.
pub fn eventsCapsForPlan(plan: PlanTier) EventsCaps {
    return switch (plan) {
        .free => FREE,
        .paid => PAID,
    };
}

// ── /_events endpoint ─────────────────────────────────────────────

/// Front-door for the SSE endpoint. Returns true iff the request
/// matched (`GET /_events`) and was finalized. Mirrors the
/// `tryHandleSystem` shape so the worker_dispatch loop's branch
/// reads naturally.
///
/// **v1 SCOPE NOTE**: the response moves into `response_in`
/// immediately with headers + minted `Set-Cookie` and an empty body.
/// The streaming path (`stream_response_in` → pump → `stream_data_in`
/// → keepalive) lands in sub-phase 11e. Browsers connecting today
/// will see a clean 200 + the cookie set, but EventSource will
/// reconnect immediately because the response closes. That's
/// acceptable as a step — the cookie minting is the load-bearing
/// piece for cross-tenant isolation testing, and the test gates
/// established here will remain the same once the stream phase lands.
pub fn tryHandleEvents(
    server: anytype,
    allocator: std.mem.Allocator,
    ent: rove.Entity,
    sid_h2: h2.StreamId,
    sess: h2.Session,
    method: []const u8,
    path: []const u8,
    rh: h2.ReqHeaders,
    received_ns: i64,
) !bool {
    // Match `/_events` exactly (with optional `?query=...`). Sub-paths
    // like `/_events/foo` are NOT matched — the endpoint is a single
    // resource, not a tree.
    const qmark = std.mem.indexOfScalar(u8, path, '?');
    const path_no_q = if (qmark) |q| path[0..q] else path;
    if (!std.mem.eql(u8, path_no_q, "/_events")) return false;

    // Method gate. SSE is GET-only by convention; some clients may
    // try HEAD for readiness probing — answer 200 with no body.
    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "HEAD")) {
        try respb.setSimpleResponse(server, ent, sid_h2, sess, 405, "GET only\n", allocator);
        return true;
    }

    // Resolve / mint the session cookie. Mint policy + cookie shape
    // are defined in session.zig.
    var prng = std.Random.DefaultPrng.init(@bitCast(received_ns));
    const resolved = session_mod.resolve(rh, prng.random());

    // Build response headers: text/event-stream + cache-control: no-store
    // + (optional) Set-Cookie.
    const platform_cookie: ?[]u8 = if (resolved.mint_set_cookie)
        try session_mod.formatSetCookie(allocator, &resolved.sid)
    else
        null;
    defer if (platform_cookie) |pc| allocator.free(pc);

    var pairs_buf: [3]respb.RespHeaderPair = undefined;
    var n: usize = 0;
    pairs_buf[n] = .{ .name = "content-type", .value = "text/event-stream; charset=utf-8" };
    n += 1;
    pairs_buf[n] = .{ .name = "cache-control", .value = "no-store" };
    n += 1;
    if (platform_cookie) |pc| {
        pairs_buf[n] = .{ .name = "set-cookie", .value = pc };
        n += 1;
    }
    const hdrs = try respb.packRespHeaders(allocator, pairs_buf[0..n]);

    try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = 200 });
    try server.reg.set(ent, &server.request_out, h2.RespHeaders, hdrs);
    try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = null, .len = 0 });
    try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
    try server.reg.set(ent, &server.request_out, h2.StreamId, sid_h2);
    try server.reg.set(ent, &server.request_out, h2.Session, sess);
    try server.reg.move(ent, &server.request_out, &server.response_in);
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "eventsCapsForPlan: free vs paid" {
    const f = eventsCapsForPlan(.free);
    const p = eventsCapsForPlan(.paid);
    try testing.expect(p.max_concurrent_connections_per_instance > f.max_concurrent_connections_per_instance);
    try testing.expect(p.max_emits_per_request > f.max_emits_per_request);
    try testing.expect(p.retention_seconds > f.retention_seconds);
    try testing.expect(p.bytes_out_per_sec > f.bytes_out_per_sec);
    // Per-session connection cap is the same on both tiers — it's a
    // sanity guard against multi-tab abuse, not a plan-tier knob.
    try testing.expectEqual(f.max_concurrent_connections_per_session, p.max_concurrent_connections_per_session);
}
