//! Holder → worker wake delivery (plan §6.1 degenerate case).
//!
//! The holder forwards a parked request to a worker. A wake is "an
//! ordinary replayable request" (plan §1) — for the `open` wake at
//! chain-length-one that means: replay the captured connect request
//! to a worker, let the worker's normal pipeline run the owning
//! tenant's handler (its response is already gated on the raft
//! propose by the existing data-durability model), and hand the
//! response back so the holder can flush it to the held socket and
//! close.
//!
//! The forward carries the internal bearer so the worker can treat
//! it as platform-originated (layer 3). Synchronous inside the
//! holder's drain for 2b; the async apply→notify path is Phase 3's
//! concern, forced there by cross-wake fan-in, not by the
//! degenerate case.

const std = @import("std");
const blob_curl = @import("rove-blob").curl;

/// Sentinel header an `open` handler that wants to STAY HELD sets
/// (plan §6.4: "fires http.send(on_result) but does not complete the
/// HTTP response — it pends nothing and the handle stays held"). The
/// `connection.hold()` JS shim (Phase 3b) produces a response
/// carrying this; 3a only needs the holder to recognise it.
pub const HOLD_HEADER = "x-rove-hold";

/// The worker's response to a forwarded `open` wake. `body` is owned
/// by the caller's allocator; `deinit` frees it.
pub const WakeResult = struct {
    status: u16,
    body: []u8,
    /// Echoed content-type (empty → none). Separately owned.
    ctype: []u8,
    /// True iff the handler returned the hold sentinel — the
    /// connection must STAY PARKED (a later `connection.respond`
    /// callback, or the deadline, resolves it). Plan §6.4.
    held: bool,

    pub fn deinit(self: *WakeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.ctype);
    }
};

/// Forward the captured connect request to `worker_base` as the
/// `open` wake. Returns the worker's status + body for the holder to
/// flush onto the held socket.
///
/// `handle`/`tenant` ride dedicated headers so a later phase's
/// worker-side wake intake can bind the owning tenant from the
/// internal-token'd claim (layer 4) rather than a spoofable Host;
/// 2b's worker is unmodified and ignores them, which is fine for the
/// chain-length-one proof.
pub fn deliverOpenWake(
    allocator: std.mem.Allocator,
    easy: *blob_curl.Easy,
    worker_base: []const u8,
    internal_token: ?[]const u8,
    tenant: []const u8,
    handle: []const u8,
    method: []const u8,
    body: []const u8,
    ctype: []const u8,
    insecure_tls: bool,
    timeout_ms: u32,
) !WakeResult {
    // Degenerate §6.1: forward to the worker root. How a held
    // connection maps to a customer route is a Phase-3 concern (the
    // §6.4 connect/upgrade request carries the real target); the
    // captured original path is kept on the Connection for then.
    const url = try std.fmt.allocPrint(allocator, "{s}/", .{worker_base});
    defer allocator.free(url);

    var hdrs: std.ArrayListUnmanaged(blob_curl.Header) = .empty;
    defer hdrs.deinit(allocator);
    var auth_buf: ?[]u8 = null;
    defer if (auth_buf) |b| allocator.free(b);
    if (internal_token) |tok| {
        auth_buf = try std.fmt.allocPrint(allocator, "Bearer {s}", .{tok});
        try hdrs.append(allocator, .{ .name = "Authorization", .value = auth_buf.? });
    }
    try hdrs.append(allocator, .{ .name = "X-Rove-Wake", .value = "open" });
    try hdrs.append(allocator, .{ .name = "X-Rove-Conn", .value = handle });
    try hdrs.append(allocator, .{ .name = "X-Rove-Tenant", .value = tenant });
    if (ctype.len > 0) {
        try hdrs.append(allocator, .{ .name = "Content-Type", .value = ctype });
    }

    const use_h2c = std.mem.startsWith(u8, url, "http://");
    const m: blob_curl.Method = if (std.mem.eql(u8, method, "POST"))
        .POST
    else if (std.mem.eql(u8, method, "PUT"))
        .PUT
    else if (std.mem.eql(u8, method, "DELETE"))
        .DELETE
    else
        .GET;

    var resp = try easy.request(allocator, .{
        .method = m,
        .url = url,
        .headers = hdrs.items,
        .body = body,
        .timeout_ms = timeout_ms,
        .connect_timeout_ms = 1_000,
        .http_version = if (use_h2c) .h2c_prior_knowledge else .auto,
        .verify_tls = !insecure_tls,
    });
    defer resp.deinit(allocator);

    const body_owned = try allocator.dupe(u8, if (resp.body) |b| b else "");
    errdefer allocator.free(body_owned);
    var ct_owned: []u8 = try allocator.dupe(u8, "");
    var held = false;
    for (resp.headers) |hh| {
        if (std.ascii.eqlIgnoreCase(hh.name, "content-type")) {
            allocator.free(ct_owned);
            ct_owned = try allocator.dupe(u8, hh.value);
        } else if (std.ascii.eqlIgnoreCase(hh.name, HOLD_HEADER)) {
            held = true;
        }
    }
    return .{ .status = resp.status, .body = body_owned, .ctype = ct_owned, .held = held };
}
