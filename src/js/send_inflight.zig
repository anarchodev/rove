//! http.send Option (b) increment 4a — the per-worker in-flight /
//! timer set (docs/http-send-plan.md §15; task #8). The in-memory
//! structure each worker drains to fire its own owed sends; the
//! durable backstop is the per-tenant `_send/owed/` kv (increments
//! 1-3, shipped). 3(b) settled: it is (re)populated at process start
//! by a boot-scan of `_send/owed/` and at runtime by the feed
//! (FORK-1) — both land here.
//!
//! Increment 4a (this file): the pure data shape + lifecycle ops
//! ONLY — self-contained, unit-tested, ZERO wiring into worker /
//! apply / fire. Mirrors how `send_outbox.zig` was Option (b)'s
//! additive increment 1 and `continuation.zig` was 3b's. The feed
//! (4b) and the per-worker libcurl fire + resolve (4c) build on this;
//! nothing here fires anything.
//!
//! ## State is collection membership, not a flag
//!
//! An entry is either `armed` (eligible for the drain to fire once
//! `fire_at_ns ≤ now`) or `inflight` (fired, awaiting its
//! `_send/proof/` commit). That distinction is the schedule-server
//! thread's in-flight-set role (src/schedule_server/thread.zig:27 —
//! a slow delivery must not be re-picked before its envelope-9
//! commits) and is modelled as membership in two maps, not a bool on
//! the entry (feedback_state_is_collection).
//!
//! ## Dedup / resolve-once
//!
//! `arm` rejects an id already present (armed OR inflight). Boot-scan
//! reconstruction and the live feed can both present the same owed
//! (e.g. restart re-seeing a still-inflight send); the first wins,
//! the duplicate is refused. This is the structural half of Option
//! (b)'s retained resolve-once requirement.

const std = @import("std");
const send_outbox = @import("send_outbox.zig");

pub const OwedSend = send_outbox.OwedSend;

/// The captured outcome of a fire (4c-ii). Owned + self-contained so
/// `send_inflight` stays pure (no schedule_server coupling): 4c-ii-B
/// builds it from `thread.FireResult` (dup'ing both `body` and the
/// otherwise-static `err` for uniform ownership — avoids the
/// `send_outbox.Proof.deinitOwned`-frees-a-static hazard), 4c-iii
/// converts it to a `_send/proof/` write / `on_result` event.
pub const FireOutcome = struct {
    ok: bool,
    status: u16,
    body: []u8, // owned (0-len allowed)
    err: []u8, // owned (0-len = success)

    pub fn deinit(self: *FireOutcome, a: std.mem.Allocator) void {
        a.free(self.body);
        a.free(self.err);
    }
};

pub const Entry = struct {
    /// Owned. The send id == `_send/owed/{id}` id == callback id.
    id: []u8,
    /// Owned. Issuing tenant — the `_send/owed/` lives in its app.db;
    /// owning worker = hash(tenant)→worker (resolution routes by the
    /// send-id resume-search, not a stored handle).
    tenant_id: []u8,
    /// Owned: must be the dup'd result of `OwedSend.decode`. Carries
    /// everything needed to (re-)fire + `fire_at_ns` (0 = immediate;
    /// else the durable-timer due time, §15.5).
    owed: OwedSend,
    /// Captured fire result. null while `armed`/`inflight`; set when
    /// the fire completes and the entry moves `inflight → completed`
    /// (4c-ii-B). Consumed + freed by 4c-iii resolution. Owned.
    result: ?FireOutcome = null,

    /// Frees `owed`'s slices (it owns them via `decode`) + id +
    /// tenant_id + any captured `result`. Does NOT free the `Entry`
    /// allocation itself — the set owns that and frees it after
    /// `deinit`.
    pub fn deinit(self: *Entry, a: std.mem.Allocator) void {
        self.owed.deinitOwned(a);
        a.free(self.id);
        a.free(self.tenant_id);
        if (self.result) |*r| r.deinit(a);
    }

    pub fn fireAtNs(self: *const Entry) i64 {
        return self.owed.fire_at_ns;
    }

    /// Eligible to fire at `now_ns`? (Armed-set membership is the
    /// gate on *being* fireable; this is the time predicate the
    /// drain in 4c applies on top.)
    pub fn dueAt(self: *const Entry, now_ns: i64) bool {
        return self.owed.fire_at_ns <= now_ns;
    }
};

