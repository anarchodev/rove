// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `owed_retry.zig` — the `_send/owed/` marker's Zig-visible surface.
//!
//! This is ONLY the held-sync §6.4 binding scan — there is no
//! leader-side retry sweep here. Deferred webhook fires (scheduled
//! sends, retry re-arms, crash recovery) ride the durable `scheduler`
//! as a wake aimed at the baked `__system/webhook_fire`, which issues
//! the fetch in JS via the capability-scoped `__rove_fetch`.
//! `_send/owed/` is ordinary library kv with no privileged consumer;
//! the prefix constant exists only because the §6.4 open-hop/repark
//! scan keys on it.

const std = @import("std");
const reserved = @import("rove-reserved");
const kv_mod = @import("raft-kv");

const testing = std.testing;

/// `_send/owed/` kv prefix — the durable marker key the JS-shim
/// `webhook.send` writes. Owned end-to-end by the JS
/// composition (`globals/webhook.js` + `__system/webhook_fire` +
/// `__system/webhook_onresult`); Zig touches it only to *recognize*
/// a lone owed-put in a writeset for §6.4 held-sync binding.
/// Rooted, for the same reason as `SCHED_BY_TIME_PREFIX`: `webhook.send` writes
/// the owed marker through the handler's kv, and this matches keys off a
/// WRITESET, which carries resolved keys.
pub const OWED_PREFIX: []const u8 = reserved.USER_KEY_ROOT ++ "_send/owed/";

/// §6.4 binding source: scan a writeset op-slice for exactly one
/// `_send/owed/{id}` put and return the borrowed `{id}` suffix (a slice
/// into the matched op's key). Returns null when zero or more-than-one
/// owed-puts are present — the "ambiguous / deadline-only" case where
/// the resume binds to no send. Allocation-free: the returned slice
/// borrows into `ops`; callers that need it to outlive the writeset
/// dupe it themselves. Shared by the inbound open-hop
/// (`worker_dispatch`) and the cont / bound-fetch repark hops
/// (`worker_drain`); pass a pre-sliced `ops` to scope the scan to one
/// request's contribution (the open-hop cuts at `ws_pre_len`).
pub fn scanLoneOwedSendId(ops: []const kv_mod.WriteSetOp) ?[]const u8 {
    var only: ?[]const u8 = null;
    var n: usize = 0;
    for (ops) |op| switch (op) {
        .put => |p| if (std.mem.startsWith(u8, p.key, OWED_PREFIX)) {
            n += 1;
            only = p.key[OWED_PREFIX.len..];
        },
        .delete => {},
    };
    if (n != 1) return null;
    return only;
}

test "scanLoneOwedSendId: exactly one owed put → borrowed id" {
    // Writeset ops carry RESOLVED keys — `webhook.send` writes the marker
    // through the handler's kv, so it arrives here under the user root.
    const R = reserved.USER_KEY_ROOT;
    const ops = [_]kv_mod.WriteSetOp{
        .{ .put = .{ .key = R ++ "orders/1", .value = "x" } },
        .{ .put = .{ .key = R ++ "_send/owed/wh-abc", .value = "{}" } },
        .{ .delete = .{ .key = R ++ "_send/owed/wh-old" } },
    };
    try testing.expectEqualStrings("wh-abc", scanLoneOwedSendId(&ops).?);
}

test "scanLoneOwedSendId: zero or multiple owed puts → null" {
    const R = reserved.USER_KEY_ROOT;
    const none = [_]kv_mod.WriteSetOp{
        .{ .put = .{ .key = R ++ "orders/1", .value = "x" } },
    };
    try testing.expectEqual(@as(?[]const u8, null), scanLoneOwedSendId(&none));
    const two = [_]kv_mod.WriteSetOp{
        .{ .put = .{ .key = R ++ "_send/owed/a", .value = "{}" } },
        .{ .put = .{ .key = R ++ "_send/owed/b", .value = "{}" } },
    };
    try testing.expectEqual(@as(?[]const u8, null), scanLoneOwedSendId(&two));
    // Unrooted: an engine write below the binding, never a send marker.
    const raw = [_]kv_mod.WriteSetOp{
        .{ .put = .{ .key = "_send/owed/x", .value = "{}" } },
    };
    try testing.expectEqual(@as(?[]const u8, null), scanLoneOwedSendId(&raw));
}
