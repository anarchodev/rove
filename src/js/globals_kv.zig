// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Customer-facing kv surface — the worker's DELEGATE behind the common
//! binding (`rove-binding`), plus the `markSubscriptionsDirty` hook that
//! arms kv-react subscriptions on every write.
//!
//! The binding owns the common work — JSValue coercion and its TypeError,
//! the `rove-guards` call, the refusal throw, the result shape — so those
//! cannot differ from any other engine that registers it. What lives here is
//! only what is genuinely the worker's: kvexp storage through the tracked
//! txn, the writeset, kv-trigger chains, subscription markers, and the
//! readset tape + interaction-digest folds.
//!
//! Kept apart from the privileged `platform.*` path (globals_platform.zig)
//! so the surface a customer handler can reach is legible on its own. The
//! shared `DispatchState` and `getState` stay in globals.zig and come back
//! via the `globals_mod` alias (the two files import each other).

const std = @import("std");
const qjs = @import("rove-qjs");
const kv_mod = @import("raft-kv");
const binding = @import("rove-binding");
const guards = @import("rove-guards");
const td = @import("trigger_dispatch.zig");
const tape_mod = @import("rove-tape");
const digest_mod = tape_mod.interaction_digest;

const c = qjs.c;

const globals_mod = @import("globals.zig");
const DispatchState = globals_mod.DispatchState;
const getState = globals_mod.getState;

// ── interaction digest folding ───────────────────────────────────────────
//
// One rolling hash over what the handler observably did, updated AS the
// interactions happen. It cannot be reconstructed afterwards from the readset
// and writeset, because those are two structures and the relative order of a
// read and a write between them is not preserved — and that order is part of
// what the handler did.
//
// Reads of the activation's own writes are folded too, even though they are
// elided from the readset (a self-read carries no replay input). The digest is
// a behaviour log, not an input set: the handler performed the read, and a
// replay serving it from the overlay performs it as well.

/// The digest so far, seeded on first use. A run with no interactions still
/// has a digest (the empty one); `0` on the readset means "never computed",
/// which a reader must treat as unverifiable rather than as a match.
fn digestOf(rs: anytype) digest_mod.Digest {
    return .{ .h = if (rs.interaction_digest == 0)
        digest_mod.Digest.init().h
    else
        rs.interaction_digest };
}

fn foldRead(state: *DispatchState, key: []const u8, found: bool, value: []const u8) void {
    if (state.readset) |rs| {
        var d = digestOf(rs);
        d.kvRead(key, found, value);
        rs.interaction_digest = d.h;
    }
}

fn foldWrite(state: *DispatchState, key: []const u8, value: []const u8) void {
    if (state.readset) |rs| {
        var d = digestOf(rs);
        d.kvWrite(key, value);
        rs.interaction_digest = d.h;
    }
}

fn foldDelete(state: *DispatchState, key: []const u8) void {
    if (state.readset) |rs| {
        var d = digestOf(rs);
        d.kvDelete(key);
        rs.interaction_digest = d.h;
    }
}

/// Fold a customer `kv.prefix` scan: `p <prefix> 1 <count> <rowsfold>`, where
/// the rows-fold is `key=<valuehash>;` per returned row IN ORDER — the same
/// accumulator the cross-store recorder builds (`globals_platform.zig`
/// tapeStorePrefix) and the offline engines' kv wrappers compute, over the
/// plain keys (a customer scan has no store namespace). Folds ALL returned
/// rows, read-your-writes included — the digest is a behaviour log, and the
/// scan the handler observed contains them. Best-effort like the other folds:
/// an accumulator OOM skips the fold rather than failing the read.
fn foldPrefix(state: *DispatchState, prefix: []const u8, entries: anytype) void {
    if (state.readset) |rs| {
        var acc: std.ArrayList(u8) = .empty;
        defer acc.deinit(state.allocator);
        for (entries) |e| {
            acc.writer(state.allocator).print("{s}={x};", .{ e.key, digest_mod.foldValue(e.value) }) catch return;
        }
        var d = digestOf(rs);
        d.kvPrefix(prefix, true, entries.len, digest_mod.foldValue(acc.items));
        rs.interaction_digest = d.h;
    }
}