/// Per-worker. NOT thread-safe by itself: each worker owns one and
/// touches it only from its own tick (same discipline as
/// `pending_txns` / `parked_meta`). The 4b apply→worker handoff is
/// responsible for crossing the thread boundary, not this structure.
pub const InflightSet = struct {
    /// Keyed by `entry.id` (the slice is borrowed from the owned
    /// `Entry.id` — valid for the entry's lifetime; freed only after
    /// the map node is removed). `*Entry` is heap-stable so 4c can
    /// hold a pointer across the fire.
    armed: std.StringHashMapUnmanaged(*Entry) = .empty,
    inflight: std.StringHashMapUnmanaged(*Entry) = .empty,
    /// Fired, result captured, awaiting 4c-iii worker-side resolution
    /// (on_result run / `_send/proof/` write). 7-A's work-queue role
    /// of the dissolved schedule.db — a phase, not a structure.
    completed: std.StringHashMapUnmanaged(*Entry) = .empty,
    /// 4c-iii-B: handed to a leader worker for resolution (on_result
    /// run / fire-and-forget proof), awaiting the `_send/proof/`
    /// commit (which removes it via the 4b-ii feed → `resolve`).
    /// PUSH-ONCE: the resolution-drain scans only `completed`, so an
    /// entry here is NOT re-pushed (no duplicate-on_result storm / no
    /// unbounded completion queue). A worker `.kept` transient
    /// failure moves it back `resolving → completed` (re-push next
    /// tick — the at-least-once retry the old dispatchCallbacks gave
    /// via its un-cancel-dropped `c/` row).
    resolving: std.StringHashMapUnmanaged(*Entry) = .empty,

    pub fn deinit(self: *InflightSet, a: std.mem.Allocator) void {
        inline for (.{ &self.armed, &self.inflight, &self.completed, &self.resolving }) |m| {
            var it = m.valueIterator();
            while (it.next()) |ep| {
                ep.*.deinit(a);
                a.destroy(ep.*);
            }
            m.deinit(a);
        }
    }

    /// Free every entry and empty both maps, keeping the `InflightSet`
    /// reusable (unlike `deinit`). Option (b) FORK-6: the leader-local
    /// set is dropped wholesale on raft demotion — a future leader
    /// reconstructs from the durable per-tenant `_send/owed/` via the
    /// promotion boot-scan, so discarding here loses nothing.
    pub fn clear(self: *InflightSet, a: std.mem.Allocator) void {
        inline for (.{ &self.armed, &self.inflight, &self.completed, &self.resolving }) |m| {
            var it = m.valueIterator();
            while (it.next()) |ep| {
                ep.*.deinit(a);
                a.destroy(ep.*);
            }
            m.clearRetainingCapacity();
        }
    }

    /// Option (b) FORK-6' (4b-iv): raft demotion. Unlike `clear`,
    /// KEEP the set — a now-follower must retain `armed` so a fast
    /// re-promotion fires immediately (the whole point of FORK-6').
    /// The leader-local firing phases (`inflight`; later 7-A's
    /// `completed`) collapse back into `armed`: any send the old
    /// leader had in-flight-but-unproven becomes fireable again, so
    /// on re-promotion it re-fires (at-least-once; resolve-once
    /// dedup absorbs the duplicate — identical to the schedule-server
    /// thread's "future leader can re-fire in-flight rows"). Entry
    /// pointers are heap-stable, so this is a rehome (no free). Any
    /// captured `result` (on `completed` entries) is discarded here:
    /// it was never proof-written, so re-firing on re-promotion
    /// re-derives it (at-least-once); keeping a stale result on a
    /// back-to-`armed` entry would be wrong.
    pub fn demoteToArmed(self: *InflightSet, a: std.mem.Allocator) void {
        inline for (.{ &self.inflight, &self.completed, &self.resolving }) |m| {
            var it = m.valueIterator();
            while (it.next()) |ep| {
                const e = ep.*;
                if (e.result) |*r| {
                    r.deinit(a);
                    e.result = null;
                }
                if (self.armed.contains(e.id)) {
                    // Defensive: ids are disjoint across phases by
                    // construction (markFiring/markCompleted move, not
                    // copy). If an invariant break ever doubles one,
                    // free the stray rather than leak/double-own.
                    e.deinit(a);
                    a.destroy(e);
                } else {
                    self.armed.put(a, e.id, e) catch {
                        // OOM rehoming: drop this one (it stays owed
                        // in kv; the cold-start boot-scan safety-net
                        // re-arms it on a later promotion — no silent
                        // loss).
                        e.deinit(a);
                        a.destroy(e);
                    };
                }
            }
            m.clearRetainingCapacity();
        }
    }

    /// inflight → completed: the fire returned; attach its captured
    /// `result`. Takes ownership of `result`. `null`/no-op (and frees
    /// `result`) if `id` is not inflight — it resolved/cancelled
    /// while the fire was outstanding, so the result is moot (the
    /// dedup against a duplicate fire). 4c-iii drains `completed`.
    pub fn markCompleted(
        self: *InflightSet,
        a: std.mem.Allocator,
        id: []const u8,
        result: FireOutcome,
    ) void {
        const kv = self.inflight.fetchRemove(id) orelse {
            var r = result;
            r.deinit(a);
            return;
        };
        const e = kv.value;
        if (e.result) |*old| old.deinit(a); // shouldn't happen; be safe
        e.result = result;
        self.completed.put(a, e.id, e) catch {
            // OOM: cannot stage for resolution. Drop the entry; it
            // stays owed-without-proof in kv → re-fired on a later
            // promotion (at-least-once). No silent loss.
            e.deinit(a);
            a.destroy(e);
        };
    }

    pub fn completedCount(self: *const InflightSet) usize {
        return self.completed.count();
    }

    /// 4c-iii drains this (run on_result / write `_send/proof/` then
    /// `resolve`). Same caveat as `armedIterator`: a scan of THIS
    /// node's own small set, not a per-tenant scan.
    pub fn completedIterator(self: *InflightSet) std.StringHashMapUnmanaged(*Entry).ValueIterator {
        return self.completed.valueIterator();
    }

    /// 4c-iii-B push-once: `completed → resolving` once the
    /// resolution-drain has handed the receipt to a leader worker.
    /// No-op + `false` if not in `completed` (already resolving /
    /// resolved / gone — the dedup that prevents re-pushing while a
    /// proof commit is in flight).
    pub fn markResolving(self: *InflightSet, a: std.mem.Allocator, id: []const u8) bool {
        const kv = self.completed.fetchRemove(id) orelse return false;
        self.resolving.put(a, kv.value.id, kv.value) catch {
            // OOM: cannot stage. Drop — owed-without-proof in kv ⇒
            // re-fired on a later promotion (at-least-once).
            kv.value.deinit(a);
            a.destroy(kv.value);
            return false;
        };
        return true;
    }

    /// 4c-iii-B worker `.kept` (transient resolution failure):
    /// `resolving → completed` so the drain re-pushes next tick (the
    /// at-least-once retry the old dispatchCallbacks gave via its
    /// un-cancel-dropped `c/` row). No-op if not resolving.
    pub fn requeueResolution(self: *InflightSet, a: std.mem.Allocator, id: []const u8) bool {
        const kv = self.resolving.fetchRemove(id) orelse return false;
        self.completed.put(a, kv.value.id, kv.value) catch {
            kv.value.deinit(a);
            a.destroy(kv.value);
            return false;
        };
        return true;
    }

    pub fn resolvingCount(self: *const InflightSet) usize {
        return self.resolving.count();
    }

    pub fn getById(self: *InflightSet, id: []const u8) ?*Entry {
        if (self.armed.get(id)) |e| return e;
        if (self.inflight.get(id)) |e| return e;
        if (self.completed.get(id)) |e| return e;
        if (self.resolving.get(id)) |e| return e;
        return null;
    }

    /// Take ownership of a heap-allocated `e` and arm it. Returns
    /// `false` (and does NOT take ownership — caller frees `e` +
    /// destroys it) if `e.id` is already present in ANY phase: the
    /// existing entry wins (resolve-once on re-feed / boot-scan ∪
    /// live feed; never re-arm something mid-fire or awaiting
    /// resolution).
    pub fn arm(self: *InflightSet, a: std.mem.Allocator, e: *Entry) !bool {
        if (self.armed.contains(e.id) or self.inflight.contains(e.id) or
            self.completed.contains(e.id) or self.resolving.contains(e.id)) return false;
        try self.armed.put(a, e.id, e);
        return true;
    }

    /// armed → inflight: the drain (4c) picked this to fire. Returns
    /// the (now inflight) entry, or `null` if it was not armed
    /// (already inflight, or gone) — the dedup guard against a slow
    /// delivery being re-fired before its proof commits.
    pub fn markFiring(self: *InflightSet, a: std.mem.Allocator, id: []const u8) !?*Entry {
        const kv = self.armed.fetchRemove(id) orelse return null;
        try self.inflight.put(a, kv.value.id, kv.value);
        return kv.value;
    }

    /// Remove + free from whichever map holds it: `_send/proof/`
    /// committed (resolved) or the send was cancelled. Idempotent —
    /// `false` if absent.
    pub fn resolve(self: *InflightSet, a: std.mem.Allocator, id: []const u8) bool {
        inline for (.{ &self.armed, &self.inflight, &self.completed, &self.resolving }) |m| {
            if (m.fetchRemove(id)) |kv| {
                kv.value.deinit(a);
                a.destroy(kv.value);
                return true;
            }
        }
        return false;
    }

    pub fn armedCount(self: *const InflightSet) usize {
        return self.armed.count();
    }
    pub fn inflightCount(self: *const InflightSet) usize {
        return self.inflight.count();
    }

    /// For the 4c drain: iterate armed entries, applying the
    /// `fire_at_ns ≤ now` predicate at the call site. This is a scan
    /// of THIS worker's own armed set (bounded by in-flight sends on
    /// this worker — small; sends resolve fast), NOT a per-tenant /
    /// all-tenant scan — distinct from and not in tension with the
    /// per-tick no-scan invariant (task #8).
    pub fn armedIterator(self: *InflightSet) std.StringHashMapUnmanaged(*Entry).ValueIterator {
        return self.armed.valueIterator();
    }
};

