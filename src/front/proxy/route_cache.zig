//! Front-door route caches — the stateless proxy's host→placement lookups,
//! independent of request/tunnel proxying and each other. `RouteCache`
//! (host→cluster nodes, single TTL, negative-cached + capped) and `LeaderCache`
//! (host→leader origin, learned from the post-421 2xx). `RouteResult` is the
//! resolve outcome the proxy's route path returns. Owned by `proxy.zig`, which
//! imports this file; nothing here reaches back into the proxy.

const std = @import("std");
const testing = std.testing;

/// Dupe a borrowed node-origin list into an owned `[][]u8` (both the outer
/// slice and each string). The alloc-side pair of `freeNodes`.
pub fn dupNodes(a: std.mem.Allocator, src: []const []const u8) ![][]u8 {
    const out = try a.alloc([]u8, src.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |n| a.free(n);
        a.free(out);
    }
    for (src, 0..) |n, i| {
        out[i] = try a.dupe(u8, n);
        filled = i + 1;
    }
    return out;
}

pub fn freeNodes(a: std.mem.Allocator, nodes: [][]u8) void {
    for (nodes) |n| a.free(n);
    a.free(nodes);
}

// ── Route cache (host → cluster nodes, single TTL) ────────────────────
//
// Single-threaded (one poll loop), no locking. No active eviction (size
// bounded by distinct active hosts). A fresh entry (within `ttl_ns`) is
// served inline; past the TTL the host re-resolves by PARKING (the
// off-loop resolver answers, the parked flow resumes) — never by
// blocking the poll loop, and never by serving a stale entry. Re-
// resolving past the TTL (instead of serving stale) is what keeps a
// tenant MOVE correct: serving the cached old cluster after it evicted
// the tenant returns a relayed 404, so we must re-resolve, not serve
// stale. The TTL therefore also bounds move-propagation latency.
pub const RouteCache = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(CacheEntry) = .empty,
    ttl_ns: i128,
    /// TTL for NEGATIVE entries (host the CP answered 404 for). Kept
    /// separate from `ttl_ns`: a placement changes on a tenant move
    /// (short TTL bounds move latency), but "this host doesn't exist"
    /// only changes on provisioning — and negative caching is what
    /// keeps internet scanners probing garbage Host values from
    /// serially occupying the CP resolver (plan A6).
    neg_ttl_ns: i128,
    /// Live negative entries. Negative keys are attacker-controlled
    /// (any Host header), so their count is capped — see NEG_CAP.
    neg_count: usize = 0,

    /// Max negative entries. At the cap, expired negatives are swept;
    /// if still full the insert is skipped (a flood degrades to the
    /// uncached behavior, never to unbounded memory).
    const NEG_CAP: usize = 4096;

    const CacheEntry = struct {
        /// Empty and unowned for a negative entry (`negative` guards
        /// the free).
        nodes: [][]u8,
        negative: bool,
        expires_ns: i128,
    };

    pub const Hit = union(enum) {
        nodes: []const []const u8,
        not_found,
    };

    pub fn init(allocator: std.mem.Allocator, ttl_ns: i128, neg_ttl_ns: i128) RouteCache {
        return .{ .allocator = allocator, .ttl_ns = ttl_ns, .neg_ttl_ns = neg_ttl_ns };
    }

    pub fn deinit(self: *RouteCache) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            if (!e.value_ptr.negative) freeNodes(self.allocator, e.value_ptr.nodes);
        }
        self.map.deinit(self.allocator);
    }

    pub fn get(self: *RouteCache, host: []const u8, now_ns: i128) ?Hit {
        const e = self.map.getPtr(host) orelse return null;
        if (now_ns >= e.expires_ns) return null;
        if (e.negative) return .not_found;
        return .{ .nodes = e.nodes };
    }

    pub fn putOwned(self: *RouteCache, host: []const u8, owned_nodes: [][]u8, now_ns: i128) !void {
        errdefer freeNodes(self.allocator, owned_nodes);
        const gop = try self.map.getOrPut(self.allocator, host);
        if (gop.found_existing) {
            if (gop.value_ptr.negative) {
                self.neg_count -= 1;
            } else {
                freeNodes(self.allocator, gop.value_ptr.nodes);
            }
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, host) catch |e| {
                self.map.removeByPtr(gop.key_ptr);
                return e;
            };
        }
        gop.value_ptr.* = .{ .nodes = owned_nodes, .negative = false, .expires_ns = now_ns + self.ttl_ns };
    }

    /// Record a CP 404 for `host`. Best-effort (an allocation failure
    /// or a full negative set just skips — the next request re-asks
    /// the CP, which is today's behavior).
    pub fn putNegative(self: *RouteCache, host: []const u8, now_ns: i128) void {
        if (self.neg_count >= NEG_CAP) self.sweepExpiredNegatives(now_ns);
        const gop = self.map.getOrPut(self.allocator, host) catch return;
        if (gop.found_existing) {
            if (!gop.value_ptr.negative) {
                freeNodes(self.allocator, gop.value_ptr.nodes);
                self.neg_count += 1;
            }
        } else {
            if (self.neg_count >= NEG_CAP) {
                self.map.removeByPtr(gop.key_ptr);
                return;
            }
            gop.key_ptr.* = self.allocator.dupe(u8, host) catch {
                self.map.removeByPtr(gop.key_ptr);
                return;
            };
            self.neg_count += 1;
        }
        gop.value_ptr.* = .{ .nodes = &.{}, .negative = true, .expires_ns = now_ns + self.neg_ttl_ns };
    }

    fn sweepExpiredNegatives(self: *RouteCache, now_ns: i128) void {
        var it = self.map.iterator();
        var expired: std.ArrayListUnmanaged([]const u8) = .empty;
        defer expired.deinit(self.allocator);
        while (it.next()) |e| {
            if (e.value_ptr.negative and now_ns >= e.value_ptr.expires_ns)
                expired.append(self.allocator, e.key_ptr.*) catch break;
        }
        for (expired.items) |key| self.invalidate(key);
    }

    pub fn invalidate(self: *RouteCache, host: []const u8) void {
        if (self.map.fetchRemove(host)) |kv| {
            self.allocator.free(kv.key);
            if (kv.value.negative) {
                self.neg_count -= 1;
            } else {
                freeNodes(self.allocator, kv.value.nodes);
            }
        }
    }
};