/// durable-kv-subscriptions: a successful customer write under a
/// watched subscription prefix injects the durable dirty marker
/// (`_sub/dirty/{name}` → the watched prefix) into THIS activation's
/// txn + writeset — atomic with the triggering write, which is the
/// whole at-least-once guarantee (a commit either carries both or
/// neither; there is no window where the write is durable but the owed
/// fire isn't). The marker key is one-per-subscription, so N matching
/// writes coalesce at the storage level; `subs_marked` also dedups the
/// redundant rewrites within one activation. `_sub/`-keys themselves
/// never re-trigger (recursion guard — the fire's own marker delete
/// must not re-arm it).
fn markSubscriptionsDirty(state: *DispatchState, key: []const u8) void {
    if (state.subscriptions.len == 0) return;
    if (std.mem.startsWith(u8, key, "_sub/")) return;
    for (state.subscriptions, 0..) |sub, i| {
        const prefix = switch (sub.spec) {
            .kv => |k| k.prefix,
        };
        if (!std.mem.startsWith(u8, key, prefix)) continue;
        if (i < 64) {
            const bit = @as(u64, 1) << @intCast(i);
            if (state.subs_marked & bit != 0) continue;
            state.subs_marked |= bit;
        }
        const mkey = std.fmt.allocPrint(state.allocator, "_sub/dirty/{s}", .{sub.name}) catch |err| {
            state.pending_kv_error = err;
            return;
        };
        defer state.allocator.free(mkey);
        state.txn.put(mkey, prefix) catch |err| {
            state.pending_kv_error = err;
            return;
        };
        // The dirty marker is injected by the platform, not written by the
        // handler — but it lands in the same writeset the replay must
        // reproduce, so it belongs in the digest. A replay that fails to
        // inject it (rove#252) diverges here, which is the point.
        foldWrite(state, mkey, prefix);
        state.writeset.addPut(mkey, prefix) catch |err| {
            state.pending_kv_error = err;
            return;
        };
    }
}

// ── the worker delegate ──────────────────────────────────────────────────

