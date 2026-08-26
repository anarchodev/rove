// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! SPIKE — membership axes over the fat model (fat-entity-todo.md §4).
//!
//! This file exists to answer the mechanics questions 4a–4d leave open,
//! on a deliberately minimal core, BEFORE the real steps land in
//! `fat.zig`. It is a validation harness, not a shipping surface: when
//! 4a–4d land, this file's conclusions graduate into the ledger and the
//! file dies. Questions under test:
//!
//! 1. **Per-axis membership records** (4b): one `(id, offset)` pair per
//!    axis per entity — does the single-axis case stay shape-identical,
//!    and does the multi-axis resolve stay a comptime-indexed lookup
//!    (no runtime axis search)?
//! 2. **axisOf(T)** at comptime: component → owning axis, driven by the
//!    partition declaration; getFat picks the membership record for
//!    that axis with the same instruction count as today's single
//!    lookup.
//! 3. **Partial-axis verbs** (4c): `enter` (Gained-path, no source),
//!    `leave` (Dropped-path, no destination — PARKS, nothing
//!    destroyed), and the freshness sharp edge: re-enter restores
//!    parked values (path-independence); the system deciding `leave`
//!    owns resetting first if policy wants a fresh start.
//! 4. **The throttle case** (4a's motivating example): a conn resident
//!    in a lifecycle collection AND a `throttled` collection at once,
//!    with the refill system iterating ONLY the throttled columns —
//!    dense — while lifecycle moves leave throttle membership alone.
//! 5. **Destroy exits every axis** (K id bytes), so no axis can hold a
//!    dead entity.
//!
//! Out of scope here (deliberately): deferred ops, sets, the recipes'
//! type-erasure, evict, and 4d's constraint syntax — 4d gets one
//! state-attached hook (`on_enter_leaves`) to prove the attachment
//! point composes, nothing more.
const std = @import("std");
const entity_mod = @import("entity.zig");
const row_mod = @import("row.zig");
const collection_mod = @import("collection.zig");
const Entity = entity_mod.Entity;
const Row = row_mod.Row;
const Collection = collection_mod.Collection;

const testing = std.testing;

// =============================================================================
// Axis declaration (4a shape, minimal)
// =============================================================================

/// An axis is a comptime value: a name for errors, the row of
/// components it OWNS (partition — a component in two axes' rows is a
/// compile error at world build), and whether it is the one total
/// axis. Identity in the real design is (owning part, decl); the spike
/// keys the partition check on component overlap only.
const AxisDecl = struct {
    name: [:0]const u8,
    row: type,
    total: bool = false,
};

/// A collection entry in the spike world: which axis it lives on, and
/// its row (⊆ the axis row, checked). `on_enter_leaves` is the 4d
/// state-attached probe: entering this collection leaves the named
/// axis (by index into the axes tuple), however the entry was reached.
const SpikeColl = struct {
    name: [:0]const u8,
    axis: usize, // index into axes
    row: type,
    on_enter_leaves: ?usize = null, // axis index to leave on entry
};

