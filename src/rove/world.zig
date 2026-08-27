// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! World — the declared component/collection tables for the fat model.
//!
//! A binary's world is declared ONCE, as data: each layer exports a
//! `Part` (the components it contributes and the collections it drives),
//! and the program's root module composes them:
//!
//!     pub const rove_world = rove.World(.{ .parts = rio.parts(io_opts) });
//!
//! `World` is the single comptime point where the closed component
//! universe demanded by `FatRegistry` is computed — the declaration
//! doubles as a manifest of all entity state in the program. From the
//! flattened table it derives:
//!
//! - **Ids by table position.** Collection ids are the entry's position
//!   in the flattened table, plus one (id 0 is the registry's free
//!   pool). No layer numbers anything, no prefix-ordering contract
//!   between layers, and `CollId` — variants named by entry, valued by
//!   registry id — is the one namespace an entity's `collection_ids`
//!   byte resolves through.
//! - **Registry-owned storage.** `Reg.init` constructs every declared
//!   collection and registers it; layers fetch typed pointers with
//!   `reg.coll(.name)` instead of owning collection values. Storage
//!   sits behind one stable heap pointer, so the `Reg` value itself
//!   stays movable the way `FatRegistry` always was.
//! - **Sets as row-less entries.** A `.kind = .set` entry declares pure
//!   membership in the same table and namespace as collections, but its
//!   storage is registry-internal: consumers speak `join` / `leave` /
//!   `inSet` / `setMembers` by tag and never see an `EntitySet` value.
//!   Keeping the consumer surface tag-shaped here is what lets the
//!   planned axes work merge set and collection storage later with zero
//!   blast radius.
//!
//! The world type is declared at the root; registry VALUES are
//! constructed in `main` or per worker thread (`Reg.init`) — one world
//! type per program, N registries of it. A registry value at root scope
//! is forbidden: globals initialize before `main` in an order no code
//! controls, and every thread would silently share one storage.
//!
//! Layers discover the root's world through `rove.declared_world`
//! (the `std_options` idiom — see root.zig); explicit `World(...)`
//! construction stays load-bearing underneath for tests' mini-worlds.
const std = @import("std");
const entity_mod = @import("entity.zig");
const row_mod = @import("row.zig");
const collection_mod = @import("collection.zig");
const fat_mod = @import("fat.zig");
const Entity = entity_mod.Entity;
const Row = row_mod.Row;
const Collection = collection_mod.Collection;
const CollectionOptions = collection_mod.CollectionOptions;
const FatRegistry = fat_mod.FatRegistry;
const FatRegistryConfig = fat_mod.FatRegistryConfig;
const RowView = fat_mod.RowView;

pub const CollKind = enum { collection, set };

/// The registry's own membership axis — liveness. Exactly one axis is
/// total, and it is this one, because liveness is the registry's
/// concept: position on it always exists (0 = the free pool), birth
/// requires it, there is no leave, and it is the default when a
/// collection declares no `.axis`.
///
/// An axis is a TYPE, and its identity is its declaration site: a part
/// that owns an orthogonal concern declares the axis as a plain struct
/// (`pub const throttle_axis = struct { pub const axis_name = ... };`)
/// and layers above reference the decl (`.axis = rio.throttle_axis`) —
/// unforgeable, typo-proof, private by default, shared only by
/// explicit import. Two layers independently inventing an axis called
/// "pending" get two distinct types, never one accidentally fused
/// exclusivity domain; the world merges axes by type identity.
pub const lifecycle = struct {
    pub const axis_name: [:0]const u8 = "lifecycle";
};

