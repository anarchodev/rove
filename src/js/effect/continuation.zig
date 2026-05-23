//! effect.Continuation — the generalized commit-gated parked unit
//! (`docs/effect-algebra.md` §2.2; `docs/effect-reification-plan.md`
//! Phase 3).
//!
//! Today every "parked on raft seq" site hand-rolls its own struct:
//!
//!   - `worker.ParkedUnit` (`src/js/worker.zig:132`) — used by
//!     `parkSendOps` / `parkKvWakes` / `proposeForgetfulWrites`;
//!     already commit-gated end-to-end.
//!   - h2 `RaftWait` (`worker.zig:114`) tagging entities in the
//!     three `raft_pending_*` sibling collections (response / cont /
//!     stream); the H2 reference path.
//!   - `parked_continuations` (`worker.zig:2099`) — held-sync
//!     continuation trampolines.
//!   - `stream_data_out` + `stream_response_in` (`src/h2/root.zig`) —
//!     the held-stream lifecycle.
//!
//! Phase 3 collapses these into ONE `Continuation` + ONE `reconcile`
//! system. This file (Phase 3.0) declares the primitive; the
//! migrations (Phases 3.1–3.5) move each site onto it incrementally.
//! The H2 reference path (3.2) is the dragon — generalize with
//! byte-identical H2 behavior, prove via smokes + perf gate, then
//! add non-H2 registrants. See `docs/effect-reification-plan.md`
//! Phase 3 sub-plan.
//!
//! ## Comptime-generic
//!
//! `Continuation(Buffered, Txn)` is parameterized over the buffered-
//! effects type (Phase 4's interpretCmd shape) and the txn pointer
//! type (today `*kv_mod.KvStore.TrackedTxn`). The effect module is
//! a leaf — it does NOT import `kv_mod` or `send_dispatch_mod`.
//! Concrete types are bound by the caller (worker.zig) at the
//! instantiation site.
//!
//! ## L2 / L4 alignment
//!
//! - L2 (algebra): a Continuation is always ephemeral — reconstructible
//!   from the Model, or safe to abandon. `Continuation.deinit` is
//!   abandon-safe by construction: it rolls back the txn (kvexp
//!   volatile speculative-commit — no on-disk divergence) and frees
//!   buffered Cmds (nothing externally escaped because release is
//!   commit-gated, see L4).
//! - L4 (algebra): every Cmd is commit-gated. `reconcile`'s commit arm
//!   is the ONE release point; the fault arm discards. The compile-
//!   time guarantee is "no Cmd in `buffered` reaches a runtime
//!   except through `reconcile`'s commit branch."

const std = @import("std");
const msg_mod = @import("msg.zig");

/// Resume-arm discriminant. `ok` = raft committed the seq;
/// `fault` = quorum lost, timeout, or leadership loss before commit.
pub const Disposition = enum { ok, fault };

/// The three watermarks every parked-seq sweep consults each tick.
/// Computed once per `drainRaftPending` pass and reused across every
/// arm (the four drain sites — `raft_pending_response` / `_cont` /
/// `_stream` + `parked_units` — all see the same snapshot).
pub const Watermarks = struct {
    /// Highest raft seq that has reached durable commit on this node
    /// (`RaftNode.committedSeq()`).
    committed: u64,
    /// Highest raft seq that has been declared faulted (leader lost
    /// quorum / leadership). `0` means "no fault" — production
    /// systems don't write seq 0, so `faulted > 0 and faulted >= seq`
    /// is the live check.
    faulted: u64,
    /// Wall-clock monotonic ns; `>= deadline_ns` means the unit timed
    /// out waiting for commit and should be discarded.
    now_ns: i64,
};

/// Three-way per-unit classification for a parked-seq sweep.
/// Distinct from `Disposition` (the two-way resume discriminant)
/// because `.pending` is a real outcome at sweep time — the unit
/// hasn't committed yet and isn't faulted; leave it in place.
pub const SweepClass = enum { commit, fault, pending };