fn SpikeWorld(comptime axes: []const AxisDecl, comptime colls: []const SpikeColl) type {
    @setEvalBranchQuota(1_000_000);
    comptime {
        // Exactly one total axis.
        var totals: usize = 0;
        for (axes) |a| totals += @intFromBool(a.total);
        if (totals != 1) @compileError("spike: exactly one total axis");
        // Partition: no component in two axes' rows.
        for (axes, 0..) |a, i| for (axes[i + 1 ..]) |b| {
            for (a.row.types) |T| {
                if (b.row.contains(T)) @compileError("spike: component " ++ @typeName(T) ++
                    " owned by both axis '" ++ a.name ++ "' and axis '" ++ b.name ++ "'");
            }
        };
        // Collection rows covered by their axis.
        for (colls) |cd| {
            if (!cd.row.isSubsetOf(axes[cd.axis].row)) @compileError(
                "spike: collection '" ++ cd.name ++ "' row not covered by its axis '" ++ axes[cd.axis].name ++ "'",
            );
        }
    }

    // The universe: union of the axis rows (axis-blind shadow).
    const universe = comptime blk: {
        var u = Row(&.{});
        for (axes) |a| u = u.merge(a.row);
        break :blk u;
    };

    const n_axes = axes.len;

    return struct {
        const Self = @This();
        pub const Universe = universe;

        /// The owning axis of a component — comptime, no runtime search.
        pub fn axisOf(comptime T: type) usize {
            inline for (axes, 0..) |a, i| {
                if (comptime a.row.contains(T)) return i;
            }
            @compileError("spike: " ++ @typeName(T) ++ " is in no axis");
        }

        pub fn totalAxis() usize {
            inline for (axes, 0..) |a, i| if (a.total) return i;
            unreachable;
        }

        fn axisOfColl(comptime coll_idx: usize) usize {
            return colls[coll_idx].axis;
        }

        // ── Storage ──
        // Membership record PER AXIS: id (0 = free pool on the total
        // axis / "not on this axis" on a partial one) + offset. This is
        // 4b's "per-axis arrays, not per-collection sparse tables".
        generations: []u32,
        axis_ids: [n_axes][]u8,
        axis_offsets: [n_axes][]u32,
        // Minimal shadow: one universe struct per entity + written mask
        // (gen-checked like fat.zig; the spike reuses the concept, not
        // the code — this file dies, fat.zig's shadow is the real one).
        shadow: []Shadow,
        null_pool: []Entity,
        null_count: u32,
        storage: Storage,
        max_entities: u32,
        allocator: std.mem.Allocator,

        const Shadow = blk: {
            var fields: [universe.len + 1]std.builtin.Type.StructField = undefined;
            fields[0] = .{
                .name = "hdr",
                .type = struct { gen: u32 = 0, written: u64 = 0 },
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(struct { gen: u32, written: u64 }),
            };
            var n: usize = 1;
            for (universe.types, 0..) |T, ci| {
                if (@sizeOf(T) == 0) continue;
                fields[n] = .{
                    .name = std.fmt.comptimePrint("c{d}", .{ci}),
                    .type = T,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(T),
                };
                n += 1;
            }
            break :blk @Type(.{ .@"struct" = .{
                .layout = .auto,
                .backing_integer = null,
                .fields = fields[0..n],
                .decls = &.{},
                .is_tuple = false,
            } });
        };

        const Storage = blk: {
            var fields: [colls.len]std.builtin.Type.StructField = undefined;
            for (colls, 0..) |cd, i| {
                fields[i] = .{
                    .name = cd.name,
                    .type = Collection(cd.row, .{}),
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(Collection(cd.row, .{})),
                };
            }
            break :blk @Type(.{ .@"struct" = .{
                .layout = .auto,
                .backing_integer = null,
                .fields = fields[0..colls.len],
                .decls = &.{},
                .is_tuple = false,
            } });
        };

        fn collIndex(comptime name: []const u8) usize {
            inline for (colls, 0..) |cd, i| {
                if (comptime std.mem.eql(u8, cd.name, name)) return i;
            }
            @compileError("spike: no collection '" ++ name ++ "'");
        }

        pub fn coll(self: *Self, comptime name: @TypeOf(.enum_literal)) *Collection(colls[collIndex(@tagName(name))].row, .{}) {
            return &@field(self.storage, @tagName(name));
        }

        pub fn init(allocator: std.mem.Allocator, max: u32) !Self {
            const generations = try allocator.alloc(u32, max);
            @memset(generations, 0);
            var axis_ids: [n_axes][]u8 = undefined;
            var axis_offsets: [n_axes][]u32 = undefined;
            inline for (0..n_axes) |ax| {
                axis_ids[ax] = try allocator.alloc(u8, max);
                @memset(axis_ids[ax], 0);
                axis_offsets[ax] = try allocator.alloc(u32, max);
            }
            const shadow = try allocator.alloc(Shadow, max);
            for (shadow) |*sh| sh.hdr = .{};
            const null_pool = try allocator.alloc(Entity, max);
            for (0..max) |i| null_pool[i] = .{ .index = @intCast(i), .generation = 0 };
            var self = Self{
                .generations = generations,
                .axis_ids = axis_ids,
                .axis_offsets = axis_offsets,
                .shadow = shadow,
                .null_pool = null_pool,
                .null_count = max,
                // Filled by the loop just below — the fat.zig
                // `.destroy_recipes = undefined` shape.
                .storage = undefined,
                .max_entities = max,
                .allocator = allocator,
            };
            inline for (colls) |cd| {
                @field(self.storage, cd.name) = try Collection(cd.row, .{}).init(allocator);
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            inline for (colls) |cd| @field(self.storage, cd.name).deinit();
            self.allocator.free(self.null_pool);
            self.allocator.free(self.shadow);
            inline for (0..n_axes) |ax| {
                self.allocator.free(self.axis_ids[ax]);
                self.allocator.free(self.axis_offsets[ax]);
            }
            self.allocator.free(self.generations);
            self.* = undefined;
        }

        // ── Shadow park/unpark (minimal mirror of fat.zig's) ──

        fn shadowBit(comptime T: type) u64 {
            return @as(u64, 1) << universe.indexOf(T);
        }

        fn shadowPtr(sh: *Shadow, comptime T: type) *T {
            return &@field(sh, std.fmt.comptimePrint("c{d}", .{universe.indexOf(T)}));
        }

        fn parkOne(self: *Self, comptime T: type, entity: Entity, value: T) void {
            const sh = &self.shadow[entity.index];
            if (sh.hdr.gen != entity.generation) {
                sh.hdr = .{ .gen = entity.generation, .written = 0 };
            }
            shadowPtr(sh, T).* = value;
            sh.hdr.written |= comptime shadowBit(T);
        }

        fn unparkOne(self: *Self, comptime T: type, entity: Entity, dst: *T) void {
            const sh = &self.shadow[entity.index];
            if (sh.hdr.gen == entity.generation and (sh.hdr.written & comptime shadowBit(T)) != 0) {
                dst.* = shadowPtr(sh, T).*;
            } else {
                row_mod.fillDefault(T, @as([*]T, @ptrCast(dst))[0..1]);
            }
        }

        // ── Verbs ──

        /// Birth: total axis only (4c — "position always exists, birth
        /// requires it"). Every other axis starts at 0 = not present.
        pub fn create(self: *Self, comptime name: @TypeOf(.enum_literal)) !Entity {
            const ci = comptime collIndex(@tagName(name));
            comptime {
                if (colls[ci].axis != totalAxis()) @compileError(
                    "spike: create births onto the total axis; '" ++ @tagName(name) ++ "' is a partial-axis collection — use enter",
                );
            }
            if (self.null_count == 0) return error.Full;
            self.null_count -= 1;
            const entity = self.null_pool[self.null_count];
            const c = self.coll(name);
            const off = try c.reserveSlots(1);
            c.entitySlice()[off] = entity;
            inline for (colls[ci].row.types) |T| {
                if (comptime @sizeOf(T) > 0) row_mod.fillDefault(T, c.column(T)[off .. off + 1]);
            }
            self.axis_ids[comptime axisOfColl(ci)][entity.index] = ci + 1;
            self.axis_offsets[comptime axisOfColl(ci)][entity.index] = off;
            return entity;
        }

        /// Move WITHIN an axis — src.axis == dst.axis is a comptime
        /// check (4b). Park dropped, unpark gained, exactly the fat
        /// model's total move.
        pub fn move(self: *Self, entity: Entity, comptime src: @TypeOf(.enum_literal), comptime dst: @TypeOf(.enum_literal)) !void {
            const si = comptime collIndex(@tagName(src));
            const di = comptime collIndex(@tagName(dst));
            const ax = comptime axisOfColl(si);
            comptime {
                if (axisOfColl(di) != ax) @compileError(
                    "spike: move crosses axes ('" ++ @tagName(src) ++ "' → '" ++ @tagName(dst) ++ "') — a membership changes only within its axis",
                );
            }
            const idx = entity.index;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.axis_ids[ax][idx] != si + 1) return error.WrongCollection;

            const sc = self.coll(src);
            const dc = self.coll(dst);
            const s_off = self.axis_offsets[ax][idx];
            const d_off = try dc.reserveSlots(1);
            dc.entitySlice()[d_off] = entity;

            const SrcRow = colls[si].row;
            const DstRow = colls[di].row;
            inline for (comptime SrcRow.intersect(DstRow).types) |T| {
                if (comptime @sizeOf(T) > 0) dc.column(T)[d_off] = sc.column(T)[s_off];
            }
            inline for (comptime SrcRow.subtract(&DstRow.types).types) |T| {
                if (comptime @sizeOf(T) > 0) self.parkOne(T, entity, sc.column(T)[s_off]);
            }
            inline for (comptime DstRow.subtract(&SrcRow.types).types) |T| {
                if (comptime @sizeOf(T) > 0) self.unparkOne(T, entity, &dc.column(T)[d_off]);
            }

            const moved = sc.removeRun(s_off, 1);
            for (moved) |m| self.axis_offsets[ax][m.index] = s_off;
            self.axis_ids[ax][idx] = di + 1;
            self.axis_offsets[ax][idx] = d_off;

            self.runEnterClauses(di, entity);
        }

        /// Enter a partial-axis collection: the Gained path with no
        /// source (4c). Errors if already on the axis.
        pub fn enter(self: *Self, entity: Entity, comptime dst: @TypeOf(.enum_literal)) !void {
            const di = comptime collIndex(@tagName(dst));
            const ax = comptime axisOfColl(di);
            comptime {
                if (ax == totalAxis()) @compileError("spike: enter is a partial-axis verb; total-axis membership starts at create");
            }
            const idx = entity.index;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.axis_ids[ax][idx] != 0) return error.AlreadyOnAxis;

            const dc = self.coll(dst);
            const d_off = try dc.reserveSlots(1);
            dc.entitySlice()[d_off] = entity;
            inline for (colls[di].row.types) |T| {
                if (comptime @sizeOf(T) > 0) self.unparkOne(T, entity, &dc.column(T)[d_off]);
            }
            self.axis_ids[ax][idx] = di + 1;
            self.axis_offsets[ax][idx] = d_off;

            self.runEnterClauses(di, entity);
        }

        /// Leave a partial axis: the Dropped path with no destination —
        /// every materialized component PARKS (4c). Nothing destroyed;
        /// re-enter restores the parked values (path-independence). A
        /// policy that wants a fresh start resets before leaving — the
        /// same contract as `fd = -1` at close.
        pub fn leave(self: *Self, entity: Entity, comptime ax: usize) !void {
            comptime {
                if (ax == totalAxis()) @compileError("spike: the total axis has no leave — destroy is the only exit");
            }
            const idx = entity.index;
            if (self.generations[idx] != entity.generation) return error.Stale;
            const id = self.axis_ids[ax][idx];
            if (id == 0) return error.NotOnAxis;

            inline for (colls, 0..) |cd, i| {
                if (comptime cd.axis != ax) continue;
                if (id == i + 1) {
                    const sc = &@field(self.storage, cd.name);
                    const s_off = self.axis_offsets[ax][idx];
                    inline for (cd.row.types) |T| {
                        if (comptime @sizeOf(T) > 0) self.parkOne(T, entity, sc.column(T)[s_off]);
                    }
                    const moved = sc.removeRun(s_off, 1);
                    for (moved) |m| self.axis_offsets[ax][m.index] = s_off;
                }
            }
            self.axis_ids[ax][idx] = 0;
        }

        /// Destroy: exit EVERY axis — K id bytes walked, so no axis can
        /// hold a dead entity (the destroy-leaves-every-set guarantee,
        /// generalized).
        pub fn destroy(self: *Self, entity: Entity) !void {
            const idx = entity.index;
            if (self.generations[idx] != entity.generation) return error.Stale;
            inline for (0..n_axes) |ax| {
                const id = self.axis_ids[ax][idx];
                if (id != 0) {
                    inline for (colls, 0..) |cd, i| {
                        if (comptime cd.axis != ax) continue;
                        if (id == i + 1) {
                            const sc = &@field(self.storage, cd.name);
                            const s_off = self.axis_offsets[ax][idx];
                            const moved = sc.removeRun(s_off, 1);
                            for (moved) |m| self.axis_offsets[ax][m.index] = s_off;
                        }
                    }
                    self.axis_ids[ax][idx] = 0;
                }
            }
            self.generations[idx] +%= 1;
            self.null_pool[self.null_count] = .{ .index = idx, .generation = self.generations[idx] };
            self.null_count += 1;
        }

        /// The universal read across axes: resolve T's owning axis at
        /// comptime, then one membership lookup — same instruction
        /// count as the single-axis getFat (question 2).
        pub fn getFat(self: *Self, entity: Entity, comptime T: type) !*T {
            const ax = comptime axisOf(T);
            const idx = entity.index;
            if (self.generations[idx] != entity.generation) return error.Stale;
            const id = self.axis_ids[ax][idx];
            if (id != 0) {
                // Column when the axis's current collection materializes T.
                inline for (colls, 0..) |cd, i| {
                    if (comptime cd.axis != ax or !cd.row.contains(T)) continue;
                    if (id == i + 1) {
                        return &@field(self.storage, cd.name).column(T)[self.axis_offsets[ax][idx]];
                    }
                }
            }
            // Parked (or virgin → defaults).
            const sh = &self.shadow[idx];
            const slot = shadowPtr(sh, T);
            if (sh.hdr.gen != entity.generation or (sh.hdr.written & comptime shadowBit(T)) == 0) {
                if (sh.hdr.gen != entity.generation) sh.hdr = .{ .gen = entity.generation, .written = 0 };
                row_mod.fillDefault(T, @as([*]T, @ptrCast(slot))[0..1]);
                sh.hdr.written |= comptime shadowBit(T);
            }
            return slot;
        }

        pub fn onAxis(self: *const Self, entity: Entity, comptime ax: usize) bool {
            if (self.generations[entity.index] != entity.generation) return false;
            return self.axis_ids[ax][entity.index] != 0;
        }

        // 4d probe: state-attached clause, enforced on EVERY entry
        // however reached (create lands on the total axis only; move and
        // enter both funnel through here).
        fn runEnterClauses(self: *Self, comptime ci: usize, entity: Entity) void {
            if (comptime colls[ci].on_enter_leaves) |ax| {
                if (self.axis_ids[ax][entity.index] != 0) {
                    self.leave(entity, ax) catch unreachable;
                }
            }
        }
    };
}