// ── tests ──────────────────────────────────────────────────────────

const testing = std.testing;

/// A decoded (owned) OwedSend, so `Entry.deinit`'s `deinitOwned` is
/// valid — same construction the real feed uses (decode of the
/// `_send/owed/` bytes).
fn ownedOwed(a: std.mem.Allocator, fire_at_ns: i64) !OwedSend {
    const src = OwedSend{
        .url = "https://wb.test/x",
        .method = "POST",
        .headers_json = "{}",
        .body = "b",
        .context_json = "null",
        .on_result_module = "m",
        .on_result_fn = "",
        .on_result_args_json = "",
        .timeout_ms = 30_000,
        .max_body_bytes = 1_048_576,
        .fire_at_ns = fire_at_ns,
    };
    const enc = try src.encode(a);
    defer a.free(enc);
    return OwedSend.decode(a, enc);
}

fn mkEntry(a: std.mem.Allocator, id: []const u8, fire_at_ns: i64) !*Entry {
    const e = try a.create(Entry);
    errdefer a.destroy(e);
    e.* = .{
        .id = try a.dupe(u8, id),
        .tenant_id = try a.dupe(u8, "tenant-1"),
        .owed = try ownedOwed(a, fire_at_ns),
    };
    return e;
}

test "arm / getById / lifecycle, deinit frees everything" {
    const a = testing.allocator;
    var set = InflightSet{};
    defer set.deinit(a); // leaks would fail under testing.allocator

    const e1 = try mkEntry(a, "id-1", 0);
    try testing.expect(try set.arm(a, e1));
    try testing.expectEqual(@as(usize, 1), set.armedCount());
    try testing.expect(set.getById("id-1") != null);
    try testing.expect(set.getById("nope") == null);

    // armed → inflight (drain fired it)
    const fired = (try set.markFiring(a, "id-1")).?;
    try testing.expectEqualStrings("id-1", fired.id);
    try testing.expectEqual(@as(usize, 0), set.armedCount());
    try testing.expectEqual(@as(usize, 1), set.inflightCount());
    try testing.expect(set.getById("id-1") != null); // still findable

    // proof committed → resolve removes + frees
    try testing.expect(set.resolve(a, "id-1"));
    try testing.expect(set.getById("id-1") == null);
    try testing.expect(!set.resolve(a, "id-1")); // idempotent
}

