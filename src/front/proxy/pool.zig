//! Upstream connection pool for rewind-front's streaming proxy.
//!
//! One pooled h2c connection ("leg") per backend node, up to `MAX_LEGS`
//! legs per node; each submit picks the least-loaded live leg, a spare
//! is dialed in the background under load, and a saturated node sheds
//! retryably rather than queueing invisibly in nghttp2 (plan A3).
//! Extracted from proxy.zig as the pool half of the front request path.
//!
//! Decoupled from the request state machines: a parked request is an
//! opaque `Waiter` (`{ kind, ptr }`); the pool resumes connects by
//! queueing outcomes (`drainWaiters` -> the proxy's
//! `dispatchWaiterOutcomes`), never calling into `Flow`/`WsTunnel`. That
//! one-way request->pool edge is what lets this file avoid naming those
//! types (docs/architecture/routing-and-ingress.md).
//!
//! The methods are `Fns(comptime FrontH2)` operating on the generic
//! `Proxy(FrontH2)` (re-exported onto it in proxy.zig) so `self.X()`
//! cross-calls and concrete types survive the split without `anytype`.
//! proxy.zig is a build-relative import (not a module root), so the
//! proxy<->pool import cycle is fine.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const Entity = rove.Entity;

const proxy_mod = @import("../proxy.zig");
const FlowRef = proxy_mod.FlowRef;
const resolveOrigin = proxy_mod.resolveOrigin;
const MAX_LEGS = proxy_mod.MAX_LEGS;
const LEG_GROW_THRESHOLD = proxy_mod.LEG_GROW_THRESHOLD;
const CONNECT_BACKOFF_NS = proxy_mod.CONNECT_BACKOFF_NS;
const SETTLE_WAIT_NS = proxy_mod.SETTLE_WAIT_NS;

// ── Pool types (non-generic — no FrontH2 dependency) ──────────────────

pub const WaiterKind = enum { flow, tunnel };

/// A parked request awaiting an upstream connect (`up.waiters`) or
/// a cold-route resolve (`route_waiters`). Opaque to the
/// connection pool: `ptr` is a `*Flow` (kind=.flow) or `*WsTunnel`
/// (kind=.tunnel), which the request layer casts back in
/// `dispatchWaiterOutcomes` / `resumeRouteWaiters`. Keeping it
/// opaque is what lets the pool (`acquireLeg`/`dialLeg`/
/// `drainWaiters`/`consumeConnects`/…) resume a connect without
/// naming the request state machines — the pool→request edge runs
/// one way only (request layer → pool).
pub const Waiter = struct { kind: WaiterKind, ptr: *anyopaque };

/// A waiter the pool drained from `up.waiters` with its connect
/// verdict, queued by `drainWaiters` and resumed by the request
/// layer in `dispatchWaiterOutcomes`.
pub const WaiterOutcome = struct { waiter: Waiter, ok: bool };

/// One pooled h2c connection to a backend node (plan A3). Legs
/// live inline in their heap-allocated `Upstream`, so `*Leg`
/// is stable for the process lifetime — FlowRef.leg and connect
/// entities point at them across polls.
pub const Leg = struct {
    up: *Upstream,
    state: enum { down, connecting, up } = .down,
    sess: Entity = Entity.nil,
    last_fail_ns: i128 = 0,
    /// Deadline for an in-flight connect to complete. Stamped at
    /// dial time; swept by `expireStalledConnects` (a SYN-
    /// blackholed backend otherwise pins its waiters for the
    /// kernel connect budget). 0 = no connect in flight.
    connect_deadline_ns: i128 = 0,
    /// Streams submitted on this leg whose terminals haven't
    /// landed — the least-loaded pick key and the shed gate.
    inflight: u32 = 0,
};

