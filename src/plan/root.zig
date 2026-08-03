// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
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
//! (operational state — docs/architecture/control-plane.md); each consumer parses it into the
//! resolved limits it cares about — the worker caches `PlanLimits` on the
//! tenant's hot-path slot; the log-server reads `retention_days` per query.
//!
//! `rove` only ENFORCES tiers — setting one (Stripe → admin app → CP write)
//! is the product layer's job (docs/strategy/platform-accounts-model.md). This module
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
    /// Burst cap on customer-initiated OUTBOUND calls from a handler —
    /// `on.fetch`, `http.fetch`, and the immediate fire of `webhook.send`
    /// / `email.send` (which composes over it). The platform's egress /
    /// third-party-bill guard, enforced at the frozen fetch primitive
    /// (`bindings/http.zig`) so a tenant-pinnable email/webhook package
    /// can't bypass it. Deferred webhook retries don't re-count.
    outbound_capacity: u32 = 100,
    /// 10/sec → 600/min sustained — well under any sane provider quota.
    outbound_refill_per_sec: u32 = 10,
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
    /// Ceiling on a tenant's durable KV bytes — the plan-derived form of the
    /// LMDB map size each tenant's `app.db` is opened at. KV is deliberate
    /// customer data, so the ceiling REFUSES the write; it never evicts, and
    /// it never bills elastically past the tier.
    max_kv_bytes: u64,
    /// Ceiling on a tenant's stored object bytes — the customer-written
    /// `app-blobs/` plus the deploy-written `file-blobs/`. Deliberate customer
    /// data, so the same rule as `max_kv_bytes`: refuse, never evict. Distinct
    /// from the `log-blobs/` pool, which is platform exhaust the customer never
    /// chose to write and where FIFO eviction at the ceiling is the fair
    /// answer.
    max_stored_bytes: u64,
    /// Ceiling on ONE `blob.receive` — the largest single object a tenant can
    /// create by streaming a request body straight into storage. A sibling of
    /// `max_body_bytes` rather than of `max_stored_bytes`: it bounds one
    /// write, not an accumulation. The inbound-body gate cannot serve here
    /// because that 413 sits below route resolution, so a module on the
    /// streaming path takes any-size bodies by design.
    ///
    /// A per-write ceiling is what makes the storage quota's overshoot
    /// bounded: without one, a single request can store past the quota by an
    /// unbounded amount instead of by one object.
    max_receive_bytes: u64,
};

/// `max_stored_bytes` for a tier whose storage figure is not yet a product
/// decision — arithmetically "no ceiling", so an ordinary `>` comparison at a
/// write path needs no sentinel special-case.
pub const UNMETERED_BYTES: u64 = std.math.maxInt(u64);

/// Every tier's `max_kv_bytes`. Uniform across tiers because a tenant's
/// `app.db` is a single LMDB env opened at one baked map size
/// (`src/kv/kvstore.zig`), so no tier can be sold more than this until that
/// size is itself plan-derived. The tier table may not name a larger figure
/// than the map it would have to fit in.
pub const KV_BYTES_CEILING: u64 = 1 * 1024 * 1024 * 1024;

/// Every tier's `max_receive_bytes` until the tier figures are set. 1 GiB
/// matches what the `blob.write` / `seal` recipe path already permits for one
/// object, so both large-write paths agree on how big a single object can get.
/// Uniform across tiers deliberately: differentiating it is a product call —
/// the same call that fills in the rest of the tier table — and holding it
/// uniform preserves today's behaviour until that call is made. An enterprise
/// deal can raise it now through `Overrides.max_receive_bytes` without touching
/// this table.
pub const RECEIVE_BYTES_DEFAULT: u64 = 1024 * 1024 * 1024;