test "arm dedups: existing entry wins, duplicate refused (resolve-once)" {
    const a = testing.allocator;
    var set = InflightSet{};
    defer set.deinit(a);

    const first = try mkEntry(a, "dup", 0);
    try testing.expect(try set.arm(a, first));

    // boot-scan re-sees the same still-armed owed: refused, caller frees.
    const dup = try mkEntry(a, "dup", 0);
    try testing.expect(!(try set.arm(a, dup)));
    dup.deinit(a);
    a.destroy(dup);

    // also refused when the id is inflight (slow delivery, re-fed).
    _ = try set.markFiring(a, "dup");
    const dup2 = try mkEntry(a, "dup", 0);
    try testing.expect(!(try set.arm(a, dup2)));
    dup2.deinit(a);
    a.destroy(dup2);
    try testing.expectEqual(@as(usize, 1), set.inflightCount());
}

test "markFiring on a non-armed id returns null (dedup against double-fire)" {
    const a = testing.allocator;
    var set = InflightSet{};
    defer set.deinit(a);

    try testing.expect((try set.markFiring(a, "ghost")) == null);

    const e = try mkEntry(a, "x", 0);
    try testing.expect(try set.arm(a, e));
    _ = try set.markFiring(a, "x"); // now inflight
    // a second drain pass must NOT re-fire it.
    try testing.expect((try set.markFiring(a, "x")) == null);
}

