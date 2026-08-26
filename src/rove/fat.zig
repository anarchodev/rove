// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! FatRegistry — the fat-entity storage model, living beside `Registry` so
//! the two models can be compared on the same `Collection` machinery.
//!
//! Model: every entity conceptually carries every component in the
//! registry's comptime-closed `Universe`. A collection does not define
//! which components an entity *has* — it defines which components are
//! safe to read while the entity is a member, and it is the dense SoA set
//! systems iterate. Consequences:
//!
//! - **Moves are total and lossless.** Any collection → any collection,
//!   no row-subset requirement. Components the destination lacks are
//!   *parked* in the shadow store; components the destination adds are
//!   *unparked* from it (or materialized with declared field defaults if
//!   the entity never held a value — see `row.fillDefault`). A component's
//!   value is therefore path-independent: it is always the last value any
//!   system wrote, never a function of the route the entity took.
//! - **No lifecycle hooks.** Neither moves nor destroys run component
//!   init/deinit. Release is a transition owned by a system (rove-style
//!   §16, release-is-a-transition): the system that releases a resource
//!   writes the component back to its declared default as part of that
//!   release. Birth is the single defaulting point.
//! - **The shadow store is the fat struct, literally.** One AoS array of
//!   a comptime-built universe struct, `max_entities` long, addressed by
//!   `entity.index`, never compacted — a parked component's address is
//!   stable for the entity's whole lifetime. AoS because the shadow is
//!   NEVER iterated (that is what collections are for): every access is
//!   per-entity and usually multi-component, so clustering one entity's
//!   components beats columns for exactly the operations the shadow
//!   serves. Collections remain the SoA projections of this base table.
//! - **Validity is a per-entity header, not per-slot stamps.** Each
//!   struct opens with `{ gen, written }`: the generation these bytes
//!   belong to plus a written-this-generation bitmask over the universe.
//!   A reborn index never reads its predecessor's parked values —
//!   mismatched gen makes the whole mask read as zero, lazily — and the
//!   check shares a cache line with the data it guards. This is what
//!   makes birth/death O(row), not O(universe).
//!
//! `getFat(entity, T)` is the universal read the model promises: it
//! resolves T wherever it currently lives — the owning collection's
//! column when resident, the shadow slot when parked — with no candidate
//! set at the call site. The pointer it returns obeys the usual rule:
//! valid until the next flush/immediate op (resident) or for the entity's
//! lifetime (parked).
const std = @import("std");
const entity_mod = @import("entity.zig");
const row_mod = @import("row.zig");
const collection_mod = @import("collection.zig");
const Entity = entity_mod.Entity;
const Row = row_mod.Row;
const effectiveAlign = collection_mod.effectiveAlign;

pub const FatRegistryConfig = struct {
    max_entities: u32,
    deferred_queue_capacity: u32 = 256,
};

/// A typed pointer bundle over one entity's components for a declared
/// Row — the fat model's "cast to a row type". Each pointer resolves to
/// the component's live home at construction: the owning collection's
/// column where materialized, the shadow slot otherwise. One live home
/// per component is what makes the bundle coherent with zero copies —
/// there is nothing to merge, and no contiguous row exists to return:
/// a "row" is N pointers here exactly as it is N columns everywhere
/// else in the system.
///
/// Validity is the WEAKEST member guarantee: pointers into columns die
/// at the next flush/immediate op, so treat the whole bundle that way.
pub fn RowView(comptime R: type) type {
    return struct {
        ptrs: [R.len]*anyopaque,

        pub fn at(self: @This(), comptime T: type) *T {
            return @ptrCast(@alignCast(self.ptrs[comptime R.indexOf(T)]));
        }
    };
}

/// Per-entity validity header, first field of the shadow struct. The
/// bytes after it belong to generation `gen`; bit i of `written` says
/// component i (by Universe index) has been written for that generation.
/// A mismatched gen makes the whole mask read as zero — rebirth
/// invalidation without any sweep.
pub const ShadowHeader = struct { gen: u32 = 0, written: u64 = 0 };

/// The comptime-built universe struct: header first, then one field per
/// non-ZST Universe component (named by Universe index, over-alignment
/// honored per field). The shadow is one AoS array of these.
fn ShadowStruct(comptime Universe: type) type {
    if (Universe.len > 64) @compileError("shadow written-mask is u64 — widen it for a universe past 64 components");
    comptime var fields: [Universe.len + 1]std.builtin.Type.StructField = undefined;
    fields[0] = .{
        .name = "hdr",
        .type = ShadowHeader,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(ShadowHeader),
    };
    comptime var n: usize = 1;
    inline for (Universe.types, 0..) |T, ci| {
        if (@sizeOf(T) == 0) continue;
        fields[n] = .{
            .name = std.fmt.comptimePrint("c{d}", .{ci}),
            .type = T,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = effectiveAlign(T),
        };
        n += 1;
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .backing_integer = null,
        .fields = fields[0..n],
        .decls = &.{},
        .is_tuple = false,
    } });
}

/// A pure membership set — the empty-row collection, and the degenerate
/// case of a membership axis that is unconditionally safe to overlap
/// with anything: it materializes no components, so it can contest no
/// live copy. Membership is SECONDARY and orthogonal to the entity's
/// collection: it survives every move, and only destroy ends it (the
/// registry leaves all sets structurally — release cannot be forgotten).
///
/// Storage is a dense entity list (iterable, countable in O(1)) plus a
/// sparse entity.index → offset table, both sized max_entities at init
/// so joining can never fail. Register with `registry.registerSet` and
/// operate through the registry (`join` / `leave` / `inSet`), which
/// keeps the per-entity membership mask that makes destroy exact.
pub const EntitySet = struct {
    entities: [*]Entity,
    /// entity.index → dense offset + 1; 0 = not a member.
    sparse: [*]u32,
    count: u32,
    max_entities: u32,
    /// Registry-declared bit index (0..MAX_SETS-1). Set by registerSet.
    set_id: u5 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_entities: u32) !EntitySet {
        const entities = try allocator.alloc(Entity, max_entities);
        const sparse = try allocator.alloc(u32, max_entities);
        @memset(sparse, 0);
        return .{
            .entities = entities.ptr,
            .sparse = sparse.ptr,
            .count = 0,
            .max_entities = max_entities,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EntitySet) void {
        self.allocator.free(self.entities[0..self.max_entities]);
        self.allocator.free(self.sparse[0..self.max_entities]);
        self.* = undefined;
    }

    /// The dense member list. Valid until the next join/leave/destroy.
    pub fn members(self: *const EntitySet) []const Entity {
        return self.entities[0..self.count];
    }
};

