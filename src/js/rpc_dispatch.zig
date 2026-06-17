//! Dispatch resolution — which export an activation invokes.
//!
//! Extracted from `dispatcher.zig`. The platform invokes exactly ONE
//! export per activation: the resume path's first-class target
//! (`Request.fn_override`, set by the worker's resume engines) or, when
//! none is named, the activation kind's conventional export
//! (`defaultExportForKind`). The export is always called with no
//! positional arguments — resume payloads ride `request.body` and the
//! `request.activation` union.
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

/// Resolve which export an activation invokes. Returns the owned
/// export name; the platform calls it with no positional arguments —
/// resume payloads (ctx / outcome) ride `request.body` and the typed
/// `request.activation` union, read through the request surface so
/// every read is taped (decisions.md §4.5). Caller owns the returned
/// slice.
pub fn parseDispatch(
    allocator: std.mem.Allocator,
    request: Request,
) error{OutOfMemory}![]u8 {
    // Headers-first dispatch targets `onHeaders` unconditionally, and
    // chunk dispatch targets `onChunk` (gap 2.4) — these are the
    // activation's structural contract; no override applies (no
    // resume engine sets one on them).
    if (request.activation == .inbound_headers) return allocator.dupe(u8, "onHeaders");
    if (request.activation == .inbound_chunk) return allocator.dupe(u8, "onChunk");

    // Internal resume-path target (send-callback / wake / bound-fetch /
    // subscription / chained dispatch) — first-class on the Request,
    // never parsed out of the body or query.
    if (request.fn_override) |fn_name| {
        if (fn_name.len > 0) return allocator.dupe(u8, fn_name);
    }

    // The activation kind's conventional export (handler-surface
    // Phase 4, docs/handler-shape.md §3).
    return allocator.dupe(u8, defaultExportForKind(request.activation.source()));
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

test "parseDispatch: inbound with no override → default export" {
    const fn_name = try parseDispatch(testing.allocator, .{
        .method = "POST",
        .path = "/",
        .body = "{\"fn\":\"ignored\",\"args\":[1]}",
        .query = "x=also-ignored",
    });
    defer testing.allocator.free(fn_name);
    // Body and query are opaque payload — the retired envelope shapes
    // must NOT influence dispatch.
    try testing.expectEqualStrings("default", fn_name);
}

test "parseDispatch: fn_override wins" {
    const fn_name = try parseDispatch(testing.allocator, .{
        .method = "POST",
        .path = "/",
        .activation = .send_callback,
        .fn_override = "onCharge",
    });
    defer testing.allocator.free(fn_name);
    try testing.expectEqualStrings("onCharge", fn_name);
}

test "parseDispatch: empty fn_override falls back to the conventional export" {
    const fn_name = try parseDispatch(testing.allocator, .{
        .method = "POST",
        .path = "/",
        .activation = .{ .wake_batch = .{} },
        .fn_override = "",
    });
    defer testing.allocator.free(fn_name);
    try testing.expectEqualStrings("onWake", fn_name);
}
