// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! FatRegistry — the fat-entity storage model every rove registry runs on.
//! The full argument, the measurements that carried the adoption, and the
//! prior art live in the design record
//! (docs/architecture/fat-entity-model.md); the locked decisions in
//! docs/decisions.md §17.
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
    @setEvalBranchQuota(1_000_000);
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

/// The membership-axis shape of a registry (the membership-axes design,
/// docs/architecture/fat-entity-model.md).
/// Axis 0 is the TOTAL axis (liveness): its record is the classic
/// `collection_ids`/`offsets` pair, 0 = the free pool, and every entity
/// always has a position on it. Axes 1..n are PARTIAL: 0 = "not on
/// this axis", and their records live in parallel per-axis arrays.
/// `comp_axis` maps each Universe component (by index) to the one axis
/// whose collections may materialize it — the emergent partition a
/// declared world derives; components in no collection map to 0 (their
/// reads never consult membership). The default is the single-axis
/// registry, which stores and executes exactly as it always has.
///
/// A pure membership set is the degenerate case: an EMPTY-ROW
/// collection on a one-state axis of its own. Its dense member list is
/// the collection's entity slice, the old sparse table is the axis's
/// offsets array, and destroy's exit-every-axis walk is what used to
/// be the per-set membership mask.
pub const AxesSpec = struct {
    n_axes: usize = 1,
    comp_axis: []const u8 = &.{},
    /// Identity axes (per axis; empty = none): memberships that say
    /// what the entity IS rather than what state it is in — they end
    /// only at explicit leave or destroy, and `moveOnly`/`evictOnly`
    /// leave them alone. Only a partial axis can be identity (the
    /// total axis is liveness itself).
    identity: []const bool = &.{},
};

/// `Universe` is a `Row` of every component type any registered collection
/// may carry — the comptime-closed component world. Collections whose row
/// is not covered by it are rejected at registration (comptime).
pub fn FatRegistry(comptime Universe: type) type {
    return FatRegistryAxes(Universe, .{});
}

