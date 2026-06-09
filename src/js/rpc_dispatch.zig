//! RPC dispatch parsing — turning a request into a `(fn, args)` call.
//!
//! Extracted from `dispatcher.zig`. The handler's target export + args
//! come from one of two places: a JSON `{fn, args}` POST envelope, or the
//! query string (`?fn=name&args=<urlencoded-json-array>`). Missing/empty
//! `fn` falls back to the activation source's conventional export. Pure
//! data-shaping — no JS engine, no `Dispatcher` state.

const std = @import("std");
const request_mod = @import("request.zig");

const Request = request_mod.Request;
const ActivationSource = request_mod.ActivationSource;

/// Parsed `(fn, args)` from a request. `args_json_text` is a raw JSON
/// array literal (e.g. `[]`, `["foo", 42]`); the caller does one
/// `JS_ParseJSON` on it and spreads the elements into the handler call.
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
) (error{ OutOfMemory, BadRequest })!DispatchCall {
    // RPC envelope path: a JSON-looking POST body whose top-level
    // object has `fn: string` (and optionally `args: array`). Anything
    // else — a non-JSON body, an array body, an object without `fn`,
    // or a parse failure — is treated as opaque payload and falls
    // through to the query-string path. The handler reads the raw
    // body via `request.body` in that case.
    if (request.body.len > 0 and looksLikeJson(request.body)) {
        if (std.json.parseFromSlice(
            std.json.Value,
            allocator,
            request.body,
            .{},
        )) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("fn")) |fn_val| {
                    if (fn_val != .string) return error.BadRequest;
                    const fn_owned = try allocator.dupe(u8, fn_val.string);
                    errdefer allocator.free(fn_owned);

                    const args_text = if (parsed.value.object.get("args")) |v| blk: {
                        if (v != .array) return error.BadRequest;
                        break :blk try jsonArrayToOwnedText(allocator, v.array.items);
                    } else try allocator.dupe(u8, "[]");

                    return .{ .fn_name = fn_owned, .args_json_text = args_text };
                }
            }
        } else |_| {}
    }

    // Query-string path: ?fn=name[&args=<urlencoded-json-array>].
    // Both optional. Missing or empty fn → the activation kind's
    // conventional export (handler-surface Phase 4, docs/handler-shape.md
    // §3): a `wake_batch` (`on.kv`/`on.timer`) resume lands in `onWake`,
    // inbound + everything that names its own target (the `?fn=`/`{fn}`
    // resume paths: send_callback, fetch_chunk, cron, subscription) stay
    // `default`. Named exports replace the `request.activation.kind`
    // switch as the dispatch surface.
    const query = request.query orelse "";
    const fn_owned: []u8 = blk: {
        if (queryParam(query, "fn")) |s| {
            if (s.len > 0) break :blk try decodePercent(allocator, s);
        }
        break :blk try allocator.dupe(u8, defaultExportForKind(request.activation.source()));
    };
    errdefer allocator.free(fn_owned);

    const args_text: []u8 = blk: {
        if (queryParam(query, "args")) |s| {
            if (s.len > 0) break :blk try decodePercent(allocator, s);
        }
        break :blk try allocator.dupe(u8, "[]");
    };

    return .{ .fn_name = fn_owned, .args_json_text = args_text };
}

/// Handler-surface Phase 4: map an activation source to its conventional
/// named export, used when the resume path didn't name one explicitly
/// (`?fn=`/`{fn}`). `wake_batch` (the `on.kv`/`on.timer` edge wake — and
/// the legacy singular `kv_wake`/`timer`) lands in `onWake`. Inbound and
/// the kinds whose resume path always names its own target — send_callback
/// (the `next({fn})` / `on_result`), fetch_chunk (`{to}`/`onFetchChunk`),
/// cron + subscription_fire (the registration's export), durable_wake (the
/// baked `scheduler_tick` default) — fall through to `default`, so this
/// only changes the previously-unrouted stream-wake + (future) paths.
fn defaultExportForKind(src: ActivationSource) []const u8 {
    return switch (src) {
        .wake_batch, .kv_wake, .timer => "onWake",
        .disconnect => "onDisconnect",
        .ws_message => "onMessage",
        else => "default",
    };
}

fn looksLikeJson(body: []const u8) bool {
    var i: usize = 0;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n' or body[i] == '\r')) i += 1;
    return i < body.len and (body[i] == '{' or body[i] == '[');
}

/// Re-serialize a parsed `std.json.Value` array (POST body's `args`
/// field) back into compact JSON text. The returned buffer is a full
/// JSON array literal like `[1,"two",{"k":"v"}]` ready for one
/// `JS_ParseJSON` on the qjs side.
fn jsonArrayToOwnedText(
    allocator: std.mem.Allocator,
    items: []const std.json.Value,
) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ',');
        try stringifyJson(allocator, &buf, item);
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}

fn stringifyJson(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    v: std.json.Value,
) error{OutOfMemory}!void {
    switch (v) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            var tmp: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{i}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .number_string => |s| try buf.appendSlice(allocator, s),
        .string => |s| try writeJsonEscaped(allocator, buf, s),
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.append(allocator, ',');
                try stringifyJson(allocator, buf, item);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |kv| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try writeJsonEscaped(allocator, buf, kv.key_ptr.*);
                try buf.append(allocator, ':');
                try stringifyJson(allocator, buf, kv.value_ptr.*);
            }
            try buf.append(allocator, '}');
        },
    }
}

fn writeJsonEscaped(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    s: []const u8,
) error{OutOfMemory}!void {
    try buf.append(allocator, '"');
    for (s) |b| switch (b) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0x08 => try buf.appendSlice(allocator, "\\b"),
        0x0C => try buf.appendSlice(allocator, "\\f"),
        0x00...0x07, 0x0B, 0x0E...0x1F => {
            var tmp: [6]u8 = undefined;
            const hex = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{b}) catch unreachable;
            try buf.appendSlice(allocator, hex);
        },
        else => try buf.append(allocator, b),
    };
    try buf.append(allocator, '"');
}

fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            if (std.mem.eql(u8, pair, name)) return "";
            continue;
        };
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn decodePercent(allocator: std.mem.Allocator, encoded: []const u8) error{OutOfMemory}![]u8 {
    var buf = try allocator.alloc(u8, encoded.len);
    errdefer allocator.free(buf);
    var w: usize = 0;
    var i: usize = 0;
    while (i < encoded.len) {
        const b = encoded[i];
        if (b == '+') {
            buf[w] = ' ';
            w += 1;
            i += 1;
        } else if (b == '%' and i + 2 < encoded.len) {
            const hi = std.fmt.charToDigit(encoded[i + 1], 16) catch {
                buf[w] = b;
                w += 1;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(encoded[i + 2], 16) catch {
                buf[w] = b;
                w += 1;
                i += 1;
                continue;
            };
            buf[w] = (hi << 4) | lo;
            w += 1;
            i += 3;
        } else {
            buf[w] = b;
            w += 1;
            i += 1;
        }
    }
    return allocator.realloc(buf, w) catch buf[0..w];
}