// =============================================================================
// The throttle test-world (4a's motivating example, exercised)
// =============================================================================

const Fd = struct { fd: i32 = -1 };
const ClosingState = struct { deadline: u64 = 0 };
const Tokens = struct { left: u32 = 8, refills: u32 = 0 };

const lifecycle_row = Row(&.{ Fd, ClosingState });
const throttle_row = Row(&.{Tokens});

const AXES = [_]AxisDecl{
    .{ .name = "lifecycle", .row = lifecycle_row, .total = true },
    .{ .name = "throttle", .row = throttle_row },
};
const LIFECYCLE = 0;
const THROTTLE = 1;

const COLLS = [_]SpikeColl{
    .{ .name = "conn_active", .axis = LIFECYCLE, .row = Row(&.{Fd}) },
    // Entering closing leaves the throttle axis — the 4d state-attached
    // clause ("no send work once lifecycle ∈ conn_closing"), enforced
    // however the entity gets here.
    .{ .name = "conn_closing", .axis = LIFECYCLE, .row = Row(&.{ Fd, ClosingState }), .on_enter_leaves = THROTTLE },
    .{ .name = "throttled", .axis = THROTTLE, .row = Row(&.{Tokens}) },
};

const TW = SpikeWorld(&AXES, &COLLS);