pub const Upstream = struct {
    origin: []u8, // owned, also the pool key
    addr: ?std.net.Address = null,
    legs: [MAX_LEGS]Leg,
    /// Configured leg count for this node (1..MAX_LEGS).
    n_legs: u8,
    /// Flows/tunnels waiting on an in-flight connect — AND tunnels
    /// re-parked here on a live conn whose peer hasn't yet advertised
    /// ENABLE_CONNECT_PROTOCOL (its SETTINGS trails connect-complete).
    /// `drainSettledTunnels` resumes those once the bit lands.
    waiters: std.ArrayListUnmanaged(Waiter) = .empty,
    /// Deadline for a live conn to advertise extended-connect while
    /// tunnels wait in `waiters`. 0 = unset (no tunnel awaiting
    /// SETTINGS). Stamped/cleared by `drainSettledTunnels`.
    settle_deadline_ns: i128 = 0,
    /// True once `dialLeg` has reported this origin as unresolvable.
    /// The origin is constant for the pool entry's life, so the failure
    /// repeats on every backoff retry — report it once instead of
    /// once per dial.
    origin_reported: bool = false,

    fn anyConnecting(up: *const Upstream) bool {
        for (up.legs[0..up.n_legs]) |*leg| {
            if (leg.state == .connecting) return true;
        }
        return false;
    }
};

pub const AcquireResult = union(enum) {
    /// Submit the attempt on this live leg.
    submit: *Leg,
    /// Parked on the node's waiter list (a dial is in flight or
    /// was just started); the caller sets its `waiting_conn`. The
    /// connect result resumes it via `dispatchWaiterOutcomes`.
    parked,
    /// Every leg is live but saturated — shed retryably (nothing
    /// submitted).
    shed,
    /// Every leg is down inside its reconnect backoff — re-aim at
    /// the next node.
    fail_over,
    /// Pool bookkeeping failed (OOM / unresolvable origin) — fail
    /// the attempt.
    err,
};