/// The axis-shaped registry — see `AxesSpec`. `FatRegistry` is the
/// single-axis instantiation; a declared world passes its derived
/// partition.
pub fn FatRegistryAxes(comptime Universe: type, comptime axes_spec: AxesSpec) type {
    if (!@hasDecl(Universe, "types") or !@hasDecl(Universe, "len")) {
        @compileError("FatRegistry requires a Row type as its Universe");
    }
    comptime {
        if (axes_spec.comp_axis.len != 0 and axes_spec.comp_axis.len != Universe.len) {
            @compileError("FatRegistryAxes: comp_axis must be empty (all total-axis) or one entry per Universe component");
        }
        for (axes_spec.comp_axis) |ax| {
            if (ax >= axes_spec.n_axes) @compileError("FatRegistryAxes: comp_axis entry out of range");
        }
        if (axes_spec.identity.len != 0) {
            if (axes_spec.identity.len != axes_spec.n_axes)
                @compileError("FatRegistryAxes: identity must be empty or one entry per axis");
            if (axes_spec.identity[0])
                @compileError("FatRegistryAxes: the total axis cannot be an identity axis");
        }
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

        // Deferred queues (offset-keyed), ONE PER SOURCE COLLECTION,
        // plus the entity-keyed late queue: `evict`/`evictOnly` ops
        // whose source resolves at execute time, drained after every
        // offset-keyed batch. Per-source queues are what make the
        // swap-remove discipline structural: an op's recorded offsets
        // can be invalidated only by removals from its own source (an
        // execute's effect on its destination is append-only), so each
        // queue drains independently, highest offsets first, and no
        // cross-collection ordering exists to maintain. The dirty list
        // names the queues holding ops, so an empty flush — the common
        // call — stays one integer check and a drain visits only
        // queues with work, never the id space.
        //
        // Queues never refuse and never move: a source can hold at
        // most one op per resident entity (PENDING_MOVE admits one per
        // entity), so on its first deferred op a source's queue
        // RESERVES address space for max_entities ops in one anonymous
        // NORESERVE mmap — full-proof by construction — and the OS
        // backs pages on first touch, so physical memory is the
        // queue's high-water mark at page granularity. No realloc
        // means the array's address is stable for the registry's
        // lifetime, which is what lets the drain hold a slice across
        // op executes. There is no QueueFull; physical exhaustion is
        // the OS's overcommit to enforce, like every page-backed heap.
        queues: [MAX_COLLECTIONS]CollQueue,
        dirty: [MAX_COLLECTIONS]u8,
        dirty_member: [MAX_COLLECTIONS]bool,
        dirty_count: u32,
        deferred_total: u32,
        // True while flushBatch executes: enqueues that happen during a
        // batch must land as NEW ops for the next batch — coalescing
        // could extend an op the batch already executed, silently
        // dropping the extension.
        in_flush: bool,
        late_ops: []LateOp,
        late_count: u32,

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

        // Per-collection evict recipes — the type-erased extraction half
        // of evictImmediate, indexed by collection_id like destroy_recipes.
        evict_recipes: [MAX_COLLECTIONS]EvictEntry,

        // ── Partial membership axes (§4b) ──
        // Axis 0 is `collection_ids`/`offsets` above, untouched; each
        // partial axis k+1 records membership here. 0 = not on the axis.
        partial_ids: [n_partial][]u8,
        partial_offsets: [n_partial][]u32,
        // Which axis each registered collection id lives on — destroy
        // walks it to exit every axis, evict checks it against the
        // destination's.
        id_axis: [MAX_COLLECTIONS]u8,

        allocator: std.mem.Allocator,

        const n_partial = axes_spec.n_axes - 1;

        const PENDING_MOVE: u8 = 1;
        const MAX_COLLECTIONS: usize = 256;

        pub const Fat = ShadowStruct(Universe);

        const ColumnFn = *const fn (*anyopaque, u32) [*]u8;

        const DestroyEntry = struct {
            recipe: *const fn (*Self, *anyopaque, *anyopaque, u32, u32) anyerror!void,
            ptr: *anyopaque,
        };

        const EvictEntry = struct {
            recipe: *const fn (*Self, *anyopaque, u32) Entity,
            ptr: *anyopaque,
        };

        const LateOp = struct {
            entity: Entity,
            dst_ptr: *anyopaque,
            execute: *const fn (*Self, *anyopaque, Entity) void,
        };

        pub const DeferredOp = struct {
            src_offset: u32,
            count: u32,
            execute: *const fn (*Self, *anyopaque, *anyopaque, u32, u32) anyerror!void,
            src_ptr: *anyopaque,
            dst_ptr: *anyopaque,
        };

        /// One source collection's deferred queue. `ops` is reserved
        /// (mmap, max_entities capacity) on the collection's first
        /// deferred op and lives until registry deinit. `ascending`
        /// tracks whether appends arrived in offset order — the common
        /// case, since a system deferring as it iterates appends
        /// ascending — in which case the reverse drain walk needs no
        /// sort at all; a funnel-order append (entity-keyed callers
        /// hitting arbitrary offsets) clears it and that one queue
        /// sorts before draining.
        const CollQueue = struct {
            ops: []DeferredOp = &.{},
            count: u32 = 0,
            ascending: bool = true,
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

            // The shadow store rides reserved zero pages and is never
            // initialized: a zero header is gen 0 + empty mask, which
            // reads as "nothing written" for every generation, so a
            // fresh page IS a fresh slot. It is the registry's largest
            // table by far (the universe struct per entity), and this
            // is what keeps boot from committing it whole — physical
            // memory follows the entities that actually park. The
            // metadata arrays above stay on the heap: at bytes per
            // entity there is no memory worth reserving.
            const fat_table = try reserveTable(Fat, max);

            const column_fns = try allocator.alloc(?ColumnFn, MAX_COLLECTIONS * Universe.len);
            @memset(column_fns, null);

            var partial_ids: [n_partial][]u8 = undefined;
            var partial_offsets: [n_partial][]u32 = undefined;
            inline for (0..n_partial) |k| {
                partial_ids[k] = try allocator.alloc(u8, max);
                @memset(partial_ids[k], 0);
                partial_offsets[k] = try allocator.alloc(u32, max);
            }

            return .{
                .generations = generations,
                .collection_ids = collection_ids,
                .offsets = offsets,
                .flags = flags,
                .max_entities = max,
                .null_pool = null_pool,
                .null_count = max,
                .id_used = [_]bool{false} ** MAX_COLLECTIONS,
                .queues = [_]CollQueue{.{}} ** MAX_COLLECTIONS,
                .dirty = undefined,
                .dirty_member = [_]bool{false} ** MAX_COLLECTIONS,
                .dirty_count = 0,
                .deferred_total = 0,
                .in_flush = false,
                .late_ops = &.{},
                .late_count = 0,
                .fat_table = fat_table,
                .column_fns = column_fns,
                .coll_ptrs = [_]?*anyopaque{null} ** MAX_COLLECTIONS,
                .destroy_recipes = undefined,
                .evict_recipes = undefined,
                .partial_ids = partial_ids,
                .partial_offsets = partial_offsets,
                .id_axis = [_]u8{0} ** MAX_COLLECTIONS,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            inline for (0..n_partial) |k| {
                self.allocator.free(self.partial_ids[k]);
                self.allocator.free(self.partial_offsets[k]);
            }
            releaseTable(Fat, self.fat_table);
            self.allocator.free(self.column_fns);
            self.allocator.free(self.generations);
            self.allocator.free(self.collection_ids);
            self.allocator.free(self.offsets);
            self.allocator.free(self.flags);
            self.allocator.free(self.null_pool);
            for (&self.queues) |*q| {
                if (q.ops.len > 0) releaseTable(DeferredOp, q.ops);
            }
            if (self.late_ops.len > 0) self.allocator.free(self.late_ops);
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
            self.registerCollectionOnAxis(coll, declared_id, 0);
        }

        /// Register a collection onto a membership axis (§4b). Axis 0 is
        /// the total axis; a partial axis's collections record membership
        /// in that axis's arrays. Every component of the row must belong
        /// to the axis under `comp_axis` — the emergent partition a
        /// declared world derives and checks; re-checked here so a bare
        /// registry cannot register contested storage either.
        pub inline fn registerCollectionOnAxis(self: *Self, coll: anytype, declared_id: u8, comptime axis: u8) void {
            const CollType = @typeInfo(@TypeOf(coll)).pointer.child;
            comptime {
                if (axis >= axes_spec.n_axes) @compileError("registerCollectionOnAxis: axis out of range");
                if (axes_spec.comp_axis.len != 0) {
                    for (CollType.RowType.types) |T| {
                        const ci = blk: {
                            for (Universe.types, 0..) |U, i| {
                                if (U == T) break :blk i;
                            }
                            unreachable;
                        };
                        if (axes_spec.comp_axis[ci] != axis) @compileError(
                            "registerCollectionOnAxis: component " ++ @typeName(T) ++ " belongs to a different axis than this collection",
                        );
                    }
                }
            }
            comptime {
                @setEvalBranchQuota(1_000_000);
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
            coll.axis_index = axis;
            self.id_axis[declared_id] = axis;
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

            // A growable collection re-homes onto reserved storage at
            // the structural bound — no single collection can hold
            // more than max_entities entities — so it never
            // reallocates mid-tick and its column bases are stable for
            // the registry's lifetime. Fixed-capacity collections are
            // untouched (their error.Full is admission policy). See
            // `Collection.reserveMax`. Panic, not error: registration
            // is boot, and a half-registered layer must not run.
            coll.reserveMax(self.max_entities) catch
                std.debug.panic("fat registry: could not reserve collection storage at registration", .{});

            inline for (Universe.types, 0..) |T, ci| {
                if (comptime CollType.RowType.contains(T) and @sizeOf(T) > 0) {
                    self.column_fns[id * Universe.len + ci] = columnFn(CollType, T);
                }
            }
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
            // Birth is a total-axis event: position on the total axis
            // always exists, and a partial axis is entered later (§4c).
            if (comptime axes_spec.n_axes > 1) {
                if (dst.axis_index != 0) return error.WrongAxis;
            }
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
            return self.moveWith(entity, src, dst, false);
        }

        /// `move`, plus quiesce: when the op executes, the entity also
        /// leaves every non-identity partial axis other than the
        /// destination's — afterwards, dst (and any identity
        /// memberships) is all the entity is. The call site names no
        /// axes, so a state axis added later is dropped here without
        /// this site changing. Dropped memberships' rows PARK.
        pub inline fn moveOnly(self: *Self, entity: Entity, src: anytype, dst: anytype) !void {
            return self.moveWith(entity, src, dst, true);
        }

        inline fn moveWith(self: *Self, entity: Entity, src: anytype, dst: anytype, comptime only: bool) !void {
            const SrcColl = @typeInfo(@TypeOf(src)).pointer.child;
            const DstColl = @typeInfo(@TypeOf(dst)).pointer.child;
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;
            // A membership changes only within its axis (§4b). The flag
            // freezes the whole entity, not one axis — conservative, and
            // it keeps one flag byte.
            if (comptime axes_spec.n_axes > 1) {
                if (src.axis_index != dst.axis_index) return error.WrongAxis;
                // The deferred queue is a total-axis instrument: a
                // partial-axis membership mutates immediately (enter /
                // leave / moveImmediate). Keeping partial collections
                // out of the queue is what lets destroy's and
                // moveOnly's flush-time axis exits shift them without
                // invalidating any queued op's recorded offset.
                if (src.axis_index != 0) return error.DeferredPartialAxis;
            }
            if (self.axisIds(src.axis_index)[idx] != src.registry_id) return error.WrongCollection;

            const recipe = moveRecipe(SrcColl, DstColl, only);
            try self.enqueueOp(src.registry_id, .{
                .src_offset = self.axisOffsets(src.axis_index)[idx],
                .count = 1,
                .execute = recipe,
                .src_ptr = @ptrCast(src),
                .dst_ptr = @ptrCast(dst),
            });
            // Freeze AFTER the enqueue: a failed enqueue (allocator
            // exhaustion) must not leave the entity frozen with no
            // queued op to thaw it.
            self.flags[idx] |= PENDING_MOVE;
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
            if (comptime axes_spec.n_axes > 1) {
                if (src.axis_index != dst.axis_index) return error.WrongAxis;
            }
            const ax = src.axis_index;
            if (self.axisIds(ax)[idx] != src.registry_id) return error.WrongCollection;

            const src_offset = self.axisOffsets(ax)[idx];
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
                self.axisOffsets(ax)[moved_entity.index] = src_offset;
            }

            self.axisIds(ax)[idx] = dst.registry_id;
            self.axisOffsets(ax)[idx] = new_offset;
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
                @setEvalBranchQuota(1_000_000);
                const lost = SrcColl.RowType.subtract(&DstColl.RowType.types);
                if (!Row(strip).equal(lost)) {
                    @compileError("moveStripImmediate: strip list does not match the components the destination lacks");
                }
            }
            return self.moveImmediate(entity, src, dst);
        }

        // =============================================================
        // Partial-axis verbs (§4c)
        // =============================================================

        /// Enter a partial-axis collection: the Gained path with no
        /// source. Every component of the destination's row unparks —
        /// the parked value if this generation ever held one, declared
        /// defaults otherwise — so re-entering restores state
        /// (path-independence; a system wanting a fresh start resets
        /// before leaving). Total-axis membership starts at `create`,
        /// never here.
        pub inline fn enter(self: *Self, entity: Entity, dst: anytype) !void {
            const DstColl = @typeInfo(@TypeOf(dst)).pointer.child;
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;
            const ax = dst.axis_index;
            if (ax == 0) return error.WrongAxis;
            if (self.axisIds(ax)[idx] != 0) return error.AlreadyOnAxis;

            const off = try dst.reserveSlots(1);
            dst.entitySlice()[off] = entity;
            inline for (DstColl.RowType.types) |T| {
                if (comptime @sizeOf(T) > 0) {
                    self.unparkOne(T, entity, &dst.column(T)[off]);
                }
            }
            self.axisIds(ax)[idx] = dst.registry_id;
            self.axisOffsets(ax)[idx] = off;
        }

        /// Leave a partial axis — whichever collection holds the entity
        /// there: the Dropped path with no destination. The whole row
        /// PARKS (nothing is destroyed) through the type-erased evict
        /// recipe, so the caller does not name the collection. Returns
        /// false if the entity was not on the axis (idempotent, like
        /// set leave always was). The total axis has no leave — destroy
        /// is its only exit.
        pub inline fn leave(self: *Self, entity: Entity, ax: u8) !bool {
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;
            if (ax == 0 or ax >= axes_spec.n_axes) return error.WrongAxis;

            const id = self.axisIds(ax)[idx];
            if (id == 0) return false;
            const entry = self.evict_recipes[id];
            _ = entry.recipe(self, entry.ptr, self.axisOffsets(ax)[idx]);
            self.axisIds(ax)[idx] = 0;
            return true;
        }

        /// Is the entity on this axis? False for a stale handle.
        pub inline fn onAxis(self: *const Self, entity: Entity, ax: u8) bool {
            if (entity.index >= self.max_entities) return false;
            if (self.generations[entity.index] != entity.generation) return false;
            return @constCast(self).axisIds(ax)[entity.index] != 0;
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

            const entry = self.destroy_recipes[src_id];
            try self.enqueueOp(src_id, .{
                .src_offset = self.offsets[idx],
                .count = 1,
                .execute = entry.recipe,
                .src_ptr = entry.ptr,
                .dst_ptr = @ptrFromInt(1),
            });
            // Freeze AFTER the enqueue — see moveWith.
            self.flags[idx] |= PENDING_MOVE;
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
            while (self.deferred_total > 0 or self.late_count > 0) {
                try self.flushBatch();
                // Entity-keyed ops run after every offset-keyed batch:
                // by now any queued op for their entity has executed,
                // so resolving the source fresh is exact.
                var li: u32 = 0;
                while (li < self.late_count) : (li += 1) {
                    const op = self.late_ops[li];
                    op.execute(self, op.dst_ptr, op.entity);
                }
                self.late_count = 0;
            }
        }

        /// Drain every per-source queue. Each queue drains in reverse —
        /// highest offsets first, so a swap-remove only ever relocates a
        /// row whose op already executed. Queue order across sources is
        /// free: an op's recorded offsets can be invalidated only by
        /// removals from its own source collection (an execute touches
        /// its destination by append alone, which shifts nothing).
        /// Ops enqueued DURING execution land past the batch snapshot
        /// and run in a later lap; the outer loop re-laps the dirty
        /// list until nothing is pending, since executing one queue can
        /// refill an already-drained one.
        fn flushBatch(self: *Self) !void {
            self.in_flush = true;
            defer self.in_flush = false;
            while (self.deferred_total > 0) {
                var di: u32 = 0;
                // dirty_count can grow mid-lap; new entries are picked
                // up by this same walk.
                while (di < self.dirty_count) : (di += 1) {
                    const q = &self.queues[self.dirty[di]];
                    const batch = q.count;
                    if (batch == 0) continue;

                    // Holding this slice across executes is sound
                    // because the reserved array never moves: an
                    // enqueue during an execute appends past `batch`
                    // in place.
                    const ops = q.ops[0..batch];
                    if (batch > 1 and !q.ascending) {
                        std.mem.sort(DeferredOp, ops, {}, opOrder);
                    }

                    var i = batch;
                    while (i > 0) {
                        i -= 1;
                        const op = ops[i];
                        try op.execute(self, op.src_ptr, op.dst_ptr, op.src_offset, op.count);
                    }

                    const new_count = q.count - batch;
                    if (new_count > 0) {
                        std.mem.copyForwards(DeferredOp, q.ops[0..new_count], q.ops[batch .. batch + new_count]);
                    }
                    q.count = new_count;
                    q.ascending = ascendingRun(q.ops[0..new_count]);
                    self.deferred_total -= batch;
                }
            }
            // Everything drained: retire the dirty set in one pass.
            for (self.dirty[0..self.dirty_count]) |id| self.dirty_member[id] = false;
            self.dirty_count = 0;
        }

        // =============================================================
        // Queries
        // =============================================================

        /// Ops queued for the next flush — offset-keyed (all source
        /// queues) and entity-keyed both. The empty-queue preconditions
        /// (teardown sweeps) check this, not the offset-keyed total alone.
        pub fn pendingOpCount(self: *const Self) u32 {
            return self.deferred_total + self.late_count;
        }

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
            return @constCast(self).axisIds(coll.axis_index)[entity.index] == coll.registry_id;
        }

        /// Read a component through a known collection — the dense-path
        /// accessor, identical to `Registry.get`.
        pub inline fn get(self: *Self, entity: Entity, coll: anytype, comptime T: type) !*T {
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.axisIds(coll.axis_index)[idx] != coll.registry_id) return error.WrongCollection;
            return &coll.column(T)[self.axisOffsets(coll.axis_index)[idx]];
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
            // The component's owning axis (comptime): its collections may
            // live only there, so one membership lookup answers.
            const ax: u8 = comptime if (axes_spec.comp_axis.len == 0) 0 else axes_spec.comp_axis[ci];
            const id: usize = self.axisIds(ax)[idx];
            if (id != 0) {
                if (self.column_fns[id * Universe.len + ci]) |f| {
                    return @ptrCast(@alignCast(f(self.coll_ptrs[id].?, self.axisOffsets(ax)[idx])));
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

        /// Call-site-compatible `getAny`: resolve T through a bounded
        /// candidate tuple. Under the fat model `getFat` answers without
        /// candidates and is usually what new code wants; this exists so
        /// call sites written against the archetype registry — candidate
        /// sets over collections whose rows genuinely diverge — compile
        /// unchanged. Semantics match the archetype's: error if the
        /// entity is in none of the candidates.
        pub inline fn getAny(self: *Self, entity: Entity, colls: anytype, comptime T: type) !*T {
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;

            inline for (@typeInfo(@TypeOf(colls)).@"struct".fields) |field| {
                const coll = @field(colls, field.name);
                if (self.axisIds(coll.axis_index)[idx] == coll.registry_id) {
                    return &coll.column(T)[self.axisOffsets(coll.axis_index)[idx]];
                }
            }
            return error.WrongCollection;
        }

        /// Call-site-compatible `moveAny`: move to `dst` from whichever
        /// of `sources` currently holds the entity. No row-subset
        /// requirement (moves are total); the tuple's only job is
        /// naming which sources the call site expects — an entity in
        /// none of them is an error, exactly as under the archetype.
        pub inline fn moveAny(self: *Self, entity: Entity, sources: anytype, dst: anytype) !void {
            return self.moveAnyWith(entity, sources, dst, false);
        }

        /// `moveAny` with `moveOnly`'s quiesce — the candidate-tuple
        /// flavor for a call site that cannot name the source but must
        /// end with dst as the entity's only non-identity membership.
        pub inline fn moveAnyOnly(self: *Self, entity: Entity, sources: anytype, dst: anytype) !void {
            return self.moveAnyWith(entity, sources, dst, true);
        }

        inline fn moveAnyWith(self: *Self, entity: Entity, sources: anytype, dst: anytype, comptime only: bool) !void {
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;

            const DstColl = @typeInfo(@TypeOf(dst)).pointer.child;

            inline for (@typeInfo(@TypeOf(sources)).@"struct".fields) |field| {
                const src = @field(sources, field.name);
                const SrcColl = @typeInfo(@TypeOf(src)).pointer.child;
                if (self.axisIds(src.axis_index)[idx] == src.registry_id) {
                    if (comptime axes_spec.n_axes > 1) {
                        if (src.axis_index != dst.axis_index) return error.WrongAxis;
                        // Same total-axis-only rule as `move` — see there.
                        if (src.axis_index != 0) return error.DeferredPartialAxis;
                    }
                    const recipe = moveRecipe(SrcColl, DstColl, only);
                    try self.enqueueOp(src.registry_id, .{
                        .src_offset = self.axisOffsets(src.axis_index)[idx],
                        .count = 1,
                        .execute = recipe,
                        .src_ptr = @ptrCast(src),
                        .dst_ptr = @ptrCast(dst),
                    });
                    // Freeze AFTER the enqueue — see moveWith.
                    self.flags[idx] |= PENDING_MOVE;
                    return;
                }
            }
            return error.WrongCollection;
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
            // The destination's axis names which membership is being
            // rewritten; the erased source is whatever collection holds
            // the entity THERE.
            const ax = dst.axis_index;
            const src_id = self.axisIds(ax)[idx];
            if (src_id == 0) return error.InvalidEntity;
            if (src_id == dst.registry_id) return error.WrongCollection;

            const new_offset = try dst.reserveSlots(1);

            const entry = self.evict_recipes[src_id];
            _ = entry.recipe(self, entry.ptr, self.axisOffsets(ax)[idx]);

            dst.entitySlice()[new_offset] = entity;
            inline for (DstColl.RowType.types) |T| {
                if (comptime @sizeOf(T) > 0) {
                    self.unparkOne(T, entity, &dst.column(T)[new_offset]);
                }
            }
            self.axisIds(ax)[idx] = dst.registry_id;
            self.axisOffsets(ax)[idx] = new_offset;
        }

        /// `evictImmediate`, plus quiesce: the entity also leaves every
        /// non-identity partial axis other than the destination's —
        /// the erased-source flavor of `moveOnly`, for a layer ending
        /// an entity it cannot name the holder of (the teardown
        /// sweep). Dropped memberships' rows PARK.
        pub inline fn evictOnlyImmediate(self: *Self, entity: Entity, dst: anytype) !void {
            try self.evictImmediate(entity, dst);
            self.leaveOtherAxes(entity.index, dst.axis_index);
        }

        /// Deferred, ENTITY-KEYED evict: "wherever this entity is —
        /// even after any op already queued for it — it ends up in
        /// dst." Unlike the offset-keyed queue, the source resolves at
        /// EXECUTE time, in a second pass after the offset-keyed batch,
        /// so a pending move completes first and the eviction extracts
        /// from wherever the entity landed. That makes this the one
        /// mutation verb that never refuses a moving entity — an
        /// ENDING verb must not be refusable, or callers grow silent
        /// `catch {}` drops and retry machinery. Tolerant at execute:
        /// an entity that died, or already sits in dst, is skipped.
        /// dst must be on the total axis (the deferred queue's rule).
        pub inline fn evict(self: *Self, entity: Entity, dst: anytype) !void {
            return self.evictLate(entity, dst, false);
        }

        /// `evict` with `moveOnly`'s quiesce: on execute the entity
        /// also leaves every non-identity partial axis.
        pub inline fn evictOnly(self: *Self, entity: Entity, dst: anytype) !void {
            return self.evictLate(entity, dst, true);
        }

        inline fn evictLate(self: *Self, entity: Entity, dst: anytype, comptime only: bool) !void {
            const DstColl = @typeInfo(@TypeOf(dst)).pointer.child;
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (comptime axes_spec.n_axes > 1) {
                if (dst.axis_index != 0) return error.DeferredPartialAxis;
            }
            if (self.late_count >= self.late_ops.len) try self.growLateQueue();
            self.late_ops[self.late_count] = .{
                .entity = entity,
                .dst_ptr = @ptrCast(dst),
                .execute = lateEvictRecipe(DstColl, only),
            };
            self.late_count += 1;
            // No PENDING check — tolerance for moving entities is the
            // point. Freeze the entity if it is not already frozen,
            // AFTER the append so a failed grow leaves it unfrozen.
            self.flags[idx] |= PENDING_MOVE;
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

        /// The membership-id array of an axis: 0 = collection_ids (the
        /// total axis), k>0 = that partial axis's. Comptime-folds to the
        /// classic fields on a single-axis registry, so that case costs
        /// nothing new.
        inline fn axisIds(self: *Self, ax: u8) []u8 {
            if (comptime axes_spec.n_axes == 1) return self.collection_ids;
            return if (ax == 0) self.collection_ids else self.partial_ids[ax - 1];
        }

        inline fn axisOffsets(self: *Self, ax: u8) []u32 {
            if (comptime axes_spec.n_axes == 1) return self.offsets;
            return if (ax == 0) self.offsets else self.partial_offsets[ax - 1];
        }

        const identity_axes: [axes_spec.n_axes]bool = blk: {
            var out: [axes_spec.n_axes]bool = @splat(false);
            for (axes_spec.identity, 0..) |b, i| out[i] = b;
            break :blk out;
        };

        /// Exit every non-identity partial axis other than `keep_ax` —
        /// the quiesce half of `moveOnly`/`evictOnly`. Direct (no
        /// stale/flag checks: callers own them), through the same
        /// type-erased evict recipes destroy's axis walk uses, so each
        /// dropped membership's row PARKS rather than being destroyed.
        fn leaveOtherAxes(self: *Self, idx: u32, keep_ax: u8) void {
            if (comptime axes_spec.n_axes == 1) return;
            for (1..axes_spec.n_axes) |ax_usize| {
                const ax: u8 = @intCast(ax_usize);
                if (ax == keep_ax) continue;
                if (identity_axes[ax]) continue;
                const id = self.axisIds(ax)[idx];
                if (id == 0) continue;
                const e = self.evict_recipes[id];
                _ = e.recipe(self, e.ptr, self.axisOffsets(ax)[idx]);
                self.axisIds(ax)[idx] = 0;
            }
        }

        fn enqueueOp(self: *Self, src_id: u8, op: DeferredOp) !void {
            const q = &self.queues[src_id];
            if (q.count > 0) {
                const last = &q.ops[q.count - 1];
                // RLE coalescing against this source's tail: same recipe
                // fn, same dst ptr, contiguous offset. Suppressed while a
                // flush executes — the tail may be an op the batch already
                // ran, and extending it would drop the extension.
                if (!self.in_flush and
                    last.execute == op.execute and
                    last.dst_ptr == op.dst_ptr and
                    last.src_offset + last.count == op.src_offset)
                {
                    last.count += op.count;
                    return;
                }
                if (op.src_offset < last.src_offset) q.ascending = false;
            }
            // The 0 >= 0 case is the reservation trigger: a source's
            // queue reserves on its first deferred op, so the common
            // append pays no emptiness check of its own. After the
            // reservation this branch is dead — the queue's capacity is
            // the structural maximum (one op per resident entity).
            if (q.count >= q.ops.len) try self.reserveQueue(q);

            q.ops[q.count] = op;
            q.count += 1;
            self.deferred_total += 1;
            if (!self.dirty_member[src_id]) {
                self.dirty_member[src_id] = true;
                self.dirty[self.dirty_count] = src_id;
                self.dirty_count += 1;
            }
        }

        fn growLateQueue(self: *Self) error{OutOfMemory}!void {
            @branchHint(.cold);
            self.late_ops = if (self.late_ops.len == 0)
                try self.allocator.alloc(LateOp, 16)
            else
                try self.allocator.realloc(self.late_ops, self.late_ops.len * 2);
        }

        /// The byte view of a queue's reserved region, as mmap'd —
        /// what munmap needs back.
        /// Reserve an entity-indexed table: `n` elements of T in one
        /// anonymous NORESERVE mapping. The OS backs pages on first
        /// touch and every page starts zero, so a table whose zero
        /// element means "fresh" needs no init pass at all and costs
        /// physical memory only where entities have actually reached —
        /// the whole shadow store rides on this. The mapping never
        /// moves for the registry's lifetime.
        fn reserveTable(comptime T: type, n: usize) error{OutOfMemory}![]T {
            const bytes = std.posix.mmap(
                null,
                n * @sizeOf(T),
                std.posix.PROT.READ | std.posix.PROT.WRITE,
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
                -1,
                0,
            ) catch return error.OutOfMemory;
            // Hugepage-eligible: the table is walked by entity index, so
            // 2 MiB pages cut TLB misses across the registry; under
            // NORESERVE only the huge pages actually touched commit.
            // Advisory — a kernel that declines leaves the mapping as is.
            _ = std.os.linux.madvise(bytes.ptr, bytes.len, std.os.linux.MADV.HUGEPAGE);
            return @as([*]T, @ptrCast(@alignCast(bytes.ptr)))[0..n];
        }

        fn releaseTable(comptime T: type, table: []T) void {
            const p: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(table.ptr));
            std.posix.munmap(p[0 .. table.len * @sizeOf(T)]);
        }

        /// Reserve a source's queue at the structural maximum: one op
        /// per resident entity ⇒ max_entities. Physical cost is the
        /// queue's high-water mark at page granularity.
        fn reserveQueue(self: *Self, q: *CollQueue) error{OutOfMemory}!void {
            @branchHint(.cold);
            q.ops = try reserveTable(DeferredOp, self.max_entities);
        }

        fn opOrder(_: void, a: DeferredOp, b: DeferredOp) bool {
            return a.src_offset < b.src_offset;
        }

        /// True when the ops sit in non-descending offset order — the
        /// reverse drain walk then already runs highest-first with no
        /// sort. (Equal offsets cannot occur: PENDING_MOVE refuses a
        /// second offset-keyed op for a frozen entity.)
        fn ascendingRun(ops: []const DeferredOp) bool {
            var i: usize = 1;
            while (i < ops.len) : (i += 1) {
                if (ops[i].src_offset < ops[i - 1].src_offset) return false;
            }
            return true;
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
        fn moveRecipe(comptime SrcColl: type, comptime DstColl: type, comptime only: bool) *const fn (*Self, *anyopaque, *anyopaque, u32, u32) anyerror!void {
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

                    // Same-axis by the verbs' check; the axis is read
                    // off the destination at execute time.
                    const ax = dst_coll.axis_index;
                    for (0..count) |k| {
                        const entity = src_entities[src_offset + k];
                        const idx = entity.index;
                        reg.axisIds(ax)[idx] = dst_coll.registry_id;
                        reg.axisOffsets(ax)[idx] = dest_base + @as(u32, @intCast(k));
                        reg.flags[idx] &= ~PENDING_MOVE;
                        // moveOnly's quiesce, at execute time — after the
                        // bookkeeping, so the leaves see a settled entity.
                        if (comptime only) reg.leaveOtherAxes(idx, ax);
                    }

                    const moved = src_coll.removeRun(src_offset, count);
                    for (moved, 0..) |moved_entity, r| {
                        reg.axisOffsets(ax)[moved_entity.index] = src_offset + @as(u32, @intCast(r));
                    }
                }
            }.execute;
        }

        /// Comptime-generated evict recipe: park the entity's whole row
        /// into the shadow and remove it from the collection. The typed
        /// half of eviction (insertion into a destination) lives in
        /// `evictImmediate`; this half is what gets type-erased so a
        /// foreign layer can extract without naming the collection.
        fn evictRecipe(comptime SrcColl: type) *const fn (*Self, *anyopaque, u32) Entity {
            return &struct {
                fn execute(reg: *Self, src_raw: *anyopaque, src_offset: u32) Entity {
                    const src_coll: *SrcColl = @ptrCast(@alignCast(src_raw));
                    const entity = src_coll.entitySlice()[src_offset];
                    inline for (SrcColl.RowType.types) |T| {
                        if (comptime @sizeOf(T) > 0) {
                            reg.parkOne(T, entity, src_coll.column(T)[src_offset]);
                        }
                    }
                    const moved = src_coll.removeRun(src_offset, 1);
                    for (moved) |m| reg.axisOffsets(src_coll.axis_index)[m.index] = src_offset;
                    return entity;
                }
            }.execute;
        }

        /// Execute half of the entity-keyed deferred evict: resolve the
        /// entity's collection NOW (any offset-keyed op for it already
        /// ran), extract through its type-erased evict recipe, insert
        /// into the typed destination. Skips — clearing the freeze —
        /// when the entity died or already sits in dst: an ending op
        /// arriving after the end is not an error.
        fn lateEvictRecipe(comptime DstColl: type, comptime only: bool) *const fn (*Self, *anyopaque, Entity) void {
            return &struct {
                fn execute(reg: *Self, dst_raw: *anyopaque, entity: Entity) void {
                    const dst: *DstColl = @ptrCast(@alignCast(dst_raw));
                    const idx = entity.index;
                    if (reg.generations[idx] != entity.generation) return;
                    const ax = dst.axis_index;
                    const src_id = reg.axisIds(ax)[idx];
                    if (src_id == 0 or src_id == dst.registry_id) {
                        reg.flags[idx] &= ~PENDING_MOVE;
                        return;
                    }
                    // Reserve first — the no-limbo discipline: a failed
                    // grow may not leave the entity collection-less. It
                    // is a tiny allocation on the ending path; failing
                    // it means the process is done, and failing LOUD
                    // beats an entity that silently never ends.
                    const new_offset = dst.reserveSlots(1) catch
                        std.debug.panic("fat registry: deferred evict could not reserve a slot in the destination", .{});
                    const entry = reg.evict_recipes[src_id];
                    _ = entry.recipe(reg, entry.ptr, reg.axisOffsets(ax)[idx]);
                    dst.entitySlice()[new_offset] = entity;
                    inline for (DstColl.RowType.types) |T| {
                        if (comptime @sizeOf(T) > 0) {
                            reg.unparkOne(T, entity, &dst.column(T)[new_offset]);
                        }
                    }
                    reg.axisIds(ax)[idx] = dst.registry_id;
                    reg.axisOffsets(ax)[idx] = new_offset;
                    reg.flags[idx] &= ~PENDING_MOVE;
                    if (comptime only) reg.leaveOtherAxes(idx, ax);
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
                        // Exit every partial axis first — like sets, no
                        // axis may hold a dead entity. The evict recipe
                        // does the removal (its parks are dead bytes the
                        // generation bump below invalidates).
                        if (comptime n_partial > 0) {
                            for (1..axes_spec.n_axes) |ax_usize| {
                                const ax: u8 = @intCast(ax_usize);
                                const pid = reg.axisIds(ax)[idx];
                                if (pid != 0) {
                                    const pe = reg.evict_recipes[pid];
                                    _ = pe.recipe(reg, pe.ptr, reg.axisOffsets(ax)[idx]);
                                    reg.axisIds(ax)[idx] = 0;
                                }
                            }
                        }
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

test "deferred batch — scrambled enqueue order sorts per source" {
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
    // Funnel-order enqueue: offsets 1, 3, 0, 2 — non-ascending, so the
    // queue must sort before its reverse drain walk.
    for ([_]usize{ 1, 3, 0, 2 }) |i| try reg.move(ents[i], &narrow, &wide);
    try reg.flush();

    try testing.expectEqual(@as(u32, 0), narrow.count);
    try testing.expectEqual(@as(u32, 4), wide.count);
    for (ents, 0..) |e, i| {
        try testing.expectEqual(@as(f32, @floatFromInt(i)), (try reg.get(e, &wide, Position)).x);
    }
}

test "deferred batch — interleaved sources drain independently in one flush" {
    var reg = try testReg();
    defer reg.deinit();

    var left = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer left.deinit();
    reg.registerCollection(&left, 1);

    var right = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer right.deinit();
    reg.registerCollection(&right, 2);

    var sink = try Collection(Row(&.{ Position, Velocity }), .{}).init(testing.allocator);
    defer sink.deinit();
    reg.registerCollection(&sink, 3);

    var ls: [3]Entity = undefined;
    var rs: [3]Entity = undefined;
    for (0..3) |i| {
        ls[i] = try reg.create(&left);
        try reg.set(ls[i], &left, Position, .{ .x = @floatFromInt(i), .y = 1 });
        rs[i] = try reg.create(&right);
        try reg.set(rs[i], &right, Position, .{ .x = @floatFromInt(i), .y = 2 });
    }
    // Alternate sources on enqueue — the funnel-verb pattern.
    for (ls, rs) |l, r| {
        try reg.move(l, &left, &sink);
        try reg.move(r, &right, &sink);
    }
    try reg.flush();

    try testing.expectEqual(@as(u32, 0), left.count);
    try testing.expectEqual(@as(u32, 0), right.count);
    try testing.expectEqual(@as(u32, 6), sink.count);
    try testing.expectEqual(@as(u32, 0), reg.pendingOpCount());
    for (ls, 0..) |e, i| {
        const p = try reg.get(e, &sink, Position);
        try testing.expectEqual(@as(f32, @floatFromInt(i)), p.x);
        try testing.expectEqual(@as(f32, 1), p.y);
    }
    for (rs, 0..) |e, i| {
        const p = try reg.get(e, &sink, Position);
        try testing.expectEqual(@as(f32, @floatFromInt(i)), p.x);
        try testing.expectEqual(@as(f32, 2), p.y);
    }
}

test "deferred queue reserves the structural maximum on first use" {
    var reg = try TestReg.init(testing.allocator, .{ .max_entities = 64 });
    defer reg.deinit();

    var a = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer a.deinit();
    reg.registerCollection(&a, 1);
    var sink = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer sink.deinit();
    reg.registerCollection(&sink, 2);

    // No queue memory before the first deferred op.
    try testing.expectEqual(@as(usize, 0), reg.queues[1].ops.len);

    // Enqueue in pair-swapped order (1,0, 3,2, …) so RLE coalescing
    // absorbs nothing and every move is its own op — one op per
    // resident entity, the bound the reservation is sized to.
    var as: [24]Entity = undefined;
    for (&as, 0..) |*e, i| {
        e.* = try reg.create(&a);
        try reg.set(e.*, &a, Position, .{ .x = @floatFromInt(i), .y = 0 });
    }
    var i: usize = 0;
    while (i < as.len) : (i += 2) {
        try reg.move(as[i + 1], &a, &sink);
        try reg.move(as[i], &a, &sink);
    }
    // The first op reserved capacity for every entity at once.
    try testing.expectEqual(@as(usize, 64), reg.queues[1].ops.len);
    try reg.flush();
    try testing.expectEqual(@as(u32, 0), a.count);
    for (as, 0..) |e, k| {
        try testing.expectEqual(@as(f32, @floatFromInt(k)), (try reg.get(e, &sink, Position)).x);
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

test "one-state axes — membership is orthogonal to collections and survives moves" {
    var reg = try FatRegistryAxes(TestUniverse, .{ .n_axes = 2 }).init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    var a = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer a.deinit();
    reg.registerCollection(&a, 1);
    var b = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer b.deinit();
    reg.registerCollection(&b, 2);

    // The set, post-merge: an empty-row collection on its own one-state
    // axis. The dense member list IS the collection's entity slice; the
    // old sparse table lives in the axis offsets.
    var live = try Collection(Row(&.{}), .{}).init(testing.allocator);
    defer live.deinit();
    reg.registerCollectionOnAxis(&live, 3, 1);

    const e = try reg.create(&a);
    try reg.enter(e, &live);
    try testing.expectError(error.AlreadyOnAxis, reg.enter(e, &live));
    try testing.expectEqual(@as(u32, 1), live.count);
    try testing.expect(reg.onAxis(e, 1));

    // Total-axis moves do not disturb the orthogonal membership.
    try reg.move(e, &a, &b);
    try reg.flush();
    try testing.expect(reg.onAxis(e, 1));
    try testing.expectEqual(@as(u32, 1), live.count);

    try testing.expect(try reg.leave(e, 1));
    try testing.expect(!try reg.leave(e, 1));
    try testing.expectEqual(@as(u32, 0), live.count);
}

test "one-state axes — swap-remove keeps the member list and offsets agreeing" {
    var reg = try FatRegistryAxes(TestUniverse, .{ .n_axes = 2 }).init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();
    reg.registerCollection(&coll, 1);
    var set = try Collection(Row(&.{}), .{}).init(testing.allocator);
    defer set.deinit();
    reg.registerCollectionOnAxis(&set, 2, 1);

    var ents: [3]Entity = undefined;
    for (&ents) |*e| {
        e.* = try reg.create(&coll);
        try reg.enter(e.*, &set);
    }

    // Leave the middle member: the tail fills its slot.
    _ = try reg.leave(ents[1], 1);
    try testing.expectEqual(@as(u32, 2), set.count);
    try testing.expect(reg.onAxis(ents[0], 1));
    try testing.expect(!reg.onAxis(ents[1], 1));
    try testing.expect(reg.onAxis(ents[2], 1));
    for (set.entitySlice()) |m| try testing.expect(!m.eql(ents[1]));
}

test "one-state axes — destroy exits every axis, exactly" {
    var reg = try FatRegistryAxes(TestUniverse, .{ .n_axes = 3 }).init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();
    reg.registerCollection(&coll, 1);

    var s0 = try Collection(Row(&.{}), .{}).init(testing.allocator);
    defer s0.deinit();
    reg.registerCollectionOnAxis(&s0, 2, 1);
    var s1 = try Collection(Row(&.{}), .{}).init(testing.allocator);
    defer s1.deinit();
    reg.registerCollectionOnAxis(&s1, 3, 2);

    const e = try reg.create(&coll);
    const bystander = try reg.create(&coll);
    try reg.enter(e, &s0);
    try reg.enter(e, &s1);
    try reg.enter(bystander, &s0);

    try reg.destroy(e);
    try reg.flush();

    try testing.expectEqual(@as(u32, 1), s0.count);
    try testing.expectEqual(@as(u32, 0), s1.count);
    try testing.expect(reg.onAxis(bystander, 1));

    // A reborn index is not a member of its predecessor's axes.
    const reborn = try reg.create(&coll);
    try testing.expectEqual(e.index, reborn.index);
    try testing.expect(!reg.onAxis(reborn, 1));
    try testing.expect(!reg.onAxis(reborn, 2));
}

test "evictImmediate — extract from a collection the caller cannot name" {
    var reg = try FatRegistryAxes(TestUniverse, .{ .n_axes = 2 }).init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    // The "foreign" collection: the evicting code below never names its
    // type — extraction goes through the type-erased recipe by id.
    var foreign = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer foreign.deinit();
    reg.registerCollection(&foreign, 1);

    var home = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer home.deinit();
    reg.registerCollection(&home, 2);

    var set = try Collection(Row(&.{}), .{}).init(testing.allocator);
    defer set.deinit();
    reg.registerCollectionOnAxis(&set, 4, 1);

    var ents: [3]Entity = undefined;
    for (&ents, 0..) |*e, i| {
        e.* = try reg.create(&foreign);
        try reg.set(e.*, &foreign, Fdish, .{ .fd = @intCast(i + 10) });
        try reg.enter(e.*, &set);
    }

    // Evict the middle entity: the whole row parks, the tail bystander
    // fills its slot, membership survives.
    try reg.evictImmediate(ents[1], &home);
    try testing.expectEqual(@as(u32, 2), foreign.count);
    try testing.expectEqual(@as(i32, 11), (try reg.get(ents[1], &home, Fdish)).fd);
    try testing.expectEqual(@as(i32, 10), (try reg.get(ents[0], &foreign, Fdish)).fd);
    try testing.expectEqual(@as(i32, 12), (try reg.get(ents[2], &foreign, Fdish)).fd);
    try testing.expect(reg.onAxis(ents[1], 1));

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

test "getAny and moveAny — candidate-tuple compat over fat storage" {
    var reg = try testReg();
    defer reg.deinit();

    var a = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer a.deinit();
    reg.registerCollection(&a, 1);
    var b = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer b.deinit();
    reg.registerCollection(&b, 2);
    var dst = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator);
    defer dst.deinit();
    reg.registerCollection(&dst, 3);

    const e = try reg.create(&a);
    try reg.set(e, &a, Fdish, .{ .fd = 6 });

    // Every candidate must carry T at comptime, as under the archetype.
    try testing.expectEqual(@as(i32, 6), (try reg.getAny(e, .{ &a, &dst }, Fdish)).fd);
    try testing.expectError(error.WrongCollection, reg.getAny(e, .{&b}, Position));

    // moveAny is total: b → dst would DROP nothing even though b's row
    // is narrower — the archetype's subset requirement is gone.
    try reg.moveAny(e, .{ &a, &b }, &b);
    try reg.flush();
    try reg.moveAny(e, .{ &a, &b }, &dst);
    try reg.flush();
    try testing.expectEqual(@as(i32, 6), (try reg.get(e, &dst, Fdish)).fd);
    try testing.expectError(error.WrongCollection, reg.moveAny(e, .{ &a, &b }, &dst));
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


const QuiesceReg = blk: {
    // Velocity is the state axis 1's component; everything else stays
    // on the total axis. Axis 2 is a state set, axis 3 an identity set.
    var ca: [TestUniverse.len]u8 = @splat(0);
    ca[TestUniverse.indexOf(Velocity)] = 1;
    const ca_final = ca;
    break :blk FatRegistryAxes(TestUniverse, .{
        .n_axes = 4,
        .comp_axis = &ca_final,
        .identity = &.{ false, false, false, true },
    });
};

const QuiesceWorld = struct {
    reg: QuiesceReg,
    a: Collection(Row(&.{Position}), .{}),
    b: Collection(Row(&.{ Position, Fdish }), .{}),
    armed: Collection(Row(&.{Velocity}), .{}),
    pending: Collection(Row(&.{}), .{}),
    ident: Collection(Row(&.{}), .{}),

    /// In place, on caller-owned storage: registration takes interior
    /// pointers, so the value must already sit at its final address —
    /// the same reason the world's Reg keeps storage behind a heap
    /// pointer.
    fn setup(w: *QuiesceWorld) !void {
        w.* = .{
            .reg = try QuiesceReg.init(testing.allocator, .{ .max_entities = 16 }),
            .a = try Collection(Row(&.{Position}), .{}).init(testing.allocator),
            .b = try Collection(Row(&.{ Position, Fdish }), .{}).init(testing.allocator),
            .armed = try Collection(Row(&.{Velocity}), .{}).init(testing.allocator),
            .pending = try Collection(Row(&.{}), .{}).init(testing.allocator),
            .ident = try Collection(Row(&.{}), .{}).init(testing.allocator),
        };
        w.reg.registerCollection(&w.a, 1);
        w.reg.registerCollection(&w.b, 2);
        w.reg.registerCollectionOnAxis(&w.armed, 3, 1);
        w.reg.registerCollectionOnAxis(&w.pending, 4, 2);
        w.reg.registerCollectionOnAxis(&w.ident, 5, 3);
    }

    fn deinit(w: *QuiesceWorld) void {
        w.ident.deinit();
        w.pending.deinit();
        w.armed.deinit();
        w.b.deinit();
        w.a.deinit();
        w.reg.deinit();
    }

    fn liveEntity(w: *QuiesceWorld) !Entity {
        const e = try w.reg.create(&w.a);
        try w.reg.enter(e, &w.armed);
        (try w.reg.getFat(e, Velocity)).* = .{ .x = 5, .y = 6 };
        try w.reg.enter(e, &w.pending);
        try w.reg.enter(e, &w.ident);
        return e;
    }
};

test "moveOnly — quiesce drops state axes at flush, keeps identity, parks values" {
    var w: QuiesceWorld = undefined;
    try QuiesceWorld.setup(&w);
    defer w.deinit();
    const reg = &w.reg;
    const e = try w.liveEntity();

    try reg.moveOnly(e, &w.a, &w.b);
    // Deferred: nothing changes before the flush the caller owns.
    try testing.expect(reg.onAxis(e, 1));
    try testing.expect(reg.onAxis(e, 2));

    try reg.flush();
    try testing.expect(reg.isInCollection(e, &w.b));
    try testing.expect(!reg.onAxis(e, 1));
    try testing.expect(!reg.onAxis(e, 2));
    // Identity survives quiescing — it says what the entity IS.
    try testing.expect(reg.onAxis(e, 3));
    try testing.expectEqual(@as(u32, 1), w.ident.count);
    // The dropped state's row parked, not destroyed.
    try testing.expectEqual(@as(f32, 5), (try reg.getFat(e, Velocity)).x);
}

test "evictOnlyImmediate — the erased-source quiesce" {
    var w: QuiesceWorld = undefined;
    try QuiesceWorld.setup(&w);
    defer w.deinit();
    const reg = &w.reg;
    const e = try w.liveEntity();

    // The caller names no source and no axes.
    try reg.evictOnlyImmediate(e, &w.b);
    try testing.expect(reg.isInCollection(e, &w.b));
    try testing.expect(!reg.onAxis(e, 1));
    try testing.expect(!reg.onAxis(e, 2));
    try testing.expect(reg.onAxis(e, 3));
    try testing.expectEqual(@as(f32, 5), (try reg.getFat(e, Velocity)).x);
}

test "moveAnyOnly — candidate-tuple flavor of the quiesce" {
    var w: QuiesceWorld = undefined;
    try QuiesceWorld.setup(&w);
    defer w.deinit();
    const reg = &w.reg;
    const e = try w.liveEntity();

    try reg.moveAnyOnly(e, .{ &w.b, &w.a }, &w.b);
    try reg.flush();
    try testing.expect(reg.isInCollection(e, &w.b));
    try testing.expect(!reg.onAxis(e, 1));
    try testing.expect(reg.onAxis(e, 3));
}

test "deferred moves refuse a partial-axis source; immediate stays open" {
    var w: QuiesceWorld = undefined;
    try QuiesceWorld.setup(&w);
    defer w.deinit();
    const reg = &w.reg;

    var armed2 = try Collection(Row(&.{Velocity}), .{}).init(testing.allocator);
    defer armed2.deinit();
    reg.registerCollectionOnAxis(&armed2, 6, 1);

    const e = try w.liveEntity();
    try testing.expectError(error.DeferredPartialAxis, reg.move(e, &w.armed, &armed2));
    // The state axis mutates immediately instead.
    try reg.moveImmediate(e, &w.armed, &armed2);
    try testing.expect(reg.isInCollection(e, &armed2));
}

test "evict — deferred, entity-keyed: tolerates a moving entity" {
    var w: QuiesceWorld = undefined;
    try QuiesceWorld.setup(&w);
    defer w.deinit();
    const reg = &w.reg;
    const e = try w.liveEntity();

    // A move is already queued; the ending must not be refusable —
    // the eviction resolves its source AFTER that move lands.
    try reg.move(e, &w.a, &w.b);
    try reg.evictOnly(e, &w.b);
    try testing.expect(reg.isMoving(e));

    try reg.flush();
    // The queued move ran first (a → b); then the ending found the
    // entity already in b and skipped — no double placement.
    try testing.expect(reg.isInCollection(e, &w.b));
    try testing.expect(!reg.isMoving(e));
    // ... and the quiesce still ran its part via the late op? No — an
    // already-in-dst ending skips whole. State memberships survive; a
    // caller wanting both uses moveOnly for the move itself.
    try testing.expect(reg.onAxis(e, 3));

    // Now the real cross-collection case: queued move b→a, ending to b.
    try reg.move(e, &w.b, &w.a);
    try reg.evictOnly(e, &w.b);
    try reg.flush();
    try testing.expect(reg.isInCollection(e, &w.b));
    try testing.expect(!reg.onAxis(e, 1));
    try testing.expect(!reg.onAxis(e, 2));
    try testing.expect(reg.onAxis(e, 3));
    try testing.expectEqual(@as(f32, 5), (try reg.getFat(e, Velocity)).x);
}

test "evict — an ending queued for an entity that dies first is skipped" {
    var w: QuiesceWorld = undefined;
    try QuiesceWorld.setup(&w);
    defer w.deinit();
    const reg = &w.reg;
    const e = try w.liveEntity();

    try reg.destroy(e);
    try reg.evict(e, &w.b);
    try reg.flush();
    try testing.expect(reg.isStale(e));
    try testing.expectEqual(@as(u32, 0), w.b.count);
    try testing.expectEqual(@as(u32, 0), reg.pendingOpCount());
}

test "evict — double-ending converges, values ride the park" {
    var w: QuiesceWorld = undefined;
    try QuiesceWorld.setup(&w);
    defer w.deinit();
    const reg = &w.reg;
    const e = try w.liveEntity();
    (try reg.getFat(e, Position)).* = .{ .x = 9, .y = 0 };

    try reg.evict(e, &w.b);
    try reg.evict(e, &w.b); // second ending: skipped at execute
    try reg.flush();
    try testing.expect(reg.isInCollection(e, &w.b));
    try testing.expectEqual(@as(u32, 1), w.b.count);
    try testing.expect(!reg.isMoving(e));
    try testing.expectEqual(@as(f32, 9), (try reg.getFat(e, Position)).x);
}