// ── Leader hint cache (host → leader node origin) ─────────────────────
//
// The worker dispatch-gate makes every follower 421 a *dynamic* request
// (static is served node-local before the gate, so it never enters the 421
// path). So a 2xx that follows a 421 in a flow can only have come from the
// leader — we record it here (`note`) and start the next request for that
// host AT the leader (`startIdx`), skipping the sequential redirect scan
// that would otherwise tax every read. Self-correcting: after a leadership
// change or tenant move the stale origin isn't found in the fresh `nodes`,
// so `startIdx` returns 0 and the next 421 re-learns; if the cached leader
// is found DOWN, the flow's transport-error path calls `drop`. Independent
// of `RouteCache` (which can be TTL-disabled, re-resolving every request),
// so the hint survives route re-resolution. Keys + values are owned.
pub const LeaderCache = struct {
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn deinit(self: *LeaderCache, a: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        self.map.deinit(a);
    }

    /// Index of the cached leader for `host` within `nodes`, or 0 when
    /// there's no hint or the hinted origin is absent (stale → scan + relearn).
    pub fn startIdx(self: *const LeaderCache, host: []const u8, nodes: []const []const u8) usize {
        const origin = self.map.get(host) orelse return 0;
        for (nodes, 0..) |n, i| {
            if (std.mem.eql(u8, n, origin)) return i;
        }
        return 0;
    }

    /// Record `origin` as the leader for `host`. Idempotent; replaces a
    /// changed value (freeing the old), dupes the key on first insert.
    /// Best-effort: an allocation failure just skips the hint (correctness
    /// is the 421 re-aim; this is only the optimization).
    pub fn note(self: *LeaderCache, a: std.mem.Allocator, host: []const u8, origin: []const u8) void {
        const gop = self.map.getOrPut(a, host) catch return;
        if (gop.found_existing) {
            if (std.mem.eql(u8, gop.value_ptr.*, origin)) return;
            a.free(gop.value_ptr.*);
        } else {
            const key = a.dupe(u8, host) catch {
                _ = self.map.remove(host);
                return;
            };
            gop.key_ptr.* = key;
        }
        gop.value_ptr.* = a.dupe(u8, origin) catch {
            const k = gop.key_ptr.*;
            _ = self.map.remove(host);
            a.free(k);
            return;
        };
    }

    /// Forget the cached leader for `host` (the node we started at is down).
    pub fn drop(self: *LeaderCache, a: std.mem.Allocator, host: []const u8) void {
        if (self.map.fetchRemove(host)) |kv| {
            a.free(kv.key);
            a.free(kv.value);
        }
    }
};

pub const RouteResult = union(enum) {
    nodes: []const []const u8, // cache-owned; valid for this loop iteration
    not_found,
    /// No cached route — a resolve was enqueued; the caller parks the
    /// request until `drainRouteCompletions` lands the answer.
    pending,
};