/// Per-unit classification — pure function of the unit's `seq` /
/// `deadline_ns` and the tick's `Watermarks`. Each drain arm calls
/// this at the top of every iteration; the returned class names
/// the arm action the caller takes (`.commit` → release buffered
/// Cmds + move to next state; `.fault` → discard buffered +
/// downgrade; `.pending` → skip this iteration).
///
/// Effect-reification Phase 3.2.a: extracts the previously-duplicated
/// predicate from `drainResponsePending` / `drainContPending` /
/// `drainStreamPending` + the `parked_units` sweep. The four sites
/// computed identical logic in four places; a single classifier
/// guarantees future divergence is a compile error rather than a
/// drift bug.
pub fn classify(seq: u64, deadline_ns: i64, w: Watermarks) SweepClass {
    if (w.committed >= seq) return .commit;
    const is_faulted = w.faulted > 0 and w.faulted >= seq;
    const is_timed_out = w.now_ns >= deadline_ns;
    if (is_faulted or is_timed_out) return .fault;
    return .pending;
}

/// The Msg / route key a Continuation parks on (Phase 3.5 — the
/// O(1) wake-correlation index). Today's resume is a cross-worker
/// scan (`docs/effect-algebra.md` §7 worklist #4). The indexed
/// form replaces it.
///
/// Declared but unindexed in Phase 3.0; the migration sub-phases
/// 3.1-3.4 populate `wake_key` on existing units, and 3.5 wires
/// the per-worker hash index that lets resume be O(1) instead of
/// O(workers × parked).
pub const WakeKey = union(enum) {
    /// Wait on a raft seq to commit (the H2-reference shape:
    /// `RaftWait.seq` today). Most parked units use this.
    seq: u64,
    /// Wait on a chain's correlation_id wake (held-sync resume,
    /// `parked_continuations` today).
    correlation_id: []const u8,
    /// Wait on an `effect.Msg` arrival of a specific kind (Phase
    /// 3.5 — fully-typed wake routing).
    msg: msg_mod.ActivationSource,
};

/// The generalized commit-gated parked unit.
///
/// Comptime-generic over `Buffered` (the Cmd buffer shape — Phase 4
/// settles on `effect.Cmd`'s collection type; pre-Phase-4 sites
/// embed their bespoke shapes) and `Txn` (the txn pointer type;
/// today `*kv_mod.KvStore.TrackedTxn` at the instantiation site).
///
/// The struct mirrors today's `worker.ParkedUnit` field-by-field
/// PLUS a `wake_key` slot — so a Phase 3.1 migration is structural,
/// not behavioral. The H2-reference path (Phase 3.2) eventually
/// instantiates this with the same `txn` type and a `Buffered`
/// shape covering the H2 response staging (h2.RespBody +
/// RespHeaders + Status etc.).
pub fn Continuation(comptime Buffered: type, comptime Txn: type) type {
    return struct {
        const Self = @This();

        /// The raft seq we're parked on. `reconcile` commits when
        /// `committedSeq() >= seq`; aborts on `faultedSeq() >= seq`
        /// or `now_ns >= deadline_ns`.
        seq: u64 = 0,
        deadline_ns: i64 = 0,
        /// Owned copy when non-empty. Free in `deinit`.
        tenant_id: []u8 = &.{},
        /// Buffered effects released by the reconciler on commit,
        /// discarded on fault. Shape is per-site until Phase 4
        /// settles a uniform `effect.Cmd` list.
        buffered: Buffered = .{},
        /// Optional txn pointer (`*kv_mod.KvStore.TrackedTxn` at the
        /// instantiation site). Null on entity-backed parked units
        /// where the entity's RaftWait sweep owns the txn separately;
        /// non-null on the `proposeForgetfulWrites` flavor that has
        /// no entity in `raft_pending`.
        txn: ?Txn = null,
        /// Phase 3.5 wake index key. Declared in 3.0; populated by
        /// 3.1+; indexed in 3.5.
        wake_key: ?WakeKey = null,

        /// Rove-compatible component deinit. Called by
        /// `Collection.deinit` (and `reg.destroy`'s deferred sweep)
        /// on shutdown / entity destroy. Abandon-safe (L2): rolls
        /// back any owned txn, frees the buffered effects, frees
        /// owned strings.
        ///
        /// **Structural requirements on the type parameters**
        /// (Zig's comptime checks them at instantiation):
        ///
        /// - `Buffered` MUST provide `pub fn deinit(*Self,
        ///   std.mem.Allocator) void`. The buffered-effects type
        ///   owns its inner lists / strings and frees them here.
        /// - `Txn` MUST be a pointer type `*T` where `T` has
        ///   `pub fn rollback(*T) !void`. `kvexp`'s `TrackedTxn`
        ///   fits; the fault-tolerant `catch {}` on the call swallows
        ///   any rollback error (kvexp's overlay is volatile — no
        ///   on-disk divergence to undo).
        ///
        /// Phase 3.1 worker.ParkedUnit instantiates with
        /// `Buffered = worker.BufferedSendKvOps` (the send_ops +
        /// kv_wakes pair) and `Txn = *kv_mod.KvStore.TrackedTxn`.
        pub fn deinit(allocator: std.mem.Allocator, items: []Self) void {
            for (items) |*item| {
                item.buffered.deinit(allocator);
                if (item.txn) |t| {
                    t.rollback() catch {};
                    allocator.destroy(t);
                    item.txn = null;
                }
                if (item.tenant_id.len > 0) allocator.free(item.tenant_id);
                if (item.wake_key) |wk| switch (wk) {
                    .correlation_id => |cid| if (cid.len > 0) allocator.free(@constCast(cid)),
                    else => {},
                };
                item.* = .{};
            }
        }
    };
}