test "spike: co-residency — one entity dense on two axes at once" {
    var w = try TW.init(testing.allocator, 16);
    defer w.deinit();

    const conn = try w.create(.conn_active);
    (try w.getFat(conn, Fd)).fd = 7;

    // Second membership on an orthogonal axis: no contest, no copy —
    // Tokens lives ONLY in the throttled collection's column.
    try w.enter(conn, .throttled);
    try testing.expect(w.onAxis(conn, THROTTLE));
    try testing.expect(w.onAxis(conn, LIFECYCLE));

    // Dense iteration over the orthogonal concern — the thing a set
    // (no columns) and a flag (scan everything) cannot give.
    const throttled = w.coll(.throttled);
    for (throttled.column(Tokens)) |*t| t.left -|= 1;
    try testing.expectEqual(@as(u32, 7), (try w.getFat(conn, Tokens)).left);

    // Lifecycle iteration untouched by the second membership.
    try testing.expectEqual(@as(u32, 1), w.coll(.conn_active).count);
}

test "spike: leave parks, re-enter restores — path-independence has a sharp edge" {
    var w = try TW.init(testing.allocator, 16);
    defer w.deinit();

    const conn = try w.create(.conn_active);
    try w.enter(conn, .throttled);
    (try w.getFat(conn, Tokens)).* = .{ .left = 3, .refills = 5 };

    try w.leave(conn, THROTTLE);
    try testing.expect(!w.onAxis(conn, THROTTLE));
    // Parked, not destroyed: the value is still the entity's.
    try testing.expectEqual(@as(u32, 3), (try w.getFat(conn, Tokens)).left);

    // Re-enter restores the parked value — path-independence. A system
    // wanting a fresh start must reset BEFORE leaving; the model will
    // not decide that for it.
    try w.enter(conn, .throttled);
    try testing.expectEqual(@as(u32, 5), (try w.getFat(conn, Tokens)).refills);
}