/// The engine-specific third of the kv binding. Every method runs AFTER the
/// binding's coercion + guard, so keys/values arriving here are validated
/// bytes. Storage errors park on `pending_kv_error` and the call reports
/// success to the binding — a read never throws; the dispatcher surfaces the
/// parked error at the activation seam.
pub const WorkerKv = struct {
    state: *DispatchState,

    pub fn fromCtx(ctx: ?*c.JSContext) WorkerKv {
        return .{ .state = getState(ctx) };
    }

    pub fn allocator(self: WorkerKv) std.mem.Allocator {
        return self.state.allocator;
    }

    pub fn isSystemModule(self: WorkerKv) bool {
        return self.state.is_system_module;
    }

    /// The worker has no per-key exemption: its platform writers
    /// (markSubscriptionsDirty, the shims' owed markers, …) bypass the
    /// binding and write the txn directly, so every key that arrives here IS
    /// a customer write.
    pub fn isExempt(_: WorkerKv, _: []const u8) bool {
        return false;
    }

    /// The worker always decides — it IS the rules' live authority.
    pub fn decides(_: WorkerKv) bool {
        return true;
    }

    /// Live traffic has no capture to replay outcomes from.
    pub fn tapedRefusal(_: WorkerKv, _: binding.WriteOp, _: []const u8) ?[]const u8 {
        return null;
    }

    /// A refused write goes on the tape (outcome-replay: value = the refusal
    /// CODE), so captured replay can throw the recorded verdict instead of
    /// re-deciding — an old tape stays faithful to the rules that were live
    /// when it was cut. Refusals fold NOTHING into the digest (a refused
    /// write never happened), which is already true in every engine.
    pub fn recordRefusal(self: WorkerKv, op: binding.WriteOp, key: []const u8, refusal: guards.Refusal) void {
        const state = self.state;
        if (state.readset) |rs| {
            const tape_op: tape_mod.KvOp = switch (op) {
                .set => .set,
                .delete => .delete,
            };
            rs.kv.appendKv(tape_op, key, refusal.code, .refused) catch {};
        }
    }

    /// The minimal readset (`docs/architecture/effects-and-handlers.md`,
    /// readset replication). A `kv.get(k)` where `k` is in this activation's
    /// own writeset reads a value the activation itself produced,
    /// reproducible by replay re-running the handler against its own
    /// overlay. Only FOREIGN reads (keys NOT in the writeset) carry replay
    /// information, so only those make it onto the tape. Saves tape size +
    /// S3 bytes per request without losing replay determinism. The digest
    /// folds them regardless (see the fold header above).
    pub fn get(self: WorkerKv, key: []const u8) binding.GetResult {
        const state = self.state;
        // Since `ws_base`, not the whole writeset: the writeset is shared by
        // the batch, and a key an earlier activation in the batch wrote is a
        // foreign read for this one — it must be taped or this record's
        // replay has nowhere to read it from (rove#532).
        const skip_tape = state.writeset.containsKeySince(state.ws_base, key);

        const value = state.kv.get(key) catch |err| switch (err) {
            error.NotFound => {
                if (!skip_tape) if (state.readset) |rs| rs.kv.appendKv(.get, key, "", .not_found) catch {};
                foldRead(state, key, false, "");
                return .absent;
            },
            else => {
                // A read never throws in prod: the storage error parks on the
                // dispatch state and the handler sees absent.
                state.pending_kv_error = err;
                if (!skip_tape) if (state.readset) |rs| rs.kv.appendKv(.get, key, "", .err) catch {};
                return .absent;
            },
        };

        if (!skip_tape) if (state.readset) |rs| rs.kv.appendKv(.get, key, value, .ok) catch {};
        foldRead(state, key, true, value);
        return .{ .value = value };
    }

    pub fn release(self: WorkerKv, bytes: []const u8) void {
        self.state.allocator.free(bytes);
    }

    /// kv.set is an OUTPUT, not an input
    /// (`docs/architecture/effects-and-handlers.md`): replay re-runs the
    /// handler and re-issues the write against its writeset overlay, so
    /// nothing about a write is taped — only folded.
    pub fn put(self: WorkerKv, ctx: ?*c.JSContext, key: []const u8, value: []const u8) bool {
        const state = self.state;

        // Fast path: no triggers match → write directly, no savepoint, no
        // previousValue lookup, no chain machinery — no added cost over a
        // plain write.
        if (!td.anyTriggerMatches(state, key)) {
            state.txn.put(key, value) catch |err| {
                state.pending_kv_error = err;
                return true;
            };
            state.writeset.addPut(key, value) catch |err| {
                state.pending_kv_error = err;
            };
            foldWrite(state, key, value);
            markSubscriptionsDirty(state, key);
            return true;
        }

        // Slow path: there's at least one matching trigger. Fetch the
        // previousValue, open an inner savepoint, run BEFORE chain
        // (with possible value mutation), do the write, run AFTER chain.
        // Throw anywhere → rollback the savepoint and rethrow as
        // `Error{ code: "trigger_rejected" }`.
        var prev_owned: ?[]u8 = null;
        defer if (prev_owned) |p| state.allocator.free(p);
        if (state.kv.get(key)) |bytes| {
            prev_owned = bytes;
        } else |err| switch (err) {
            error.NotFound => {},
            else => {
                state.pending_kv_error = err;
                return true;
            },
        }

        state.txn.savepoint() catch |err| {
            state.pending_kv_error = err;
            return true;
        };

        // `cur_value` starts as the original `value` (borrowed). If a
        // BEFORE trigger returns a string, the chain helper allocates a
        // fresh buffer, points `cur_value` at it, and tracks ownership
        // via `cur_owned` so we can free it before returning.
        var cur_owned: ?[]u8 = null;
        defer if (cur_owned) |o| state.allocator.free(o);
        var cur_value: ?[]const u8 = value;
        if (td.runBeforeChain(state, ctx, key, .put, &cur_value, &cur_owned, prev_owned)) |trigger_path| {
            td.rollbackInnerSavepoint(state);
            _ = td.rethrowAsTriggerRejected(state, ctx, trigger_path);
            return false;
        }

        const write_value: []const u8 = cur_value.?;

        state.txn.put(key, write_value) catch |err| {
            state.pending_kv_error = err;
            td.rollbackInnerSavepoint(state);
            return true;
        };
        state.writeset.addPut(key, write_value) catch |err| {
            state.pending_kv_error = err;
        };
        foldWrite(state, key, write_value);
        markSubscriptionsDirty(state, key);

        if (td.runAfterChain(state, ctx, key, .put, write_value, prev_owned)) |trigger_path| {
            td.rollbackInnerSavepoint(state);
            _ = td.rethrowAsTriggerRejected(state, ctx, trigger_path);
            return false;
        }

        state.txn.release() catch |err| {
            state.pending_kv_error = err;
        };
        return true;
    }

    pub fn del(self: WorkerKv, ctx: ?*c.JSContext, key: []const u8) bool {
        const state = self.state;

        // Fast path mirrors put — no triggers means no savepoint, no
        // previousValue lookup, no chain machinery. kv.delete (like kv.set)
        // is an OUTPUT and isn't taped — replay re-runs the handler against
        // its overlay.
        if (!td.anyTriggerMatches(state, key)) {
            state.txn.delete(key) catch |err| {
                state.pending_kv_error = err;
                return true;
            };
            state.writeset.addDelete(key) catch |err| {
                state.pending_kv_error = err;
            };
            foldDelete(state, key);
            markSubscriptionsDirty(state, key);
            return true;
        }

        var prev_owned: ?[]u8 = null;
        defer if (prev_owned) |p| state.allocator.free(p);
        if (state.kv.get(key)) |bytes| {
            prev_owned = bytes;
        } else |err| switch (err) {
            error.NotFound => {},
            else => {
                state.pending_kv_error = err;
                return true;
            },
        }

        state.txn.savepoint() catch |err| {
            state.pending_kv_error = err;
            return true;
        };

        // BEFORE chain: deletes don't carry a value, so cur_value stays
        // null (the helper passes that through to event.value as JS null,
        // and ignores any string return from a beforeDelete handler).
        var cur_owned: ?[]u8 = null;
        defer if (cur_owned) |o| state.allocator.free(o);
        var cur_value: ?[]const u8 = null;
        if (td.runBeforeChain(state, ctx, key, .delete, &cur_value, &cur_owned, prev_owned)) |trigger_path| {
            td.rollbackInnerSavepoint(state);
            _ = td.rethrowAsTriggerRejected(state, ctx, trigger_path);
            return false;
        }

        state.txn.delete(key) catch |err| {
            state.pending_kv_error = err;
            td.rollbackInnerSavepoint(state);
            return true;
        };
        state.writeset.addDelete(key) catch |err| {
            state.pending_kv_error = err;
        };
        foldDelete(state, key);
        markSubscriptionsDirty(state, key);

        if (td.runAfterChain(state, ctx, key, .delete, null, prev_owned)) |trigger_path| {
            td.rollbackInnerSavepoint(state);
            _ = td.rethrowAsTriggerRejected(state, ctx, trigger_path);
            return false;
        }

        state.txn.release() catch |err| {
            state.pending_kv_error = err;
        };
        return true;
    }

    /// A completed scan the binding shapes into the JS array, then releases.
    /// `entries` aliases the scan's storage, so the scan rides along.
    pub const Page = struct {
        scan: kv_mod.KvRangeResult,
        entries: []const kv_mod.KvEntry,

        pub fn deinit(self: *Page) void {
            self.scan.deinit();
        }
    };

    /// Reads go directly through `state.kv`; writes from the same handler
    /// are visible because the underlying store routes through the active
    /// txn's read view.
    ///
    /// Tape-captured via `appendKvPrefix` — the captured entry holds the
    /// inputs (prefix/cursor/limit) AND the full result list, so the
    /// replay engines can reconstruct the same rows without reaching live
    /// KV state.
    pub fn prefix(self: WorkerKv, prefix_bytes: []const u8, cursor: []const u8, limit: u32) ?Page {
        const state = self.state;

        const scan = state.kv.prefix(prefix_bytes, cursor, limit) catch |err| {
            state.pending_kv_error = err;
            // Capture the failure path too — replay needs to surface the
            // same null return, otherwise a defensive `if (page === null)`
            // branch in the handler would diverge.
            if (state.readset) |rs| rs.kv.appendKvPrefix(prefix_bytes, cursor, limit, &.{}, .err) catch {};
            return null;
        };

        if (state.readset) |rs| {
            // Convert `kv.PrefixScan.entries` (rove-kv's shape) into the
            // tape's `KvPair`s. Both are the same `(key, value)` pair, but
            // they belong to different modules so we materialize the
            // bridge on the stack. `appendKvPrefix` dups everything into
            // tape storage, so the lifetime of `pairs` and `scan` doesn't
            // need to extend past this call.
            var stack_pairs: [256]tape_mod.KvPair = undefined;
            const heap_pairs: ?[]tape_mod.KvPair = if (scan.entries.len <= stack_pairs.len)
                null
            else
                state.allocator.alloc(tape_mod.KvPair, scan.entries.len) catch null;
            defer if (heap_pairs) |h| state.allocator.free(h);
            const pairs: []tape_mod.KvPair = if (heap_pairs) |h| h else stack_pairs[0..scan.entries.len];
            // Minimal read set (mirrors the kv.get `skip_tape` gate): a row whose
            // key is in this activation's own writeset is a read-your-write, not a
            // foreign read. Keep it OUT of the taped readset — replay reproduces it
            // by re-executing the handler's own write, then reconstructs the scan
            // from the map. This keeps the readset disjoint from the writeset, so a
            // refactored read of such a key can't be served a stale write value.
            var np: usize = 0;
            for (scan.entries) |e| {
                if (state.writeset.containsKeySince(state.ws_base, e.key)) continue;
                pairs[np] = .{ .key = e.key, .value = e.value };
                np += 1;
            }
            rs.kv.appendKvPrefix(prefix_bytes, cursor, limit, pairs[0..np], .ok) catch {};
        }

        // Folded outside the tape's read-your-write filtering, like `foldRead`
        // sits outside `skip_tape`: the digest hashes the scan the handler
        // observed. The error path above folds nothing, matching `get`'s —
        // the offline engines have no storage-error path to agree with.
        foldPrefix(state, prefix_bytes, scan.entries);

        return .{ .scan = scan, .entries = scan.entries };
    }
};

/// The worker's instantiation of the common binding — what globals.zig
/// registers as `_system.kv.{get,set,delete,prefix}`.
const B = binding.Kv(c, WorkerKv);
pub const jsKvGet = B.jsKvGet;
pub const jsKvSet = B.jsKvSet;
pub const jsKvDelete = B.jsKvDelete;
pub const jsKvPrefix = B.jsKvPrefix;