test "clear frees armed+inflight and stays reusable" {
    const a = testing.allocator;
    var set = InflightSet{};
    defer set.deinit(a);

    try testing.expect(try set.arm(a, try mkEntry(a, "a", 0)));
    try testing.expect(try set.arm(a, try mkEntry(a, "b", 0)));
    _ = try set.markFiring(a, "b"); // one armed, one inflight
    set.clear(a);
    try testing.expectEqual(@as(usize, 0), set.armedCount());
    try testing.expectEqual(@as(usize, 0), set.inflightCount());
    try testing.expect(set.getById("a") == null);
    // reusable after clear
    try testing.expect(try set.arm(a, try mkEntry(a, "c", 0)));
    try testing.expectEqual(@as(usize, 1), set.armedCount());
}

test "demoteToArmed: inflight collapses back to armed, set retained" {
    const a = testing.allocator;
    var set = InflightSet{};
    defer set.deinit(a);

    try testing.expect(try set.arm(a, try mkEntry(a, "a", 0)));
    try testing.expect(try set.arm(a, try mkEntry(a, "b", 0)));
    _ = try set.markFiring(a, "b"); // a armed, b inflight
    try testing.expectEqual(@as(usize, 1), set.armedCount());
    try testing.expectEqual(@as(usize, 1), set.inflightCount());

    set.demoteToArmed(a); // raft demotion

    try testing.expectEqual(@as(usize, 2), set.armedCount()); // b rehomed
    try testing.expectEqual(@as(usize, 0), set.inflightCount());
    try testing.expect(set.getById("a") != null);
    try testing.expect(set.getById("b") != null); // kept, not freed
    // re-promotion would re-fire b (at-least-once) — still armed:
    const b = (try set.markFiring(a, "b")).?;
    try testing.expectEqualStrings("b", b.id);
}

fn mkOutcome(a: std.mem.Allocator, ok: bool) !FireOutcome {
    return .{
        .ok = ok,
        .status = if (ok) 200 else 500,
        .body = try a.dupe(u8, "resp-body"),
        .err = try a.dupe(u8, if (ok) "" else "boom"),
    };
}

test "4c-ii-A: inflight→completed via markCompleted; getById/resolve see it" {
    const a = testing.allocator;
    var set = InflightSet{};
    defer set.deinit(a);

    try testing.expect(try set.arm(a, try mkEntry(a, "c1", 0)));
    _ = try set.markFiring(a, "c1"); // inflight
    set.markCompleted(a, "c1", try mkOutcome(a, true));
    try testing.expectEqual(@as(usize, 0), set.inflightCount());
    try testing.expectEqual(@as(usize, 1), set.completedCount());

    const e = set.getById("c1").?; // getById sees completed
    try testing.expect(e.result != null);
    try testing.expectEqual(@as(u16, 200), e.result.?.status);
    try testing.expectEqualStrings("resp-body", e.result.?.body);

    // arm dedups vs completed (never re-arm awaiting-resolution).
    const dup = try mkEntry(a, "c1", 0);
    try testing.expect(!(try set.arm(a, dup)));
    dup.deinit(a);
    a.destroy(dup);

    // resolve removes+frees from completed (proof committed).
    try testing.expect(set.resolve(a, "c1"));
    try testing.expect(set.getById("c1") == null);
}

