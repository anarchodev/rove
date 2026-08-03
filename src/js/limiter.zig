// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Token-bucket rate limiter for noisy-neighbor protection (PLAN §2.10).
//!
//! Per-(instance, action) buckets. Each bucket has a capacity (the
//! maximum burst size) and a refill rate (tokens added per second).
//! `check` decrements one token if available and returns true; returns
//! false when the bucket is empty so the caller can reject (HTTP 429
//! for requests, JS exception for `email.send`, etc.).
//!
//! Per-worker, in-memory only — no cross-worker sync in v1. Multi-worker
//! setups effectively give each instance Nx the configured limit (one
//! bucket per worker); acceptable overshoot at launch scale. A future
//! iteration can periodically sync buckets via root.db.
//!
//! Per-tenant plan tiers: `check`/`checkN` take the tenant's plan-resolved
//! `RateLimitCaps` + `plan_gen` (from its `TenantSlot`, docs/architecture/control-plane.md
//! Lever 1). A bucket snapshots its caps at creation, so when the generation
//! moves (a tier change) `getOrCreate` re-inits the caps. Callers without a
//! resolved plan (test paths, async activations that never ran a request-rate
//! check) fall back to a default `RateLimitCaps{}`.
//!
//! Actions covered: `request` (per-instance inbound HTTP request budget,
//! protects the worker from a single noisy tenant) and `outbound`
//! (per-instance customer-initiated outbound-HTTP budget — `on.fetch`,
//! `http.fetch`, and the immediate fire of `webhook.send` / `email.send`;
//! protects the platform's egress reputation + third-party bill). The
//! outbound bucket is enforced at the frozen fetch primitive
//! (`bindings/http.zig`), not in a pinnable email/webhook shim, so a
//! tenant-pinnable package can't bypass it; deferred webhook retries
//! (`is_system_module` fires) don't re-count. Other actions in PLAN §2.10
//! (`deploy`, `kv_write`) are deferred — deploys are low-volume; kv_write
//! is a hot path with real per-call cost to add bucket math.
//!
//! Thread safety: not synchronized; each worker thread owns its own
//! RateLimiter. Same model as `penalty.zig`.

const std = @import("std");
const plan_mod = @import("rove-plan");

pub const Action = enum(u8) {
    request,
    outbound,
    /// Log-byte ingest rate — the ingest-rate guardrail
    /// (docs/strategy/pricing-model.md, throttle log-byte ingest RATE):
    /// bytes are the cost currency, so this bucket is denominated in RAW
    /// bytes, not calls. A LAGGING, post-exec bucket: a request whose log
    /// was already produced cannot be un-logged, so `charge` lands after
    /// execution (the bucket goes negative) and the NEXT admission pays
    /// for it via `hasCredit` → 429.
    log_bytes,
    /// The coarse SUSTAINED ceiling over `outbound` — the spam bound.
    /// The burst bucket is tuned for burst absorption, which makes its
    /// sustained rate the wrong shape for abuse: the free tier's 10/s
    /// held for a day is ~864k outbound calls from a tenant that cost an
    /// email address to create. This second, day-scale bucket bounds
    /// exactly that: capacity = a 10%-duty-cycle day of the plan's
    /// sustained rate (`sustainedOutboundBudget`), refilling at
    /// capacity/day. Checked at the same frozen-native funnel as
    /// `outbound`; saturating it is an incident signal, not a sales
    /// lead — the refusal carries a distinct error code and trips a
    /// counter an operator can alert on.
    outbound_sustained,
};

const ACTION_COUNT: usize = std.meta.fields(Action).len;

/// `log_bytes` bucket caps — uniform across tiers for now. `PlanLimits` is
/// the eventual home (the ingest-rate tier field), at which point these
/// become that field's free-tier figures; until then one conservative
/// number bounds every tenant's S3 log volume. 8 MiB of burst absorbs a
/// traffic spike's logs; 64 KiB/s sustained is ≈5.3 GiB/day — generous for
/// a legitimate tenant, a hard wall for a log flood.
pub const LOG_BYTES_CAPACITY: u32 = 8 * 1024 * 1024;
pub const LOG_BYTES_REFILL_PER_SEC: u32 = 64 * 1024;
/// The `k` in `effective_bytes = actual + k` per record: fixed per-request
/// overhead (index row, batch framing, S3 request amortization) is priced
/// rather than free, so a flood of tiny requests can't ride under the
/// byte meter.
pub const LOG_BYTES_PER_RECORD_OVERHEAD: u32 = 512;