/// One entry in a part's collection table. The row is the machinery
/// describing the collection — which components it materializes as SoA
/// columns. A set entry keeps the default empty row (pure membership).
///
/// `.axis` tags which membership axis the collection lives on; the
/// partition over components is EMERGENT: a component inherits the
/// axis of the collections that materialize it, and materialization on
/// two different axes is a compile error at world build (overlap
/// freely WITHIN an axis — state alternation — never across: that is
/// contested storage). A component in no collection's row is axis-free
/// (the shadow is axis-blind).
pub const CollDecl = struct {
    name: [:0]const u8,
    row: type = Row(&.{}),
    kind: CollKind = .collection,
    options: CollectionOptions = .{},
    axis: type = lifecycle,
    /// Set entries only: an IDENTITY membership says what the entity
    /// IS ("every conn this instance created"), not what state it is
    /// in — it ends only at explicit leave or destroy, and the quiesce
    /// verbs (`moveOnly`/`evictOnly`) leave it alone. A multi-state
    /// membership is state by nature and cannot be identity.
    identity: bool = false,
};

/// One layer's contribution to the world: pure data, declared outside
/// the layer's type function (a part evaluated inside `Io(...)` /
/// `H2(...)` would recurse through `@import("root")` when the root
/// builds the world from it).
pub const Part = struct {
    name: [:0]const u8,
    /// Components in no collection's row — "in the world, materialized
    /// nowhere": they exist per-entity in the shadow store only.
    components: []const type = &.{},
    collections: []const CollDecl = &.{},
};

pub const WorldConfig = struct {
    parts: []const Part,
};

