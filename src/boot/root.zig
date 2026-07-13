//! rove-boot — the shared process-boot scaffolding for the four serving
//! binaries (rewind-worker / rewind-cp / rewind-front / rewind-logs).
//! It holds the blocks the four binaries share: SIGINT/TERM → stop-flag
//! wiring, URL-list env parsing, and the operator-metrics listener
//! bring-up (whose per-binary default ports must stay disjoint so all
//! four coexist on a co-located host — that invariant lives in ONE
//! table below).

const std = @import("std");
const MetricsServer = @import("metrics-server").MetricsServer;

// ── Signal-driven shutdown ────────────────────────────────────────────

var stop_ptr: ?*std.atomic.Value(bool) = null;

fn handleSignal(_: c_int) callconv(.c) void {
    if (stop_ptr) |p| p.store(true, .release);
}

/// Route SIGINT/SIGTERM to `flag` (the binary's stop flag; its poll loop
/// reads it with `.acquire`). Call once from main before the loop.
pub fn installSignalHandlers(flag: *std.atomic.Value(bool)) void {
    stop_ptr = flag;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

// ── URL-list env parsing ──────────────────────────────────────────────

/// Parse a `;`/`,`-separated list of origins into an owned, owned-element
/// slice (a single URL → a one-element list; empty input → empty slice).
pub fn parseUrlList(a: std.mem.Allocator, config: []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |u| a.free(u);
        list.deinit(a);
    }
    var it = std.mem.tokenizeAny(u8, config, ";,");
    while (it.next()) |raw| {
        const url = std.mem.trim(u8, raw, " \t\r\n");
        if (url.len == 0) continue;
        try list.append(a, try a.dupe(u8, url));
    }
    return list.toOwnedSlice(a);
}

pub fn freeUrlList(a: std.mem.Allocator, urls: []const []const u8) void {
    for (urls) |u| a.free(u);
    a.free(urls);
}

// ── Operator-metrics listener ─────────────────────────────────────────

/// Default operator-metrics ports, one per binary — DISJOINT so all four
/// coexist on a co-located production host. Change one here and the
/// others stay visibly clear of it.
pub const METRICS_PORT_WORKER: u16 = 9110;
pub const METRICS_PORT_CP: u16 = 9111;
pub const METRICS_PORT_FRONT: u16 = 9112;
pub const METRICS_PORT_LOGS: u16 = 9113;

/// Read a port from `name`, falling back to `default` when unset or
/// unparseable.
pub fn parsePortEnv(name: []const u8, default: u16) u16 {
    const s = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(u16, std.mem.trim(u8, s, " \t"), 10) catch default;
}

/// Bring up the dedicated loopback HTTP/1.1 operator-metrics listener —
/// separate from the binary's data port so stock Prometheus/Alloy can
/// scrape it and so `/metrics` stays answerable while the main loop is
/// wedged. Bound to 127.0.0.1 (node-local scrapes; network isolation is
/// the auth). `{env_name}=0` disables; a bind failure warns and runs
/// without metrics (they're optional, the service isn't). Caller
/// `deinit`s the returned server.
pub fn metricsFromEnv(
    allocator: std.mem.Allocator,
    env_name: []const u8,
    default_port: u16,
    bin_name: []const u8,
) ?*MetricsServer {
    const mport = parsePortEnv(env_name, default_port);
    if (mport == 0) return null;
    const maddr = std.net.Address.parseIp("127.0.0.1", mport) catch return null;
    const srv = MetricsServer.init(allocator, maddr) catch |err| {
        std.log.warn("{s}: operator metrics listener disabled — bind 127.0.0.1:{d} failed ({s})", .{ bin_name, mport, @errorName(err) });
        return null;
    };
    std.log.info("{s}: operator metrics on http://127.0.0.1:{d}/metrics", .{ bin_name, mport });
    return srv;
}

/// The ~2s re-render/publish cadence gate the serving loops share:
/// `if (cadence.due(std.time.nanoTimestamp())) { render + publish }`.
/// Pure timing — rendering stays with the binary (each reads its own
/// counters on its own loop thread).
pub const Cadence = struct {
    interval_ns: i128 = 2 * std.time.ns_per_s,
    last_ns: i128 = 0,

    pub fn due(self: *Cadence, now_ns: i128) bool {
        if (now_ns - self.last_ns < self.interval_ns) return false;
        self.last_ns = now_ns;
        return true;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseUrlList: splits on ;/,, trims, drops empties" {
    const a = testing.allocator;
    const urls = try parseUrlList(a, " http://a:1 ;, http://b:2,");
    defer freeUrlList(a, urls);
    try testing.expectEqual(@as(usize, 2), urls.len);
    try testing.expectEqualStrings("http://a:1", urls[0]);
    try testing.expectEqualStrings("http://b:2", urls[1]);

    const empty = try parseUrlList(a, "");
    defer freeUrlList(a, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "Cadence: gates to the interval" {
    var c = Cadence{ .interval_ns = 100 };
    try testing.expect(c.due(1000));
    try testing.expect(!c.due(1050));
    try testing.expect(c.due(1100));
}

test "metrics ports are pairwise disjoint" {
    const ports = [_]u16{ METRICS_PORT_WORKER, METRICS_PORT_CP, METRICS_PORT_FRONT, METRICS_PORT_LOGS };
    for (ports, 0..) |p, i| for (ports[i + 1 ..]) |q| try testing.expect(p != q);
}