test "RouteCache: fresh hit within TTL, miss past it (re-resolve, no stale serve)" {
    const ttl_ns: i128 = 100;
    var cache = RouteCache.init(testing.allocator, ttl_ns, 500);
    defer cache.deinit();

    const nodes = try dupNodes(testing.allocator, &.{ "http://a:1", "http://b:1" });
    try cache.putOwned("acme.example", nodes, 1000); // expires at 1100

    // Within TTL: hit.
    try testing.expectEqual(@as(usize, 2), cache.get("acme.example", 1050).?.nodes.len);
    // At/after expiry: miss → caller parks + re-resolves (never serves
    // the stale entry, so a move past the TTL routes correctly).
    try testing.expect(cache.get("acme.example", 1100) == null);
    try testing.expect(cache.get("acme.example", 1200) == null);
    // Unknown host: miss.
    try testing.expect(cache.get("nope.example", 1050) == null);
}

test "RouteCache: putOwned refreshes the entry in place and frees the old nodes" {
    var cache = RouteCache.init(testing.allocator, 100, 500);
    defer cache.deinit();

    try cache.putOwned("h", try dupNodes(testing.allocator, &.{"http://old:1"}), 1000);
    // Re-store with a new list; the old one must be freed (testing
    // allocator catches a leak) and the expiry pushed out.
    try cache.putOwned("h", try dupNodes(testing.allocator, &.{ "http://new:1", "http://new:2" }), 1200);
    try testing.expectEqual(@as(usize, 2), cache.get("h", 1250).?.nodes.len);

    cache.invalidate("h");
    try testing.expect(cache.get("h", 1250) == null);
}

test "RouteCache: negative entries answer not_found within their own TTL" {
    // Positive TTL 100, negative TTL 500 — independent windows.
    var cache = RouteCache.init(testing.allocator, 100, 500);
    defer cache.deinit();

    cache.putNegative("ghost.example", 1000); // expires at 1500
    try testing.expect(cache.get("ghost.example", 1100).? == .not_found);
    try testing.expect(cache.get("ghost.example", 1499).? == .not_found);
    // Past the negative TTL: miss → the CP is asked again.
    try testing.expect(cache.get("ghost.example", 1500) == null);

    // A negative entry is replaced by a later placement (host got
    // provisioned) and vice versa (tenant deleted), with no leak.
    cache.putNegative("flip.example", 1000);
    try cache.putOwned("flip.example", try dupNodes(testing.allocator, &.{"http://a:1"}), 1010);
    try testing.expectEqual(@as(usize, 1), cache.get("flip.example", 1050).?.nodes.len);
    try testing.expectEqual(@as(usize, 1), cache.neg_count); // ghost only
    cache.putNegative("flip.example", 1060);
    try testing.expect(cache.get("flip.example", 1100).? == .not_found);
    try testing.expectEqual(@as(usize, 2), cache.neg_count);

    // invalidate keeps the count honest.
    cache.invalidate("flip.example");
    try testing.expectEqual(@as(usize, 1), cache.neg_count);
}

test "LeaderCache: note seeds the start index; stale origin falls back to 0" {
    const a = testing.allocator;
    var lc: LeaderCache = .{};
    defer lc.deinit(a);

    const nodes = &[_][]const u8{ "http://n1:1", "http://n2:1", "http://n3:1" };

    // Cold: no hint → start at 0 (the front then scans + learns).
    try testing.expectEqual(@as(usize, 0), lc.startIdx("acme", nodes));

    // Learn the leader is n3 → subsequent requests start at index 2 directly
    // (no redirect scan — the tax is gone).
    lc.note(a, "acme", "http://n3:1");
    try testing.expectEqual(@as(usize, 2), lc.startIdx("acme", nodes));

    // A different host is independent.
    lc.note(a, "beta", "http://n2:1");
    try testing.expectEqual(@as(usize, 1), lc.startIdx("beta", nodes));

    // Stale hint after a move/membership change: the cached origin is no
    // longer in `nodes` → fall back to 0 so the next 421 re-learns.
    const moved_nodes = &[_][]const u8{ "http://m1:1", "http://m2:1" };
    try testing.expectEqual(@as(usize, 0), lc.startIdx("acme", moved_nodes));
}

test "LeaderCache: note replaces in place (no leak); drop forgets" {
    const a = testing.allocator;
    var lc: LeaderCache = .{};
    defer lc.deinit(a);

    const nodes = &[_][]const u8{ "http://n1:1", "http://n2:1", "http://n3:1" };

    lc.note(a, "acme", "http://n1:1");
    // Re-note with a new leader (leadership changed): the old value must be
    // freed in place (testing allocator catches a leak) and the index move.
    lc.note(a, "acme", "http://n3:1");
    try testing.expectEqual(@as(usize, 2), lc.startIdx("acme", nodes));
    // Idempotent re-note of the same value is a no-op.
    lc.note(a, "acme", "http://n3:1");
    try testing.expectEqual(@as(usize, 2), lc.startIdx("acme", nodes));

    // drop forgets → back to a cold start.
    lc.drop(a, "acme");
    try testing.expectEqual(@as(usize, 0), lc.startIdx("acme", nodes));
    // drop of an absent host is a harmless no-op.
    lc.drop(a, "acme");
}