pub fn World(comptime cfg: WorldConfig) type {
    @setEvalBranchQuota(1_000_000);

    // Flatten the parts' tables into the one table that defines ids.
    const table: []const CollDecl = comptime blk: {
        var t: []const CollDecl = &.{};
        for (cfg.parts) |p| t = t ++ p.collections;
        break :blk t;
    };

    comptime {
        // A registry id is one byte and 0 is the free pool.
        if (table.len > 255) @compileError(std.fmt.comptimePrint(
            "world: {d} collection entries declared, 255 ids available (id 0 is the free pool)",
            .{table.len},
        ));
        // Set entries are row-less by definition; a row on one is a
        // confusion between membership and storage.
        for (cfg.parts) |p| for (p.collections) |d| {
            if (d.kind == .set and d.row.len != 0) @compileError(
                "world: set entry '" ++ d.name ++ "' (part '" ++ p.name ++
                    "') declares a row — a set is a row-less entry; give the components a .collection entry instead",
            );
        };
    }

    // Which part declared each flattened entry — for the duplicate error.
    const owners: []const [:0]const u8 = comptime blk: {
        var o: []const [:0]const u8 = &.{};
        for (cfg.parts) |p| {
            for (p.collections) |_| o = o ++ [_][:0]const u8{p.name};
        }
        break :blk o;
    };

    comptime {
        // Names are the namespace; a duplicate would silently shadow in
        // the id enum. Name both owning parts in the error.
        for (table, 0..) |da, i| {
            for (table[i + 1 ..], i + 1..) |db, j| {
                if (std.mem.eql(u8, da.name, db.name)) @compileError(
                    "world: collection name '" ++ da.name ++ "' declared by both part '" ++
                        owners[i] ++ "' and part '" ++ owners[j] ++ "'",
                );
            }
        }
    }

    // The closed universe: every part's shadow-only components plus
    // every entry's row, canonically merged.
    const universe = comptime blk: {
        var u = Row(&.{});
        for (cfg.parts) |p| u = u.merge(Row(p.components));
        for (table) |d| u = u.merge(d.row);
        break :blk u;
    };

    comptime {
        // Axis declarations are well-formed, and sets take none — a set
        // is its own one-state axis (their storage merge is the axes
        // work's 4c step; the tag surface here does not change then).
        for (table) |d| {
            if (!@hasDecl(d.axis, "axis_name")) @compileError(
                "world: collection '" ++ d.name ++ "' declares an axis with no `axis_name` — an axis is a struct type with `pub const axis_name` (see rove.lifecycle)",
            );
            if (d.kind == .set and d.axis != lifecycle) @compileError(
                "world: set entry '" ++ d.name ++ "' declares an axis — a set IS its own one-state axis and takes no `.axis`",
            );
            if (d.identity and d.kind != .set) @compileError(
                "world: '" ++ d.name ++ "' declares .identity — identity is a property of set entries; a multi-state membership is state, and state drops on moveOnly",
            );
        }
        // The emergent partition: a component inherits the axis of the
        // collections that materialize it; materialization on two axes
        // is contested storage — two live homes at once — and the error
        // names the component and both sites. (Conflict graphs that are
        // not axis-representable are rejected here by construction:
        // remodel by flattening cliques or splitting meanings.)
        for (universe.types) |T| {
            var first: ?CollDecl = null;
            for (table) |d| {
                if (d.kind == .set) continue;
                if (!d.row.contains(T)) continue;
                if (first) |f| {
                    if (f.axis != d.axis) @compileError(
                        "world: component " ++ @typeName(T) ++ " is materialized by '" ++ f.name ++
                            "' (axis '" ++ f.axis.axis_name ++ "') and by '" ++ d.name ++ "' (axis '" ++
                            d.axis.axis_name ++ "') — overlap freely within an axis, never across",
                    );
                } else first = d;
            }
        }
    }

    // Every distinct axis in the world, lifecycle (the total axis)
    // first, then declaration order. Merged by type identity.
    const axis_list: []const type = comptime blk: {
        var out: []const type = &.{lifecycle};
        for (table) |d| {
            if (d.kind == .set) continue;
            var seen = false;
            for (out) |A| seen = seen or (A == d.axis);
            if (!seen) out = out ++ [_]type{d.axis};
        }
        break :blk out;
    };

    // The emergent partition, flattened for the registry: one axis
    // index per universe component (axis-free components map to the
    // total axis — their reads never consult membership).
    const comp_axis: [universe.len]u8 = comptime blk: {
        var out: [universe.len]u8 = @splat(0);
        for (universe.types, 0..) |T, i| {
            for (table) |d| {
                if (d.kind == .set) continue;
                if (!d.row.contains(T)) continue;
                for (axis_list, 0..) |A, k| {
                    if (A == d.axis) out[i] = k;
                }
                break;
            }
        }
        break :blk out;
    };

    const n_sets = comptime blk: {
        var n: usize = 0;
        for (table) |d| n += @intFromBool(d.kind == .set);
        break :blk n;
    };
    // The id namespace: variant per entry in table order, valued by
    // registry id directly (position + 1) so no call site does the +1.
    const IdEnum = comptime blk: {
        var fields: [table.len]std.builtin.Type.EnumField = undefined;
        for (table, 0..) |d, i| fields[i] = .{ .name = d.name, .value = i + 1 };
        break :blk @Type(.{ .@"enum" = .{
            .tag_type = u8,
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = true,
        } });
    };

    return struct {
        pub const parts = cfg.parts;
        pub const decls = table;
        pub const Universe = universe;
        pub const CollId = IdEnum;

        pub fn declOf(comptime id: CollId) CollDecl {
            return table[@intFromEnum(id) - 1];
        }

        pub fn RowOf(comptime id: CollId) type {
            return declOf(id).row;
        }

        /// Every distinct axis in the world — lifecycle (the total
        /// axis) first, then declaration order.
        pub const axes = axis_list;

        /// The axis a declared entry's collection lives on.
        pub fn axisOfColl(comptime id: CollId) type {
            return declOf(id).axis;
        }

        /// An axis's index in `axes` — the registry's axis numbering
        /// (0 = lifecycle, the total axis).
        pub fn axisIndex(comptime A: type) u8 {
            inline for (axis_list, 0..) |B, i| {
                if (comptime A == B) return i;
            }
            @compileError("world: axis '" ++ A.axis_name ++ "' is not in this world");
        }

        /// The owning axis of a materialized component (emergent from
        /// the collections that materialize it — the partition check
        /// above makes it unique), or null when the component is
        /// axis-free: in no collection's row, shadow-only.
        pub fn axisOf(comptime T: type) ?type {
            inline for (table) |d| {
                if (comptime d.kind == .set) continue;
                if (comptime d.row.contains(T)) return d.axis;
            }
            return null;
        }

        /// The Collection type of a declared entry. Set entries have no
        /// collection type — their storage is registry-internal.
        pub fn CollOf(comptime id: CollId) type {
            const d = declOf(id);
            if (d.kind == .set) @compileError(
                "world: '" ++ d.name ++ "' is a set entry — sets are registry-internal; use join/leave/inSet/setMembers",
            );
            return Collection(d.row, d.options);
        }

        /// A set entry's position among the set-kind entries, in table
        /// order — its one-state axis is `axis_list.len + setBit(id)`.
        fn setBit(comptime id: CollId) usize {
            const d = comptime declOf(id);
            comptime {
                if (d.kind != .set) @compileError("world: '" ++ d.name ++ "' is a collection entry, not a set");
            }
            comptime var bit: usize = 0;
            inline for (table[0 .. @intFromEnum(id) - 1]) |e| {
                if (e.kind == .set) bit += 1;
            }
            return bit;
        }

        fn setAxis(comptime id: CollId) u8 {
            return comptime @intCast(axis_list.len + setBit(id));
        }

        // One field per entry, named by the entry. A set entry's
        // storage is its empty-row collection (the component loops in
        // every shared recipe vanish at comptime for an empty row).
        const CollStorage = blk: {
            var fields: [table.len]std.builtin.Type.StructField = undefined;
            for (table, 0..) |d, n| {
                fields[n] = .{
                    .name = d.name,
                    .type = Collection(d.row, d.options),
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(Collection(d.row, d.options)),
                };
            }
            break :blk @Type(.{ .@"struct" = .{
                .layout = .auto,
                .backing_integer = null,
                .fields = fields[0..table.len],
                .decls = &.{},
                .is_tuple = false,
            } });
        };

        const Storage = struct {
            colls: CollStorage,
        };

        /// The world's registry: `FatRegistry(Universe)` plus ownership
        /// of every declared collection and set. Verbs forward to the
        /// core so call sites read identically to a bare `FatRegistry`.
        /// Construction is `init`/`deinit` by value, like the core: the
        /// owned storage sits behind one heap pointer, so the interior
        /// registration pointers survive the value being returned.
        pub const Reg = struct {
            core: Core,
            storage: *Storage,

            // One axis per declared axis, plus one ONE-STATE axis per
            // set entry: a set is the empty-row collection on an axis
            // of its own — its dense member list is the collection's
            // entity slice, its old sparse table is the axis's offsets.
            pub const Core = fat_mod.FatRegistryAxes(universe, .{
                .n_axes = axis_list.len + n_sets,
                .comp_axis = &comp_axis,
                .identity = &identity_axes,
            });

            const identity_axes: [axis_list.len + n_sets]bool = blk: {
                var out: [axis_list.len + n_sets]bool = @splat(false);
                for (table) |d| {
                    if (d.kind == .set and d.identity)
                        out[axis_list.len + setBit(@field(CollId, d.name))] = true;
                }
                break :blk out;
            };
            pub const Fat = Core.Fat;

            pub fn init(allocator: std.mem.Allocator, config: FatRegistryConfig) !Reg {
                var core = try Core.init(allocator, config);
                errdefer core.deinit();
                const storage = try allocator.create(Storage);
                errdefer allocator.destroy(storage);

                var inited: usize = 0;
                errdefer inline for (table, 0..) |d, i| {
                    if (i < inited) @field(storage.colls, d.name).deinit();
                };

                inline for (table, 0..) |d, i| {
                    @field(storage.colls, d.name) = try Collection(d.row, d.options).init(allocator);
                    const ax = comptime switch (d.kind) {
                        .collection => axisIndex(d.axis),
                        // A set's one-state axis, after the declared ones.
                        .set => axis_list.len + setBit(@field(CollId, d.name)),
                    };
                    core.registerCollectionOnAxis(&@field(storage.colls, d.name), i + 1, ax);
                    inited = i + 1;
                }

                return .{ .core = core, .storage = storage };
            }

            pub fn deinit(self: *Reg) void {
                const allocator = self.core.allocator;
                inline for (table) |d| {
                    @field(self.storage.colls, d.name).deinit();
                }
                allocator.destroy(self.storage);
                self.core.deinit();
                self.* = undefined;
            }

            /// Typed pointer to a declared collection's registry-owned
            /// storage. Comptime tag in, stable pointer out — fetch once
            /// at layer setup or per use, both are field loads.
            pub fn coll(self: *const Reg, comptime id: CollId) *CollOf(id) {
                return &@field(self.storage.colls, declOf(id).name);
            }

            fn setColl(self: *const Reg, comptime id: CollId) *Collection(Row(&.{}), .{}) {
                comptime {
                    if (declOf(id).kind != .set) @compileError("world: '" ++ declOf(id).name ++ "' is not a set entry");
                }
                return &@field(self.storage.colls, declOf(id).name);
            }

            // ── Membership sets, by tag — an empty-row collection on
            //    its own one-state axis; the tag surface is unchanged
            //    from the EntitySet era, which is the point ──

            /// Join a set. Idempotent: returns false if already a
            /// member. Membership survives every move on other axes and
            /// ends only at leave or destroy.
            pub fn join(self: *Reg, entity: Entity, comptime id: CollId) !bool {
                if (self.core.onAxis(entity, comptime setAxis(id))) return false;
                try self.core.enter(entity, self.setColl(id));
                return true;
            }

            /// Leave a set. Returns false if not a member.
            pub fn leave(self: *Reg, entity: Entity, comptime id: CollId) !bool {
                return self.core.leave(entity, comptime setAxis(id));
            }

            pub fn inSet(self: *const Reg, entity: Entity, comptime id: CollId) bool {
                return self.core.onAxis(entity, comptime setAxis(id));
            }

            /// The set's dense member list. Valid until the next
            /// join/leave/destroy.
            pub fn setMembers(self: *const Reg, comptime id: CollId) []const Entity {
                return self.setColl(id).entitySlice();
            }

            pub fn setCount(self: *const Reg, comptime id: CollId) u32 {
                return self.setColl(id).count;
            }

            // ── Partial-axis verbs (collections on a declared axis) ──

            /// Enter a partial-axis collection (the Gained path with no
            /// source): pass `reg.coll(.name)`. Total-axis membership
            /// starts at `create`.
            pub inline fn enter(self: *Reg, entity: Entity, dst: anytype) !void {
                return self.core.enter(entity, dst);
            }

            /// Leave a declared partial axis — whichever collection
            /// holds the entity there; its row parks. False if not on
            /// the axis.
            pub fn leaveAxis(self: *Reg, entity: Entity, comptime A: type) !bool {
                return self.core.leave(entity, comptime axisIndex(A));
            }

            pub fn onAxis(self: *const Reg, entity: Entity, comptime A: type) bool {
                return self.core.onAxis(entity, comptime axisIndex(A));
            }

            // ── Core forwards — one line each, so `reg.<verb>` reads
            //    identically to a bare FatRegistry ──

            pub inline fn create(self: *Reg, dst: anytype) !Entity {
                return self.core.create(dst);
            }
            pub inline fn move(self: *Reg, entity: Entity, src: anytype, dst: anytype) !void {
                return self.core.move(entity, src, dst);
            }
            pub inline fn moveImmediate(self: *Reg, entity: Entity, src: anytype, dst: anytype) !void {
                return self.core.moveImmediate(entity, src, dst);
            }
            pub inline fn moveStripImmediate(self: *Reg, entity: Entity, src: anytype, dst: anytype, comptime strip: []const type) !void {
                return self.core.moveStripImmediate(entity, src, dst, strip);
            }
            pub inline fn destroy(self: *Reg, entity: Entity) !void {
                return self.core.destroy(entity);
            }
            pub inline fn destroyImmediate(self: *Reg, entity: Entity) !void {
                return self.core.destroyImmediate(entity);
            }
            pub inline fn evictImmediate(self: *Reg, entity: Entity, dst: anytype) !void {
                return self.core.evictImmediate(entity, dst);
            }
            pub inline fn flush(self: *Reg) !void {
                return self.core.flush();
            }
            pub inline fn isStale(self: *const Reg, entity: Entity) bool {
                return self.core.isStale(entity);
            }
            pub inline fn isMoving(self: *const Reg, entity: Entity) bool {
                return self.core.isMoving(entity);
            }
            pub inline fn isInCollection(self: *const Reg, entity: Entity, c: anytype) bool {
                return self.core.isInCollection(entity, c);
            }
            pub inline fn get(self: *Reg, entity: Entity, c: anytype, comptime T: type) !*T {
                return self.core.get(entity, c, T);
            }
            pub inline fn set(self: *Reg, entity: Entity, c: anytype, comptime T: type, value: T) !void {
                return self.core.set(entity, c, T, value);
            }
            pub inline fn getFat(self: *Reg, entity: Entity, comptime T: type) !*T {
                return self.core.getFat(entity, T);
            }
            pub inline fn getRow(self: *Reg, entity: Entity, comptime R: type) !RowView(R) {
                return self.core.getRow(entity, R);
            }
            pub inline fn getAny(self: *Reg, entity: Entity, colls: anytype, comptime T: type) !*T {
                return self.core.getAny(entity, colls, T);
            }
            pub inline fn moveAny(self: *Reg, entity: Entity, sources: anytype, dst: anytype) !void {
                return self.core.moveAny(entity, sources, dst);
            }
            pub inline fn moveOnly(self: *Reg, entity: Entity, src: anytype, dst: anytype) !void {
                return self.core.moveOnly(entity, src, dst);
            }
            pub inline fn moveAnyOnly(self: *Reg, entity: Entity, sources: anytype, dst: anytype) !void {
                return self.core.moveAnyOnly(entity, sources, dst);
            }
            pub inline fn evictOnly(self: *Reg, entity: Entity, dst: anytype) !void {
                return self.core.evictOnly(entity, dst);
            }
            pub inline fn collectionIdOf(self: *const Reg, entity: Entity) ?u8 {
                return self.core.collectionIdOf(entity);
            }
            pub inline fn maxEntities(self: *const Reg) u32 {
                return self.core.max_entities;
            }
        };
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const TPos = struct { x: f32 = 0, y: f32 = 0 };
const TVel = struct { dx: f32 = 0, dy: f32 = 0 };
const THp = struct { hp: u32 = 100 };
const TTag = struct { v: u8 = 7 };

const io_ish_part = Part{
    .name = "io-ish",
    .collections = &.{
        .{ .name = "active", .row = Row(&.{ TPos, TVel }) },
        .{ .name = "closing", .row = Row(&.{TPos}) },
        .{ .name = "watched", .kind = .set },
    },
};

const app_part = Part{
    .name = "app",
    .components = &.{TTag},
    .collections = &.{
        .{ .name = "scored", .row = Row(&.{THp}) },
    },
};

const TestWorld = World(.{ .parts = &.{ io_ish_part, app_part } });

// A part-owned orthogonal axis (4a): identity is the declaration site.
const TTokens = struct { left: u32 = 8 };
const throttle_axis = struct {
    pub const axis_name: [:0]const u8 = "throttle";
};
const throttle_part = Part{
    .name = "throttler",
    .collections = &.{
        .{ .name = "throttled", .row = Row(&.{TTokens}), .axis = throttle_axis },
        .{ .name = "tracked", .kind = .set, .identity = true },
    },
};
const AxisWorld = World(.{ .parts = &.{ io_ish_part, app_part, throttle_part } });

test "world: the emergent partition — components inherit their collections' axis" {
    // Materialized components resolve to their axis; the same component
    // in two same-axis collections is fine (active/closing share TPos).
    try testing.expect(AxisWorld.axisOf(TPos).? == lifecycle);
    try testing.expect(AxisWorld.axisOf(THp).? == lifecycle);
    try testing.expect(AxisWorld.axisOf(TTokens).? == throttle_axis);
    // Shadow-only components are axis-free.
    try testing.expect(AxisWorld.axisOf(TTag) == null);
    // lifecycle first, then declaration order; a world with no tagged
    // collections still has the total axis.
    try testing.expectEqual(@as(usize, 2), AxisWorld.axes.len);
    try testing.expect(AxisWorld.axes[0] == lifecycle);
    try testing.expect(AxisWorld.axes[1] == throttle_axis);
    try testing.expectEqual(@as(usize, 1), TestWorld.axes.len);
    try testing.expect(AxisWorld.axisOfColl(.throttled) == throttle_axis);
    try testing.expect(AxisWorld.axisOfColl(.active) == lifecycle);
}

test "world: a two-axis registry — lifecycle mechanics unchanged, axis edges guarded" {
    var reg = try AxisWorld.Reg.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    const active = reg.coll(.active);
    const e = try reg.create(active);

    // Not on the throttle axis: its component resolves through the
    // shadow as declared defaults, the same read shape as any parked
    // component.
    try testing.expectEqual(@as(u32, 8), (try reg.getFat(e, TTokens)).left);

    // Birth is a total-axis event, and a membership changes only
    // within its axis — both refused loudly, at the verb.
    try testing.expectError(error.WrongAxis, reg.create(reg.coll(.throttled)));
    try testing.expectError(error.WrongAxis, reg.moveImmediate(e, active, reg.coll(.throttled)));

    // The real second axis: enter the throttled collection, iterate
    // its columns densely, and watch lifecycle moves leave it alone.
    try reg.enter(e, reg.coll(.throttled));
    try testing.expect(reg.onAxis(e, throttle_axis));
    for (reg.coll(.throttled).column(TTokens)) |*t| t.left -|= 1;
    try testing.expectEqual(@as(u32, 7), (try reg.getFat(e, TTokens)).left);

    // Lifecycle mechanics are unchanged by the second membership.
    (try reg.get(e, active, TPos)).* = .{ .x = 9, .y = 0 };
    try reg.moveImmediate(e, active, reg.coll(.closing));
    try testing.expectEqual(@as(f32, 9), (try reg.getFat(e, TPos)).x);
    try testing.expect(reg.onAxis(e, throttle_axis));

    // Leave parks; re-enter restores (path-independence's sharp edge:
    // a fresh start is the leaving system's job, by resetting first).
    try testing.expect(try reg.leaveAxis(e, throttle_axis));
    try testing.expectEqual(@as(u32, 7), (try reg.getFat(e, TTokens)).left);
    try reg.enter(e, reg.coll(.throttled));
    try testing.expectEqual(@as(u32, 7), (try reg.getFat(e, TTokens)).left);

    // Destroy exits every axis.
    try reg.destroyImmediate(e);
    try testing.expect(reg.collectionIdOf(e) == null);
    try testing.expectEqual(@as(u32, 0), reg.coll(.throttled).count);
}

test "world: moveOnly/evictOnly — quiesce drops state memberships, spares identity" {
    var reg = try AxisWorld.Reg.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    const active = reg.coll(.active);
    const closing = reg.coll(.closing);
    const e = try reg.create(active);
    try reg.enter(e, reg.coll(.throttled));
    (try reg.getFat(e, TTokens)).left = 3;
    _ = try reg.join(e, .watched);
    _ = try reg.join(e, .tracked);

    // The call site names no axes: entering the closing state IS the
    // quiesce, and a state axis added later is dropped here without
    // this site changing.
    try reg.moveOnly(e, active, closing);
    try reg.flush();

    try testing.expect(reg.isInCollection(e, closing));
    try testing.expect(!reg.onAxis(e, throttle_axis));
    try testing.expect(!reg.inSet(e, .watched));
    // Identity says what the entity IS — it survives quiescing.
    try testing.expect(reg.inSet(e, .tracked));
    // The dropped state's row parked, not destroyed.
    try testing.expectEqual(@as(u32, 3), (try reg.getFat(e, TTokens)).left);

    // The erased-source flavor, back the other way.
    try reg.enter(e, reg.coll(.throttled));
    try reg.evictOnly(e, active);
    try testing.expect(reg.isInCollection(e, active));
    try testing.expect(!reg.onAxis(e, throttle_axis));
    try testing.expect(reg.inSet(e, .tracked));
}

test "world: ids by table position, one namespace across parts" {
    try testing.expectEqual(@as(u8, 1), @intFromEnum(TestWorld.CollId.active));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(TestWorld.CollId.closing));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(TestWorld.CollId.watched));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(TestWorld.CollId.scored));
    // TPos, TVel, THp from rows; TTag from app_part's shadow-only list.
    try testing.expectEqual(@as(usize, 4), TestWorld.Universe.len);
    try testing.expect(TestWorld.Universe.contains(TTag));
}

