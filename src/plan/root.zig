//! rove-plan — per-tenant plan tiers + effective limits (docs/architecture/control-plane.md).
//!
//! A LEAF module (std only) so every consumer can import it without a cycle:
//! the worker (`rove-js`) resolves rate/body limits from it, and the
//! log-query surface (`rove-log-server`) resolves the retention window from it
//! (docs/architecture/control-plane.md Lever 3). It owns `RateLimitCaps` too — the limiter
//! re-exports it — so the table that maps a tier to its numbers lives in ONE
//! place reachable from both layers.
//!
//! A tenant's plan is `{tier, overrides}`: a named tier (the comptime table
//! baked here) plus optional per-field overrides for enterprise custom deals.
//! The CP stores the `{tier, overrides}` JSON blob verbatim and replicates it
//! (docs/v2-cp-operational-state.md); each consumer parses it into the
//! resolved limits it cares about — the worker caches `PlanLimits` on the
//! tenant's hot-path slot; the log-server reads `retention_days` per query.
//!
//! `rove` only ENFORCES tiers — setting one (Stripe → admin app → CP write)
//! is the product layer's job (docs/platform-accounts-model.md). This module
//! never knows what a dollar is; it only maps a tier name to numbers.
//!
//! ## The resolution rule
//!
//! `effective(tier, overrides)` folds `override ?? table(tier).field` per
//! field. Resolving at read-time (not set-time) means changing what "pro"
//! means is a one-line table edit, never a per-customer migration.

const std = @import("std");

/// Per-(instance, action) token-bucket caps. Lives here (not in the limiter)
/// so `rove-plan` stays a leaf the limiter can depend on; the limiter
/// re-exports it as `limiter.RateLimitCaps` for its existing callers.
pub const RateLimitCaps = struct {
    /// Burst cap: max requests accepted in a single instant from one instance.
    request_capacity: u32 = 1000,
    /// Sustained rate: requests per second the bucket refills at.
    request_refill_per_sec: u32 = 500,
    /// Burst cap on `email.send` calls from a handler.
    email_capacity: u32 = 100,
    /// 10/sec → 600/min sustained — well under any sane Resend quota.
    email_refill_per_sec: u32 = 10,
};

/// The named tiers. Free is the default for any tenant with no CP plan blob.
/// `pro` / `enterprise` numbers below are launch placeholders — the concrete
/// figures are a product call (decisions.md §10.9 — a product call), not an
/// engineering one, and live here so changing them is a one-line edit.
pub const Tier = enum(u8) {
    free,
    pro,
    enterprise,

    /// Parse a tier name; unknown / absent → free (forward-compatible: a
    /// blob naming a tier this build doesn't know falls back to free rather
    /// than failing the request).
    pub fn parse(s: []const u8) Tier {
        if (std.mem.eql(u8, s, "pro")) return .pro;
        if (std.mem.eql(u8, s, "enterprise")) return .enterprise;
        return .free;
    }
};

/// The resolved limits a tenant is enforced against. Small + copyable —
/// cached by value behind an atomic pointer on the worker's slot.
pub const PlanLimits = struct {
    /// Per-(instance, action) token-bucket caps (Lever 1).
    rate: RateLimitCaps,
    /// Inbound request body ceiling — 413 above this (Lever 2).
    max_body_bytes: u32,
    /// Total raw (uncompressed) bytes of HTML documents a deployment may
    /// hold resident in worker RAM. The worker holds every HTML doc
    /// resident (gzip-compressed) so the serve path never touches blob
    /// storage; a deploy whose HTML exceeds this budget is rejected at
    /// load (Lever 2, sibling of max_body_bytes).
    max_resident_html_bytes: u32,
    /// Tape/log read-window in days — list/query clamp to the last N days
    /// (Lever 3; a read-path clamp, not GC).
    retention_days: u32,
};

/// The baked tier table. The single source of what each named tier means.
pub fn table(t: Tier) PlanLimits {
    return switch (t) {
        .free => .{
            .rate = .{
                .request_capacity = 1000,
                .request_refill_per_sec = 500,
                .email_capacity = 100,
                .email_refill_per_sec = 10,
            },
            // A few MB — generous-but-finite, coherent with the 256 KB
            // streaming QUEUE_BYTES_CAP (docs/architecture/control-plane.md Lever 2).
            .max_body_bytes = 4 * 1024 * 1024,
            .max_resident_html_bytes = 4 * 1024 * 1024,
            .retention_days = 7,
        },
        .pro => .{
            .rate = .{
                .request_capacity = 10_000,
                .request_refill_per_sec = 5_000,
                .email_capacity = 1_000,
                .email_refill_per_sec = 100,
            },
            .max_body_bytes = 32 * 1024 * 1024,
            .max_resident_html_bytes = 32 * 1024 * 1024,
            .retention_days = 30,
        },
        .enterprise => .{
            .rate = .{
                .request_capacity = 100_000,
                .request_refill_per_sec = 50_000,
                .email_capacity = 10_000,
                .email_refill_per_sec = 1_000,
            },
            .max_body_bytes = 256 * 1024 * 1024,
            .max_resident_html_bytes = 256 * 1024 * 1024,
            .retention_days = 365,
        },
    };
}

