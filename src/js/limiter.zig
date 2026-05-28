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
//! Single plan tier in v1 — `defaultCaps()` returns the same numbers
//! for every instance. Phase 10 will branch on the instance's plan.
//!
//! Actions covered in v1: `request` (per-instance HTTP request budget,
//! protects the worker from a single noisy tenant) and `email`
//! (per-instance Resend send budget, protects the platform's
//! reputation/bill). Other actions in PLAN §2.10 (`deploy`,
//! `webhook_attempt`, `kv_write`) are deferred — webhooks are already
//! paced by webhooks.db depth + per-destination cap + exponential
//! backoff; deploys are low-volume; kv_write is a hot path with real
//! per-call cost to add bucket math.
//!
//! Thread safety: not synchronized; each worker thread owns its own
//! RateLimiter. Same model as `penalty.zig`.

const std = @import("std");

pub const Action = enum(u8) {
    request,
    email,
};

const ACTION_COUNT: usize = std.meta.fields(Action).len;

pub const RateLimitCaps = struct {
    /// Burst cap: max requests we'll accept in a single instant
    /// from one instance.
    request_capacity: u32 = 1000,
    /// Sustained rate: requests per second the bucket refills at.
    request_refill_per_sec: u32 = 500,
    /// Burst cap on `email.send` calls from a handler.
    email_capacity: u32 = 100,
    /// 10/sec → 600/min sustained — well under any sane Resend quota.
    email_refill_per_sec: u32 = 10,
};

pub fn defaultCaps() RateLimitCaps {
    return .{};
}

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

    fn init(caps: RateLimitCaps, now_ns: i64) InstanceBuckets {
        var bs: [ACTION_COUNT]TokenBucket = undefined;
        bs[@intFromEnum(Action.request)] = TokenBucket.init(
            caps.request_capacity,
            caps.request_refill_per_sec,
            now_ns,
        );
        bs[@intFromEnum(Action.email)] = TokenBucket.init(
            caps.email_capacity,
            caps.email_refill_per_sec,
            now_ns,
        );
        return .{ .buckets = bs };
    }
};

pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    caps: RateLimitCaps,
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

    /// Take one token from `(instance_id, action)`. Returns true if
    /// the action is allowed, false if the bucket is empty.
    /// `error.OutOfMemory` only on first-use lazy bucket creation.
    pub fn check(
        self: *RateLimiter,
        instance_id: []const u8,
        action: Action,
        now_ns: i64,
    ) !bool {
        return self.checkN(instance_id, action, 1, now_ns);
    }

    /// Take `n` tokens from `(instance_id, action)`. Returns true
    /// iff the bucket had `n` tokens (decremented); false if not
    /// (bucket unchanged beyond the refill).
    pub fn checkN(
        self: *RateLimiter,
        instance_id: []const u8,
        action: Action,
        n: u32,
        now_ns: i64,
    ) !bool {
        const inst = try self.getOrCreate(instance_id, now_ns);
        return inst.buckets[@intFromEnum(action)].tryTake(@floatFromInt(n), now_ns);
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
        now_ns: i64,
    ) !*InstanceBuckets {
        const gop = try self.instances.getOrPut(self.allocator, instance_id);
        if (!gop.found_existing) {
            const owned = try self.allocator.dupe(u8, instance_id);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = InstanceBuckets.init(self.caps, now_ns);
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
        .email_capacity = 1,
        .email_refill_per_sec = 0,
    });
    defer rl.deinit();

    try testing.expect(try rl.check("acme", .request, 0));
    try testing.expect(try rl.check("acme", .request, 0));
    try testing.expect(!(try rl.check("acme", .request, 0))); // exhausted

    // Different instance has its own bucket.
    try testing.expect(try rl.check("beta", .request, 0));
    try testing.expect(try rl.check("beta", .request, 0));
    try testing.expect(!(try rl.check("beta", .request, 0)));
}

test "limiter: actions are independent within an instance" {
    var rl = RateLimiter.init(testing.allocator, .{
        .request_capacity = 1,
        .request_refill_per_sec = 0,
        .email_capacity = 1,
        .email_refill_per_sec = 0,
    });
    defer rl.deinit();

    try testing.expect(try rl.check("acme", .request, 0));
    try testing.expect(!(try rl.check("acme", .request, 0)));
    // request bucket exhausted but email bucket still has tokens.
    try testing.expect(try rl.check("acme", .email, 0));
    try testing.expect(!(try rl.check("acme", .email, 0)));
}

test "limiter: retryAfterSeconds returns at least 1 + caps inf at 60" {
    var rl = RateLimiter.init(testing.allocator, .{
        .request_capacity = 1,
        .request_refill_per_sec = 5, // 0.2s/token
        .email_capacity = 1,
        .email_refill_per_sec = 0, // disabled
    });
    defer rl.deinit();

    _ = try rl.check("acme", .request, 0);
    _ = try rl.check("acme", .request, 0);
    // 0.2s away in real terms, but we round up to 1s minimum.
    try testing.expectEqual(@as(u32, 1), rl.retryAfterSeconds("acme", .request));

    _ = try rl.check("acme", .email, 0);
    _ = try rl.check("acme", .email, 0);
    // Refill rate 0 → infinite wait → fallback 60s.
    try testing.expectEqual(@as(u32, 60), rl.retryAfterSeconds("acme", .email));
}

test "limiter: retryAfterSeconds = 1 for unknown instance" {
    var rl = RateLimiter.init(testing.allocator, .{});
    defer rl.deinit();
    // Never seen `ghost` — sensible default rather than crash.
    try testing.expectEqual(@as(u32, 1), rl.retryAfterSeconds("ghost", .request));
}
