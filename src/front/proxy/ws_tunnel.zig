//! Extended-CONNECT (RFC 8441) WebSocket tunnel leg for rewind-front.
//!
//! Each accepted downstream h1 Upgrade tunnels upstream as a CONNECT
//! stream on the pooled h2c conn (architecture/websockets.md); the front
//! relays raw bytes both ways, the worker unmasks. This file owns the
//! tunnel *leg* lifecycle — attempt/submit on a pool leg, the CONNECT
//! response -> downstream 101, the two relay sinks, re-aim/teardown.
//! Accepting the Upgrade + route resolution (`intakeWsUpgrades`) stays in
//! proxy.zig with the other intake; the `WsTunnel` struct stays nested in
//! `Proxy` (it holds `proxy: *Self`).
//!
//! Methods are `Fns(comptime FrontH2)` on the generic `Proxy(FrontH2)`,
//! re-exported onto it in proxy.zig so `self.X()` cross-calls and
//! concrete types survive without `anytype`. It shares the leg pool via
//! the opaque `Waiter` (never naming Flow) and the pure header helpers in
//! util.zig.

const std = @import("std");
const rove = @import("rove");
const h2 = @import("rove-h2");
const Entity = rove.Entity;

const proxy_mod = @import("../proxy.zig");
const pool = @import("pool.zig");
const util = @import("util.zig");
const route_cache = @import("route_cache.zig");

const FlowRef = proxy_mod.FlowRef;
const freeNodes = route_cache.freeNodes;
const headerValue = util.headerValue;
const packFields = util.packFields;
const NameValue = util.NameValue;

