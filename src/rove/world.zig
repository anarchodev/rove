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
const EntitySet = fat_mod.EntitySet;
const RowView = fat_mod.RowView;

pub const CollKind = enum { collection, set };

/// One entry in a part's collection table. The row is the machinery
/// describing the collection — which components it materializes as SoA
/// columns. A set entry keeps the default empty row (pure membership).
pub const CollDecl = struct {
    name: [:0]const u8,
    row: type = Row(&.{}),
    kind: CollKind = .collection,
    options: CollectionOptions = .{},
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

    const n_sets = comptime blk: {
        var n: usize = 0;
        for (table) |d| n += @intFromBool(d.kind == .set);
        break :blk n;
    };
    comptime {
        if (n_sets > 32) @compileError("world: more than 32 set entries — the per-entity membership mask is u32");
    }

    // The closed universe: every part's shadow-only components plus
    // every entry's row, canonically merged.
    const universe = comptime blk: {
        var u = Row(&.{});
        for (cfg.parts) |p| u = u.merge(Row(p.components));
        for (table) |d| u = u.merge(d.row);
        break :blk u;
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

        /// The Collection type of a declared entry. Set entries have no
        /// collection type — their storage is registry-internal.
        pub fn CollOf(comptime id: CollId) type {
            const d = declOf(id);
            if (d.kind == .set) @compileError(
                "world: '" ++ d.name ++ "' is a set entry — sets are registry-internal; use join/leave/inSet/setMembers",
            );
            return Collection(d.row, d.options);
        }

        /// Bit index of a set entry in the registry's membership mask:
        /// its position among the set-kind entries, in table order.
        fn setBit(comptime id: CollId) u5 {
            const d = comptime declOf(id);
            comptime {
                if (d.kind != .set) @compileError("world: '" ++ d.name ++ "' is a collection entry, not a set");
            }
            comptime var bit: u5 = 0;
            inline for (table[0 .. @intFromEnum(id) - 1]) |e| {
                if (e.kind == .set) bit += 1;
            }
            return bit;
        }

        // One field per collection-kind entry, named by the entry.
        const CollStorage = blk: {
            var fields: [table.len]std.builtin.Type.StructField = undefined;
            var n: usize = 0;
            for (table) |d| {
                if (d.kind == .set) continue;
                fields[n] = .{
                    .name = d.name,
                    .type = Collection(d.row, d.options),
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(Collection(d.row, d.options)),
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

        const Storage = struct {
            colls: CollStorage,
            sets: [n_sets]EntitySet,
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

            pub const Core = FatRegistry(universe);
            pub const Fat = Core.Fat;

            pub fn init(allocator: std.mem.Allocator, config: FatRegistryConfig) !Reg {
                var core = try Core.init(allocator, config);
                errdefer core.deinit();
                const storage = try allocator.create(Storage);
                errdefer allocator.destroy(storage);

                var inited: usize = 0;
                errdefer inline for (table, 0..) |d, i| {
                    if (i < inited) switch (d.kind) {
                        .collection => @field(storage.colls, d.name).deinit(),
                        .set => storage.sets[comptime setBit(@field(CollId, d.name))].deinit(),
                    };
                };

                inline for (table, 0..) |d, i| {
                    switch (d.kind) {
                        .collection => {
                            @field(storage.colls, d.name) = try Collection(d.row, d.options).init(allocator);
                            core.registerCollection(&@field(storage.colls, d.name), i + 1);
                        },
                        .set => {
                            const bit = comptime setBit(@field(CollId, d.name));
                            storage.sets[bit] = try EntitySet.init(allocator, config.max_entities);
                            core.registerSet(&storage.sets[bit], bit);
                        },
                    }
                    inited = i + 1;
                }

                return .{ .core = core, .storage = storage };
            }

            pub fn deinit(self: *Reg) void {
                const allocator = self.core.allocator;
                inline for (table) |d| {
                    if (d.kind == .collection) @field(self.storage.colls, d.name).deinit();
                }
                for (&self.storage.sets) |*s| s.deinit();
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

            fn setPtr(self: *const Reg, comptime id: CollId) *EntitySet {
                return &self.storage.sets[comptime setBit(id)];
            }

            // ── Membership sets, by tag (storage stays internal) ──

            pub fn join(self: *Reg, entity: Entity, comptime id: CollId) !bool {
                return self.core.join(entity, self.setPtr(id));
            }

            pub fn leave(self: *Reg, entity: Entity, comptime id: CollId) !bool {
                return self.core.leave(entity, self.setPtr(id));
            }

            pub fn inSet(self: *const Reg, entity: Entity, comptime id: CollId) bool {
                return self.core.inSet(entity, self.setPtr(id));
            }

            /// The set's dense member list. Valid until the next
            /// join/leave/destroy.
            pub fn setMembers(self: *const Reg, comptime id: CollId) []const Entity {
                return self.setPtr(id).members();
            }

            pub fn setCount(self: *const Reg, comptime id: CollId) u32 {
                return self.setPtr(id).count;
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
