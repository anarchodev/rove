// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The offline engine's delegate behind the common kv binding
//! (`rove-binding`) — the same native `kv.get/set/delete/prefix` the worker
//! registers, installed over arenajs's replay kv object at reactor base
//! setup (`mod_loader.simSetup`).
//!
//! Storage stays exactly where it was: the delegate dispatches through the
//! registered replay-host vtable (`host.setHost`'s mirror), the same
//! indirection arenajs's own kv binding used — so the run host (`host.zig`,
//! closed-world map) and the rewind-test harness host (`harness.zig`, which
//! re-takes the vtable around nested sim runs) both keep serving without
//! knowing the JS surface changed.
//!
//! Everything ABOVE the vtable is one implementation with the worker now.
//! The binding owns coercion + guards + refusal shapes + result shaping;
//! this delegate owns the offline mirror of the worker delegate's duties, in
//! the worker's order — guard, BEFORE-trigger chain, store, effect record,
//! subscription markers, AFTER-trigger chain:
//!
//!   - the ordered effect log entries (`globalThis.__rove_effects`, pushed
//!     through the epilogue's PATCHED push so the interaction digest folds
//!     at the same points);
//!   - the kv-trigger chains, dispatched to the epilogue-defined
//!     `__rove_run_triggers` (the trigger table and its module namespaces
//!     are per-request JS; the chain's `previousValue` is supplied from
//!     here via a RAW read, effect-invisible exactly as the worker's
//!     slow-path prev fetch is);
//!   - the `_sub/dirty/{name}` subscription markers (the worker's
//!     markSubscriptionsDirty, stated offline): raw reads/writes below the
//!     binding, so no guard exemption is reachable from customer JS;
//!   - the harness-namespace carve-outs (`__rove_store/` reads/writes are
//!     the facade's own and never recorded; customer prefix scans never see
//!     namespaced rows).

const std = @import("std");
const binding = @import("rove-binding");
const guards = binding.guards;
const c = @import("qjs_c.zig").c;
const host = @import("host.zig");
const decode = @import("tape_decode.zig");
const digest_mod = @import("interaction-digest");

/// Keys the binding's guards do not judge, because they are not customer
/// writes (the JS evaluator's `isExempt` parameter, stated natively): the
/// harness store namespace — `platform.scope/root` facade keys and the sim's
/// own bookkeeping (`system_recorders.js` NS_STORE). The facade pushes its
/// OWN store-tagged effect entries, so the delegate records nothing for
/// them either.
///
/// Deliberately NOT exempt: `_sub/dirty/` (the delegate's marker writes run
/// below the binding, so a customer spoof hits the reserved-prefix refusal
/// exactly as in prod) and the parked-output sentinel (output parks through
/// `__rove_park_output`, not kv — a customer write to `__replay_output__`
/// is refused like any reserved key).
///
/// Carried corner: a customer writing directly under `__rove_store/` is
/// allowed here where prod refuses (the namespace is a harness construct
/// prod has never heard of). Same posture the JS wrapper had; closes when
/// the facade gets its own door.
pub const STORE_NS = "__rove_store/";

pub fn exempt(key: []const u8) bool {
    return std.mem.startsWith(u8, key, STORE_NS);
}

/// A handler-spelled key as the STORE holds it — the seeding side of the same
/// rule `binding.Kv(.user)` applies on the calling side. Authored worlds and
/// fixtures are written in the handler's spelling; anything that seeds the
/// host's maps has to resolve, or the world seeds at one depth and reads at
/// another (the writer/reader prefix-depth split: it presents as a world that
/// loads cleanly and then reads back empty).
///
/// Exempt keys are not the caller's to have rerooted — same carve-out, same
/// reason, as the binding's.
pub fn storeKey(a: std.mem.Allocator, named: []const u8) ![]const u8 {
    if (exempt(named)) return named;
    return std.mem.concat(a, u8, &.{ binding.guards.reserved.USER_KEY_ROOT, named });
}

/// Per-run `_sub/dirty/` marker dedup — the worker's `subs_marked` bitmask,
/// keyed by subscription name hash. Reset whenever a host is (re)installed:
/// each sim run installs its single-shot Host, so a generation bump is a new
/// activation.
var marked_gen: u64 = 0;
var marked_names: [64]u64 = undefined;
var marked_count: usize = 0;