test "4c-ii-A: markCompleted on a non-inflight id is a no-op + frees the result" {
    const a = testing.allocator;
    var set = InflightSet{};
    defer set.deinit(a);
    // id never inflight (resolved/cancelled while fire outstanding):
    set.markCompleted(a, "ghost", try mkOutcome(a, false)); // must free, no leak
    try testing.expectEqual(@as(usize, 0), set.completedCount());
}

test "4c-ii-A: demoteToArmed collapses completed→armed, frees the stale result" {
    const a = testing.allocator;
    var set = InflightSet{};
    defer set.deinit(a);

    try testing.expect(try set.arm(a, try mkEntry(a, "d1", 0)));
    _ = try set.markFiring(a, "d1");
    set.markCompleted(a, "d1", try mkOutcome(a, true));
    try testing.expectEqual(@as(usize, 1), set.completedCount());

    set.demoteToArmed(a); // demotion: result discarded, re-fireable

    try testing.expectEqual(@as(usize, 0), set.completedCount());
    try testing.expectEqual(@as(usize, 1), set.armedCount());
    const e = set.getById("d1").?;
    try testing.expect(e.result == null); // stale result cleared
}

test "4c-iii-B-1: resolving phase — push-once, requeue, resolve, demote" {
    const a = testing.allocator;
    var set = InflightSet{};
    defer set.deinit(a);

    try testing.expect(try set.arm(a, try mkEntry(a, "x", 0)));
    _ = try set.markFiring(a, "x");
    set.markCompleted(a, "x", try mkOutcome(a, true)); // completed

    // push-once: completed → resolving; a 2nd markResolving no-ops
    // (NOT in completed any more → not re-pushed while proof commits).
    try testing.expect(set.markResolving(a, "x"));
    try testing.expectEqual(@as(usize, 0), set.completedCount());
    try testing.expectEqual(@as(usize, 1), set.resolvingCount());
    try testing.expect(!set.markResolving(a, "x"));
    try testing.expect(set.getById("x") != null); // still findable
    // arm dedups vs resolving (never re-arm an awaiting-proof send)
    const dup = try mkEntry(a, "x", 0);
    try testing.expect(!(try set.arm(a, dup)));
    dup.deinit(a);
    a.destroy(dup);

    // worker `.kept`: resolving → completed (re-push next tick)
    try testing.expect(set.requeueResolution(a, "x"));
    try testing.expectEqual(@as(usize, 1), set.completedCount());
    try testing.expectEqual(@as(usize, 0), set.resolvingCount());
    try testing.expect(!set.requeueResolution(a, "x")); // not resolving now

    // success path: proof commit → resolve removes from resolving
    try testing.expect(set.markResolving(a, "x"));
    try testing.expect(set.resolve(a, "x"));
    try testing.expect(set.getById("x") == null);

    // demote collapses resolving → armed (re-fire on re-promotion)
    try testing.expect(try set.arm(a, try mkEntry(a, "y", 0)));
    _ = try set.markFiring(a, "y");
    set.markCompleted(a, "y", try mkOutcome(a, false));
    try testing.expect(set.markResolving(a, "y"));
    set.demoteToArmed(a);
    try testing.expectEqual(@as(usize, 0), set.resolvingCount());
    try testing.expectEqual(@as(usize, 1), set.armedCount());
    try testing.expect(set.getById("y").?.result == null);
}

test "due predicate: immediate vs future fire_at_ns" {
    const a = testing.allocator;
    var set = InflightSet{};
    defer set.deinit(a);

    const immediate = try mkEntry(a, "now", 0);
    try testing.expect(try set.arm(a, immediate));
    const future = try mkEntry(a, "later", 9_000_000_000_000_000_000);
    try testing.expect(try set.arm(a, future));

    try testing.expect(set.getById("now").?.dueAt(1));
    try testing.expect(!set.getById("later").?.dueAt(1));
}