/// A day's sustained outbound budget for a plan: a 10% duty cycle of the
/// burst bucket's refill rate held for 24h (free tier: 10/s → 86,400/day).
/// Derived from the existing caps rather than a new plan field for now;
/// when the tier table grows an explicit sustained figure this becomes
/// that field's fallback. Saturating so a pathological override can't wrap.
pub fn sustainedOutboundBudget(caps: RateLimitCaps) u32 {
    return caps.outbound_refill_per_sec *| 8640;
}

/// Re-exported from `rove-plan` (the leaf module that owns the tier table) so
/// the limiter's existing callers keep using `limiter.RateLimitCaps`, while the
/// definition lives in one place reachable from both the worker and the
/// log-query surface (docs/architecture/control-plane.md).
pub const RateLimitCaps = plan_mod.RateLimitCaps;

pub const TokenBucket = struct {
    /// Maximum tokens the bucket can hold.
    capacity: f64,
    /// Tokens added per second when not at capacity.
    refill_per_sec: f64,
    /// Current tokens. `f64` for accurate fractional refill across
    /// short intervals.
    tokens: f64,
    /// Last time we computed a refill. Wall-clock nanoseconds via
    /// `std.time.nanoTimestamp()`.
    last_refill_ns: i64,

    pub fn init(capacity: u32, refill_per_sec: u32, now_ns: i64) TokenBucket {
        return .{
            .capacity = @floatFromInt(capacity),
            .refill_per_sec = @floatFromInt(refill_per_sec),
            // Start full so a fresh tenant can immediately handle
            // a burst up to capacity.
            .tokens = @floatFromInt(capacity),
            .last_refill_ns = now_ns,
        };
    }

    /// Try to take `n` tokens. Returns true if the bucket had them
    /// (decremented by `n`); false if not (bucket unchanged beyond
    /// the refill).
    pub fn tryTake(self: *TokenBucket, n: f64, now_ns: i64) bool {
        self.refill(now_ns);
        if (self.tokens >= n) {
            self.tokens -= n;
            return true;
        }
        return false;
    }

    fn refill(self: *TokenBucket, now_ns: i64) void {
        const elapsed_ns = now_ns - self.last_refill_ns;
        if (elapsed_ns <= 0) return;
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);
        const candidate = self.tokens + elapsed_sec * self.refill_per_sec;
        self.tokens = @min(self.capacity, candidate);
        self.last_refill_ns = now_ns;
    }

    /// Unconditional take — the LAGGING half of a post-exec bucket. The
    /// balance may go (further) negative: the cost already happened, so
    /// it must be recorded either way; `hasCredit` is where a negative
    /// balance bites. Refills first so debt is netted against elapsed time.
    pub fn charge(self: *TokenBucket, n: f64, now_ns: i64) void {
        self.refill(now_ns);
        self.tokens -= n;
    }

    /// Admission read for a lagging bucket: true while the balance is
    /// positive. Deliberately not "≥ n" — admission doesn't know the
    /// upcoming cost; it only requires the tenant to have worked off
    /// prior debt.
    pub fn hasCredit(self: *TokenBucket, now_ns: i64) bool {
        self.refill(now_ns);
        return self.tokens > 0;
    }

    /// Seconds until at least `n` tokens are available. Used to
    /// compute the `Retry-After` hint on 429 responses. Returns 0
    /// when the bucket already has `n` tokens. Caller should refill
    /// before calling (or accept stale staleness — the Retry-After
    /// is advisory anyway).
    pub fn secondsUntil(self: *const TokenBucket, n: f64) f64 {
        if (self.tokens >= n) return 0;
        if (self.refill_per_sec <= 0) return std.math.inf(f64);
        return (n - self.tokens) / self.refill_per_sec;
    }
};

