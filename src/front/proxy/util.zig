// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Pure HTTP header wire helpers for rewind-front — header read
//! (`headerValue`/`respHeaderValue`) and pack (`packFields`). No
//! Proxy/Flow/WsTunnel dependency: a leaf that both proxy.zig (flow +
//! response relay) and proxy/ws_tunnel.zig import, so the header
//! primitives aren't Proxy-nested internals reached across files.

const std = @import("std");
const h2 = @import("rove-h2");

pub fn headerValue(rh: h2.ReqHeaders, name: []const u8) ?[]const u8 {
    const fields = rh.fields orelse return null;
    var i: u32 = 0;
    while (i < rh.count) : (i += 1) {
        const f = fields[i];
        if (std.ascii.eqlIgnoreCase(f.name[0..f.name_len], name)) {
            return f.value[0..f.value_len];
        }
    }
    return null;
}

/// Same lookup over a RESPONSE header set (worker → front). Used to read the
/// `x-rewind-leader` redirect hint off a 421.
pub fn respHeaderValue(rh: h2.RespHeaders, name: []const u8) ?[]const u8 {
    const fields = rh.fields orelse return null;
    var i: u32 = 0;
    while (i < rh.count) : (i += 1) {
        const f = fields[i];
        if (std.ascii.eqlIgnoreCase(f.name[0..f.name_len], name)) {
            return f.value[0..f.value_len];
        }
    }
    return null;
}

// ── Header packing ────────────────────────────────────────────────────

pub const PackedFields = struct {
    fields: ?[*]h2.HeaderField,
    count: u32,
    buf: ?[*]u8,
    buf_len: u32,
};

pub const NameValue = struct { name: []const u8, value: []const u8 };

pub fn packFields(a: std.mem.Allocator, list: []const NameValue) !PackedFields {
    if (list.len == 0) return .{ .fields = null, .count = 0, .buf = null, .buf_len = 0 };
    const HF = h2.HeaderField;
    var strbytes: usize = 0;
    for (list) |nv| strbytes += nv.name.len + nv.value.len;
    const fields_size = list.len * @sizeOf(HF);
    const total = fields_size + strbytes;
    const buf = try a.alloc(u8, total);
    const fields: [*]HF = @ptrCast(@alignCast(buf.ptr));
    const sb = buf.ptr + fields_size;
    var off: usize = 0;
    for (list, 0..) |nv, i| {
        const noff = off;
        @memcpy(sb[noff .. noff + nv.name.len], nv.name);
        // HTTP/2 requires lowercase field names (h1 ingress may
        // carry mixed case).
        for (sb[noff .. noff + nv.name.len]) |*ch| ch.* = std.ascii.toLower(ch.*);
        off += nv.name.len;
        const voff = off;
        @memcpy(sb[voff .. voff + nv.value.len], nv.value);
        off += nv.value.len;
        fields[i] = .{
            .name = sb + noff,
            .name_len = @intCast(nv.name.len),
            .value = sb + voff,
            .value_len = @intCast(nv.value.len),
        };
    }
    return .{ .fields = fields, .count = @intCast(list.len), .buf = buf.ptr, .buf_len = @intCast(total) };
}
