//! CP → backend HTTP client — the move-secret-authenticated call the
//! control plane makes to a rewind worker's `/_system/*` surface, split out
//! of `cp/main.zig`'s Router. Every move-orchestration and membership-
//! reconciler hop rides `call` / `callTimeout`; centralizing them keeps the
//! move-secret header + the CP transport in one place.
//!
//! Free functions taking `router: anytype` for structural access to the
//! Router's `allocator` + `move_secret` — the same shape the worker_*.zig
//! family uses.

const std = @import("std");
const blob = @import("rove-blob");
const curl = blob.curl;

/// Header carrying the shared move-secret, required on every CP↔worker
/// `/_system/*` call and checked on the CP's own `/_control/*` writes.
pub const MOVE_SECRET_HEADER = "X-Rewind-Move-Secret";

/// One backend response the orchestrator cares about: status + an owned
/// copy of the body (the source bundle, relayed into the attach call).
pub const BackendResp = struct {
    status: u16,
    body: []u8,
    pub fn deinit(self: BackendResp, a: std.mem.Allocator) void {
        a.free(self.body);
    }
};

/// POST/GET a worker's `/_system/*` surface with the move-secret header and
/// the standard 15 s deadline.
pub fn call(
    router: anytype,
    base_url: []const u8,
    path_suffix: []const u8,
    method: curl.Method,
    body: []const u8,
    extra_headers: []const curl.Header,
) !BackendResp {
    return callTimeout(router, base_url, path_suffix, method, body, extra_headers, 15_000);
}

/// `call` with an explicit total-transfer deadline. A streamed move push
/// (`v2-snapshot-push`) holds the CP↔source call open for the WHOLE transfer
/// (the source parks until its off-loop push lands), so it needs a generous
/// timeout — the source's own `REWIND_SNAPSHOT_XFER_MAX_MS` deadline aborts +
/// responds first; this is the wedged-source backstop.
pub fn callTimeout(
    router: anytype,
    base_url: []const u8,
    path_suffix: []const u8,
    method: curl.Method,
    body: []const u8,
    extra_headers: []const curl.Header,
    timeout_ms: u32,
) !BackendResp {
    const a = router.allocator;
    const url = try std.fmt.allocPrint(a, "{s}{s}", .{ base_url, path_suffix });
    defer a.free(url);

    var headers: std.ArrayListUnmanaged(curl.Header) = .empty;
    defer headers.deinit(a);
    try headers.append(a, .{ .name = MOVE_SECRET_HEADER, .value = router.move_secret.? });
    for (extra_headers) |h| try headers.append(a, h);

    var resp = try curl.cpRequest(a, method, url, body, .{
        .headers = headers.items,
        .timeout_ms = timeout_ms,
    });
    defer resp.deinit(a);

    const body_copy = if (resp.body) |b| try a.dupe(u8, b) else try a.dupe(u8, "");
    return .{ .status = resp.status, .body = body_copy };
}
