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

/// The gate: which events earn rows. Separated from the write so the decision
/// is testable without a worker, since every way of getting it wrong is
/// silent — an event wrongly admitted inflates a tenant's usage toward a
/// refusal they did not earn, and one wrongly skipped is storage nobody is
/// charged for.
///
/// Only the terminal carries the stored facts, and only a 2xx actually stored
/// bytes: S3 either took the objects or it did not, and a failed transfer
/// leaves nothing to account for.
pub fn storedFromEvent(
    ev: *const components_mod.UpstreamFetchEvent,
) []const components_mod.UpstreamFetchEvent.StoredObject {
    if (!ev.final) return &.{};
    if (ev.terminal_status < 200 or ev.terminal_status >= 300) return &.{};
    return ev.stored;
}

/// Which tenant an event's stored bytes belong to. Normally the tenant the
/// event routes to; a scoped deploy receive names the TARGET instead, because
/// the bytes land in that tenant's storage and metering the issuer would
/// charge the wrong account.
pub fn storedTenant(ev: *const components_mod.UpstreamFetchEvent) []const u8 {
    return if (ev.stored_tenant.len > 0) ev.stored_tenant else ev.tenant_id;
}

/// Record whatever a terminal fetch event says it stored.
pub fn recordFromEvent(worker: anytype, ev: *const components_mod.UpstreamFetchEvent) void {
    const rows = storedFromEvent(ev);
    if (rows.len == 0) return;
    const tenant = storedTenant(ev);
    for (rows) |r| {
        recordStored(worker, tenant, switch (r.pool) {
            .app => usage.Pool.app,
            .file => usage.Pool.file,
        }, &r.hash, r.bytes);
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const Ev = components_mod.UpstreamFetchEvent;

fn storedEvent(status: u16, final: bool, rows: []Ev.StoredObject) Ev {
    return .{ .final = final, .terminal_status = status, .stored = rows };
}

test "blob usage: a 2xx terminal earns every row it carries" {
    var rows = [_]Ev.StoredObject{
        .{ .pool = .app, .hash = ("a" ** 64).*, .bytes = 4096 },
        .{ .pool = .file, .hash = ("b" ** 64).*, .bytes = 17 },
    };
    const ev = storedEvent(200, true, &rows);
    const got = storedFromEvent(&ev);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(Ev.StoredPool.app, got[0].pool);
    try testing.expectEqual(@as(u64, 17), got[1].bytes);
    try testing.expectEqualStrings("a" ** 64, &got[0].hash);
}

test "blob usage: nothing stored, nothing recorded" {
    // The overwhelming majority of transfers: an ordinary outbound fetch.
    const plain = storedEvent(200, true, &.{});
    try testing.expect(storedFromEvent(&plain).len == 0);
}

test "blob usage: a write that did not store is not charged" {
    // S3 refused, or the transfer never got a response at all. Charging here
    // would bill a tenant for bytes that are not in the bucket. 3xx is not
    // success either — the object is not known to be there.
    var rows = [_]Ev.StoredObject{.{ .pool = .app, .hash = ("c" ** 64).*, .bytes = 1 }};
    for ([_]u16{ 0, 307, 403, 404, 500, 503 }) |status| {
        const ev = storedEvent(status, true, &rows);
        try testing.expect(storedFromEvent(&ev).len == 0);
    }
}

test "blob usage: only the terminal event counts" {
    // Intermediate chunks describe the RESPONSE; counting them would charge a
    // tenant once per chunk for a single stored object.
    var rows = [_]Ev.StoredObject{.{ .pool = .app, .hash = ("d" ** 64).*, .bytes = 9 }};
    const mid = storedEvent(200, false, &rows);
    try testing.expect(storedFromEvent(&mid).len == 0);
}

test "blob usage: a scoped write is charged to the target, not the issuer" {
    // A scoped deploy receive streams into the TARGET tenant's file-blobs
    // while the chain — and so the event — belongs to the issuer. Metering the
    // issuer would charge an admin tenant for every customer's deploy.
    var rows = [_]Ev.StoredObject{.{ .pool = .file, .hash = ("e" ** 64).*, .bytes = 32 }};
    var ev = storedEvent(200, true, &rows);
    ev.tenant_id = @constCast("__admin__");
    try testing.expectEqualStrings("__admin__", storedTenant(&ev));

    ev.stored_tenant = @constCast("acme");
    try testing.expectEqualStrings("acme", storedTenant(&ev));
}