test "spike: state-attached clause fires on every entry path" {
    var w = try TW.init(testing.allocator, 16);
    defer w.deinit();

    const conn = try w.create(.conn_active);
    try w.enter(conn, .throttled);
    try testing.expect(w.onAxis(conn, THROTTLE));

    // The lifecycle move into conn_closing drops throttle membership —
    // declared on the DESTINATION state, not repeated at call sites.
    try w.move(conn, .conn_active, .conn_closing);
    try testing.expect(!w.onAxis(conn, THROTTLE));
    // ... and the throttle state survived as a parked value (leave
    // parks; a clause that wanted erasure would be a different verb).
    try testing.expectEqual(@as(u32, 8), (try w.getFat(conn, Tokens)).left);
    try testing.expectEqual(@as(u32, 1), w.coll(.conn_closing).count);
    try testing.expectEqual(@as(u32, 0), w.coll(.throttled).count);
}

test "spike: destroy exits every axis; rebirth resurrects nothing" {
    var w = try TW.init(testing.allocator, 16);
    defer w.deinit();

    const conn = try w.create(.conn_active);
    try w.enter(conn, .throttled);
    (try w.getFat(conn, Tokens)).left = 1;
    const old_index = conn.index;

    try w.destroy(conn);
    try testing.expectEqual(@as(u32, 0), w.coll(.conn_active).count);
    try testing.expectEqual(@as(u32, 0), w.coll(.throttled).count);
    try testing.expectError(error.Stale, w.getFat(conn, Tokens));

    // Reuse the slot: the new generation reads defaults, never the
    // predecessor's parked or column values.
    var reborn: Entity = undefined;
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        reborn = try w.create(.conn_active);
        if (reborn.index == old_index) break;
        try w.destroy(reborn);
    }
    try testing.expectEqual(old_index, reborn.index);
    try testing.expectEqual(@as(u32, 8), (try w.getFat(reborn, Tokens)).left);
}