test "world: registry-owned storage — create, cross-part move, getFat" {
    var reg = try TestWorld.Reg.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    const active = reg.coll(.active);
    const scored = reg.coll(.scored);

    const e = try reg.create(active);
    (try reg.get(e, active, TPos)).* = .{ .x = 3, .y = 4 };
    // A shadow-only component is addressable with no row anywhere.
    (try reg.getFat(e, TTag)).* = .{ .v = 9 };

    try reg.moveImmediate(e, active, scored);
    try testing.expectEqual(@as(u32, 0), active.count);
    try testing.expectEqual(@as(u32, 1), scored.count);
    // Parked and shadow-only values both survive the cross-part move.
    try testing.expectEqual(@as(f32, 3), (try reg.getFat(e, TPos)).x);
    try testing.expectEqual(@as(u8, 9), (try reg.getFat(e, TTag)).v);
    try testing.expectEqual(@intFromEnum(TestWorld.CollId.scored), reg.collectionIdOf(e).?);
}

test "world: sets are tag-addressed and left structurally at destroy" {
    var reg = try TestWorld.Reg.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    const active = reg.coll(.active);
    const e = try reg.create(active);
    try testing.expect(try reg.join(e, .watched));
    try testing.expect(!try reg.join(e, .watched));
    try testing.expect(reg.inSet(e, .watched));
    try testing.expectEqual(@as(u32, 1), reg.setCount(.watched));
    try testing.expectEqual(e.index, reg.setMembers(.watched)[0].index);

    try reg.destroyImmediate(e);
    try testing.expectEqual(@as(u32, 0), reg.setCount(.watched));
}

test "world: getRow spans resident and parked homes" {
    var reg = try TestWorld.Reg.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    const active = reg.coll(.active);
    const closing = reg.coll(.closing);

    const e = try reg.create(active);
    (try reg.get(e, active, TVel)).* = .{ .dx = 5, .dy = 6 };
    try reg.moveImmediate(e, active, closing);

    // TPos resident in closing, TVel parked in the shadow.
    const view = try reg.getRow(e, Row(&.{ TPos, TVel }));
    try testing.expectEqual(@as(f32, 5), view.at(TVel).dx);
}