const InstanceBuckets = struct {
    buckets: [ACTION_COUNT]TokenBucket,
    /// Plan generation the caps were snapshotted at (the tenant's
    /// `TenantSlot.plan_gen` at creation). A bucket snapshots its caps once,
    /// so a tier change only takes effect when `getOrCreate` notices the
    /// generation moved and re-inits (docs/architecture/control-plane.md Lever 1
    /// generation-refresh). 0 = the default-caps generation.
    gen: u64,

    fn init(caps: RateLimitCaps, now_ns: i64, gen: u64) InstanceBuckets {
        var bs: [ACTION_COUNT]TokenBucket = undefined;
        bs[@intFromEnum(Action.request)] = TokenBucket.init(
            caps.request_capacity,
            caps.request_refill_per_sec,
            now_ns,
        );
        bs[@intFromEnum(Action.outbound)] = TokenBucket.init(
            caps.outbound_capacity,
            caps.outbound_refill_per_sec,
            now_ns,
        );
        // Uniform (not yet plan-derived — see the constants' doc).
        bs[@intFromEnum(Action.log_bytes)] = TokenBucket.init(
            LOG_BYTES_CAPACITY,
            LOG_BYTES_REFILL_PER_SEC,
            now_ns,
        );
        const daily = sustainedOutboundBudget(caps);
        bs[@intFromEnum(Action.outbound_sustained)] = TokenBucket.init(
            daily,
            @max(1, daily / 86_400),
            now_ns,
        );
        return .{ .buckets = bs, .gen = gen };
    }
};

pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    caps: RateLimitCaps,
    /// Refusals from the `outbound_sustained` bucket — the incident
    /// signal (a tenant saturating its day-scale outbound budget is a
    /// spam/flood suspect, not a sales lead). Per-worker, unsynced,
    /// like every field here; surfaced on `/_system/metrics`.
    sustained_trips: u64 = 0,
    /// `instance_id` → per-action buckets. Lazily created on first
    /// `check` for an instance; never evicted in v1 (memory bounded
    /// by registered tenant count).
    instances: std.StringHashMapUnmanaged(InstanceBuckets),

    pub fn init(allocator: std.mem.Allocator, caps: RateLimitCaps) RateLimiter {
        return .{
            .allocator = allocator,
            .caps = caps,
            .instances = .empty,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        var it = self.instances.iterator();
        while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.instances.deinit(self.allocator);
    }

    /// Take one token from `(instance_id, action)`, sourcing the bucket caps
    /// from the tenant's resolved plan (`caps`/`gen` from its `TenantSlot`).
    /// Returns true if allowed, false if the bucket is empty.
    /// `error.OutOfMemory` only on first-use lazy bucket creation.
    pub fn check(
        self: *RateLimiter,
        instance_id: []const u8,
        action: Action,
        caps: RateLimitCaps,
        gen: u64,
        now_ns: i64,
    ) !bool {
        return self.checkN(instance_id, action, 1, caps, gen, now_ns);
    }

    /// Take `n` tokens from `(instance_id, action)`. Returns true iff the
    /// bucket had `n` tokens (decremented); false if not (bucket unchanged
    /// beyond the refill). `caps`/`gen` are the tenant's plan-resolved rate
    /// caps + plan generation; a moved generation re-snapshots the caps.
    pub fn checkN(
        self: *RateLimiter,
        instance_id: []const u8,
        action: Action,
        n: u32,
        caps: RateLimitCaps,
        gen: u64,
        now_ns: i64,
    ) !bool {
        const inst = try self.getOrCreate(instance_id, caps, gen, now_ns);
        return inst.buckets[@intFromEnum(action)].tryTake(@floatFromInt(n), now_ns);
    }

    /// Post-exec charge against `(instance_id, action)` — the lagging
    /// half of a cost that already happened (see `TokenBucket.charge`).
    /// Never refuses; the bucket may go negative and the next
    /// `hasCredit` admission pays. Unlike `check`/`hasCredit` this NEVER
    /// generation-refreshes: charge sites run off the dispatch path
    /// without the resolved plan gen, and a refresh here would wipe every
    /// bucket's state (including the debt being recorded). `caps` is used
    /// only if the instance has no buckets yet.
    pub fn charge(
        self: *RateLimiter,
        instance_id: []const u8,
        action: Action,
        n: u64,
        caps: RateLimitCaps,
        now_ns: i64,
    ) !void {
        const gop = try self.instances.getOrPut(self.allocator, instance_id);
        if (!gop.found_existing) {
            const owned = try self.allocator.dupe(u8, instance_id);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = InstanceBuckets.init(caps, now_ns, 0);
        }
        gop.value_ptr.buckets[@intFromEnum(action)].charge(@floatFromInt(n), now_ns);
    }

    /// Admission read for a lagging bucket: true while `(instance_id,
    /// action)` has a positive balance. A never-seen instance is
    /// creditworthy by construction (fresh bucket starts full).
    pub fn hasCredit(
        self: *RateLimiter,
        instance_id: []const u8,
        action: Action,
        caps: RateLimitCaps,
        gen: u64,
        now_ns: i64,
    ) !bool {
        const inst = try self.getOrCreate(instance_id, caps, gen, now_ns);
        return inst.buckets[@intFromEnum(action)].hasCredit(now_ns);
    }

    /// Suggested `Retry-After` value (in seconds, rounded up) for a
    /// rejected check. Returns at least 1 even when the bucket is
    /// theoretically about to refill — clients with second-resolution
    /// retry timers shouldn't busy-loop. Returns 60 (an arbitrary
    /// large fallback) if the bucket has no refill (effectively
    /// disabled), so the caller can still emit a sensible header.
    pub fn retryAfterSeconds(
        self: *RateLimiter,
        instance_id: []const u8,
        action: Action,
    ) u32 {
        const inst = self.instances.getPtr(instance_id) orelse return 1;
        const sec = inst.buckets[@intFromEnum(action)].secondsUntil(1.0);
        if (std.math.isInf(sec)) return 60;
        const ceil = @ceil(sec);
        if (ceil < 1) return 1;
        return @intFromFloat(ceil);
    }

    fn getOrCreate(
        self: *RateLimiter,
        instance_id: []const u8,
        caps: RateLimitCaps,
        gen: u64,
        now_ns: i64,
    ) !*InstanceBuckets {
        const gop = try self.instances.getOrPut(self.allocator, instance_id);
        if (!gop.found_existing) {
            const owned = try self.allocator.dupe(u8, instance_id);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = InstanceBuckets.init(caps, now_ns, gen);
        } else if (gop.value_ptr.gen != gen) {
            // The tenant's plan changed (generation moved): re-snapshot the
            // caps. Reset tokens to full — simpler than rescaling, and harmless
            // (a tenant whose tier just changed starts fresh at the new burst).
            // docs/architecture/control-plane.md Lever 1 "generation-refresh."
            gop.value_ptr.* = InstanceBuckets.init(caps, now_ns, gen);
        }
        return gop.value_ptr;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "bucket: starts full + take draws down" {
    var b = TokenBucket.init(10, 0, 0);
    try testing.expect(b.tryTake(1, 0));
    try testing.expect(b.tryTake(5, 0));
    try testing.expect(b.tryTake(4, 0));
    try testing.expect(!b.tryTake(1, 0));
}

test "bucket: refill restores tokens at the configured rate" {
    var b = TokenBucket.init(10, 5, 0); // 5 tokens/sec
    try testing.expect(b.tryTake(10, 0));
    try testing.expect(!b.tryTake(1, 0));
    // After 1 second: 5 tokens refilled.
    try testing.expect(b.tryTake(5, 1 * std.time.ns_per_s));
    try testing.expect(!b.tryTake(1, 1 * std.time.ns_per_s));
}

test "bucket: refill caps at capacity (no infinite accumulation)" {
    var b = TokenBucket.init(10, 100, 0);
    try testing.expect(b.tryTake(10, 0));
    // After an hour at 100/sec, in theory 360_000 tokens — but we
    // only ever hold `capacity`.
    try testing.expect(b.tryTake(10, 3600 * std.time.ns_per_s));
    try testing.expect(!b.tryTake(1, 3600 * std.time.ns_per_s));
}

test "bucket: secondsUntil reports refill time when empty" {
    var b = TokenBucket.init(10, 5, 0); // 5/sec
    try testing.expect(b.tryTake(10, 0));
    // Need 1 token at 5/sec → 0.2s.
    try testing.expectApproxEqAbs(@as(f64, 0.2), b.secondsUntil(1), 0.0001);
}

test "bucket: secondsUntil returns 0 when bucket has enough" {
    var b = TokenBucket.init(10, 5, 0);
    try testing.expectEqual(@as(f64, 0), b.secondsUntil(1));
    try testing.expectEqual(@as(f64, 0), b.secondsUntil(10));
}


test "bucket: secondsUntil = inf when refill rate is 0" {
    var b = TokenBucket.init(10, 0, 0);
    try testing.expect(b.tryTake(10, 0));
    try testing.expect(std.math.isInf(b.secondsUntil(1)));
}

test "limiter: per-instance isolation" {
    var rl = RateLimiter.init(testing.allocator, .{
        .request_capacity = 2,
        .request_refill_per_sec = 0,
        .outbound_capacity = 1,
        .outbound_refill_per_sec = 0,
    });
    defer rl.deinit();

    try testing.expect(try rl.check("acme", .request, rl.caps, 0, 0));
    try testing.expect(try rl.check("acme", .request, rl.caps, 0, 0));
    try testing.expect(!(try rl.check("acme", .request, rl.caps, 0, 0))); // exhausted

    // Different instance has its own bucket.
    try testing.expect(try rl.check("beta", .request, rl.caps, 0, 0));
    try testing.expect(try rl.check("beta", .request, rl.caps, 0, 0));
    try testing.expect(!(try rl.check("beta", .request, rl.caps, 0, 0)));
}

test "limiter: actions are independent within an instance" {
    var rl = RateLimiter.init(testing.allocator, .{
        .request_capacity = 1,
        .request_refill_per_sec = 0,
        .outbound_capacity = 1,
        .outbound_refill_per_sec = 0,
    });
    defer rl.deinit();

    try testing.expect(try rl.check("acme", .request, rl.caps, 0, 0));
    try testing.expect(!(try rl.check("acme", .request, rl.caps, 0, 0)));
    // request bucket exhausted but email bucket still has tokens.
    try testing.expect(try rl.check("acme", .outbound, rl.caps, 0, 0));
    try testing.expect(!(try rl.check("acme", .outbound, rl.caps, 0, 0)));
}

test "limiter: retryAfterSeconds returns at least 1 + caps inf at 60" {
    var rl = RateLimiter.init(testing.allocator, .{
        .request_capacity = 1,
        .request_refill_per_sec = 5, // 0.2s/token
        .outbound_capacity = 1,
        .outbound_refill_per_sec = 0, // disabled
    });
    defer rl.deinit();

    _ = try rl.check("acme", .request, rl.caps, 0, 0);
    _ = try rl.check("acme", .request, rl.caps, 0, 0);
    // 0.2s away in real terms, but we round up to 1s minimum.
    try testing.expectEqual(@as(u32, 1), rl.retryAfterSeconds("acme", .request));

    _ = try rl.check("acme", .outbound, rl.caps, 0, 0);
    _ = try rl.check("acme", .outbound, rl.caps, 0, 0);
    // Refill rate 0 → infinite wait → fallback 60s.
    try testing.expectEqual(@as(u32, 60), rl.retryAfterSeconds("acme", .outbound));
}

test "limiter: retryAfterSeconds = 1 for unknown instance" {
    var rl = RateLimiter.init(testing.allocator, .{});
    defer rl.deinit();
    // Never seen `ghost` — sensible default rather than crash.
    try testing.expectEqual(@as(u32, 1), rl.retryAfterSeconds("ghost", .request));
}

test "limiter: per-instance caps come from the passed plan, not the default" {
    // The limiter's own `caps` is small, but a tenant on a bigger plan passes
    // bigger caps per call — its bucket is sized from the plan, not `self.caps`.
    var rl = RateLimiter.init(testing.allocator, .{ .request_capacity = 1, .request_refill_per_sec = 0 });
    defer rl.deinit();
    const pro: RateLimitCaps = .{ .request_capacity = 3, .request_refill_per_sec = 0 };
    try testing.expect(try rl.check("acme", .request, pro, 1, 0));
    try testing.expect(try rl.check("acme", .request, pro, 1, 0));
    try testing.expect(try rl.check("acme", .request, pro, 1, 0));
    try testing.expect(!(try rl.check("acme", .request, pro, 1, 0))); // 3-burst from the plan
}

test "bucket: charge goes negative; credit returns only after the debt refills off" {
    var b = TokenBucket.init(10, 5, 0); // 5 tokens/sec
    // Post-exec: a 25-token cost lands on a 10-token bucket → -15.
    b.charge(25, 0);
    try testing.expect(!b.hasCredit(0));
    // 2s later: -15 + 10 = -5 — still in debt.
    try testing.expect(!b.hasCredit(2 * std.time.ns_per_s));
    // 4s: -15 + 20 = +5 — credit restored (admission opens).
    try testing.expect(b.hasCredit(4 * std.time.ns_per_s));
    // secondsUntil accounts for the debt from a negative balance.
    b.charge(30, 4 * std.time.ns_per_s); // 5 - 30 = -25
    try testing.expectApproxEqAbs(@as(f64, 26.0 / 5.0), b.secondsUntil(1), 0.0001);
}

test "limiter: log_bytes is a lagging post-exec bucket — charge then 429 the next admission" {
    var rl = RateLimiter.init(testing.allocator, .{});
    defer rl.deinit();
    const caps: RateLimitCaps = .{};

    // Fresh tenant: creditworthy (bucket starts full at LOG_BYTES_CAPACITY).
    try testing.expect(try rl.hasCredit("acme", .log_bytes, caps, 0, 0));

    // A huge log lands post-exec — cannot be refused, drives the bucket
    // deep negative.
    try rl.charge("acme", .log_bytes, 2 * LOG_BYTES_CAPACITY, caps, 0);
    try testing.expect(!(try rl.hasCredit("acme", .log_bytes, caps, 0, 0)));

    // Sibling tenant unaffected; sibling ACTION on the same tenant too.
    try testing.expect(try rl.hasCredit("beta", .log_bytes, caps, 0, 0));
    try testing.expect(try rl.check("acme", .request, caps, 0, 0));

    // The debt works off at LOG_BYTES_REFILL_PER_SEC: one capacity's worth
    // of overdraft needs capacity/refill seconds.
    const debt_sec: i64 = @intCast(LOG_BYTES_CAPACITY / LOG_BYTES_REFILL_PER_SEC + 1);
    try testing.expect(try rl.hasCredit("acme", .log_bytes, caps, 0, debt_sec * std.time.ns_per_s));
}

test "limiter: outbound_sustained is a day-scale ceiling derived from the plan's refill rate" {
    var rl = RateLimiter.init(testing.allocator, .{});
    defer rl.deinit();
    // A tiny plan: 1/s refill → 8,640/day sustained budget.
    const caps: RateLimitCaps = .{ .outbound_capacity = 1000, .outbound_refill_per_sec = 1 };
    try testing.expectEqual(@as(u32, 8640), sustainedOutboundBudget(caps));

    // Drain the whole day budget at t=0 (checkN in one gulp).
    try testing.expect(try rl.checkN("acme", .outbound_sustained, 8640, caps, 0, 0));
    try testing.expect(!(try rl.check("acme", .outbound_sustained, caps, 0, 0)));

    // Refill is capacity/day (≥1/s floor): after 100s at most ~100 back.
    try testing.expect(try rl.checkN("acme", .outbound_sustained, 50, caps, 0, 100 * std.time.ns_per_s));
    // But nowhere near the full budget again.
    try testing.expect(!(try rl.checkN("acme", .outbound_sustained, 8640, caps, 0, 101 * std.time.ns_per_s)));
}

test "limiter: charge never generation-refreshes (a lagging charge can't wipe bucket state)" {
    var rl = RateLimiter.init(testing.allocator, .{});
    defer rl.deinit();
    const tight: RateLimitCaps = .{ .request_capacity = 1, .request_refill_per_sec = 0 };

    // Dispatch path creates the buckets at gen 7 and exhausts request.
    try testing.expect(try rl.check("acme", .request, tight, 7, 0));
    try testing.expect(!(try rl.check("acme", .request, tight, 7, 0)));

    // A post-exec charge arrives with DEFAULT caps and no gen — it must
    // record the debt without re-initializing anything.
    try rl.charge("acme", .log_bytes, 123, .{}, 0);
    try testing.expect(!(try rl.check("acme", .request, tight, 7, 0))); // still exhausted
}

test "limiter: a moved generation re-snapshots the caps (tier change)" {
    var rl = RateLimiter.init(testing.allocator, .{});
    defer rl.deinit();
    const free: RateLimitCaps = .{ .request_capacity = 1, .request_refill_per_sec = 0 };
    const pro: RateLimitCaps = .{ .request_capacity = 5, .request_refill_per_sec = 0 };

    // Free tier (gen 1): a single-token burst, then exhausted.
    try testing.expect(try rl.check("acme", .request, free, 1, 0));
    try testing.expect(!(try rl.check("acme", .request, free, 1, 0)));

    // Same generation → caps are NOT re-read; still exhausted even if we pass
    // bigger caps (the bucket snapshotted free at gen 1).
    try testing.expect(!(try rl.check("acme", .request, pro, 1, 0)));

    // Upgrade bumps the generation → caps re-snapshot to pro, bucket resets
    // full. The paying customer's higher limit is live immediately.
    try testing.expect(try rl.check("acme", .request, pro, 2, 0));
    try testing.expect(try rl.check("acme", .request, pro, 2, 0));
    try testing.expect(try rl.check("acme", .request, pro, 2, 0));
    try testing.expect(try rl.check("acme", .request, pro, 2, 0));
    try testing.expect(try rl.check("acme", .request, pro, 2, 0));
    try testing.expect(!(try rl.check("acme", .request, pro, 2, 0))); // pro 5-burst spent
}