/// The baked tier table. The single source of what each named tier means.
pub fn table(t: Tier) PlanLimits {
    return switch (t) {
        .free => .{
            .rate = .{
                .request_capacity = 1000,
                .request_refill_per_sec = 500,
                .outbound_capacity = 100,
                .outbound_refill_per_sec = 10,
            },
            // A few MB — generous-but-finite, coherent with the 256 KB
            // streaming QUEUE_BYTES_CAP (docs/architecture/control-plane.md Lever 2).
            .max_body_bytes = 4 * 1024 * 1024,
            .max_resident_html_bytes = 4 * 1024 * 1024,
            .retention_days = 7,
            .max_kv_bytes = KV_BYTES_CEILING,
            .max_stored_bytes = UNMETERED_BYTES,
            .max_receive_bytes = RECEIVE_BYTES_DEFAULT,
        },
        .pro => .{
            .rate = .{
                .request_capacity = 10_000,
                .request_refill_per_sec = 5_000,
                .outbound_capacity = 1_000,
                .outbound_refill_per_sec = 100,
            },
            .max_body_bytes = 32 * 1024 * 1024,
            .max_resident_html_bytes = 32 * 1024 * 1024,
            .retention_days = 30,
            .max_kv_bytes = KV_BYTES_CEILING,
            .max_stored_bytes = UNMETERED_BYTES,
            .max_receive_bytes = RECEIVE_BYTES_DEFAULT,
        },
        .enterprise => .{
            .rate = .{
                .request_capacity = 100_000,
                .request_refill_per_sec = 50_000,
                .outbound_capacity = 10_000,
                .outbound_refill_per_sec = 1_000,
            },
            .max_body_bytes = 256 * 1024 * 1024,
            .max_resident_html_bytes = 256 * 1024 * 1024,
            .retention_days = 365,
            .max_kv_bytes = KV_BYTES_CEILING,
            .max_stored_bytes = UNMETERED_BYTES,
            .max_receive_bytes = RECEIVE_BYTES_DEFAULT,
        },
    };
}

/// Sparse per-field overrides — every field optional. A null field falls
/// through to the tier table. Enterprise custom deals set the ones they need
/// without schema churn (decisions.md §10.9).
pub const Overrides = struct {
    request_capacity: ?u32 = null,
    request_refill_per_sec: ?u32 = null,
    outbound_capacity: ?u32 = null,
    outbound_refill_per_sec: ?u32 = null,
    max_body_bytes: ?u32 = null,
    max_resident_html_bytes: ?u32 = null,
    retention_days: ?u32 = null,
    max_kv_bytes: ?u64 = null,
    max_stored_bytes: ?u64 = null,
    max_receive_bytes: ?u64 = null,
};

/// Fold overrides over the tier table: `override ?? table(tier).field`.
pub fn effective(tier: Tier, ov: Overrides) PlanLimits {
    var p = table(tier);
    if (ov.request_capacity) |v| p.rate.request_capacity = v;
    if (ov.request_refill_per_sec) |v| p.rate.request_refill_per_sec = v;
    if (ov.outbound_capacity) |v| p.rate.outbound_capacity = v;
    if (ov.outbound_refill_per_sec) |v| p.rate.outbound_refill_per_sec = v;
    if (ov.max_body_bytes) |v| p.max_body_bytes = v;
    if (ov.max_resident_html_bytes) |v| p.max_resident_html_bytes = v;
    if (ov.retention_days) |v| p.retention_days = v;
    if (ov.max_kv_bytes) |v| p.max_kv_bytes = v;
    if (ov.max_stored_bytes) |v| p.max_stored_bytes = v;
    if (ov.max_receive_bytes) |v| p.max_receive_bytes = v;
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
    try testing.expectEqual(table(.pro).rate.outbound_capacity, p.rate.outbound_capacity);
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

test "plan: every tier carries both byte ceilings" {
    for ([_]Tier{ .free, .pro, .enterprise }) |t| {
        const p = table(t);
        // No tier may promise more KV than the map its `app.db` opens at.
        try testing.expect(p.max_kv_bytes <= KV_BYTES_CEILING);
        try testing.expect(p.max_kv_bytes > 0);
        try testing.expect(p.max_stored_bytes > 0);
    }
}

test "plan: effective folds the byte-ceiling overrides" {
    const p = effective(.enterprise, .{
        .max_kv_bytes = 512 * 1024 * 1024,
        .max_stored_bytes = 100 * 1024 * 1024 * 1024,
    });
    try testing.expectEqual(@as(u64, 512 * 1024 * 1024), p.max_kv_bytes);
    try testing.expectEqual(@as(u64, 100 * 1024 * 1024 * 1024), p.max_stored_bytes);
    // Unset fields still fall through to the enterprise table.
    try testing.expectEqual(table(.enterprise).retention_days, p.retention_days);
}

test "plan: parseBlob carries the byte ceilings" {
    const a = testing.allocator;
    const p = parseBlob(a, "{\"tier\":\"pro\",\"overrides\":{\"max_stored_bytes\":42}}");
    try testing.expectEqual(@as(u64, 42), p.max_stored_bytes);
    // A blob that names neither ceiling resolves to the tier's own figures.
    try testing.expectEqual(table(.pro).max_kv_bytes, p.max_kv_bytes);
    const bare = parseBlob(a, "{\"tier\":\"free\"}");
    try testing.expectEqual(table(.free).max_stored_bytes, bare.max_stored_bytes);
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