fn markedContains(name: []const u8) bool {
    if (marked_gen != host.generation) {
        marked_gen = host.generation;
        marked_count = 0;
    }
    const h = std.hash.Wyhash.hash(0, name);
    for (marked_names[0..marked_count]) |m| if (m == h) return true;
    return false;
}

fn markedAdd(name: []const u8) void {
    if (marked_count >= marked_names.len) return;
    marked_names[marked_count] = std.hash.Wyhash.hash(0, name);
    marked_count += 1;
}

pub const OfflineKv = struct {
    ctx: ?*c.JSContext,

    pub fn fromCtx(ctx: ?*c.JSContext) OfflineKv {
        return .{ .ctx = ctx };
    }

    pub fn allocator(_: OfflineKv) std.mem.Allocator {
        return std.heap.c_allocator;
    }

    /// The offline engines have no baked platform modules; nothing that runs
    /// here is `__system/`-trusted.
    pub fn isSystemModule(_: OfflineKv) bool {
        return false;
    }

    pub fn isExempt(_: OfflineKv, key: []const u8) bool {
        return exempt(key);
    }

    /// The per-activation write budget (`reserved.KV_WRITES_MAX` /
    /// `KV_WRITE_BYTES_MAX`), so a sim run refuses where prod would. Counters
    /// live on the run host and reset with it — offline, one run is one
    /// activation, so they are that activation's slice.
    pub fn writeBudget(_: OfflineKv) guards.WriteBudget {
        return host.activeWriteBudget();
    }

    pub fn noteWrite(_: OfflineKv, bytes: usize) void {
        host.noteActiveWrite(bytes);
    }

    /// Authored worlds (and the harness) DECIDE — the same rules as the
    /// worker, through the same binding. A CAPTURED world replays outcomes
    /// instead: a write with no taped refusal succeeded at capture and must
    /// succeed here, whatever today's rules would say — rule evolution
    /// cannot manufacture a false divergence.
    pub fn decides(_: OfflineKv) bool {
        return !host.activeReplaysOutcomes();
    }

    /// Authored worlds have no release to scope `_config/` by, so a seeded
    /// key reads back exactly as the world wrote it. A captured world does
    /// not need one either: this binding is `.user`-rooted, where the config
    /// resolution does not apply — handler-named config is the narrower
    /// `config` capability's to serve, over a `.raw` binding.
    pub fn configScope(_: OfflineKv) u64 {
        return 0;
    }

    pub fn tapedRefusal(_: OfflineKv, op: binding.WriteOp, key: []const u8) ?[]const u8 {
        return host.activeTapedRefusal(switch (op) {
            .set => 's',
            .delete => 'd',
        }, key);
    }

    /// The offline engines produce no tapes — a live refusal in an authored
    /// world has nowhere to be recorded.
    pub fn recordRefusal(_: OfflineKv, _: binding.WriteOp, _: []const u8, _: anytype) void {}

    fn vtable(self: OfflineKv) ?*const host.ReplayHost {
        _ = self;
        return host.active_vtable;
    }

    /// "tape not installed" / responder-error → the same InternalError family
    /// arenajs's binding raised, so a failure stays legible rather than
    /// becoming a silent absent.
    fn throwHostError(self: OfflineKv, comptime what: []const u8, rc: c_int) void {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "kv.{s}: replay host error (rc={d})", .{ what, rc }) catch "kv: replay host error";
        _ = c.JS_ThrowInternalError(self.ctx, "%s", msg.ptr);
    }

    // ── raw storage (no effects, no guards — the delegate's own reads/writes) ──

    /// malloc'd value (free via std.c.free) | null = absent/error. The
    /// trigger chain's previousValue and the subscription-spec read use
    /// this: prod's equivalents (`state.kv.get` direct) are effect-invisible
    /// too.
    fn rawGet(self: OfflineKv, key: []const u8) ?[]u8 {
        const vt = self.vtable() orelse return null;
        const responder = vt.kv_get orelse return null;
        var outcome: c_int = 0;
        var val: [*c]u8 = null;
        var val_len: c_int = 0;
        const rc = responder(key.ptr, @intCast(key.len), &outcome, &val, &val_len, host.active_user);
        if (rc != 0 or outcome != @intFromEnum(decode.KvOutcome.ok) or val == null) {
            if (val != null) std.c.free(val);
            return null;
        }
        if (val_len == 0) {
            std.c.free(val);
            return null;
        }
        return val[0..@intCast(val_len)];
    }

    fn rawSet(self: OfflineKv, key: []const u8, value: []const u8) bool {
        const vt = self.vtable() orelse return false;
        const responder = vt.kv_set orelse return false;
        var outcome: c_int = 0;
        return responder(key.ptr, @intCast(key.len), value.ptr, @intCast(value.len), &outcome, host.active_user) == 0;
    }

    // ── the effect log — the shared binding helpers (binding.Effects) ────

    const FX = binding.Effects(c);

    // ── kv-trigger chains ────────────────────────────────────────────────

    const TriggerResult = union(enum) {
        /// Value to write: the original (borrowed) or a trigger-mutated copy
        /// (owned via c_allocator — caller frees when `mutated`).
        proceed: struct { value: ?[]const u8, mutated: bool },
        thrown,
    };

    /// Dispatch one chain to the epilogue-defined `__rove_run_triggers` —
    /// per-request JS (the trigger table + imported module namespaces live
    /// there), called from here so the chain sits in the worker's ORDER:
    /// after the guard, around the store. Absent global = no triggers
    /// registered for this run.
    fn runTriggers(
        self: OfflineKv,
        comptime op: []const u8,
        comptime timing: []const u8,
        key: []const u8,
        value: ?[]const u8,
        prev: ?[]const u8,
    ) TriggerResult {
        const g = c.JS_GetGlobalObject(self.ctx);
        defer c.JS_FreeValue(self.ctx, g);
        const f = c.JS_GetPropertyStr(self.ctx, g, "__rove_run_triggers");
        defer c.JS_FreeValue(self.ctx, f);
        if (!c.JS_IsFunction(self.ctx, f)) return .{ .proceed = .{ .value = value, .mutated = false } };

        const undef = c.JSValue{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
        const nul = c.JSValue{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_NULL };
        var argv = [5]c.JSValue{
            c.JS_NewStringLen(self.ctx, op.ptr, op.len),
            c.JS_NewStringLen(self.ctx, timing.ptr, timing.len),
            c.JS_NewStringLen(self.ctx, key.ptr, key.len),
            if (value) |v| c.JS_NewStringLen(self.ctx, v.ptr, v.len) else nul,
            if (prev) |p| c.JS_NewStringLen(self.ctx, p.ptr, p.len) else nul,
        };
        defer for (argv) |a| c.JS_FreeValue(self.ctx, a);
        const r = c.JS_Call(self.ctx, f, undef, argv.len, &argv);
        if (c.JS_IsException(r)) return .thrown;
        defer c.JS_FreeValue(self.ctx, r);
        if (c.JS_IsString(r)) {
            var len: usize = 0;
            const cstr = c.JS_ToCStringLen(self.ctx, &len, r);
            if (cstr == null) return .thrown;
            defer c.JS_FreeCString(self.ctx, cstr);
            const dup = std.heap.c_allocator.dupe(u8, @as([*]const u8, @ptrCast(cstr))[0..len]) catch
                return .{ .proceed = .{ .value = value, .mutated = false } };
            return .{ .proceed = .{ .value = dup, .mutated = true } };
        }
        return .{ .proceed = .{ .value = value, .mutated = false } };
    }

    // ── subscription markers ─────────────────────────────────────────────

    const Sub = struct { name: []const u8, prefix: []const u8 };

    /// The worker's markSubscriptionsDirty, offline: a customer write under
    /// a watched prefix injects ONE durable `_sub/dirty/{name}` marker —
    /// coalesced per activation, recursion-guarded on `_sub/` keys. Raw
    /// storage below the binding (a platform injection, not a customer
    /// write); the marker's write EFFECT is recorded, so the digest folds it
    /// exactly as the worker folds its foldWrite.
    fn markSubscriptionsDirty(self: OfflineKv, key: []const u8) void {
        if (std.mem.startsWith(u8, key, "_sub/")) return;
        const spec = self.rawGet(STORE_NS ++ "subscriptions") orelse return;
        defer std.c.free(@constCast(spec.ptr));
        const parsed = std.json.parseFromSlice([]Sub, std.heap.c_allocator, spec, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        for (parsed.value) |sub| {
            if (!std.mem.startsWith(u8, key, sub.prefix)) continue;
            if (markedContains(sub.name)) continue;
            markedAdd(sub.name);
            var mbuf: [96]u8 = undefined;
            const mkey = std.fmt.bufPrint(&mbuf, "_sub/dirty/{s}", .{sub.name}) catch continue;
            if (!self.rawSet(mkey, sub.prefix)) continue;
            FX.write(self.ctx, mkey, sub.prefix);
        }
    }

    // ── the delegate surface the binding calls ───────────────────────────

    pub fn get(self: OfflineKv, k: binding.Key) binding.GetResult {
        const key = k.stored;
        const vt = self.vtable() orelse {
            self.throwHostError("get", 1);
            return .thrown;
        };
        const responder = vt.kv_get orelse {
            self.throwHostError("get", 1);
            return .thrown;
        };
        var outcome: c_int = 0;
        var val: [*c]u8 = null;
        var val_len: c_int = 0;
        const rc = responder(key.ptr, @intCast(key.len), &outcome, &val, &val_len, host.active_user);
        if (rc != 0) {
            if (val != null) std.c.free(val);
            self.throwHostError("get", rc);
            return .thrown;
        }
        const facade = exempt(k.named);
        switch (@as(decode.KvOutcome, @enumFromInt(outcome))) {
            .ok => {
                // An empty value's buffer is freed here (release() frees by
                // pointer only when the slice is non-empty).
                if (val == null or val_len == 0) {
                    if (val != null) std.c.free(val);
                    if (!facade) FX.read(self.ctx, k.named, "");
                    return .{ .value = "" };
                }
                const v: []const u8 = val[0..@intCast(val_len)];
                if (!facade) FX.read(self.ctx, k.named, v);
                return .{ .value = v };
            },
            .not_found => {
                if (val != null) std.c.free(val);
                if (!facade) FX.read(self.ctx, k.named, null);
                return .absent;
            },
            .err => {
                // A recorded failure replays as the failure (arenajs's
                // "recorded failure" spelling).
                if (val != null) std.c.free(val);
                _ = c.JS_ThrowInternalError(self.ctx, "kv.get: recorded failure");
                return .thrown;
            },
            // The capture resolved this read and dropped its value (over the
            // activation's kv budget). The host has already recorded the
            // divergence and the interrupt is braking the run; answer absent
            // so the run unwinds instead of throwing something a handler
            // could catch and turn into a plausible alternative path.
            .elided => {
                if (val != null) std.c.free(val);
                if (!facade) FX.read(self.ctx, k.named, null);
                return .absent;
            },
            // `refused` exists only on write entries; a host answering a GET
            // with it is a protocol bug — loud, not absent.
            .refused => {
                if (val != null) std.c.free(val);
                _ = c.JS_ThrowInternalError(self.ctx, "kv.get: malformed host outcome");
                return .thrown;
            },
        }
    }

    pub fn release(_: OfflineKv, bytes: []const u8) void {
        // Responder buffers are malloc'd by the host (`host.dupC` contract);
        // an empty value never allocated.
        if (bytes.len > 0) std.c.free(@constCast(bytes.ptr));
    }

    pub fn put(self: OfflineKv, _: ?*c.JSContext, k: binding.Key, value: []const u8) bool {
        const key = k.stored;
        // Facade writes are the harness's own: stored raw, never recorded,
        // no triggers, no markers.
        if (exempt(k.named)) {
            if (!self.rawSet(key, value)) {
                self.throwHostError("set", -1);
                return false;
            }
            return true;
        }

        // The worker's order: guard (already run by the binding) →
        // BEFORE-chain (may mutate the value) → store → effect → markers →
        // AFTER-chain. `prev` is fetched raw — effect-invisible, like the
        // worker's slow-path previousValue.
        const prev = self.rawGet(key);
        defer if (prev) |p| std.c.free(@constCast(p.ptr));

        const before = self.runTriggers("put", "before", k.named, value, prev);
        const write_value: []const u8, const owned: bool = switch (before) {
            .thrown => return false,
            .proceed => |p| .{ p.value.?, p.mutated },
        };
        defer if (owned) std.heap.c_allocator.free(@constCast(write_value));

        const vt = self.vtable() orelse {
            self.throwHostError("set", 1);
            return false;
        };
        const responder = vt.kv_set orelse {
            self.throwHostError("set", 1);
            return false;
        };
        var outcome: c_int = 0;
        const rc = responder(key.ptr, @intCast(key.len), write_value.ptr, @intCast(write_value.len), &outcome, host.active_user);
        if (rc != 0) {
            self.throwHostError("set", rc);
            return false;
        }
        if (outcome == @intFromEnum(decode.KvOutcome.err)) {
            _ = c.JS_ThrowInternalError(self.ctx, "kv.set: recorded failure");
            return false;
        }

        FX.write(self.ctx, k.named, write_value);
        self.markSubscriptionsDirty(k.named);

        switch (self.runTriggers("put", "after", k.named, write_value, prev)) {
            .thrown => return false,
            .proceed => |p| if (p.mutated) std.heap.c_allocator.free(@constCast(p.value.?)),
        }
        return true;
    }

    pub fn del(self: OfflineKv, _: ?*c.JSContext, k: binding.Key) bool {
        const key = k.stored;
        if (exempt(k.named)) {
            const vt0 = self.vtable() orelse return true;
            const resp0 = vt0.kv_delete orelse return true;
            var oc0: c_int = 0;
            _ = resp0(key.ptr, @intCast(key.len), &oc0, host.active_user);
            return true;
        }

        const prev = self.rawGet(key);
        defer if (prev) |p| std.c.free(@constCast(p.ptr));

        switch (self.runTriggers("delete", "before", k.named, null, prev)) {
            .thrown => return false,
            .proceed => |p| if (p.mutated) std.heap.c_allocator.free(@constCast(p.value.?)),
        }

        const vt = self.vtable() orelse {
            self.throwHostError("delete", 1);
            return false;
        };
        const responder = vt.kv_delete orelse {
            self.throwHostError("delete", 1);
            return false;
        };
        var outcome: c_int = 0;
        const rc = responder(key.ptr, @intCast(key.len), &outcome, host.active_user);
        if (rc != 0) {
            self.throwHostError("delete", rc);
            return false;
        }
        if (outcome == @intFromEnum(decode.KvOutcome.err)) {
            _ = c.JS_ThrowInternalError(self.ctx, "kv.delete: recorded failure");
            return false;
        }

        FX.del(self.ctx, k.named);
        self.markSubscriptionsDirty(k.named);

        switch (self.runTriggers("delete", "after", k.named, null, prev)) {
            .thrown => return false,
            .proceed => |p| if (p.mutated) std.heap.c_allocator.free(@constCast(p.value.?)),
        }
        return true;
    }

    const Row = struct { key: []const u8, value: []const u8 };

    pub const Page = struct {
        parsed: std.json.Parsed([]Row),
        json_ptr: [*c]u8,
        entries: []Row,

        pub fn deinit(self: *Page) void {
            self.parsed.deinit();
            std.c.free(self.json_ptr);
        }
    };

    /// The responder returns the page as JSON (`host.zig` builds it; arenajs
    /// parsed it with JS_ParseJSON). The binding shapes the JS array itself,
    /// so parse it here. A facade scan (`__rove_store/…`) returns raw rows
    /// for the facade to strip and is not recorded; a customer scan never
    /// sees namespaced rows and records `count` + `rowsFold` over what it
    /// observed.
    pub fn prefix(self: OfflineKv, req: binding.Scan) ?Page {
        const p = req.prefix.stored;
        const cursor = req.cursor.stored;
        const limit = req.limit;
        const vt = self.vtable() orelse return null;
        const responder = vt.kv_prefix orelse return null;
        var outcome: c_int = 0;
        var json: [*c]u8 = null;
        var json_len: c_int = 0;
        const rc = responder(
            p.ptr,
            @intCast(p.len),
            cursor.ptr,
            @intCast(cursor.len),
            @intCast(limit),
            &outcome,
            &json,
            &json_len,
            host.active_user,
        );
        if (rc != 0 or json == null) {
            if (json != null) std.c.free(json);
            return null;
        }
        const bytes: []const u8 = json[0..@intCast(json_len)];
        var parsed = std.json.parseFromSlice([]Row, std.heap.c_allocator, bytes, .{}) catch {
            std.c.free(json);
            return null;
        };
        if (exempt(req.prefix.named)) {
            return .{ .parsed = parsed, .json_ptr = json, .entries = parsed.value };
        }
        // Strip harness-namespaced rows in place — prod has none to see.
        var n: usize = 0;
        for (parsed.value) |row| {
            if (std.mem.startsWith(u8, row.key, STORE_NS)) continue;
            parsed.value[n] = row;
            n += 1;
        }
        const rows = parsed.value[0..n];
        // The effect log records the scan the HANDLER saw, so its row keys are
        // un-rooted — `toHaveScanned("orders/")` asserts the spelling the
        // handler used. `rows` itself stays STORED: the binding un-maps on the
        // way out, and a row handed back already-visible would fail that check
        // and be dropped from the page.
        if (req.root.len == 0) {
            FX.prefixScan(self.ctx, std.heap.c_allocator, req.prefix.named, rows);
        } else if (std.heap.c_allocator.alloc(Row, rows.len)) |vis| {
            defer std.heap.c_allocator.free(vis);
            for (rows, 0..) |row, i| vis[i] = .{ .key = req.visible(row.key), .value = row.value };
            FX.prefixScan(self.ctx, std.heap.c_allocator, req.prefix.named, vis);
        } else |_| {}
        return .{ .parsed = parsed, .json_ptr = json, .entries = rows };
    }
};

// ── request.tag — the common Tag binding's offline delegate ─────────────
//
// Per-run tag storage (the worker keeps state.tags on its DispatchState; the
// offline engine keeps the equivalent here), generation-keyed like the
// subscription-marker dedup. Each accepted call also lands a {kind:"tag"}
// entry on the effect log so tests can assert what would index the record —
// timeline-only, like the old wrapper's push: the worker does not fold tags
// into the digest, so neither does anyone.

const TagPair = struct { key: []u8, value: []u8 };
var tag_gen: u64 = 0;
var tag_list: std.ArrayList(TagPair) = .empty;

fn tagsReset() void {
    if (tag_gen == host.generation) return;
    tag_gen = host.generation;
    // Same lifetime, same reset: the destroy cap is per ACTIVATION, and
    // a count carried across runs would refuse in replay what production
    // allowed.
    binding.OfflineShred.reset();
    for (tag_list.items) |t| {
        std.heap.c_allocator.free(t.key);
        std.heap.c_allocator.free(t.value);
    }
    tag_list.clearRetainingCapacity();
}

pub const OfflineTag = struct {
    ctx: ?*c.JSContext,

    pub fn fromCtx(ctx: ?*c.JSContext) OfflineTag {
        return .{ .ctx = ctx };
    }

    pub fn allocator(_: OfflineTag) std.mem.Allocator {
        return std.heap.c_allocator;
    }

    pub fn tagCount(_: OfflineTag) usize {
        tagsReset();
        return tag_list.items.len;
    }

    fn effectTag(self: OfflineTag, key: []const u8, val: []const u8) void {
        binding.Effects(c).tag(self.ctx, key, val);
    }

    pub fn tagUpdate(self: OfflineTag, key: []const u8, val: []const u8) bool {
        tagsReset();
        for (tag_list.items) |*t| {
            if (std.mem.eql(u8, t.key, key)) {
                const new_v = std.heap.c_allocator.dupe(u8, val) catch return true;
                std.heap.c_allocator.free(t.value);
                t.value = new_v;
                self.effectTag(key, val);
                return true;
            }
        }
        return false;
    }

    /// Stored, not sealed: the offline engines run against a recorded
    /// tape, not live key material. It exists here so the surface is the
    /// same shape on every engine — a handler calling `shredKey` must
    /// behave identically in the sim, the arena and the worker.
    pub fn setShredKey(_: OfflineTag, id: []const u8) bool {
        tagsReset();
        return binding.OfflineShred.set(id);
    }

    pub fn destroyCount(_: OfflineTag) usize {
        tagsReset();
        return binding.OfflineShred.destroyCount();
    }

    /// Counted and validated, never performed: these engines hold no key
    /// material. The surface must behave identically on every engine —
    /// including the cap, so a handler that trips it offline trips it in
    /// production too.
    pub fn destroyShredKey(_: OfflineTag, _: []const u8) bool {
        tagsReset();
        return binding.OfflineShred.destroy();
    }

    pub fn tagAppend(self: OfflineTag, key: []const u8, val: []const u8) bool {
        tagsReset();
        const k = std.heap.c_allocator.dupe(u8, key) catch return false;
        const v = std.heap.c_allocator.dupe(u8, val) catch {
            std.heap.c_allocator.free(k);
            return false;
        };
        tag_list.append(std.heap.c_allocator, .{ .key = k, .value = v }) catch {
            std.heap.c_allocator.free(k);
            std.heap.c_allocator.free(v);
            return false;
        };
        self.effectTag(key, val);
        return true;
    }
};

const B = binding.Kv(c, OfflineKv, .user);
const T = binding.Tag(c, OfflineTag);

/// `__rove_poison(what)` — the epilogue's divergence verdict, as a native so
/// the flag lives on the HOST (post-run reportable, interrupt-visible), not
/// in catchable JS. Calling it never throws: the whole point is that a
/// divergence is not an exception a handler can swallow — the read returns
/// absent, this records the verdict, and the uncatchable interrupt brakes
/// the run. A handler calling it directly only poisons its own run.
fn jsPoison(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const undef = c.JSValue{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
    if (argc < 1) {
        host.poisonActive("an input");
        return undef;
    }
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, argv[0]);
    if (cstr == null) {
        host.poisonActive("an input");
        return undef;
    }
    defer c.JS_FreeCString(ctx, cstr);
    host.poisonActive(@as([*]const u8, @ptrCast(cstr))[0..len]);
    return undef;
}

/// `__rove_park_output(json)` — the run-output side channel. The epilogue
/// used to park through `kv.set(OUTPUT_KEY, …)` on a raw native; through the
/// guarded binding that spelling would need a customer-reachable exemption
/// for a reserved-looking key. A dedicated native keeps the door off the kv
/// surface entirely: a customer `kv.set("__replay_output__", …)` now hits
/// the reserved-prefix refusal exactly as in prod, and a customer calling
/// THIS only overwrites a value the epilogue's own final park overwrites
/// again.
fn jsParkOutput(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const undef = c.JSValue{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
    if (argc < 1) return undef;
    var len: usize = 0;
    const cstr = c.JS_ToCStringLen(ctx, &len, argv[0]);
    if (cstr == null) return undef;
    defer c.JS_FreeCString(ctx, cstr);
    const bytes = @as([*]const u8, @ptrCast(cstr))[0..len];
    // Through the vtable's kv_set with the sentinel key: the run host
    // intercepts it as the parked output (host.zig kvSet), which keeps one
    // interception point rather than a second host channel.
    const vt = host.active_vtable orelse return undef;
    const responder = vt.kv_set orelse return undef;
    var outcome: c_int = 0;
    _ = responder(host.OUTPUT_KEY.ptr, @intCast(host.OUTPUT_KEY.len), bytes.ptr, @intCast(len), &outcome, host.active_user);
    return undef;
}

/// Replace arenajs's replay kv object with the common binding, and register
/// the offline-engine natives (`__rove_poison`, `__rove_park_output`).
/// Called from the reactor base-setup hook, after
/// `arena_install_replay_bindings` (which still owns the module loader and
/// the crypto surface).
pub fn installKv(ctx: ?*c.JSContext) c_int {
    const g = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, g);
    const obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, obj, "get", c.JS_NewCFunction2(ctx, B.jsKvGet, "get", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "set", c.JS_NewCFunction2(ctx, B.jsKvSet, "set", 2, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "delete", c.JS_NewCFunction2(ctx, B.jsKvDelete, "delete", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, obj, "prefix", c.JS_NewCFunction2(ctx, B.jsKvPrefix, "prefix", 3, c.JS_CFUNC_generic, 0));
    if (c.JS_SetPropertyStr(ctx, g, "kv", obj) < 0) return -1;
    _ = c.JS_SetPropertyStr(ctx, g, "__rove_poison", c.JS_NewCFunction2(ctx, jsPoison, "__rove_poison", 1, c.JS_CFUNC_generic, 0));
    // The common request.tag binding — the epilogue assigns it onto the
    // per-request `request` object (`request.tag = __rove_request_tag`).
    _ = c.JS_SetPropertyStr(ctx, g, "__rove_request_tag", c.JS_NewCFunction2(ctx, T.jsRequestTag, "__rove_request_tag", 2, c.JS_CFUNC_generic, 0));
    const SK = binding.ShredKey(c, OfflineTag);
    _ = c.JS_SetPropertyStr(ctx, g, "__rove_request_shred_key", c.JS_NewCFunction2(ctx, SK.jsRequestShredKey, "__rove_request_shred_key", 1, c.JS_CFUNC_generic, 0));
    _ = c.JS_SetPropertyStr(ctx, g, "__rove_park_output", c.JS_NewCFunction2(ctx, jsParkOutput, "__rove_park_output", 1, c.JS_CFUNC_generic, 0));
    return 0;
}