/// Sparse per-field overrides — every field optional. A null field falls
/// through to the tier table. Enterprise custom deals set the ones they need
/// without schema churn (decisions.md §10.9).
pub const Overrides = struct {
    request_capacity: ?u32 = null,
    request_refill_per_sec: ?u32 = null,
    email_capacity: ?u32 = null,
    email_refill_per_sec: ?u32 = null,
    max_body_bytes: ?u32 = null,
    max_resident_html_bytes: ?u32 = null,
    retention_days: ?u32 = null,
};

/// Fold overrides over the tier table: `override ?? table(tier).field`.
pub fn effective(tier: Tier, ov: Overrides) PlanLimits {
    var p = table(tier);
    if (ov.request_capacity) |v| p.rate.request_capacity = v;
    if (ov.request_refill_per_sec) |v| p.rate.request_refill_per_sec = v;
    if (ov.email_capacity) |v| p.rate.email_capacity = v;
    if (ov.email_refill_per_sec) |v| p.rate.email_refill_per_sec = v;
    if (ov.max_body_bytes) |v| p.max_body_bytes = v;
    if (ov.max_resident_html_bytes) |v| p.max_resident_html_bytes = v;
    if (ov.retention_days) |v| p.retention_days = v;
    return p;
}

/// Parse a CP plan blob (`{"tier":"pro","overrides":{…}}`) into resolved
/// limits. An empty blob, malformed JSON, or an unknown tier all resolve to
/// the FREE tier — the blob is operator/admin-authored, but a consumer must
/// never fail a request on a bad plan record (fail toward the free tier,
/// never toward unbounded). `overrides` is optional and sparse.
pub fn parseBlob(allocator: std.mem.Allocator, blob: []const u8) PlanLimits {
    const trimmed = std.mem.trim(u8, blob, " \t\r\n");
    if (trimmed.len == 0) return table(.free);
    const Doc = struct {
        tier: []const u8 = "free",
        overrides: Overrides = .{},
    };
    var parsed = std.json.parseFromSlice(Doc, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch {
        std.log.warn("plan: unparseable plan blob ({d} bytes) — defaulting to free tier", .{trimmed.len});
        return table(.free);
    };
    defer parsed.deinit();
    return effective(Tier.parse(parsed.value.tier), parsed.value.overrides);
}

/// Seconds of retention for a resolved plan — the read-clamp floor is
/// `now_ns - retentionNs(plan)` (docs/architecture/control-plane.md Lever 3).
pub fn retentionNs(p: PlanLimits) i64 {
    return @as(i64, p.retention_days) * std.time.ns_per_day;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "plan: free is the default tier table" {
    const f = table(.free);
    try testing.expectEqual(@as(u32, 1000), f.rate.request_capacity);
    try testing.expectEqual(@as(u32, 7), f.retention_days);
}

test "plan: tiers escalate the numbers" {
    try testing.expect(table(.pro).max_body_bytes > table(.free).max_body_bytes);
    try testing.expect(table(.enterprise).rate.request_refill_per_sec > table(.pro).rate.request_refill_per_sec);
    try testing.expect(table(.enterprise).retention_days > table(.pro).retention_days);
}

test "plan: effective folds sparse overrides over the table" {
    const p = effective(.pro, .{ .max_body_bytes = 999, .request_capacity = 7 });
    try testing.expectEqual(@as(u32, 999), p.max_body_bytes); // overridden
    try testing.expectEqual(@as(u32, 7), p.rate.request_capacity); // overridden
    // Unset fields fall through to the pro table.
    try testing.expectEqual(table(.pro).retention_days, p.retention_days);
    try testing.expectEqual(table(.pro).rate.email_capacity, p.rate.email_capacity);
}

test "plan: Tier.parse unknown → free" {
    try testing.expectEqual(Tier.pro, Tier.parse("pro"));
    try testing.expectEqual(Tier.enterprise, Tier.parse("enterprise"));
    try testing.expectEqual(Tier.free, Tier.parse("free"));
    try testing.expectEqual(Tier.free, Tier.parse("platinum")); // unknown
    try testing.expectEqual(Tier.free, Tier.parse(""));
}

test "plan: parseBlob round-trips tier + overrides" {
    const a = testing.allocator;
    {
        const p = parseBlob(a, "{\"tier\":\"pro\"}");
        try testing.expectEqual(table(.pro).max_body_bytes, p.max_body_bytes);
    }
    {
        const p = parseBlob(a, "{\"tier\":\"pro\",\"overrides\":{\"retention_days\":90}}");
        try testing.expectEqual(@as(u32, 90), p.retention_days);
        try testing.expectEqual(table(.pro).max_body_bytes, p.max_body_bytes);
    }
}

test "plan: parseBlob fails toward the free tier" {
    const a = testing.allocator;
    try testing.expectEqual(table(.free).max_body_bytes, parseBlob(a, "").max_body_bytes);
    try testing.expectEqual(table(.free).max_body_bytes, parseBlob(a, "   ").max_body_bytes);
    try testing.expectEqual(table(.free).max_body_bytes, parseBlob(a, "not json").max_body_bytes);
    try testing.expectEqual(table(.free).max_body_bytes, parseBlob(a, "{\"tier\":\"galaxy\"}").max_body_bytes);
}

test "plan: retentionNs scales days to ns" {
    try testing.expectEqual(@as(i64, 7) * std.time.ns_per_day, retentionNs(table(.free)));
    try testing.expectEqual(@as(i64, 365) * std.time.ns_per_day, retentionNs(table(.enterprise)));
}