/// `Universe` is a `Row` of every component type any registered collection
/// may carry — the comptime-closed component world. Collections whose row
/// is not covered by it are rejected at registration (comptime).
pub fn FatRegistry(comptime Universe: type) type {
    if (!@hasDecl(Universe, "types") or !@hasDecl(Universe, "len")) {
        @compileError("FatRegistry requires a Row type as its Universe");
    }

    return struct {
        const Self = @This();

        // Entity metadata (SoA) — index-addressed, never compacted
        generations: []u32,
        collection_ids: []u8, // 0 = null pool (free)
        offsets: []u32,
        flags: []u8,

        max_entities: u32,

        // Null pool — free entity slots
        null_pool: []Entity,
        null_count: u32,

        // Which collection ids are taken. Ids are DECLARED by the
        // registering layer, so an entity's `collection_ids` byte is
        // directly interpretable as that layer's collection enum; this
        // guard is all that stops two layers from picking the same slot.
        id_used: [MAX_COLLECTIONS]bool,

        // Deferred queue
        deferred_ops: []DeferredOp,
        deferred_count: u32,
        deferred_capacity: u32,

        // The base table: one universe struct per entity, addressed by
        // entity.index, never compacted. Point access only — the shadow
        // is never iterated.
        fat_table: []Fat,

        // Runtime (collection_id, component) → element accessor. Null when
        // that collection's row lacks the component (the shadow is then the
        // live home). MAX_COLLECTIONS * Universe.len.
        column_fns: []?ColumnFn,
        coll_ptrs: [MAX_COLLECTIONS]?*anyopaque,
        destroy_recipes: [MAX_COLLECTIONS]DestroyEntry,

        // Secondary memberships: one bit per registered set, per entity.
        // The mask is what makes destroy leave every set the entity
        // joined — membership release is structural, never remembered.
        set_memberships: []u32,
        set_ptrs: [MAX_SETS]?*EntitySet,

        // Per-collection evict recipes — the type-erased extraction half
        // of evictImmediate, indexed by collection_id like destroy_recipes.
        evict_recipes: [MAX_COLLECTIONS]EvictEntry,

        allocator: std.mem.Allocator,

        const PENDING_MOVE: u8 = 1;
        const MAX_COLLECTIONS: usize = 256;
        const MAX_SETS: usize = 32;

        pub const Fat = ShadowStruct(Universe);

        const ColumnFn = *const fn (*anyopaque, u32) [*]u8;

        const DestroyEntry = struct {
            recipe: *const fn (*Self, *anyopaque, *anyopaque, u32, u32) anyerror!void,
            ptr: *anyopaque,
        };

        const EvictEntry = struct {
            recipe: *const fn (*Self, *anyopaque, u32) void,
            ptr: *anyopaque,
        };

        pub const DeferredOp = struct {
            src_collection_id: u8,
            src_offset: u32,
            count: u32,
            execute: *const fn (*Self, *anyopaque, *anyopaque, u32, u32) anyerror!void,
            src_ptr: *anyopaque,
            dst_ptr: *anyopaque,
        };

        pub fn init(allocator: std.mem.Allocator, config: FatRegistryConfig) !Self {
            const max = config.max_entities;

            const generations = try allocator.alloc(u32, max);
            @memset(generations, 0);

            const collection_ids = try allocator.alloc(u8, max);
            @memset(collection_ids, 0);

            const offsets = try allocator.alloc(u32, max);
            const flags = try allocator.alloc(u8, max);
            @memset(flags, 0);

            const null_pool = try allocator.alloc(Entity, max);
            for (0..max) |i| {
                null_pool[i] = .{ .index = @intCast(i), .generation = 0 };
                offsets[i] = @intCast(i);
            }

            const deferred_ops = try allocator.alloc(DeferredOp, config.deferred_queue_capacity);

            const fat_table = try allocator.alloc(Fat, max);
            // Headers only: gen 0 + empty mask reads as "nothing written"
            // for every generation, including 0. Component bytes stay
            // untouched until first park/materialize.
            for (fat_table) |*f| f.hdr = .{};

            const column_fns = try allocator.alloc(?ColumnFn, MAX_COLLECTIONS * Universe.len);
            @memset(column_fns, null);

            const set_memberships = try allocator.alloc(u32, max);
            @memset(set_memberships, 0);

            return .{
                .generations = generations,
                .collection_ids = collection_ids,
                .offsets = offsets,
                .flags = flags,
                .max_entities = max,
                .null_pool = null_pool,
                .null_count = max,
                .id_used = [_]bool{false} ** MAX_COLLECTIONS,
                .deferred_ops = deferred_ops,
                .deferred_count = 0,
                .deferred_capacity = config.deferred_queue_capacity,
                .fat_table = fat_table,
                .column_fns = column_fns,
                .coll_ptrs = [_]?*anyopaque{null} ** MAX_COLLECTIONS,
                .destroy_recipes = undefined,
                .set_memberships = set_memberships,
                .set_ptrs = [_]?*EntitySet{null} ** MAX_SETS,
                .evict_recipes = undefined,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.fat_table);
            self.allocator.free(self.column_fns);
            self.allocator.free(self.set_memberships);
            self.allocator.free(self.generations);
            self.allocator.free(self.collection_ids);
            self.allocator.free(self.offsets);
            self.allocator.free(self.flags);
            self.allocator.free(self.null_pool);
            self.allocator.free(self.deferred_ops);
            self.* = undefined;
        }

        /// Register an already-created collection under a DECLARED id,
        /// mirroring `Registry.registerCollection`: the id is the caller's
        /// to choose because it is what makes an entity's state readable —
        /// `collection_ids[entity.index]` is that id, so a layer whose
        /// collection enum declared these values recovers the typed
        /// collection with a cast + switch instead of a candidate scan.
        /// The row must be covered by the Universe (comptime); id 0 is the
        /// free/null pool and is never a collection.
        pub inline fn registerCollection(self: *Self, coll: anytype, declared_id: u8) void {
            const CollType = @typeInfo(@TypeOf(coll)).pointer.child;
            comptime {
                @setEvalBranchQuota(100_000);
                if (!CollType.RowType.isSubsetOf(Universe)) {
                    @compileError("registerCollection: collection row is not covered by the registry Universe");
                }
            }

            // Explicit rather than `assert`: the shipped build is
            // ReleaseFast, where an assert is not compiled. Id 0 is the
            // free pool; a collection there would make every FREE entity
            // resolve as one of its members.
            if (declared_id == 0) std.debug.panic("fat registry: collection id 0 is the free pool", .{});
            if (self.id_used[declared_id]) std.debug.panic(
                "fat registry: collection id {d} registered twice — two layers' id ranges overlap",
                .{declared_id},
            );
            self.id_used[declared_id] = true;
            coll.registry_id = declared_id;
            const id: usize = declared_id;

            self.coll_ptrs[id] = @ptrCast(coll);
            self.destroy_recipes[id] = .{
                .recipe = destroyRecipe(CollType),
                .ptr = @ptrCast(coll),
            };
            self.evict_recipes[id] = .{
                .recipe = evictRecipe(CollType),
                .ptr = @ptrCast(coll),
            };

            inline for (Universe.types, 0..) |T, ci| {
                if (comptime CollType.RowType.contains(T) and @sizeOf(T) > 0) {
                    self.column_fns[id * Universe.len + ci] = columnFn(CollType, T);
                }
            }
        }

        /// Register a membership set under a DECLARED bit index
        /// (0..MAX_SETS-1), mirroring collection registration: declared so
        /// the per-entity membership mask is directly interpretable by the
        /// layer that numbered its sets. The set must be sized to this
        /// registry's max_entities — checked loudly, since a short sparse
        /// table would index out of bounds on a high entity index.
        pub fn registerSet(self: *Self, s: *EntitySet, declared_id: u5) void {
            if (s.max_entities != self.max_entities) std.debug.panic(
                "fat registry: set sized for {d} entities registered on a registry of {d}",
                .{ s.max_entities, self.max_entities },
            );
            if (self.set_ptrs[declared_id] != null) std.debug.panic(
                "fat registry: set id {d} registered twice",
                .{declared_id},
            );
            s.set_id = declared_id;
            self.set_ptrs[declared_id] = s;
        }

        /// Join a set. Idempotent: returns false if already a member.
        /// Membership is orthogonal to the entity's collection — it
        /// survives every move and ends only at leave or destroy.
        pub fn join(self: *Self, entity: Entity, s: *EntitySet) !bool {
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (s.sparse[idx] != 0) return false;
            s.entities[s.count] = entity;
            s.sparse[idx] = s.count + 1;
            s.count += 1;
            self.set_memberships[idx] |= @as(u32, 1) << s.set_id;
            return true;
        }

        /// Leave a set. Returns false if not a member.
        pub fn leave(self: *Self, entity: Entity, s: *EntitySet) !bool {
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (s.sparse[idx] == 0) return false;
            self.removeFromSet(s, idx);
            self.set_memberships[idx] &= ~(@as(u32, 1) << s.set_id);
            return true;
        }

        pub fn inSet(self: *const Self, entity: Entity, s: *const EntitySet) bool {
            const idx = entity.index;
            if (idx >= self.max_entities) return false;
            if (self.generations[idx] != entity.generation) return false;
            return s.sparse[idx] != 0;
        }

        fn removeFromSet(self: *Self, s: *EntitySet, idx: u32) void {
            _ = self;
            const off = s.sparse[idx] - 1;
            const last = s.count - 1;
            const moved = s.entities[last];
            s.entities[off] = moved;
            s.sparse[moved.index] = off + 1;
            s.count -= 1;
            s.sparse[idx] = 0;
        }

        /// Destroy's structural half of membership: leave every set the
        /// entity joined, driven by the mask — so a set can never hold a
        /// dead entity and counts stay exact.
        fn leaveAllSets(self: *Self, idx: u32) void {
            var mask = self.set_memberships[idx];
            while (mask != 0) {
                const bit: u5 = @intCast(@ctz(mask));
                mask &= mask - 1;
                self.removeFromSet(self.set_ptrs[bit].?, idx);
            }
            self.set_memberships[idx] = 0;
        }

        // =============================================================
        // Create — immediate (entity is live right away)
        // =============================================================

        /// Birth is the single defaulting point: every component in the
        /// birth collection's row gets its declared field defaults. No
        /// init hook runs. Components outside the row default lazily on
        /// first touch (stamp mismatch reads as default).
        pub inline fn create(self: *Self, dst: anytype) !Entity {
            const DstColl = @typeInfo(@TypeOf(dst)).pointer.child;
            if (self.null_count == 0) return error.Full;
            self.null_count -= 1;
            const entity = self.null_pool[self.null_count];

            const offset = try dst.reserveSlots(1);
            dst.entitySlice()[offset] = entity;
            inline for (DstColl.RowType.types) |T| {
                if (comptime @sizeOf(T) > 0) {
                    row_mod.fillDefault(T, dst.column(T)[offset .. offset + 1]);
                }
            }

            self.collection_ids[entity.index] = dst.registry_id;
            self.offsets[entity.index] = offset;

            return entity;
        }

        // =============================================================
        // move — total: any collection to any collection, lossless
        // =============================================================

        pub inline fn move(self: *Self, entity: Entity, src: anytype, dst: anytype) !void {
            const SrcColl = @typeInfo(@TypeOf(src)).pointer.child;
            const DstColl = @typeInfo(@TypeOf(dst)).pointer.child;
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;
            if (self.collection_ids[idx] != src.registry_id) return error.WrongCollection;

            self.flags[idx] |= PENDING_MOVE;

            const recipe = moveRecipe(SrcColl, DstColl);
            try self.enqueueOp(.{
                .src_collection_id = src.registry_id,
                .src_offset = self.offsets[idx],
                .count = 1,
                .execute = recipe,
                .src_ptr = @ptrCast(src),
                .dst_ptr = @ptrCast(dst),
            });
        }

        /// Immediately move an entity. Same total semantics as `move`,
        /// no deferred queue.
        pub inline fn moveImmediate(self: *Self, entity: Entity, src: anytype, dst: anytype) !void {
            const SrcColl = @typeInfo(@TypeOf(src)).pointer.child;
            const DstColl = @typeInfo(@TypeOf(dst)).pointer.child;
            const SrcRow = SrcColl.RowType;
            const DstRow = DstColl.RowType;
            const Shared = SrcRow.intersect(DstRow);
            const Dropped = SrcRow.subtract(&DstRow.types);
            const Gained = DstRow.subtract(&SrcRow.types);

            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;
            if (self.collection_ids[idx] != src.registry_id) return error.WrongCollection;

            const src_offset = self.offsets[idx];
            const new_offset = try dst.reserveSlots(1);
            dst.entitySlice()[new_offset] = entity;

            inline for (Shared.types) |T| {
                if (comptime @sizeOf(T) > 0) {
                    dst.column(T)[new_offset] = src.column(T)[src_offset];
                }
            }
            inline for (Dropped.types) |T| {
                if (comptime @sizeOf(T) > 0) {
                    self.parkOne(T, entity, src.column(T)[src_offset]);
                }
            }
            inline for (Gained.types) |T| {
                if (comptime @sizeOf(T) > 0) {
                    self.unparkOne(T, entity, &dst.column(T)[new_offset]);
                }
            }

            const moved = src.removeRun(src_offset, 1);
            for (moved) |moved_entity| {
                self.offsets[moved_entity.index] = src_offset;
            }

            self.collection_ids[idx] = dst.registry_id;
            self.offsets[idx] = new_offset;
        }

        /// Call-site-compatible `moveStrip`: under the fat model nothing
        /// is dropped — components the destination lacks are parked, not
        /// destroyed — so this IS `moveImmediate`. The strip list is still
        /// comptime-checked against the rows' difference: it remains the
        /// call site's declaration of what the destination does not read,
        /// and a stale list is a compile error rather than rot.
        pub inline fn moveStripImmediate(self: *Self, entity: Entity, src: anytype, dst: anytype, comptime strip: []const type) !void {
            const SrcColl = @typeInfo(@TypeOf(src)).pointer.child;
            const DstColl = @typeInfo(@TypeOf(dst)).pointer.child;
            comptime {
                @setEvalBranchQuota(100_000);
                const lost = SrcColl.RowType.subtract(&DstColl.RowType.types);
                if (!Row(strip).equal(lost)) {
                    @compileError("moveStripImmediate: strip list does not match the components the destination lacks");
                }
            }
            return self.moveImmediate(entity, src, dst);
        }

        // =============================================================
        // Destroy
        // =============================================================

        /// Destroy an entity (deferred). No deinit hook runs: a system
        /// that owns a resource resets its component during the teardown
        /// transition, before the entity reaches destroy.
        pub fn destroy(self: *Self, entity: Entity) !void {
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;

            const src_id = self.collection_ids[idx];
            if (src_id == 0) return error.InvalidEntity;

            self.flags[idx] |= PENDING_MOVE;

            const entry = self.destroy_recipes[src_id];
            try self.enqueueOp(.{
                .src_collection_id = src_id,
                .src_offset = self.offsets[idx],
                .count = 1,
                .execute = entry.recipe,
                .src_ptr = entry.ptr,
                .dst_ptr = @ptrFromInt(1),
            });
        }

        /// Immediately destroy an entity. Source collection is looked up
        /// automatically.
        pub fn destroyImmediate(self: *Self, entity: Entity) !void {
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;

            const src_id = self.collection_ids[idx];
            if (src_id == 0) return error.InvalidEntity;

            const entry = self.destroy_recipes[src_id];
            try entry.recipe(self, entry.ptr, @ptrFromInt(1), self.offsets[idx], 1);
        }

        // =============================================================
        // Flush
        // =============================================================

        pub fn flush(self: *Self) !void {
            while (self.deferred_count > 0) {
                const batch_count = self.deferred_count;

                const ops = self.deferred_ops[0..batch_count];
                if (batch_count > 1) {
                    std.mem.sort(DeferredOp, ops, {}, opOrder);
                }

                // Process in reverse — highest offsets first within each source
                var i = batch_count;
                while (i > 0) {
                    i -= 1;
                    const op = self.deferred_ops[i];
                    try op.execute(self, op.src_ptr, op.dst_ptr, op.src_offset, op.count);
                }

                const new_count = self.deferred_count - batch_count;
                if (new_count > 0) {
                    std.mem.copyForwards(
                        DeferredOp,
                        self.deferred_ops[0..new_count],
                        self.deferred_ops[batch_count .. batch_count + new_count],
                    );
                }
                self.deferred_count = new_count;
            }
        }

        // =============================================================
        // Queries
        // =============================================================

        pub fn isStale(self: *const Self, entity: Entity) bool {
            if (entity.index >= self.max_entities) return true;
            return self.generations[entity.index] != entity.generation;
        }

        pub fn isMoving(self: *const Self, entity: Entity) bool {
            if (entity.index >= self.max_entities) return false;
            if (self.generations[entity.index] != entity.generation) return false;
            return self.flags[entity.index] & PENDING_MOVE != 0;
        }

        pub inline fn isInCollection(self: *const Self, entity: Entity, coll: anytype) bool {
            if (entity.index >= self.max_entities) return false;
            if (self.generations[entity.index] != entity.generation) return false;
            return self.collection_ids[entity.index] == coll.registry_id;
        }

        /// Read a component through a known collection — the dense-path
        /// accessor, identical to `Registry.get`.
        pub inline fn get(self: *Self, entity: Entity, coll: anytype, comptime T: type) !*T {
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.collection_ids[idx] != coll.registry_id) return error.WrongCollection;
            return &coll.column(T)[self.offsets[idx]];
        }

        pub inline fn set(self: *Self, entity: Entity, coll: anytype, comptime T: type, value: T) !void {
            const ptr = try self.get(entity, coll, T);
            ptr.* = value;
        }

        /// The universal read: resolve T wherever it currently lives — the
        /// owning collection's column when resident, the shadow slot when
        /// parked — with no candidate set at the call site. A virgin slot
        /// (never written for this generation) materializes the declared
        /// field defaults on first touch. Resident pointers are valid until
        /// the next flush/immediate op; parked pointers for the entity's
        /// lifetime.
        pub inline fn getFat(self: *Self, entity: Entity, comptime T: type) !*T {
            comptime {
                if (!Universe.contains(T)) {
                    @compileError("getFat: " ++ @typeName(T) ++ " is not in the registry Universe");
                }
            }
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;

            if (comptime @sizeOf(T) == 0) {
                return @ptrFromInt(comptime effectiveAlign(T));
            }

            const ci = comptime compIndex(T);
            const id: usize = self.collection_ids[idx];
            if (id != 0) {
                if (self.column_fns[id * Universe.len + ci]) |f| {
                    return @ptrCast(@alignCast(f(self.coll_ptrs[id].?, self.offsets[idx])));
                }
            }

            const f = &self.fat_table[idx];
            const slot = fatPtr(f, T);
            if (f.hdr.gen != entity.generation or (f.hdr.written & comptime shadowBit(T)) == 0) {
                freshHeader(f, entity.generation);
                row_mod.fillDefault(T, @as([*]T, @ptrCast(slot))[0..1]);
                f.hdr.written |= comptime shadowBit(T);
            }
            return slot;
        }

        /// The declared id of the entity's current collection, or null
        /// when the handle is stale or out of range. Because ids are
        /// declared, the byte IS the registering layer's collection enum
        /// value: the layer casts it and recovers the typed collection
        /// through an exhaustive switch (a jump table via `inline else`),
        /// which is checked where an "assert the type and cast" accessor
        /// cannot be. Never null for a live entity — a live entity is
        /// always a member of exactly one collection.
        pub fn collectionIdOf(self: *const Self, entity: Entity) ?u8 {
            const idx = entity.index;
            if (idx >= self.max_entities) return null;
            if (self.generations[idx] != entity.generation) return null;
            const raw = self.collection_ids[idx];
            // 0 is the registry's free pool and is never a collection.
            if (raw == 0) return null;
            return raw;
        }

        /// Move the entity into `dst` from WHATEVER collection currently
        /// holds it, without the caller naming the source type: the
        /// extraction half runs through a type-erased per-collection
        /// recipe (park the whole row, remove from the collection), the
        /// insertion half is an ordinary typed unpark of dst's row. This
        /// is what lets a layer end an entity it created after another
        /// layer adopted it into a collection the creator cannot name.
        ///
        /// The destination slot is reserved FIRST — the only fallible
        /// step — so a failure never leaves the entity collection-less
        /// (a live entity carrying the free-pool id would alias dead
        /// ones; there is deliberately no observable "in no collection"
        /// state). Evict-to-self is refused: the reserve/extract
        /// interleave is unsound within one collection, and an ordinary
        /// move covers it. Components in both rows take a park/unpark
        /// round trip instead of a direct copy — eviction is a cold
        /// path, and the detour is the price of the type erasure.
        pub inline fn evictImmediate(self: *Self, entity: Entity, dst: anytype) !void {
            const DstColl = @typeInfo(@TypeOf(dst)).pointer.child;
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;
            const src_id = self.collection_ids[idx];
            if (src_id == 0) return error.InvalidEntity;
            if (src_id == dst.registry_id) return error.WrongCollection;

            const new_offset = try dst.reserveSlots(1);

            const entry = self.evict_recipes[src_id];
            entry.recipe(self, entry.ptr, self.offsets[idx]);

            dst.entitySlice()[new_offset] = entity;
            inline for (DstColl.RowType.types) |T| {
                if (comptime @sizeOf(T) > 0) {
                    self.unparkOne(T, entity, &dst.column(T)[new_offset]);
                }
            }
            self.collection_ids[idx] = dst.registry_id;
            self.offsets[idx] = new_offset;
        }

        /// Cast the entity to a row type: one handle validation, then one
        /// `getFat` resolution per component of R. The RowType is the call
        /// site's DECLARED claim about which component set is meaningful
        /// for this entity here — greppable and universe-checked, where a
        /// bare `getFat` is anonymous point access. Access only; it does
        /// not move the entity, materialize anything into a collection,
        /// or check freshness (a member never written reads as declared
        /// defaults, like any other fat read).
        pub inline fn getRow(self: *Self, entity: Entity, comptime R: type) !RowView(R) {
            var view: RowView(R) = undefined;
            inline for (R.types, 0..) |T, i| {
                view.ptrs[i] = @ptrCast(try self.getFat(entity, T));
            }
            return view;
        }

        // =============================================================
        // Internal
        // =============================================================

        fn enqueueOp(self: *Self, op: DeferredOp) !void {
            // RLE coalescing: same src, same recipe fn, same dst ptr, contiguous offset
            if (self.deferred_count > 0) {
                const last = &self.deferred_ops[self.deferred_count - 1];
                if (last.src_collection_id == op.src_collection_id and
                    last.execute == op.execute and
                    last.dst_ptr == op.dst_ptr and
                    last.src_offset + last.count == op.src_offset)
                {
                    last.count += op.count;
                    return;
                }
            }
            if (self.deferred_count >= self.deferred_capacity) return error.QueueFull;

            self.deferred_ops[self.deferred_count] = op;
            self.deferred_count += 1;
        }

        fn opOrder(_: void, a: DeferredOp, b: DeferredOp) bool {
            if (a.src_collection_id != b.src_collection_id) return a.src_collection_id < b.src_collection_id;
            return a.src_offset < b.src_offset;
        }

        fn compIndex(comptime T: type) comptime_int {
            inline for (Universe.types, 0..) |U, i| {
                if (U == T) return i;
            }
            @compileError("Component " ++ @typeName(T) ++ " is not in the registry Universe");
        }

        /// The shadow field for component T inside one entity's struct.
        fn fatPtr(f: *Fat, comptime T: type) *T {
            return &@field(f, std.fmt.comptimePrint("c{d}", .{compIndex(T)}));
        }

        /// Bring an entity's header to its current generation, invalidating
        /// any previous generation's bytes in one write.
        fn freshHeader(f: *Fat, generation: u32) void {
            if (f.hdr.gen != generation) {
                f.hdr.gen = generation;
                f.hdr.written = 0;
            }
        }

        fn shadowBit(comptime T: type) u64 {
            return @as(u64, 1) << comptime compIndex(T);
        }

        /// Park a dropped component: the shadow field becomes the live copy.
        fn parkOne(self: *Self, comptime T: type, entity: Entity, value: T) void {
            const f = &self.fat_table[entity.index];
            freshHeader(f, entity.generation);
            f.hdr.written |= comptime shadowBit(T);
            fatPtr(f, T).* = value;
        }

        /// Unpark a gained component into its column slot: the parked value
        /// if this generation ever held one, the declared defaults otherwise.
        fn unparkOne(self: *Self, comptime T: type, entity: Entity, out: *T) void {
            const f = &self.fat_table[entity.index];
            if (f.hdr.gen == entity.generation and (f.hdr.written & comptime shadowBit(T)) != 0) {
                out.* = fatPtr(f, T).*;
            } else {
                row_mod.fillDefault(T, @as([*]T, @ptrCast(out))[0..1]);
            }
        }

        fn columnFn(comptime CollType: type, comptime T: type) ColumnFn {
            return &struct {
                fn f(raw: *anyopaque, offset: u32) [*]u8 {
                    const coll: *CollType = @ptrCast(@alignCast(raw));
                    return @ptrCast(&coll.column(T)[offset]);
                }
            }.f;
        }

        /// Comptime-generated move recipe for (SrcColl, DstColl) — copies
        /// shared components, parks dropped ones, unparks gained ones.
        /// Only instantiated if a move call site references this pair.
        fn moveRecipe(comptime SrcColl: type, comptime DstColl: type) *const fn (*Self, *anyopaque, *anyopaque, u32, u32) anyerror!void {
            const SrcRow = SrcColl.RowType;
            const DstRow = DstColl.RowType;

            const Shared = SrcRow.intersect(DstRow);
            const Dropped = SrcRow.subtract(&DstRow.types);
            const Gained = DstRow.subtract(&SrcRow.types);

            return &struct {
                fn execute(reg: *Self, src_raw: *anyopaque, dst_raw: *anyopaque, src_offset: u32, count: u32) anyerror!void {
                    const src_coll: *SrcColl = @ptrCast(@alignCast(src_raw));
                    const dst_coll: *DstColl = @ptrCast(@alignCast(dst_raw));

                    const dest_base = try dst_coll.reserveSlots(count);
                    const src_entities = src_coll.entitySlice();

                    @memcpy(
                        dst_coll.entitySlice()[dest_base .. dest_base + count],
                        src_entities[src_offset .. src_offset + count],
                    );

                    inline for (Shared.types) |T| {
                        if (comptime @sizeOf(T) > 0) {
                            @memcpy(
                                dst_coll.column(T)[dest_base .. dest_base + count],
                                src_coll.column(T)[src_offset .. src_offset + count],
                            );
                        }
                    }

                    inline for (Dropped.types) |T| {
                        if (comptime @sizeOf(T) > 0) {
                            for (0..count) |k| {
                                const entity = src_entities[src_offset + k];
                                reg.parkOne(T, entity, src_coll.column(T)[src_offset + k]);
                            }
                        }
                    }

                    inline for (Gained.types) |T| {
                        if (comptime @sizeOf(T) > 0) {
                            for (0..count) |k| {
                                const entity = src_entities[src_offset + k];
                                reg.unparkOne(T, entity, &dst_coll.column(T)[dest_base + k]);
                            }
                        }
                    }

                    for (0..count) |k| {
                        const entity = src_entities[src_offset + k];
                        const idx = entity.index;
                        reg.collection_ids[idx] = dst_coll.registry_id;
                        reg.offsets[idx] = dest_base + @as(u32, @intCast(k));
                        reg.flags[idx] &= ~PENDING_MOVE;
                    }

                    const moved = src_coll.removeRun(src_offset, count);
                    for (moved, 0..) |moved_entity, r| {
                        reg.offsets[moved_entity.index] = src_offset + @as(u32, @intCast(r));
                    }
                }
            }.execute;
        }

        /// Comptime-generated evict recipe: park the entity's whole row
        /// into the shadow and remove it from the collection. The typed
        /// half of eviction (insertion into a destination) lives in
        /// `evictImmediate`; this half is what gets type-erased so a
        /// foreign layer can extract without naming the collection.
        fn evictRecipe(comptime SrcColl: type) *const fn (*Self, *anyopaque, u32) void {
            return &struct {
                fn execute(reg: *Self, src_raw: *anyopaque, src_offset: u32) void {
                    const src_coll: *SrcColl = @ptrCast(@alignCast(src_raw));
                    const entity = src_coll.entitySlice()[src_offset];
                    inline for (SrcColl.RowType.types) |T| {
                        if (comptime @sizeOf(T) > 0) {
                            reg.parkOne(T, entity, src_coll.column(T)[src_offset]);
                        }
                    }
                    const moved = src_coll.removeRun(src_offset, 1);
                    for (moved) |m| reg.offsets[m.index] = src_offset;
                }
            }.execute;
        }

        /// Comptime-generated destroy recipe. No deinit hook: the shadow
        /// slots go stale by generation, so a reborn index reads defaults.
        fn destroyRecipe(comptime SrcColl: type) *const fn (*Self, *anyopaque, *anyopaque, u32, u32) anyerror!void {
            return &struct {
                fn execute(reg: *Self, src_raw: *anyopaque, _: *anyopaque, src_offset: u32, count: u32) anyerror!void {
                    const src_coll: *SrcColl = @ptrCast(@alignCast(src_raw));
                    const src_entities = src_coll.entitySlice();

                    for (0..count) |k| {
                        const entity = src_entities[src_offset + k];
                        const idx = entity.index;
                        reg.leaveAllSets(idx);
                        reg.generations[idx] += 1;
                        reg.collection_ids[idx] = 0;
                        reg.flags[idx] &= ~PENDING_MOVE;
                        reg.null_pool[reg.null_count] = .{ .index = idx, .generation = reg.generations[idx] };
                        reg.null_count += 1;
                    }

                    const moved = src_coll.removeRun(src_offset, count);
                    for (moved, 0..) |moved_entity, r| {
                        reg.offsets[moved_entity.index] = src_offset + @as(u32, @intCast(r));
                    }
                }
            }.execute;
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const Collection = collection_mod.Collection;

const Position = struct { x: f32 = 0, y: f32 = 0 };
const Velocity = struct { x: f32 = 0, y: f32 = 0 };
/// Non-zero declared default — the case where default-vs-garbage matters.
const Fdish = struct { fd: i32 = -1 };
const Tag = struct {};

const TestUniverse = Row(&.{ Position, Velocity, Fdish, Tag });
const TestReg = FatRegistry(TestUniverse);

fn testReg() !TestReg {
    return TestReg.init(testing.allocator, .{ .max_entities = 16 });
}

test "move is total — wide to narrow and back preserves the dropped value" {
    var reg = try testReg();
    defer reg.deinit();

    var wide = try Collection(Row(&.{ Position, Velocity }), .{}).init(testing.allocator);
    defer wide.deinit();
    reg.registerCollection(&wide, 1);

    var narrow = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer narrow.deinit();
    reg.registerCollection(&narrow, 2);

    const e = try reg.create(&wide);
    try reg.set(e, &wide, Velocity, .{ .x = 3, .y = 4 });
    try reg.set(e, &wide, Position, .{ .x = 1, .y = 2 });

    // Wide → narrow: Velocity is parked, not destroyed. This move is a
    // compile error in the archetype Registry.
    try reg.move(e, &wide, &narrow);
    try reg.flush();
    try testing.expectEqual(@as(u32, 0), wide.count);
    try testing.expectEqual(@as(u32, 1), narrow.count);
    try testing.expectEqual(@as(f32, 1), (try reg.get(e, &narrow, Position)).x);

    // Narrow → wide: Velocity is unparked with the value written before.
    try reg.move(e, &narrow, &wide);
    try reg.flush();
    const vel = try reg.get(e, &wide, Velocity);
    try testing.expectEqual(@as(f32, 3), vel.x);
    try testing.expectEqual(@as(f32, 4), vel.y);
}

test "gained component never held arrives with declared defaults" {
    var reg = try testReg();
    defer reg.deinit();

    var narrow = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer narrow.deinit();
    reg.registerCollection(&narrow, 1);

    var with_fd = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer with_fd.deinit();
    reg.registerCollection(&with_fd, 2);

    const e = try reg.create(&narrow);
    try reg.move(e, &narrow, &with_fd);
    try reg.flush();

    try testing.expectEqual(@as(i32, -1), (try reg.get(e, &with_fd, Fdish)).fd);
}

test "rebirth does not resurrect the predecessor's parked values" {
    var reg = try testReg();
    defer reg.deinit();

    var narrow = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer narrow.deinit();
    reg.registerCollection(&narrow, 1);

    var with_fd = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer with_fd.deinit();
    reg.registerCollection(&with_fd, 2);

    const e = try reg.create(&with_fd);
    try reg.set(e, &with_fd, Fdish, .{ .fd = 9 });
    try reg.move(e, &with_fd, &narrow); // parks fd = 9
    try reg.flush();
    try reg.destroy(e);
    try reg.flush();

    // The null pool is LIFO: the next create reuses e's index at gen+1.
    const reborn = try reg.create(&narrow);
    try testing.expectEqual(e.index, reborn.index);
    try testing.expect(reborn.generation != e.generation);

    try reg.move(reborn, &narrow, &with_fd);
    try reg.flush();
    try testing.expectEqual(@as(i32, -1), (try reg.get(reborn, &with_fd, Fdish)).fd);

    // And the dead handle is rejected everywhere.
    try testing.expectError(error.Stale, reg.getFat(e, Fdish));
}

test "getFat — resident resolves to the column" {
    var reg = try testReg();
    defer reg.deinit();

    var with_fd = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer with_fd.deinit();
    reg.registerCollection(&with_fd, 1);

    const e = try reg.create(&with_fd);
    try reg.set(e, &with_fd, Fdish, .{ .fd = 5 });

    const p = try reg.getFat(e, Fdish);
    try testing.expectEqual(@as(i32, 5), p.fd);
    try testing.expectEqual(try reg.get(e, &with_fd, Fdish), p);

    p.fd = 6;
    try testing.expectEqual(@as(i32, 6), (try reg.get(e, &with_fd, Fdish)).fd);
}

test "getFat — parked reads and writes the shadow, and the value rides home" {
    var reg = try testReg();
    defer reg.deinit();

    var with_fd = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer with_fd.deinit();
    reg.registerCollection(&with_fd, 1);

    var narrow = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer narrow.deinit();
    reg.registerCollection(&narrow, 2);

    const e = try reg.create(&with_fd);
    try reg.set(e, &with_fd, Fdish, .{ .fd = 5 });
    try reg.move(e, &with_fd, &narrow);
    try reg.flush();

    // Parked: getFat resolves the shadow slot, which holds the live copy.
    const p = try reg.getFat(e, Fdish);
    try testing.expectEqual(@as(i32, 5), p.fd);
    p.fd = 6;

    // The write is what the entity carries back into a column.
    try reg.move(e, &narrow, &with_fd);
    try reg.flush();
    try testing.expectEqual(@as(i32, 6), (try reg.get(e, &with_fd, Fdish)).fd);
}

test "getFat — virgin slot materializes declared defaults" {
    var reg = try testReg();
    defer reg.deinit();

    var narrow = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer narrow.deinit();
    reg.registerCollection(&narrow, 1);

    const e = try reg.create(&narrow);
    try testing.expectEqual(@as(i32, -1), (try reg.getFat(e, Fdish)).fd);
}

test "parked slot address is stable across unrelated churn" {
    var reg = try testReg();
    defer reg.deinit();

    var with_fd = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer with_fd.deinit();
    reg.registerCollection(&with_fd, 1);

    var narrow = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer narrow.deinit();
    reg.registerCollection(&narrow, 2);

    const a = try reg.create(&with_fd);
    try reg.set(a, &with_fd, Fdish, .{ .fd = 3 });
    try reg.move(a, &with_fd, &narrow);
    try reg.flush();

    const p = try reg.getFat(a, Fdish);

    // Churn both collections: creates, moves, swap-removes.
    const b = try reg.create(&with_fd);
    const c = try reg.create(&with_fd);
    try reg.move(b, &with_fd, &narrow);
    try reg.flush();
    try reg.destroy(c);
    try reg.flush();
    try reg.move(b, &narrow, &with_fd);
    try reg.flush();

    try testing.expectEqual(@as(i32, 3), p.fd);
    try testing.expectEqual(p, try reg.getFat(a, Fdish));
}

test "deferred batch — several entities move through one flush" {
    var reg = try testReg();
    defer reg.deinit();

    var narrow = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer narrow.deinit();
    reg.registerCollection(&narrow, 1);

    var wide = try Collection(Row(&.{ Position, Velocity }), .{}).init(testing.allocator);
    defer wide.deinit();
    reg.registerCollection(&wide, 2);

    var ents: [4]Entity = undefined;
    for (0..4) |i| {
        ents[i] = try reg.create(&narrow);
        try reg.set(ents[i], &narrow, Position, .{ .x = @floatFromInt(i), .y = 0 });
    }
    for (ents) |e| try reg.move(e, &narrow, &wide);
    try reg.flush();

    try testing.expectEqual(@as(u32, 0), narrow.count);
    try testing.expectEqual(@as(u32, 4), wide.count);
    for (ents, 0..) |e, i| {
        try testing.expectEqual(@as(f32, @floatFromInt(i)), (try reg.get(e, &wide, Position)).x);
        try testing.expectEqual(@as(f32, 0), (try reg.get(e, &wide, Velocity)).x);
    }
}

test "moveImmediate — total, lossless, visible this tick" {
    var reg = try testReg();
    defer reg.deinit();

    var wide = try Collection(Row(&.{ Position, Velocity }), .{}).init(testing.allocator);
    defer wide.deinit();
    reg.registerCollection(&wide, 1);

    var narrow = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer narrow.deinit();
    reg.registerCollection(&narrow, 2);

    const e = try reg.create(&wide);
    try reg.set(e, &wide, Velocity, .{ .x = 7, .y = 0 });

    try reg.moveImmediate(e, &wide, &narrow);
    try testing.expectEqual(@as(u32, 1), narrow.count);

    try reg.moveImmediate(e, &narrow, &wide);
    try testing.expectEqual(@as(f32, 7), (try reg.get(e, &wide, Velocity)).x);
}

test "ZST components ride moves and getFat" {
    var reg = try testReg();
    defer reg.deinit();

    var tagged = try Collection(Row(&.{ Position, Tag }), .{}).init(testing.allocator);
    defer tagged.deinit();
    reg.registerCollection(&tagged, 1);

    var plain = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer plain.deinit();
    reg.registerCollection(&plain, 2);

    const e = try reg.create(&tagged);
    try reg.move(e, &tagged, &plain);
    try reg.flush();
    try reg.move(e, &plain, &tagged);
    try reg.flush();
    _ = try reg.getFat(e, Tag);
    try testing.expectEqual(@as(u32, 1), tagged.count);
}

test "collectionIdOf — declared ids make membership readable and typed" {
    var reg = try testReg();
    defer reg.deinit();

    const PhaseColl = Collection(Row(&.{ Position, Fdish }), .{});
    // The consumer's declared namespace: a variant's value + 1 is the
    // registry id, the numbering rove-h2's collection enum uses. The
    // exhaustive switch is what makes recovery CHECKED: a new variant is
    // a compile error here, not a candidate list nobody updated.
    const Coll = enum(u8) { phase_a, phase_b };

    var pa = try PhaseColl.init(testing.allocator);
    defer pa.deinit();
    reg.registerCollection(&pa, @intFromEnum(Coll.phase_a) + 1);
    var pb = try PhaseColl.init(testing.allocator);
    defer pb.deinit();
    reg.registerCollection(&pb, @intFromEnum(Coll.phase_b) + 1);

    const resolve = struct {
        fn go(pa_: *PhaseColl, pb_: *PhaseColl, k: Coll) *PhaseColl {
            return switch (k) {
                .phase_a => pa_,
                .phase_b => pb_,
            };
        }
    }.go;

    const e = try reg.create(&pa);
    var k: Coll = @enumFromInt(reg.collectionIdOf(e).? - 1);
    try testing.expectEqual(Coll.phase_a, k);
    try testing.expectEqual(&pa, resolve(&pa, &pb, k));

    // Move through the recovered home — no candidate set anywhere.
    try reg.move(e, resolve(&pa, &pb, k), &pb);
    try reg.flush();
    k = @enumFromInt(reg.collectionIdOf(e).? - 1);
    try testing.expectEqual(Coll.phase_b, k);

    try reg.destroy(e);
    try reg.flush();
    try testing.expectEqual(@as(?u8, null), reg.collectionIdOf(e));
}

test "moveStripImmediate — the strip list parks instead of destroying" {
    var reg = try testReg();
    defer reg.deinit();

    var with_fd = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer with_fd.deinit();
    reg.registerCollection(&with_fd, 1);

    var narrow = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer narrow.deinit();
    reg.registerCollection(&narrow, 2);

    const e = try reg.create(&with_fd);
    try reg.set(e, &with_fd, Fdish, .{ .fd = 8 });

    // In the archetype registry this destroys the Fdish; here it parks.
    try reg.moveStripImmediate(e, &with_fd, &narrow, &.{Fdish});
    try testing.expectEqual(@as(i32, 8), (try reg.getFat(e, Fdish)).fd);

    try reg.moveImmediate(e, &narrow, &with_fd);
    try testing.expectEqual(@as(i32, 8), (try reg.get(e, &with_fd, Fdish)).fd);
}

test "getRow — one bundle spans materialized and parked components" {
    var reg = try testReg();
    defer reg.deinit();

    var with_fd = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer with_fd.deinit();
    reg.registerCollection(&with_fd, 1);

    var wide = try Collection(Row(&.{ Position, Fdish, Velocity }), .{}).init(testing.allocator);
    defer wide.deinit();
    reg.registerCollection(&wide, 2);

    const e = try reg.create(&with_fd);
    try reg.set(e, &with_fd, Fdish, .{ .fd = 4 });

    const v = try reg.getRow(e, Row(&.{ Position, Fdish, Velocity }));

    // Materialized members resolve to the columns (same pointers as get);
    // Velocity is not in the current row, so it resolves to the shadow
    // and reads as declared defaults.
    try testing.expectEqual(try reg.get(e, &with_fd, Position), v.at(Position));
    try testing.expectEqual(try reg.get(e, &with_fd, Fdish), v.at(Fdish));
    try testing.expectEqual(@as(i32, 4), v.at(Fdish).fd);
    try testing.expectEqual(@as(f32, 0), v.at(Velocity).x);

    // Writes through the view hit the live copy on both sides of the
    // split: the column write is visible to get, and the shadow write
    // rides into a column when the entity gains the component.
    v.at(Fdish).fd = 5;
    v.at(Velocity).* = .{ .x = 9, .y = 0 };
    try testing.expectEqual(@as(i32, 5), (try reg.get(e, &with_fd, Fdish)).fd);

    try reg.move(e, &with_fd, &wide);
    try reg.flush();
    try testing.expectEqual(@as(f32, 9), (try reg.get(e, &wide, Velocity)).x);
}

test "getRow — ZST members and stale handles" {
    var reg = try testReg();
    defer reg.deinit();

    var coll = try Collection(Row(&.{ Position, Tag }), .{}).init(testing.allocator);
    defer coll.deinit();
    reg.registerCollection(&coll, 1);

    const e = try reg.create(&coll);
    const v = try reg.getRow(e, Row(&.{ Position, Tag }));
    _ = v.at(Tag);
    try testing.expectEqual(try reg.get(e, &coll, Position), v.at(Position));

    try reg.destroy(e);
    try reg.flush();
    try testing.expectError(error.Stale, reg.getRow(e, Row(&.{Position})));
}

test "sets — membership is orthogonal to collections and survives moves" {
    var reg = try testReg();
    defer reg.deinit();

    var a = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer a.deinit();
    reg.registerCollection(&a, 1);
    var b = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer b.deinit();
    reg.registerCollection(&b, 2);

    var live = try EntitySet.init(testing.allocator, 16);
    defer live.deinit();
    reg.registerSet(&live, 0);

    const e = try reg.create(&a);
    try testing.expect(try reg.join(e, &live));
    try testing.expect(!try reg.join(e, &live)); // idempotent
    try testing.expectEqual(@as(u32, 1), live.count);
    try testing.expect(reg.inSet(e, &live));

    // Moves do not disturb secondary membership.
    try reg.move(e, &a, &b);
    try reg.flush();
    try testing.expect(reg.inSet(e, &live));
    try testing.expectEqual(@as(u32, 1), live.count);

    try testing.expect(try reg.leave(e, &live));
    try testing.expect(!try reg.leave(e, &live));
    try testing.expectEqual(@as(u32, 0), live.count);
}

test "sets — swap-remove keeps the dense list and sparse table agreeing" {
    var reg = try testReg();
    defer reg.deinit();

    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();
    reg.registerCollection(&coll, 1);
    var set = try EntitySet.init(testing.allocator, 16);
    defer set.deinit();
    reg.registerSet(&set, 0);

    var ents: [3]Entity = undefined;
    for (&ents) |*e| {
        e.* = try reg.create(&coll);
        _ = try reg.join(e.*, &set);
    }

    // Leave the middle member: the tail fills its slot.
    _ = try reg.leave(ents[1], &set);
    try testing.expectEqual(@as(u32, 2), set.count);
    try testing.expect(reg.inSet(ents[0], &set));
    try testing.expect(!reg.inSet(ents[1], &set));
    try testing.expect(reg.inSet(ents[2], &set));
    for (set.members()) |m| try testing.expect(!m.eql(ents[1]));
}

test "sets — destroy leaves every joined set, exactly" {
    var reg = try testReg();
    defer reg.deinit();

    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();
    reg.registerCollection(&coll, 1);

    var s0 = try EntitySet.init(testing.allocator, 16);
    defer s0.deinit();
    reg.registerSet(&s0, 0);
    var s1 = try EntitySet.init(testing.allocator, 16);
    defer s1.deinit();
    reg.registerSet(&s1, 5);

    const e = try reg.create(&coll);
    const bystander = try reg.create(&coll);
    _ = try reg.join(e, &s0);
    _ = try reg.join(e, &s1);
    _ = try reg.join(bystander, &s0);

    try reg.destroy(e);
    try reg.flush();

    try testing.expectEqual(@as(u32, 1), s0.count);
    try testing.expectEqual(@as(u32, 0), s1.count);
    try testing.expect(reg.inSet(bystander, &s0));

    // A reborn index is not a member of its predecessor's sets.
    const reborn = try reg.create(&coll);
    try testing.expectEqual(e.index, reborn.index);
    try testing.expect(!reg.inSet(reborn, &s0));
    try testing.expect(!reg.inSet(reborn, &s1));
}

test "evictImmediate — extract from a collection the caller cannot name" {
    var reg = try testReg();
    defer reg.deinit();

    // The "foreign" collection: the evicting code below never names its
    // type — extraction goes through the type-erased recipe by id.
    var foreign = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer foreign.deinit();
    reg.registerCollection(&foreign, 1);

    var home = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer home.deinit();
    reg.registerCollection(&home, 2);

    var set = try EntitySet.init(testing.allocator, 16);
    defer set.deinit();
    reg.registerSet(&set, 0);

    var ents: [3]Entity = undefined;
    for (&ents, 0..) |*e, i| {
        e.* = try reg.create(&foreign);
        try reg.set(e.*, &foreign, Fdish, .{ .fd = @intCast(i + 10) });
        _ = try reg.join(e.*, &set);
    }

    // Evict the middle entity: the whole row parks, the tail bystander
    // fills its slot, membership survives.
    try reg.evictImmediate(ents[1], &home);
    try testing.expectEqual(@as(u32, 2), foreign.count);
    try testing.expectEqual(@as(i32, 11), (try reg.get(ents[1], &home, Fdish)).fd);
    try testing.expectEqual(@as(i32, 10), (try reg.get(ents[0], &foreign, Fdish)).fd);
    try testing.expectEqual(@as(i32, 12), (try reg.get(ents[2], &foreign, Fdish)).fd);
    try testing.expect(reg.inSet(ents[1], &set));

    // Round trip through park: evict into a NARROW destination, the fd
    // stays parked, and rides home into a later gain.
    var narrow = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer narrow.deinit();
    reg.registerCollection(&narrow, 3);
    try reg.evictImmediate(ents[1], &narrow);
    try testing.expectEqual(@as(i32, 11), (try reg.getFat(ents[1], Fdish)).fd);
    try reg.moveImmediate(ents[1], &narrow, &home);
    try testing.expectEqual(@as(i32, 11), (try reg.get(ents[1], &home, Fdish)).fd);
}

test "evictImmediate — evict-to-self is refused; stale handles rejected" {
    var reg = try testReg();
    defer reg.deinit();

    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();
    reg.registerCollection(&coll, 1);
    var other = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer other.deinit();
    reg.registerCollection(&other, 2);

    const e = try reg.create(&coll);
    try testing.expectError(error.WrongCollection, reg.evictImmediate(e, &coll));

    try reg.destroy(e);
    try reg.flush();
    try testing.expectError(error.Stale, reg.evictImmediate(e, &other));
}

test "destroy — entity leaves, handle goes stale, pool refills" {
    var reg = try testReg();
    defer reg.deinit();

    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();
    reg.registerCollection(&coll, 1);

    const e = try reg.create(&coll);
    try reg.destroy(e);
    try reg.flush();

    try testing.expect(reg.isStale(e));
    try testing.expectEqual(@as(u32, 0), coll.count);
    try testing.expectError(error.Stale, reg.getFat(e, Position));
}

test "swap-remove bookkeeping — offsets stay correct after a middle move" {
    var reg = try testReg();
    defer reg.deinit();

    var src = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer src.deinit();
    reg.registerCollection(&src, 1);

    var dst = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer dst.deinit();
    reg.registerCollection(&dst, 2);

    var ents: [3]Entity = undefined;
    for (0..3) |i| {
        ents[i] = try reg.create(&src);
        try reg.set(ents[i], &src, Fdish, .{ .fd = @intCast(i + 10) });
    }

    // Move the middle one out; the tail entity fills its slot.
    try reg.moveImmediate(ents[1], &src, &dst);
    try testing.expectEqual(@as(i32, 10), (try reg.get(ents[0], &src, Fdish)).fd);
    try testing.expectEqual(@as(i32, 12), (try reg.get(ents[2], &src, Fdish)).fd);
    try testing.expectEqual(@as(i32, 11), (try reg.getFat(ents[1], Fdish)).fd);
}
