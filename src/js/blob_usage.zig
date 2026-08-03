// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Records what a tenant stored, as the object rows the storage quota is
//! summed from (`src/kv/usage.zig`).
//!
//! ## Why this is not in the `blob.put` shim
//!
//! The `rove-blob.internal` door is reachable without the shim: the fetch
//! engine selects it by URL prefix alone, and the public fetch verb puts no
//! host restriction on a customer-supplied URL, so an ordinary handler can PUT
//! straight into its own `app-blobs/` prefix. Confinement holds — the prefix
//! comes from the activation, never the URL — but a record written by the shim
//! would miss exactly the writes that chose not to declare themselves. So the
//! fetch engine stamps what a transfer stored onto its terminal event, and the
//! row is written HERE, on the worker, for every blob-door PUT that returned
//! 2xx.
//!
//! For the same reason this must not ride a handler activation. A door write
//! may name no result module at all, and one that does can throw before it
//! reaches its first line. Recording happens as the terminal event is drained,
//! before any routing decision.
//!
//! ## Why the local write and the propose are both required
//!
//! Under `worker_overlay` the LEADER skips the store apply — the worker owns
//! the speculative overlay and commits it when the watermark advances, so a
//! propose alone would land the row on followers and never on the leader
//! (`ApplyMode`, `src/consensus/node_core.zig`). A local write alone would
//! land it nowhere else. Both, in that order, is the shape every non-handler
//! producer here uses.

const std = @import("std");
const kv_mod = @import("raft-kv");
const raft_propose = @import("raft_propose.zig");
const components_mod = @import("components.zig");

const usage = kv_mod.usage;

/// Record one stored object against `tenant_id`. Idempotent: the row key is
/// the content hash, so a duplicate terminal or a re-put rewrites the same row
/// with the same value and the summed total does not move.
///
/// Best-effort by design. A failure here loses accounting for one object, and
/// the alternatives are worse — refusing the customer's already-durable write,
/// or wedging the drain loop. Each failure logs, so an undercount has a
/// trail rather than being silent.
pub fn recordStored(
    worker: anytype,
    tenant_id: []const u8,
    pool: usage.Pool,
    hash: []const u8,
    bytes: u64,
) void {
    if (tenant_id.len == 0 or hash.len == 0) return;

    const inst_opt = worker.node.tenant.getInstance(tenant_id) catch null;
    const inst = inst_opt orelse {
        std.log.warn(
            "rove-js usage: unknown tenant {s}; {d} stored bytes unaccounted",
            .{ tenant_id, bytes },
        );
        return;
    };

    var key_buf: [usage.ROW_KEY_MAX]u8 = undefined;
    const key = usage.rowKey(&key_buf, pool, hash);
    var val_buf: [20]u8 = undefined;
    const val = usage.formatLen(&val_buf, bytes);

    var txn = inst.kv.beginTrackedImmediate() catch |err| {
        std.log.warn(
            "rove-js usage: {s} txn open failed: {s}; {d} stored bytes unaccounted",
            .{ tenant_id, @errorName(err), bytes },
        );
        return;
    };
    txn.put(key, val) catch |err| {
        txn.rollback() catch {};
        std.log.warn(
            "rove-js usage: {s} row put failed: {s}; {d} stored bytes unaccounted",
            .{ tenant_id, @errorName(err), bytes },
        );
        return;
    };
    txn.commit() catch |err| {
        std.log.warn(
            "rove-js usage: {s} row commit failed: {s}; {d} stored bytes unaccounted",
            .{ tenant_id, @errorName(err), bytes },
        );
        return;
    };

    var ws = kv_mod.WriteSet.init(worker.allocator);
    defer ws.deinit();
    ws.addPut(key, val) catch |err| {
        std.log.warn(
            "rove-js usage: {s} row writeset failed: {s}; row is local-only",
            .{ tenant_id, @errorName(err) },
        );
        return;
    };
    // No dispatched handler here, so no readset rides the envelope — the same
    // stance every non-handler producer takes.
    _ = raft_propose.proposeWriteSet(worker, &ws, tenant_id, "") catch |err| {
        std.log.warn(
            "rove-js usage: {s} row propose failed: {s}; row is local-only until a later write",
            .{ tenant_id, @errorName(err) },
        );
    };
}