pub fn Fns(comptime FrontH2: type) type {
    const Self = proxy_mod.Proxy(FrontH2);
    const WsTunnel = Self.WsTunnel;
    const Leg = pool.Leg;
    const keyOf = Self.keyOf;
    return struct {
        pub fn startTunnelAttempt(self: *Self, t: *WsTunnel) void {
            t.up_sid = 0;
            t.up_sess = Entity.nil;
            t.chunk_inflight = 0;
            switch (self.acquireLeg(t.nodes[t.node_idx], .{ .kind = .tunnel, .ptr = t })) {
                .submit => |leg| self.submitTunnel(t, leg),
                .parked => t.waiting_conn = true,
                .shed => {
                    // Saturated: refuse the Upgrade retryably (plan A3).
                    self.count_upstream_sheds += 1;
                    self.tunnelAttemptFailed(t);
                },
                .fail_over, .err => self.tunnelAttemptFailed(t),
            }
        }

        /// Open the Extended-CONNECT stream on a live pool leg. RFC 8441
        /// requires the peer's ENABLE_CONNECT_PROTOCOL before submitting.
        pub fn submitTunnel(self: *Self, t: *WsTunnel, leg: *Leg) void {
            if (!self.server.connExtendedConnect(leg.sess)) {
                // Live conn, but the peer's ENABLE_CONNECT_PROTOCOL SETTINGS
                // hasn't arrived yet — common on a freshly-`.up` leg (its
                // SETTINGS trails connect-complete). Re-park on the pool
                // entry's existing waiter list (the same home as a tunnel
                // awaiting connect) rather than failing; drainSettledTunnels
                // resumes it once the bit lands. The old immediate give-up
                // surfaced a transient 502 on cold upstream connections.
                leg.up.waiters.append(self.allocator, .{ .kind = .tunnel, .ptr = t }) catch {
                    self.tunnelAttemptFailed(t);
                    return;
                };
                t.waiting_conn = true;
                return;
            }
            const packed_hdrs = self.packTunnelHeaders(t) catch {
                self.tunnelAttemptFailed(t);
                return;
            };
            const pump = self.reg.create(&self.server.client_stream_request_in) catch {
                if (packed_hdrs._buf) |b| self.allocator.free(b[0..packed_hdrs._buf_len]);
                self.tunnelAttemptFailed(t);
                return;
            };
            const coll = &self.server.client_stream_request_in;
            t.attempt += 1;
            self.reg.set(pump, coll, h2.Session, .{ .entity = leg.sess }) catch {};
            self.reg.set(pump, coll, h2.ReqHeaders, packed_hdrs) catch {};
            self.reg.set(pump, coll, h2.ReqBody, .{}) catch {};
            self.reg.set(pump, coll, h2.H2IoResult, .{ .err = 0 }) catch {};
            self.reg.set(pump, coll, h2.StreamId, .{ .id = 0 }) catch {};
            self.reg.set(pump, coll, FlowRef, .{ .ptr = @ptrCast(t), .attempt = t.attempt, .tunnel = true, .leg = @ptrCast(leg) }) catch {};
            leg.inflight += 1;
            t.up_sess = leg.sess;
            t.attempt_live = true;
            t.pending_terminals += 1;
        }

        /// The five RFC 8441 CONNECT headers + the forwarding identity
        /// (plan B7), one owned buffer via `packFields`.
        pub fn packTunnelHeaders(self: *Self, t: *WsTunnel) !h2.ReqHeaders {
            // :path comes from the Upgrade head (still on the entity).
            const rh_src = self.reg.get(t.upgrade_ent, &self.server.ws_upgrade_out, h2.ReqHeaders) catch null;
            const path: []const u8 = if (rh_src) |rh| (headerValue(rh.*, ":path") orelse "/") else "/";

            var pairs: [8]NameValue = undefined;
            var n: usize = 0;
            pairs[n] = .{ .name = ":method", .value = "CONNECT" };
            n += 1;
            pairs[n] = .{ .name = ":protocol", .value = "websocket" };
            n += 1;
            pairs[n] = .{ .name = ":scheme", .value = "http" };
            n += 1;
            pairs[n] = .{ .name = ":authority", .value = t.authority };
            n += 1;
            pairs[n] = .{ .name = ":path", .value = path };
            n += 1;
            if (t.peer_ip_len > 0) {
                pairs[n] = .{ .name = "x-forwarded-for", .value = t.peer_ip[0..t.peer_ip_len] };
                n += 1;
            }
            pairs[n] = .{ .name = "x-forwarded-proto", .value = t.fwd_proto };
            n += 1;
            pairs[n] = .{ .name = "via", .value = "1.1 rewind-front" }; // WS upgrades are h1 at the edge
            n += 1;
            const p = try packFields(self.allocator, pairs[0..n]);
            return .{ .fields = p.fields, .count = p.count, ._buf = p.buf, ._buf_len = p.buf_len };
        }

        /// Current tunnel attempt failed before the 200: next node or
        /// refuse the downstream Upgrade.
        pub fn tunnelAttemptFailed(self: *Self, t: *WsTunnel) void {
            self.unmapTunnel(t);
            t.attempt_live = false;
            if (t.down_gone or self.reg.isStale(t.down_conn)) {
                self.finishTunnel(t);
                return;
            }
            if (t.node_idx + 1 < t.nodes.len) {
                t.node_idx += 1;
                self.startTunnelAttempt(t);
                return;
            }
            self.cache.invalidate(t.host);
            self.finishTunnel(t);
        }

        pub fn unmapTunnel(self: *Self, t: *WsTunnel) void {
            if (!t.up_sess.isNil() and t.up_sid != 0) {
                _ = self.tunnels_by_up.remove(keyOf(t.up_sess, t.up_sid));
            }
        }

        /// Terminal state: nothing more will happen for this tunnel. An
        /// undecided downstream Upgrade is refused here (also destroys
        /// the handle entity when the conn is already dead). Frees once
        /// outstanding terminals + sink refs drain.
        pub fn finishTunnel(self: *Self, t: *WsTunnel) void {
            if (!t.decided) {
                t.decided = true;
                self.server.wsUpgradeReject(t.upgrade_ent, 502);
            }
            t.done = true;
            self.maybeDestroyTunnel(t);
        }

        pub fn maybeDestroyTunnel(self: *Self, t: *WsTunnel) void {
            if (!t.done or t.pending_terminals != 0 or t.sink_refs != 0) return;
            if (t.peer_ip_len > 0) self.peerFlowDec(t.peer_ip[0..t.peer_ip_len]);
            self.unmapTunnel(t);
            self.allocator.free(t.authority);
            self.allocator.free(t.host);
            freeNodes(self.allocator, t.nodes);
            t.up_buf.deinit(self.allocator);
            self.live_tunnels -= 1;
            self.allocator.destroy(t);
        }

        /// Terminal failure of a route-parked tunnel: reject the still-held
        /// Upgrade with `code` (retryable), unless the downstream already
        /// died — `finishTunnel` then just reaps the handle. No upstream
        /// attempt was ever started, so there are no terminals to await.
        pub fn failParkedTunnel(self: *Self, t: *WsTunnel, code: u16) void {
            t.awaiting_route = false;
            if (!t.decided and !t.down_gone and !self.reg.isStale(t.down_conn)) {
                t.decided = true;
                self.server.wsUpgradeReject(t.upgrade_ent, code);
            }
            self.finishTunnel(t);
        }

        // Tunnel sinks. Downstream socket bytes → `up_buf` (pumped as
        // upstream chunks); upstream response bytes → the downstream
        // write queue. Both run on the poll thread.
        fn tunnelOf(ctx: *anyopaque) *WsTunnel {
            return @ptrCast(@alignCast(ctx));
        }
        fn downTunnelPush(ctx: *anyopaque, bytes: []const u8) bool {
            const t = tunnelOf(ctx);
            if (t.done) return false;
            t.up_buf.appendSlice(t.proxy.allocator, bytes) catch return false;
            return true;
        }
        fn downTunnelFinish(_: *anyopaque) void {}
        fn downTunnelAbort(ctx: *anyopaque) void {
            const t = tunnelOf(ctx);
            t.down_gone = true;
        }
        fn downTunnelDrained(ctx: *anyopaque) u32 {
            const t = tunnelOf(ctx);
            const d = t.down_drained;
            t.down_drained = 0;
            return d;
        }
        fn downTunnelRelease(ctx: *anyopaque) void {
            const t = tunnelOf(ctx);
            t.down_gone = true;
            t.sink_refs -|= 1;
            t.proxy.maybeDestroyTunnel(t);
        }
        fn downTunnelSinkOf(t: *WsTunnel) h2.BodySink {
            return .{
                .ctx = @ptrCast(t),
                .push = &downTunnelPush,
                .finish = &downTunnelFinish,
                .abort = &downTunnelAbort,
                .drained = &downTunnelDrained,
                .release = &downTunnelRelease,
            };
        }
        fn upTunnelPush(ctx: *anyopaque, bytes: []const u8) bool {
            const t = tunnelOf(ctx);
            if (t.down_gone or t.proxy.reg.isStale(t.down_conn)) return false;
            t.proxy.server.wsTunnelWrite(t.down_conn, bytes);
            t.up_drained +%= @intCast(bytes.len);
            return true;
        }
        fn upTunnelFinish(ctx: *anyopaque) void {
            // Upstream ended cleanly (worker sent Close + END): close
            // the downstream socket once its queue drains.
            const t = tunnelOf(ctx);
            t.proxy.server.wsTunnelClose(t.down_conn);
        }
        fn upTunnelAbort(ctx: *anyopaque) void {
            const t = tunnelOf(ctx);
            if (!t.down_gone and !t.proxy.reg.isStale(t.down_conn)) {
                t.proxy.reg.destroy(t.down_conn) catch {};
            }
        }
        fn upTunnelDrained(ctx: *anyopaque) u32 {
            const t = tunnelOf(ctx);
            const d = t.up_drained;
            t.up_drained = 0;
            return d;
        }
        fn upTunnelRelease(ctx: *anyopaque) void {
            const t = tunnelOf(ctx);
            t.sink_refs -|= 1;
            t.proxy.maybeDestroyTunnel(t);
        }
        fn upTunnelSinkOf(t: *WsTunnel) h2.BodySink {
            return .{
                .ctx = @ptrCast(t),
                .push = &upTunnelPush,
                .finish = &upTunnelFinish,
                .abort = &upTunnelAbort,
                .drained = &upTunnelDrained,
                .release = &upTunnelRelease,
            };
        }

        /// An early-emitted response on a tunnel's CONNECT stream. 200 =
        /// tunnel accepted: send the deferred downstream 101 and wire
        /// both relay sinks. Anything else = refused mid-handshake.
        pub fn tunnelResponse(self: *Self, t: *WsTunnel, up_sess: Entity, up_sid: u32, code: u16) void {
            if (code != 200 or t.down_gone or self.reg.isStale(t.down_conn)) {
                self.server.clientStreamReset(up_sess, up_sid);
                self.tunnelAttemptFailed(t);
                return;
            }
            t.decided = true;
            switch (self.server.wsUpgradeAccept(t.upgrade_ent, downTunnelSinkOf(t))) {
                .ok => {
                    t.accepted = true;
                    t.sink_refs += 1;
                },
                .gone => {
                    // Downstream died between intake and the 200.
                    self.server.clientStreamReset(up_sess, up_sid);
                    self.finishTunnel(t);
                    return;
                },
            }
            switch (self.server.requestBodySink(up_sess, up_sid, upTunnelSinkOf(t))) {
                .streaming, .eof => t.sink_refs += 1,
                .gone => {
                    // Upstream stream already dead; terminal will land.
                    self.server.wsTunnelClose(t.down_conn);
                },
            }
        }
    };
}
