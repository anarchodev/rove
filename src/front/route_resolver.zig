// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Background route resolver for rewind-front.
//!
//! The front door is a single-threaded poll loop. Resolving a
//! tenant's Host→cluster placement means a `/_cp/route` round-trip to
//! the control plane — synchronous libcurl. Doing that on the poll
//! loop would freeze the WHOLE front door (every tenant, every
//! in-flight request) for the duration of the CP call: ~hundreds of ms
//! when the CP answers promptly, multiple seconds when a CP node is
//! slow or down (5 s connect timeout + failover). The workers never
//! block; a blocking proxy in front of them would make that moot.
//!
//! So the CP query runs off the loop. The poll loop hands a host
//! to `enqueue`; this thread runs the curl query and pushes a
//! `Completion` back. The loop drains completions each cycle,
//! populates its route cache, and resumes the requests it parked
//! while the route was in flight. All registry / cache / proxy
//! mutation stays on the loop thread — this thread touches only its
//! own curl handle and the two mutex-guarded queues.
//!
//! Modeled on `src/js/deployment_loader.zig` (the worker's background
//! manifest loader): Mutex + `ResetEvent` wake + `stop` atomic +
//! final-drain-on-shutdown.

const std = @import("std");
const blob = @import("rove-blob");
const curl = blob.curl;

/// CP queries run off the loop, so a slow CP doesn't freeze
/// serving — but it shouldn't pin the resolver thread for the libcurl
/// defaults (5 s connect / 15 s total) either, since that delays other
/// hosts' resolves queued behind it. Tight bounds matched to the
/// proxy's parked-flow deadline.
const CP_CONNECT_TIMEOUT_MS: u32 = 1000;
const CP_TOTAL_TIMEOUT_MS: u32 = 2000;

/// The result of a single route resolution. `placed` carries an
/// allocator-owned `[][]u8` node list (ownership transfers to the loop
/// thread when it drains the completion).
pub const Outcome = union(enum) {
    placed: [][]u8,
    not_found,
    /// Every CP node failed (unreachable / bad status / bad body).
    err,
};

pub const Completion = struct {
    /// Allocator-owned host copy; freed by the loop after it drains.
    host: []u8,
    outcome: Outcome,
};