/// What an event says was stored, once it has earned a row.
pub const Stored = struct {
    pool: usage.Pool,
    hash: [64]u8,
    bytes: u64,
};

/// The gate: which events earn a row. Separated from the write so the decision
/// is testable without a worker, since every way of getting it wrong is
/// silent — an event wrongly admitted inflates a tenant's usage toward a
/// refusal they did not earn, and one wrongly skipped is storage nobody is
/// charged for.
///
/// Only the terminal carries the stored facts, and only a 2xx actually stored
/// bytes: S3 either took the object or it did not, and a failed PUT leaves
/// nothing to account for.
pub fn storedFromEvent(ev: *const components_mod.UpstreamFetchEvent) ?Stored {
    if (!ev.final) return null;
    if (ev.terminal_status < 200 or ev.terminal_status >= 300) return null;
    const hash = ev.stored_hash orelse return null;
    return .{
        .pool = switch (ev.stored_pool) {
            .app => .app,
            .file => .file,
            .none => return null,
        },
        .hash = hash,
        .bytes = ev.stored_bytes,
    };
}

/// Record whatever a terminal fetch event says it stored.
pub fn recordFromEvent(worker: anytype, ev: *const components_mod.UpstreamFetchEvent) void {
    const s = storedFromEvent(ev) orelse return;
    recordStored(worker, ev.tenant_id, s.pool, &s.hash, s.bytes);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const Ev = components_mod.UpstreamFetchEvent;

fn storedEvent(status: u16, final: bool, pool: Ev.StoredPool) Ev {
    return .{
        .final = final,
        .terminal_status = status,
        .stored_hash = ("a" ** 64).*,
        .stored_bytes = 4096,
        .stored_pool = pool,
    };
}

test "blob usage: a 2xx terminal blob-door PUT earns a row" {
    const ev = storedEvent(200, true, .app);
    const s = storedFromEvent(&ev).?;
    try testing.expectEqual(usage.Pool.app, s.pool);
    try testing.expectEqual(@as(u64, 4096), s.bytes);
    try testing.expectEqualStrings("a" ** 64, &s.hash);

    const file_ev = storedEvent(204, true, .file);
    try testing.expectEqual(usage.Pool.file, storedFromEvent(&file_ev).?.pool);
}

test "blob usage: nothing stored, nothing recorded" {
    // The overwhelming majority of transfers: an ordinary outbound fetch.
    const plain = storedEvent(200, true, .none);
    try testing.expect(storedFromEvent(&plain) == null);

    // A terminal that claims a pool but carries no hash is incoherent; it
    // must not be charged against anyone.
    var no_hash = storedEvent(200, true, .app);
    no_hash.stored_hash = null;
    try testing.expect(storedFromEvent(&no_hash) == null);
}

test "blob usage: a PUT that did not store is not charged" {
    // S3 refused, or the transfer never got a response at all. Charging here
    // would bill a tenant for bytes that are not in the bucket.
    for ([_]u16{ 0, 403, 404, 500, 503 }) |status| {
        const ev = storedEvent(status, true, .app);
        try testing.expect(storedFromEvent(&ev) == null);
    }
    // 3xx is not success either — the object is not known to be there.
    const redirect = storedEvent(307, true, .app);
    try testing.expect(storedFromEvent(&redirect) == null);
}

test "blob usage: only the terminal event counts" {
    // Intermediate chunks describe the RESPONSE; counting them would charge a
    // tenant once per chunk for a single stored object.
    const mid = storedEvent(200, false, .app);
    try testing.expect(storedFromEvent(&mid) == null);
}
