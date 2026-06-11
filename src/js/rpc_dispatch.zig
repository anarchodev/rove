//! Dispatch resolution — which export an activation invokes.
//!
//! Extracted from `dispatcher.zig`. The platform invokes exactly ONE
//! export per activation: the resume path's first-class target
//! (`Request.fn_override` + `Request.fn_args_json`, set by the worker's
//! resume engines) or, when none is named, the activation kind's
//! conventional export (`defaultExportForKind`).
//!
//! The former customer-facing `{fn,args}` JSON-body envelope and
//! `?fn=name&args=` query dispatch are RETIRED (decisions.md §4.5):
//! the request body and query string are opaque payload the platform
//! never interprets. Handlers that want named-function routing do it
//! in JS — the documented `rpc({...})` recipe in `handler-shape.md`
//! parses the same wire shapes inside the handler, where every read
//! is taped. Pure data-shaping — no JS engine, no `Dispatcher` state.

const std = @import("std");
const request_mod = @import("request.zig");

const Request = request_mod.Request;
const ActivationSource = request_mod.ActivationSource;

/// Resolved `(fn, args)` for one activation. `args_json_text` is a raw
/// JSON array literal (e.g. `[]`, `[{...ctx},{...outcome}]`); the
/// caller does one `JS_ParseJSON` on it and spreads the elements into
/// the handler call.
pub const DispatchCall = struct {
    fn_name: []u8,
    args_json_text: []u8,

    pub fn deinit(self: *DispatchCall, allocator: std.mem.Allocator) void {
        allocator.free(self.fn_name);
        allocator.free(self.args_json_text);
        self.* = undefined;
    }
};

pub fn parseDispatch(
    allocator: std.mem.Allocator,
    request: Request,
) error{OutOfMemory}!DispatchCall {
    // Headers-first dispatch targets `onHeaders` unconditionally, and
    // chunk dispatch targets `onChunk` (gap 2.4) — these are the
    // activation's structural contract; no override applies (no
    // resume engine sets one on them).
    if (request.activation == .inbound_headers) {
        const fn_owned = try allocator.dupe(u8, "onHeaders");
        errdefer allocator.free(fn_owned);
        return .{ .fn_name = fn_owned, .args_json_text = try allocator.dupe(u8, "[]") };
    }
    if (request.activation == .inbound_chunk) {
        const fn_owned = try allocator.dupe(u8, "onChunk");
        errdefer allocator.free(fn_owned);
        return .{ .fn_name = fn_owned, .args_json_text = try allocator.dupe(u8, "[]") };
    }

    // Internal resume-path target (send-callback / wake / bound-fetch /
    // subscription / chained dispatch) — first-class on the Request,
    // never parsed out of the body or query.
    if (request.fn_override) |fn_name| {
        if (fn_name.len > 0) {
            const fn_owned = try allocator.dupe(u8, fn_name);
            errdefer allocator.free(fn_owned);
            return .{
                .fn_name = fn_owned,
                .args_json_text = try allocator.dupe(u8, request.fn_args_json),
            };
        }
    }

    // The activation kind's conventional export (handler-surface
    // Phase 4, docs/handler-shape.md §3).
    const fn_owned = try allocator.dupe(u8, defaultExportForKind(request.activation.source()));
    errdefer allocator.free(fn_owned);
    return .{ .fn_name = fn_owned, .args_json_text = try allocator.dupe(u8, "[]") };
}

/// Handler-surface Phase 4: map an activation source to its conventional
/// named export, used when the resume path didn't name one explicitly
/// (`Request.fn_override`). `wake_batch` (the `on.kv`/`on.timer` edge
/// wake — and the legacy singular `kv_wake`/`timer`) lands in `onWake`.
/// Inbound and the kinds whose resume path always names its own target —
/// send_callback (the `next({fn})` / `on_result`), fetch_chunk
/// (`{to}`/`onFetchChunk`), cron + subscription_fire (the registration's
/// export), durable_wake (the baked `scheduler_tick` default) — fall
/// through to `default`.
fn defaultExportForKind(src: ActivationSource) []const u8 {
    return switch (src) {
        .wake_batch, .kv_wake, .timer => "onWake",
        .disconnect => "onDisconnect",
        .ws_message => "onMessage",
        .inbound_headers => "onHeaders",
        .inbound_chunk => "onChunk",
        else => "default",
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseDispatch: inbound with no override → default, empty args" {
    var call = try parseDispatch(testing.allocator, .{
        .method = "POST",
        .path = "/",
        .body = "{\"fn\":\"ignored\",\"args\":[1]}",
        .query = "fn=also-ignored",
    });
    defer call.deinit(testing.allocator);
    // Body and query are opaque payload — the retired envelope shapes
    // must NOT influence dispatch.
    try testing.expectEqualStrings("default", call.fn_name);
    try testing.expectEqualStrings("[]", call.args_json_text);
}

test "parseDispatch: fn_override wins and carries its args" {
    var call = try parseDispatch(testing.allocator, .{
        .method = "POST",
        .path = "/",
        .activation = .send_callback,
        .fn_override = "onCharge",
        .fn_args_json = "[{\"k\":1},{\"ok\":true}]",
    });
    defer call.deinit(testing.allocator);
    try testing.expectEqualStrings("onCharge", call.fn_name);
    try testing.expectEqualStrings("[{\"k\":1},{\"ok\":true}]", call.args_json_text);
}

test "parseDispatch: empty fn_override falls back to the conventional export" {
    var call = try parseDispatch(testing.allocator, .{
        .method = "POST",
        .path = "/",
        .activation = .{ .wake_batch = .{} },
        .fn_override = "",
    });
    defer call.deinit(testing.allocator);
    try testing.expectEqualStrings("onWake", call.fn_name);
}