pub const RouteResolver = struct {
    allocator: std.mem.Allocator,
    /// CP origins for `/_cp/route` (any node answers; tried in order).
    /// Borrowed from main — read-only, outlives the resolver.
    cp_urls: []const []const u8,

    /// Owned host copies waiting to be resolved (loop → resolver).
    /// FIFO via `req_head` cursor: entries before it were already
    /// handed to a resolver thread; the tail is compacted away when
    /// the queue drains empty.
    req_queue: std.ArrayListUnmanaged([]u8),
    req_head: usize,
    req_mu: std.Thread.Mutex,
    /// Wakes resolver threads when work arrives / on shutdown.
    req_cond: std.Thread.Condition,

    /// Finished resolutions (resolver → loop).
    done_queue: std.ArrayListUnmanaged(Completion),
    done_mu: std.Thread.Mutex,

    stop: std.atomic.Value(bool),
    /// Resolver worker pool (plan A6b). A single thread would serialize
    /// every cold resolve behind the slowest CP query (up to 2 s each),
    /// starving the tail into its park deadline under a burst of
    /// distinct cold hosts. Each thread owns its own curl handle; the
    /// two queues stay the only shared state.
    threads: [MAX_THREADS]?std.Thread,

    pub const MAX_THREADS = 8;
    pub const DEFAULT_THREADS = 4;

    pub fn init(allocator: std.mem.Allocator, cp_urls: []const []const u8) !*RouteResolver {
        const self = try allocator.create(RouteResolver);
        self.* = .{
            .allocator = allocator,
            .cp_urls = cp_urls,
            .req_queue = .empty,
            .req_head = 0,
            .req_mu = .{},
            .req_cond = .{},
            .done_queue = .empty,
            .done_mu = .{},
            .stop = std.atomic.Value(bool).init(false),
            .threads = @splat(null),
        };
        return self;
    }

    pub fn start(self: *RouteResolver, n_threads: usize) !void {
        std.debug.assert(self.threads[0] == null);
        const n = @max(1, @min(n_threads, MAX_THREADS));
        for (self.threads[0..n]) |*slot| {
            slot.* = try std.Thread.spawn(.{}, threadMain, .{self});
        }
    }

    pub fn shutdown(self: *RouteResolver) void {
        self.stop.store(true, .release);
        self.req_mu.lock();
        self.req_cond.broadcast();
        self.req_mu.unlock();
        for (&self.threads) |*slot| {
            if (slot.*) |t| {
                t.join();
                slot.* = null;
            }
        }
    }

    pub fn deinit(self: *RouteResolver) void {
        // Caller must have shut down by here. Free anything still
        // queued (a host the thread never popped, or a completion the
        // loop never drained) so nothing leaks.
        for (self.req_queue.items[self.req_head..]) |h| self.allocator.free(h);
        self.req_queue.deinit(self.allocator);
        for (self.done_queue.items) |c| self.freeCompletion(c);
        self.done_queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Loop thread: enqueue a host for resolution. The caller dedupes
    /// (its own pending set), so this always pushes. Takes an owned
    /// copy of `host` — the caller's slice need not outlive the call.
    pub fn enqueue(self: *RouteResolver, host: []const u8) !void {
        const copy = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(copy);
        self.req_mu.lock();
        defer self.req_mu.unlock();
        try self.req_queue.append(self.allocator, copy);
        self.req_cond.signal();
    }

    /// Loop thread: take all finished completions. Ownership of the
    /// returned list (and every `host` / `placed` node list inside it)
    /// transfers to the caller, which must `deinit` the list and free
    /// each completion's owned memory after processing.
    pub fn takeCompletions(self: *RouteResolver) std.ArrayListUnmanaged(Completion) {
        self.done_mu.lock();
        defer self.done_mu.unlock();
        const out = self.done_queue;
        self.done_queue = .empty;
        return out;
    }

    fn freeCompletion(self: *RouteResolver, c: Completion) void {
        self.allocator.free(c.host);
        if (c.outcome == .placed) freeNodes(self.allocator, c.outcome.placed);
    }

    // ── Resolver thread ───────────────────────────────────────────────

    fn threadMain(self: *RouteResolver) void {
        // Queued hosts drain even after `stop` (popRequestBlocking
        // returns work before it returns null), so a host enqueued
        // just before shutdown still produces a completion — deinit
        // frees any the loop never took.
        while (self.popRequestBlocking()) |host| {
            const outcome = self.query(host);
            // `host` ownership moves into the completion.
            self.pushCompletion(.{ .host = host, .outcome = outcome });
        }
    }

    /// Worker thread: block until work or shutdown. Null = stopping
    /// and the queue is empty.
    fn popRequestBlocking(self: *RouteResolver) ?[]u8 {
        self.req_mu.lock();
        defer self.req_mu.unlock();
        while (true) {
            if (self.popLocked()) |host| return host;
            if (self.stop.load(.acquire)) return null;
            self.req_cond.wait(&self.req_mu);
        }
    }

    /// Non-blocking pop; caller holds `req_mu` (tests call via
    /// `popRequest`). FIFO — a LIFO pop would starve the OLDEST
    /// parked flows under backlog, the ones closest to their 503
    /// deadline (plan A6).
    fn popLocked(self: *RouteResolver) ?[]u8 {
        if (self.req_head >= self.req_queue.items.len) {
            self.req_queue.clearRetainingCapacity();
            self.req_head = 0;
            return null;
        }
        const host = self.req_queue.items[self.req_head];
        self.req_head += 1;
        return host;
    }

    fn popRequest(self: *RouteResolver) ?[]u8 {
        self.req_mu.lock();
        defer self.req_mu.unlock();
        return self.popLocked();
    }

    fn pushCompletion(self: *RouteResolver, c: Completion) void {
        self.done_mu.lock();
        const failed = blk: {
            self.done_queue.append(self.allocator, c) catch break :blk true;
            break :blk false;
        };
        self.done_mu.unlock();
        // OOM: drop the completion but free its owned memory (outside
        // the lock). The parked flow falls back to its deadline 503.
        if (failed) self.freeCompletion(c);
    }

    /// The CP `/_cp/route` query, run off the loop. Tries each CP node
    /// in order; tight timeouts so a dead node fails over fast.
    fn query(self: *RouteResolver, host: []const u8) Outcome {
        const a = self.allocator;
        const suffix = std.fmt.allocPrint(a, "/_cp/route?host={s}", .{host}) catch return .err;
        defer a.free(suffix);

        for (self.cp_urls) |base| {
            const url = std.fmt.allocPrint(a, "{s}{s}", .{ base, suffix }) catch continue;
            defer a.free(url);
            var resp = curl.cpGet(a, url, .{
                .connect_timeout_ms = CP_CONNECT_TIMEOUT_MS,
                .timeout_ms = CP_TOTAL_TIMEOUT_MS,
            }) catch |e| {
                std.log.warn("front: CP route {s} on {s} failed: {s}", .{ host, base, @errorName(e) });
                continue;
            };
            defer resp.deinit(a);

            if (resp.status == 404) return .not_found;
            if (resp.status != 200) continue;
            const body = resp.body orelse "";
            var parsed = std.json.parseFromSlice(struct {
                cluster: []const u8 = "",
                tenant: []const u8 = "",
                nodes: []const []const u8 = &.{},
            }, a, body, .{ .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();
            const owned = dupNodes(a, parsed.value.nodes) catch return .err;
            return .{ .placed = owned };
        }
        return .err;
    }
};

fn dupNodes(a: std.mem.Allocator, src: []const []const u8) ![][]u8 {
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

fn freeNodes(a: std.mem.Allocator, nodes: [][]u8) void {
    for (nodes) |n| a.free(n);
    a.free(nodes);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "popRequest is FIFO — oldest parked flow resolves first" {
    const r = try RouteResolver.init(testing.allocator, &.{});
    defer r.deinit();

    // No thread started — drive the queue directly.
    try r.enqueue("first.example");
    try r.enqueue("second.example");
    const a = r.popRequest().?;
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("first.example", a);
    const b = r.popRequest().?;
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("second.example", b);
    try testing.expect(r.popRequest() == null);

    // The drained queue compacts; a fresh enqueue starts at the head.
    try r.enqueue("third.example");
    const c = r.popRequest().?;
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("third.example", c);
}

test "enqueue takes an owned copy; takeCompletions swaps the queue" {
    const r = try RouteResolver.init(testing.allocator, &.{});
    defer r.deinit();

    // No thread started — exercise the queue plumbing directly.
    var buf = "acme.example".*;
    try r.enqueue(buf[0..]);
    buf[0] = 'X'; // mutate caller's buffer: the resolver kept its own copy
    try testing.expectEqual(@as(usize, 1), r.req_queue.items.len);
    try testing.expectEqualStrings("acme.example", r.req_queue.items[0]);

    // Hand a fabricated completion through the done queue.
    r.done_queue.append(testing.allocator, .{
        .host = try testing.allocator.dupe(u8, "acme.example"),
        .outcome = .not_found,
    }) catch unreachable;
    var taken = r.takeCompletions();
    defer {
        for (taken.items) |c| r.freeCompletion(c);
        taken.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 1), taken.items.len);
    try testing.expectEqual(@as(usize, 0), r.done_queue.items.len); // swapped out
    try testing.expect(taken.items[0].outcome == .not_found);
}