/// Pick or dial an upstream leg on `origin` for one attempt,
/// parking `waiter` if a connect must complete first. Opaque to
/// which request (`waiter` is a `*Flow`/`*WsTunnel` token) — this
/// keeps the leg-pick in the pool without naming the request
/// state machines.
pub fn Fns(comptime FrontH2: type) type {
    const Self = proxy_mod.Proxy(FrontH2);
    return struct {
        pub fn acquireLeg(self: *Self, origin: []const u8, waiter: Waiter) AcquireResult {
            const up = self.poolEntry(origin) catch return .err;
            const now = std.time.nanoTimestamp();
            if (self.pickLeg(up)) |leg| {
                // Background scale-out: the chosen leg is getting busy and
                // a spare leg exists — dial it for FUTURE submits; this
                // attempt rides the live leg now.
                if (leg.inflight >= LEG_GROW_THRESHOLD and !up.anyConnecting()) {
                    if (dialableLeg(up, now)) |spare| _ = self.dialLeg(spare, null);
                }
                return .{ .submit = leg };
            }
            if (up.anyConnecting()) {
                up.waiters.append(self.allocator, waiter) catch return .err;
                return .parked;
            }
            if (dialableLeg(up, now)) |leg| {
                return if (self.dialLeg(leg, waiter)) .parked else .err;
            }
            if (self.anyLegUp(up)) return .shed;
            return .fail_over;
        }

        pub fn poolEntry(self: *Self, origin: []const u8) !*Upstream {
            if (self.pool.get(origin)) |up| return up;
            const up = try self.allocator.create(Upstream);
            errdefer self.allocator.destroy(up);
            up.* = .{
                .origin = try self.allocator.dupe(u8, origin),
                .legs = undefined,
                .n_legs = @max(1, @min(self.legs_per_node, MAX_LEGS)),
            };
            for (&up.legs) |*leg| leg.* = .{ .up = up };
            try self.pool.put(self.allocator, up.origin, up);
            return up;
        }

        /// Least-loaded live leg below the stream cap; stale legs are
        /// marked down in passing (an idle reap is not a failure — no
        /// backoff). Null = nothing submittable right now.
        pub fn pickLeg(self: *Self, up: *Upstream) ?*Leg {
            var best: ?*Leg = null;
            for (up.legs[0..up.n_legs]) |*leg| {
                if (leg.state != .up) continue;
                if (self.reg.isStale(leg.sess)) {
                    leg.state = .down;
                    leg.sess = Entity.nil;
                    leg.last_fail_ns = 0;
                    continue;
                }
                if (leg.inflight >= self.leg_stream_cap) continue;
                if (best == null or leg.inflight < best.?.inflight) best = leg;
            }
            return best;
        }

        /// First down leg outside its reconnect backoff, or null.
        fn dialableLeg(up: *Upstream, now_ns: i128) ?*Leg {
            for (up.legs[0..up.n_legs]) |*leg| {
                if (leg.state != .down) continue;
                if (now_ns - leg.last_fail_ns < CONNECT_BACKOFF_NS) continue;
                return leg;
            }
            return null;
        }

        /// True if any leg is live (even saturated) — distinguishes
        /// "shed" from "node down" when nothing is submittable.
        pub fn anyLegUp(self: *Self, up: *Upstream) bool {
            for (up.legs[0..up.n_legs]) |*leg| {
                if (leg.state == .up and !self.reg.isStale(leg.sess)) return true;
            }
            return false;
        }

        /// Mark any live leg whose session died (idle-reaped / conn
        /// error) as down, without backoff.
        pub fn markStaleLegsDown(self: *Self, up: *Upstream) void {
            for (up.legs[0..up.n_legs]) |*leg| {
                if (leg.state == .up and self.reg.isStale(leg.sess)) {
                    leg.state = .down;
                    leg.sess = Entity.nil;
                    leg.last_fail_ns = 0;
                }
            }
        }

        /// Dial one down leg (caller checked backoff via `dialableLeg`).
        /// `waiter` (if any) parks on the NODE's waiter list until any leg
        /// comes up; returns true when it was parked (the caller then sets
        /// its `waiting_conn`). Returns false when the dial couldn't start
        /// or the waiter couldn't be parked — the caller fails the waiter
        /// over. A null waiter is the background scale-out dial; its return
        /// is ignored. `waiter` is opaque here (a `*Flow`/`*WsTunnel`
        /// token) — the pool never touches the request state machines.
        pub fn dialLeg(self: *Self, leg: *Leg, waiter: ?Waiter) bool {
            const up = leg.up;
            const now = std.time.nanoTimestamp();
            const addr = up.addr orelse blk: {
                const a = resolveOrigin(up.origin) catch |err| {
                    if (!up.origin_reported) {
                        up.origin_reported = true;
                        switch (err) {
                            error.HostnameOriginUnsupported => std.log.err(
                                "front: origin {s} is not an IP literal — hostname origins are unsupported (would block the poll loop on DNS); set IP-literal origins in REWIND_CLUSTERS",
                                .{up.origin},
                            ),
                            else => std.log.err(
                                "front: origin {s} is unusable: {s} — set `host:port` IP-literal origins in REWIND_CLUSTERS",
                                .{ up.origin, @errorName(err) },
                            ),
                        }
                    }
                    leg.last_fail_ns = now;
                    return false;
                };
                up.addr = a;
                break :blk a;
            };

            const ce = self.reg.create(&self.server.client_connect_in) catch return false;
            self.reg.set(ce, &self.server.client_connect_in, h2.ConnectTarget, .{ .addr = addr }) catch {};
            self.reg.set(ce, &self.server.client_connect_in, h2.Session, .{}) catch {};
            self.reg.set(ce, &self.server.client_connect_in, h2.H2IoResult, .{ .err = 0 }) catch {};
            self.reg.set(ce, &self.server.client_connect_in, FlowRef, .{ .ptr = @ptrCast(leg) }) catch {};

            leg.state = .connecting;
            leg.connect_deadline_ns = now + self.connect_timeout_ns;
            if (waiter) |w| {
                up.waiters.append(self.allocator, w) catch {
                    // The connect proceeds (other waiters may join); this
                    // one fails over.
                    return false;
                };
                return true;
            }
            return false;
        }

        pub fn consumeConnects(self: *Self, now_ns: i128) !void {
            {
                const coll = &self.server.client_connect_out;
                const entities = coll.entitySlice();
                const sessions = coll.column(h2.Session);
                const flow_refs = coll.column(FlowRef);
                for (entities, sessions, flow_refs) |ent, sess, fr| {
                    if (fr.ptr) |p| {
                        const leg: *Leg = @ptrCast(@alignCast(p));
                        leg.state = .up;
                        leg.sess = sess.entity;
                        // inflight is NOT reset: submits on the dead
                        // predecessor conn still owe their (error)
                        // terminals, each repaying exactly once.
                        leg.connect_deadline_ns = 0;
                        self.drainWaiters(leg.up, true);
                    }
                    try self.reg.destroy(ent);
                }
            }
            {
                const coll = &self.server.client_connect_errors;
                const entities = coll.entitySlice();
                const flow_refs = coll.column(FlowRef);
                for (entities, flow_refs) |ent, fr| {
                    if (fr.ptr) |p| {
                        const leg: *Leg = @ptrCast(@alignCast(p));
                        leg.state = .down;
                        leg.sess = Entity.nil;
                        leg.last_fail_ns = now_ns;
                        leg.connect_deadline_ns = 0;
                        self.count_conn_failures += 1;
                        std.log.warn("front: connect to {s} failed", .{leg.up.origin});
                        // Waiters stay parked while a sibling leg is
                        // still dialing; they fail over only when the
                        // whole node's dials are exhausted.
                        if (!leg.up.anyConnecting()) self.drainWaiters(leg.up, false);
                    }
                    try self.reg.destroy(ent);
                }
            }
        }

        /// Queue the node's parked waiters for resume with connect verdict
        /// `ok`. The request layer drains the queue in
        /// `dispatchWaiterOutcomes` — the pool itself never calls into the
        /// Flow/WsTunnel state machines, so a connect resume can't reach
        /// back into the request cluster.
        pub fn drainWaiters(self: *Self, up: *Upstream, ok: bool) void {
            // Take the list — the queued resumes may re-append to it later.
            var waiters = up.waiters;
            up.waiters = .empty;
            defer waiters.deinit(self.allocator);
            for (waiters.items) |w| {
                self.waiter_outcomes.append(self.allocator, .{ .waiter = w, .ok = ok }) catch {
                    // OOM queuing an outcome drops this waiter's resume. It
                    // stays bounded by its connect/response/route deadline
                    // (not stranded), and OOM here means the process is
                    // already failing — preferable to unbounded retry
                    // mid-drain.
                };
            }
        }

        /// Resume tunnels re-parked in `up.waiters` on a live conn that hadn't
        /// yet advertised ENABLE_CONNECT_PROTOCOL (the SETTINGS-trails-connect
        /// race). Iterates the small, stable `pool` map — never an entity
        /// column — so there is no cross-lifetime pointer deref (the bug class
        /// that sank the first attempt at this fix). A `drainWaiters(false)`
        /// can re-aim a tunnel and thereby `poolEntry`-insert a new pool entry,
        /// so snapshot the (heap-stable) `*Upstream` set before acting.
        pub fn drainSettledTunnels(self: *Self, now_ns: i128) void {
            var ups: [64]*Upstream = undefined;
            var n: usize = 0;
            var it = self.pool.valueIterator();
            while (it.next()) |up_ptr| {
                if (n >= ups.len) {
                    // Implausible (pool size ≈ cluster nodes); the rest are
                    // serviced next cycle — their deadlines still bound them.
                    std.log.warn("front: pool exceeds {d} entries — settling sweep deferred some", .{ups.len});
                    break;
                }
                ups[n] = up_ptr.*;
                n += 1;
            }
            for (ups[0..n]) |up| {
                if (up.waiters.items.len == 0) {
                    up.settle_deadline_ns = 0;
                    continue;
                }
                self.markStaleLegsDown(up);
                var any_up = false;
                var any_settled = false;
                for (up.legs[0..up.n_legs]) |*leg| {
                    if (leg.state != .up) continue;
                    any_up = true;
                    if (self.server.connExtendedConnect(leg.sess)) any_settled = true;
                }
                if (any_settled) {
                    up.settle_deadline_ns = 0;
                    self.drainWaiters(up, true);
                } else if (any_up) {
                    if (up.settle_deadline_ns == 0) {
                        up.settle_deadline_ns = now_ns + SETTLE_WAIT_NS;
                    } else if (now_ns >= up.settle_deadline_ns) {
                        std.log.warn("front: {s} never advertised extended-connect within {d}ms — failing {d} waiting WS tunnel(s)", .{ up.origin, @divTrunc(SETTLE_WAIT_NS, std.time.ns_per_ms), up.waiters.items.len });
                        up.settle_deadline_ns = 0;
                        self.drainWaiters(up, false);
                    }
                } else if (up.anyConnecting()) {
                    // A dial is in flight; its completion drains the
                    // waiters (either way).
                    up.settle_deadline_ns = 0;
                } else {
                    // Every leg died under the waiters — fail them
                    // (they re-aim).
                    up.settle_deadline_ns = 0;
                    self.drainWaiters(up, false);
                }
            }
        }

        /// Fail the waiters of any `.connecting` pool entry past its
        /// connect deadline (plan A1). The io connect op has no timeout,
        /// so a SYN-blackholed backend otherwise pins its waiters for
        /// the kernel connect budget (~2 min); waiters fail over to the
        /// next node instead (`attemptFailed` with nothing sent — safe
        /// for any method). The entry is marked down with a fresh
        /// backoff stamp so immediate re-dials don't hammer it. The
        /// LATE io completion is harmless: a success flips the entry
        /// back to `.up` (usable, waiters already gone; the conn is
        /// idle-reaped if unused), an error re-marks it down. Snapshot
        /// the heap-stable `*Upstream` set first — `drainWaiters` can
        /// re-aim a flow and `poolEntry`-insert a new entry (the same
        /// pattern as `drainSettledTunnels`).
        pub fn expireStalledConnects(self: *Self, now_ns: i128) void {
            var ups: [64]*Upstream = undefined;
            var n: usize = 0;
            var it = self.pool.valueIterator();
            while (it.next()) |up_ptr| {
                if (n >= ups.len) {
                    std.log.warn("front: pool exceeds {d} entries — connect sweep deferred some", .{ups.len});
                    break;
                }
                ups[n] = up_ptr.*;
                n += 1;
            }
            for (ups[0..n]) |up| {
                var timed_out = false;
                for (up.legs[0..up.n_legs]) |*leg| {
                    if (leg.state != .connecting or leg.connect_deadline_ns == 0) continue;
                    if (now_ns < leg.connect_deadline_ns) continue;
                    std.log.warn("front: connect to {s} timed out after {d}ms", .{
                        up.origin,
                        @divTrunc(self.connect_timeout_ns, std.time.ns_per_ms),
                    });
                    leg.state = .down;
                    leg.sess = Entity.nil;
                    leg.last_fail_ns = now_ns;
                    leg.connect_deadline_ns = 0;
                    self.count_connect_timeouts += 1;
                    timed_out = true;
                }
                if (!timed_out) continue;
                // A dial just died. Waiters fail over only when no dial
                // remains in flight; a live sibling leg (if any) serves
                // them instead. (Waiters parked for extended-connect
                // SETTLE stay owned by drainSettledTunnels.)
                if (up.waiters.items.len > 0 and !up.anyConnecting()) {
                    self.drainWaiters(up, self.anyLegUp(up));
                }
            }
        }
    };
}