/// `reconcile` — the unified drain. One iteration over a collection
/// of Continuations: commit the ones whose raft seq is durable,
/// discard the ones that faulted or timed out.
///
/// **The L4 commit gate lives here.** Buffered Cmds release only
/// through the `onCommit` arm; the `onFault` arm discards. Any new
/// origin that wants commit-gated effects parks a Continuation +
/// trusts the reconciler — no need to reinvent the gate.
///
/// Phase 3.0 declares the function shape; Phase 3.1+ migrates each
/// existing drain (drainRaftPending's parked_units arm, the H2
/// raft_pending_* sweeps, parked_continuations, the streaming
/// sweeps) onto it. Comptime-generic over the host types so the
/// effect module stays a leaf.
///
/// `now_ns` — caller passes `std.time.nanoTimestamp()` (or test-
/// injected) so the reconciler is pure-function-testable.
///
/// `committedSeq` / `faultedSeq` — callbacks that consult the raft
/// state; opaque pointers so this fn doesn't import `kv_mod`.
///
/// `onCommit(cont, ctx)` — release buffered Cmds + resume.
/// `onFault(cont, ctx)` — discard buffered Cmds + resume with the
/// fault disposition (typically: respond 503, free txn rollback).
///
/// Both arms are invoked once per Continuation per pass; the caller
/// is responsible for destroying / moving the entity out of the
/// collection (typically via `reg.destroy` or `reg.move`).
pub fn ReconcileCtx(comptime Cont: type, comptime UserCtx: type) type {
    return struct {
        pub const SeqQuery = *const fn (UserCtx, u64) bool;
        pub const ResumeFn = *const fn (UserCtx, *Cont, Disposition) void;
        pub const NowFn = *const fn () i64;
    };
}

// Note: the actual `reconcile(...)` loop is intentionally NOT
// declared as a single concrete function in Phase 3.0 — each
// existing drain site has its own iteration + entity-destroy
// idiom (rove ECS deferred destroy + reg.move for state-as-
// membership). The migration approach is to extract the
// commit-vs-fault decision logic per site into a call to a
// shared helper, then unify those calls when the shape stabilizes.
// Phase 3.1's PR is where the first concrete iteration template
// emerges; the design here is the contract that template fills.

// ── tests ───────────────────────────────────────────────────────

