//! Per-tenant SSE caps + plan-tier defaults. Used by `sse_token` to
//! embed limits in the JWT it mints, so sse-server enforces caps at
//! connect time without a callback to the worker.
//!
//! After the legacy `/_events` worker route retired (sse-plan §7
//! step 7), this module no longer carries the route handler — it's
//! pure config.

const std = @import("std");

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
    /// Max simultaneous SSE connections one tenant may hold open
    /// against sse-server. Above this, the (cap+1)th connect is
    /// refused 503.
    max_concurrent_connections_per_instance: u32,
    /// Max simultaneous EventSource connections one session may hold.
    /// Multi-tab sanity guard, not plan-tiered. Above this, the
    /// newest connect is refused 503.
    max_concurrent_connections_per_session: u32,
    /// Max `events.emit` calls per handler invocation. Customer JS
    /// gets `Error{code: "events_cap_exceeded"}` on the (cap+1)th call.
    max_emits_per_request: u32,
    /// Retention window for ring-cache entries on sse-server. The
    /// catch-up replay won't find events older than this.
    retention_seconds: u32,
    /// Slow-consumer defense: ring-cache size cap per session.
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
    /// Per-connection bytes-out token bucket fill rate (bytes/s).
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