test "spike: swap-remove keeps per-axis offsets exact under churn" {
    var w = try TW.init(testing.allocator, 32);
    defer w.deinit();

    // Three conns, all throttled; remove the middle one's throttle
    // membership and check the swapped tail still resolves — offsets
    // are per-axis, so the lifecycle offsets must be untouched.
    const a = try w.create(.conn_active);
    const b = try w.create(.conn_active);
    const c = try w.create(.conn_active);
    for ([_]Entity{ a, b, c }) |e| try w.enter(e, .throttled);
    (try w.getFat(a, Tokens)).left = 11;
    (try w.getFat(b, Tokens)).left = 22;
    (try w.getFat(c, Tokens)).left = 33;
    (try w.getFat(a, Fd)).fd = 1;
    (try w.getFat(c, Fd)).fd = 3;

    try w.leave(b, THROTTLE);

    try testing.expectEqual(@as(u32, 11), (try w.getFat(a, Tokens)).left);
    try testing.expectEqual(@as(u32, 22), (try w.getFat(b, Tokens)).left); // parked
    try testing.expectEqual(@as(u32, 33), (try w.getFat(c, Tokens)).left); // swapped, still resolves
    try testing.expectEqual(@as(i32, 1), (try w.getFat(a, Fd)).fd);
    try testing.expectEqual(@as(i32, 3), (try w.getFat(c, Fd)).fd);
    try testing.expectEqual(@as(u32, 2), w.coll(.throttled).count);
}