test "Continuation: typed instantiation + deinit walks structurally" {
    const testing = std.testing;

    // Buffered must have `deinit(*Self, allocator)` per the
    // structural contract.
    const FakeBuffered = struct {
        owned: ?[]u8 = null,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (self.owned) |b| allocator.free(b);
            self.* = .{};
        }
    };

    // Txn (when a pointer) must have `rollback(*T) !void`.
    var rollbacks_called: u32 = 0;
    const Rollback = struct {
        var counter: *u32 = undefined;
    };
    Rollback.counter = &rollbacks_called;

    const FakeTxn = struct {
        pub fn rollback(_: *@This()) !void {
            Rollback.counter.* += 1;
        }
    };

    const Cont = Continuation(FakeBuffered, *FakeTxn);

    // Build one with owned bytes + a heap-allocated txn; verify
    // deinit frees both.
    const txn_ptr = try testing.allocator.create(FakeTxn);
    txn_ptr.* = .{};
    const owned = try testing.allocator.dupe(u8, "hello");

    var items = [_]Cont{.{
        .seq = 7,
        .deadline_ns = 1000,
        .tenant_id = try testing.allocator.dupe(u8, "acme"),
        .buffered = .{ .owned = owned },
        .txn = txn_ptr,
        .wake_key = .{ .seq = 7 },
    }};

    Cont.deinit(testing.allocator, &items);
    try testing.expectEqual(@as(u32, 1), rollbacks_called);
    try testing.expect(items[0].txn == null);
    try testing.expect(items[0].tenant_id.len == 0);
}

test "classify: commit / fault / timeout / pending outcomes" {
    const testing = std.testing;

    // committed >= seq → commit (wins even if also timed out).
    try testing.expectEqual(SweepClass.commit, classify(7, 1, .{
        .committed = 10, .faulted = 0, .now_ns = 1000,
    }));
    try testing.expectEqual(SweepClass.commit, classify(7, 1, .{
        // Edge: now > deadline AND committed >= seq → commit still
        // wins. The order matches today's drainRaftPending body.
        .committed = 7, .faulted = 0, .now_ns = 9999,
    }));

    // faulted (>= seq, faulted>0) → fault.
    try testing.expectEqual(SweepClass.fault, classify(7, 1000, .{
        .committed = 5, .faulted = 8, .now_ns = 0,
    }));
    // faulted == seq → fault (boundary).
    try testing.expectEqual(SweepClass.fault, classify(7, 1000, .{
        .committed = 5, .faulted = 7, .now_ns = 0,
    }));

    // timed-out → fault.
    try testing.expectEqual(SweepClass.fault, classify(7, 100, .{
        .committed = 5, .faulted = 0, .now_ns = 150,
    }));

    // Pre-commit, pre-fault, pre-deadline → pending.
    try testing.expectEqual(SweepClass.pending, classify(7, 100, .{
        .committed = 5, .faulted = 0, .now_ns = 50,
    }));

    // faulted == 0 means "no fault declared"; not a fault even if 0 >= seq=0.
    try testing.expectEqual(SweepClass.pending, classify(7, 100, .{
        .committed = 5, .faulted = 0, .now_ns = 50,
    }));
}

test "Continuation: WakeKey variants construct" {
    const testing = std.testing;

    const FakeBuffered = struct {
        pub fn deinit(self: *@This(), _: std.mem.Allocator) void { self.* = .{}; }
    };
    const FakeTxn = struct {
        pub fn rollback(_: *@This()) !void {}
    };
    const Cont = Continuation(FakeBuffered, *FakeTxn);

    var c: Cont = .{};
    c.wake_key = .{ .seq = 42 };
    try testing.expectEqual(@as(u64, 42), c.wake_key.?.seq);

    c.wake_key = .{ .msg = .fetch_chunk };
    try testing.expectEqual(msg_mod.ActivationSource.fetch_chunk, c.wake_key.?.msg);
}

test "Disposition is a two-variant enum" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 2), @typeInfo(Disposition).@"enum".fields.len);
}
