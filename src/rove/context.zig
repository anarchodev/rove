const std = @import("std");
const row_mod = @import("row.zig");
const entity_mod = @import("entity.zig");
const collection_mod = @import("collection.zig");
const Entity = entity_mod.Entity;
const Row = row_mod.Row;
const Collection = collection_mod.Collection;

/// Context configuration passed to init.
pub const ContextConfig = struct {
    max_entities: u32,
    deferred_queue_capacity: u32 = 256,
};

/// Create a Context type parameterized by a collection spec type.
///
/// The spec type is produced by `MakeSpec`, `MergeSpecs`, or a library's
/// `SpecType()` function.
///
///   const Spec = rove.MakeSpec(&.{
///       rove.specField("active", FullEntityRow, null),
///       rove.specField("dead", DeadRow, null),
///   });
///   const Ctx = Context(Spec);
///   var ctx = try Ctx.init(allocator, .{ .max_entities = 65536 });
///
pub fn Context(comptime Spec: type) type {
    @setEvalBranchQuota(100_000);
    const spec_fields = @typeInfo(Spec).@"struct".fields;
    const num_user_collections = spec_fields.len;
    const total_collections = num_user_collections + 1; // +1 for null

    // Generate CollectionId enum
    const CollectionIdEnum = blk: {
        var enum_fields: [num_user_collections]std.builtin.Type.EnumField = undefined;
        for (spec_fields, 0..) |field, i| {
            enum_fields[i] = .{ .name = field.name, .value = i };
        }
        break :blk @Type(.{ .@"enum" = .{
            .tag_type = u8,
            .fields = &enum_fields,
            .is_exhaustive = true,
            .decls = &.{},
        } });
    };

    // Generate the Collections struct type.
    // _null at index 0 (dynamic, capacity set at runtime via ensureCapacity).
    // User collections at index 1..N.
    const CollectionsStruct = blk: {
        var struct_fields: [total_collections]std.builtin.Type.StructField = undefined;

        // Null collection: dynamic (capacity managed at init)
        const NullColl = Collection(Row(&.{}), .{});
        struct_fields[0] = .{
            .name = "_null",
            .type = NullColl,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(NullColl),
        };

        // User collections — field.type is already the Collection type
        for (spec_fields, 0..) |field, i| {
            struct_fields[i + 1] = .{
                .name = field.name,
                .type = field.type,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(field.type),
            };
        }

        break :blk @Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = &struct_fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    };

    return struct {
        const Self = @This();

        pub const CollectionId = CollectionIdEnum;
        pub const num_cols = num_user_collections;

        // Entity metadata (SoA)
        generations: []u32,
        collection_ids: []u8,
        offsets: []u32,
        flags: []u8,

        max_entities: u32,
        null_front: u32,

        collections: CollectionsStruct,

        // Deferred queue
        deferred_ops: []DeferredOp,
        deferred_count: u32,
        deferred_capacity: u32,

        // Sort optimization: track max enqueued offset per source collection.
        // If an op is enqueued with a lower offset than the max, we need to sort.
        max_src_offsets: [total_collections]u32,
        needs_sort: bool,

        allocator: std.mem.Allocator,

        pub const DeferredOp = struct {
            src_id: u8,
            dst_id: u8,
            src_offset: u32,
            count: u32,
        };

        const PENDING_MOVE: u8 = 1;

        // =============================================================
        // Init / Deinit
        // =============================================================

        pub fn init(allocator: std.mem.Allocator, config: ContextConfig) !Self {
            const max = config.max_entities;

            const generations = try allocator.alloc(u32, max);
            @memset(generations, 0);

            const collection_ids = try allocator.alloc(u8, max);
            @memset(collection_ids, 0);

            const offsets = try allocator.alloc(u32, max);
            for (offsets, 0..) |*o, i| o.* = @intCast(i);

            const flags = try allocator.alloc(u8, max);
            @memset(flags, 0);

            const deferred_ops = try allocator.alloc(DeferredOp, config.deferred_queue_capacity);

            var collections: CollectionsStruct = undefined;

            // Null collection: dynamic, pre-allocate for max_entities
            collections._null = try Collection(Row(&.{}), .{}).init(allocator);
            try collections._null.ensureCapacity(max);
            for (0..max) |i| {
                _ = try collections._null.appendEntity(.{ .index = @intCast(i), .generation = 0 });
            }

            // User collections
            inline for (spec_fields) |field| {
                @field(collections, field.name) = try field.type.init(allocator);
            }

            return .{
                .generations = generations,
                .collection_ids = collection_ids,
                .offsets = offsets,
                .flags = flags,
                .max_entities = max,
                .null_front = 0,
                .collections = collections,
                .deferred_ops = deferred_ops,
                .deferred_count = 0,
                .deferred_capacity = config.deferred_queue_capacity,
                .max_src_offsets = [_]u32{0} ** total_collections,
                .needs_sort = false,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            inline for (spec_fields) |field| {
                @field(self.collections, field.name).deinit();
            }
            self.collections._null.deinit();

            self.allocator.free(self.generations);
            self.allocator.free(self.collection_ids);
            self.allocator.free(self.offsets);
            self.allocator.free(self.flags);
            self.allocator.free(self.deferred_ops);

            self.* = undefined;
        }

        // =============================================================
        // Collection access
        // =============================================================

        /// Returns a typed, aligned column slice for a component in the named collection.
        /// Compile error if the component is not in the collection's row.
        pub fn column(self: *Self, comptime id: CollectionId, comptime T: type) []align(collection_mod.effectiveAlign(T)) T {
            return self.getCollection(id).column(T);
        }

        /// Returns the entity handle slice for the named collection.
        pub fn entities(self: *Self, comptime id: CollectionId) []Entity {
            return self.getCollection(id).entitySlice();
        }

        /// Internal: get a pointer to a collection by ID.
        fn getCollection(self: *Self, comptime id: CollectionId) *CollectionType(id) {
            return &@field(self.collections, @tagName(id));
        }

        /// Register a typed init context for a component. Propagates to all
        /// collections whose Row contains T. One call, applies globally.
        pub fn setInitCtx(self: *Self, comptime T: type, ctx_ptr: *T.InitCtx) void {
            // Set on null collection if applicable
            if (comptime Row(&.{}).contains(T)) {
                self.collections._null.setInitCtx(T, ctx_ptr);
            }
            // Set on all user collections
            inline for (spec_fields) |field| {
                if (comptime field.type.RowType.contains(T)) {
                    @field(self.collections, field.name).setInitCtx(T, ctx_ptr);
                }
            }
        }

        /// Register a typed deinit context for a component. Propagates to all
        /// collections whose Row contains T. One call, applies globally.
        pub fn setDeinitCtx(self: *Self, comptime T: type, ctx_ptr: *T.DeinitCtx) void {
            if (comptime Row(&.{}).contains(T)) {
                self.collections._null.setDeinitCtx(T, ctx_ptr);
            }
            inline for (spec_fields) |field| {
                if (comptime field.type.RowType.contains(T)) {
                    @field(self.collections, field.name).setDeinitCtx(T, ctx_ptr);
                }
            }
        }

        // =============================================================
        // Create
        // =============================================================

        /// Batch-create `count` entities in the given collection. Returns a
        /// slice of entity handles pointing into the null pool — valid until
        /// the next flush. Components are not accessible until after flush.
        pub fn create(self: *Self, comptime dst: CollectionId, count: u32) ![]const Entity {
            if (self.null_front + count > self.max_entities) return error.Full;

            const null_coll = &self.collections._null;
            const start = self.null_front;
            const null_ents = null_coll.entitySlice()[start .. start + count];

            for (null_ents) |entity| {
                self.flags[entity.index] |= PENDING_MOVE;
            }

            try self.enqueue(0, internalIndex(dst), start, count);

            self.null_front += count;
            return null_ents;
        }

        /// Create a single entity. Convenience wrapper around batch create.
        pub fn createOne(self: *Self, comptime dst: CollectionId) !Entity {
            const result = try self.create(dst, 1);
            return result[0];
        }

        // =============================================================
        // Move
        // =============================================================

        /// Batch-move entities between two collections with compatible rows.
        /// Source is explicit (comptime dispatch). The destination must be a
        /// superset of the source (no component loss).
        pub fn moveFrom(
            self: *Self,
            ents: []const Entity,
            comptime src: CollectionId,
            comptime dst: CollectionId,
        ) !void {
            comptime {
                const SrcRow = CollectionRow(src);
                const DstRow = CollectionRow(dst);
                if (!SrcRow.isSubsetOf(DstRow)) {
                    const lost = SrcRow.subtract(&DstRow.types);
                    @compileError("move from ." ++ @tagName(src) ++ " to ." ++ @tagName(dst) ++
                        " loses " ++ std.fmt.comptimePrint("{d}", .{lost.len}) ++
                        " component(s). Use moveStrip.");
                }
            }
            for (ents) |entity| {
                try self.enqueueMove(entity, src, dst);
            }
        }

        /// Move a single entity with explicit source. Comptime dispatch, fast.
        pub fn moveOneFrom(
            self: *Self,
            entity: Entity,
            comptime src: CollectionId,
            comptime dst: CollectionId,
        ) !void {
            try self.moveFrom(&.{entity}, src, dst);
        }

        /// Move a single entity to dst. Source is looked up at runtime.
        /// Slower than moveOneFrom but doesn't require knowing the source.
        pub fn moveOne(
            self: *Self,
            entity: Entity,
            comptime dst: CollectionId,
        ) !void {
            if (entity.index >= self.max_entities) return error.InvalidEntity;
            if (self.generations[entity.index] != entity.generation) return error.InvalidEntity;
            const src_internal = self.collection_ids[entity.index];
            if (src_internal == 0) return error.InvalidEntity;
            const dst_internal = comptime internalIndex(dst);
            if (src_internal == dst_internal) return;
            try self.enqueueMoveRaw(entity, src_internal, dst_internal);
        }

        /// Batch-move entities, explicitly stripping components. The strip list
        /// must exactly match the components lost in the move.
        pub fn moveStripFrom(
            self: *Self,
            ents: []const Entity,
            comptime src: CollectionId,
            comptime dst: CollectionId,
            comptime strip: []const type,
        ) !void {
            comptime {
                const SrcRow = CollectionRow(src);
                const DstRow = CollectionRow(dst);
                const lost = SrcRow.subtract(&DstRow.types);
                if (!Row(strip).equal(lost)) {
                    @compileError("moveStrip: strip list does not match lost components for ." ++
                        @tagName(src) ++ " -> ." ++ @tagName(dst));
                }
            }
            for (ents) |entity| {
                try self.enqueueMove(entity, src, dst);
            }
        }

        /// Move a single entity with strip. Convenience wrapper.
        pub fn moveStripOneFrom(
            self: *Self,
            entity: Entity,
            comptime src: CollectionId,
            comptime dst: CollectionId,
            comptime strip: []const type,
        ) !void {
            try self.moveStripFrom(&.{entity}, src, dst, strip);
        }

        // =============================================================
        // Destroy
        // =============================================================

        /// Batch-destroy entities. Source collection is looked up from metadata.
        pub fn destroy(self: *Self, ents: []const Entity) !void {
            for (ents) |entity| {
                const idx = entity.index;
                if (idx >= self.max_entities) return error.InvalidEntity;
                if (self.generations[idx] != entity.generation) return error.Stale;
                if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;
                if (self.collection_ids[idx] == 0) return error.InvalidEntity;

                self.flags[idx] |= PENDING_MOVE;

                try self.enqueue(
                    self.collection_ids[idx],
                    0,
                    self.offsets[idx],
                    1,
                );
            }
        }

        /// Destroy a single entity. Convenience wrapper.
        pub fn destroyOne(self: *Self, entity: Entity) !void {
            try self.destroy(&.{entity});
        }

        // =============================================================
        // Get / Set
        // =============================================================

        pub fn get(self: *Self, entity: Entity, comptime T: type) !*T {
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;

            const col_internal = self.collection_ids[idx];
            const offset = self.offsets[idx];

            inline for (spec_fields, 0..) |field, i| {
                if (comptime field.type.RowType.contains(T)) {
                    if (col_internal == i + 1) {
                        return &@field(self.collections, field.name).column(T)[offset];
                    }
                }
            }
            return error.NotFound;
        }

        pub fn set(self: *Self, entity: Entity, comptime T: type, value: T) !void {
            const ptr = try self.get(entity, T);
            ptr.* = value;
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

        /// Returns true if the entity belongs to the given collection.
        /// Returns false if stale or in a different collection.
        pub fn isInCollection(self: *const Self, entity: Entity, comptime id: CollectionId) bool {
            if (entity.index >= self.max_entities) return false;
            if (self.generations[entity.index] != entity.generation) return false;
            return self.collection_ids[entity.index] == internalIndex(id);
        }

        // =============================================================
        // Immediate operations
        // =============================================================

        /// Create an entity immediately — it is live and accessible right away.
        /// Components are zero-initialized and batch init() is called.
        /// Batch-create entities immediately — live and accessible right away.
        /// Returns a slice of entity handles from the null pool (valid until
        /// next operation that modifies the null pool).
        pub fn createImmediate(self: *Self, comptime dst: CollectionId, count: u32) ![]const Entity {
            if (self.null_front + count > self.max_entities) return error.Full;

            const null_coll = &self.collections._null;
            const src_offset = self.null_front;
            self.null_front += count;

            const dst_coll = self.getCollection(dst);
            const dest_base = try dst_coll.appendEntities(count);

            // Copy entity handles from null pool into destination
            const src_entities = null_coll.entitySlice()[src_offset .. src_offset + count];
            const dst_entities = dst_coll.entitySlice()[dest_base .. dest_base + count];
            @memcpy(dst_entities, src_entities);

            // Update metadata
            for (dst_entities, 0..) |entity, k| {
                self.collection_ids[entity.index] = internalIndex(dst);
                self.offsets[entity.index] = dest_base + @as(u32, @intCast(k));
            }

            // Remove from null pool (after we've copied handles out)
            const moved = null_coll.removeRun(src_offset, count);
            for (moved, 0..) |moved_entity, r| {
                self.offsets[moved_entity.index] = src_offset + @as(u32, @intCast(r));
            }
            self.null_front -= count;

            // Return slice from destination — stable after removeRun
            return dst_entities;
        }

        /// Create a single entity immediately. Convenience wrapper.
        pub fn createOneImmediate(self: *Self, comptime dst: CollectionId) !Entity {
            const result = try self.createImmediate(dst, 1);
            return result[0];
        }

        /// Immediately move an entity between collections. Same comptime row
        /// checks as deferred move — destination must be superset of source.
        pub fn moveImmediateFrom(
            self: *Self,
            entity: Entity,
            comptime src: CollectionId,
            comptime dst: CollectionId,
        ) !void {
            comptime {
                const SrcRow = CollectionRow(src);
                const DstRow = CollectionRow(dst);
                if (!SrcRow.isSubsetOf(DstRow)) {
                    const lost = SrcRow.subtract(&DstRow.types);
                    @compileError("moveImmediate from ." ++ @tagName(src) ++ " to ." ++ @tagName(dst) ++
                        " loses " ++ std.fmt.comptimePrint("{d}", .{lost.len}) ++
                        " component(s). Use moveStripImmediate.");
                }
            }
            try self.executeMoveImmediate(entity, src, dst);
        }

        /// Immediately move an entity, explicitly stripping components.
        pub fn moveStripImmediateFrom(
            self: *Self,
            entity: Entity,
            comptime src: CollectionId,
            comptime dst: CollectionId,
            comptime strip: []const type,
        ) !void {
            comptime {
                const SrcRow = CollectionRow(src);
                const DstRow = CollectionRow(dst);
                const lost = SrcRow.subtract(&DstRow.types);
                if (!Row(strip).equal(lost)) {
                    @compileError("moveStripImmediate: strip list does not match lost components for ." ++
                        @tagName(src) ++ " -> ." ++ @tagName(dst));
                }
            }
            try self.executeMoveImmediate(entity, src, dst);
        }

        /// Immediately destroy an entity. Calls deinit, bumps generation.
        pub fn destroyImmediate(self: *Self, entity: Entity) !void {
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;
            if (self.collection_ids[idx] == 0) return error.InvalidEntity;

            const src_internal = self.collection_ids[idx];
            const src_offset = self.offsets[idx];

            // Dispatch to the correct comptime-specialized destroy
            inline for (1..total_collections) |i| {
                if (src_internal == i) {
                    const src_coll = getCollectionByIdx(self, i);

                    // Deinit all components (via collection's callDeinit for context support)
                    const SrcRow = collectionRowByIdx(i);
                    inline for (comptime SrcRow.deinitTypes()) |T| {
                        src_coll.callDeinit(T, src_coll.column(T)[src_offset .. src_offset + 1]);
                    }

                    // Swap-remove from source (no deinit — handled above)
                    const moved = src_coll.removeRun(src_offset, 1);
                    for (moved) |moved_entity| {
                        self.offsets[moved_entity.index] = src_offset;
                    }
                }
            }

            // Bump generation, return to null pool
            self.generations[idx] += 1;
            const null_coll = &self.collections._null;
            const new_entity = Entity{ .index = idx, .generation = self.generations[idx] };
            const null_offset = try null_coll.appendEntity(new_entity);

            self.collection_ids[idx] = 0;
            self.offsets[idx] = null_offset;
        }

        fn executeMoveImmediate(
            self: *Self,
            entity: Entity,
            comptime src: CollectionId,
            comptime dst: CollectionId,
        ) !void {
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;
            if (self.collection_ids[idx] != internalIndex(src)) return error.WrongCollection;

            const src_coll = self.getCollection(src);
            const dst_coll = self.getCollection(dst);
            const src_offset = self.offsets[idx];

            const SrcRow = CollectionRow(src);
            const DstRow = CollectionRow(dst);

            // Append to destination (zero-init + construct)
            const new_offset = try dst_coll.appendEntity(entity);

            // Copy shared components
            const Shared = SrcRow.intersect(DstRow);
            inline for (Shared.types) |T| {
                dst_coll.column(T)[new_offset] = src_coll.column(T)[src_offset];
            }

            // Deinit dropped components
            const Dropped = SrcRow.subtract(&DstRow.types);
            inline for (comptime Dropped.deinitTypes()) |T| {
                src_coll.callDeinit(T, src_coll.column(T)[src_offset .. src_offset + 1]);
            }

            // Remove from source (no deinit — handled above)
            const moved = src_coll.removeRun(src_offset, 1);
            for (moved) |moved_entity| {
                self.offsets[moved_entity.index] = src_offset;
            }

            // Update metadata
            self.collection_ids[idx] = internalIndex(dst);
            self.offsets[idx] = new_offset;
        }

        // =============================================================
        // Flush
        // =============================================================

        pub fn flush(self: *Self) !void {
            // Re-entrant flush: deinit/init callbacks may enqueue new ops.
            // Process rounds until no new ops are generated.
            while (self.deferred_count > 0) {
                // Snapshot the current batch size. Ops enqueued by deinit/init
                // during this round land beyond batch_count and are picked up
                // in the next round.
                const batch_count = self.deferred_count;

                if (batch_count > 1 and self.needs_sort) {
                    const ops = self.deferred_ops[0..batch_count];
                    std.mem.sort(DeferredOp, ops, {}, opOrder);
                }

                // Process in reverse (highest offsets first within each source)
                // so removeRun doesn't invalidate earlier offsets.
                var i = batch_count;
                while (i > 0) {
                    i -= 1;
                    try self.executeOp(self.deferred_ops[i]);
                }

                // Shift any ops enqueued during this round to the front.
                const new_count = self.deferred_count - batch_count;
                if (new_count > 0) {
                    std.mem.copyForwards(
                        DeferredOp,
                        self.deferred_ops[0..new_count],
                        self.deferred_ops[batch_count .. batch_count + new_count],
                    );
                }
                self.deferred_count = new_count;
                // Always sort the next round — the offsets were computed
                // against pre-compaction state and max_src_offsets is stale.
                self.needs_sort = true;
                self.max_src_offsets = [_]u32{0} ** total_collections;
                self.null_front = 0;
            }
        }

        fn opOrder(_: void, a: DeferredOp, b: DeferredOp) bool {
            if (a.src_id != b.src_id) return a.src_id < b.src_id;
            // Within same source: ascending offset so we process highest first in reverse
            return a.src_offset < b.src_offset;
        }

        fn executeOp(self: *Self, op: DeferredOp) !void {
            @setEvalBranchQuota(100_000);
            // Comptime-generated dispatch on (src_id, dst_id) pair.
            inline for (0..total_collections) |src_idx| {
                inline for (0..total_collections) |dst_idx| {
                    if (comptime src_idx != dst_idx) {
                        if (op.src_id == src_idx and op.dst_id == dst_idx) {
                            try self.dispatchBatch(src_idx, dst_idx, op.src_offset, op.count);
                            return;
                        }
                    }
                }
            }
        }

        /// Process a batch of `count` contiguous entities from src at src_offset.
        fn dispatchBatch(
            self: *Self,
            comptime src_idx: u8,
            comptime dst_idx: u8,
            src_offset: u32,
            count: u32,
        ) !void {
            const src_coll = getCollectionByIdx(self, src_idx);

            if (dst_idx == 0) {
                // Destroy: move entities back to null pool
                const null_coll = &self.collections._null;
                const src_entities = src_coll.entitySlice();

                // Call deinit on dropped components (all of them — going to null)
                const SrcRow = collectionRowByIdx(src_idx);
                inline for (comptime SrcRow.deinitTypes()) |T| {
                    src_coll.callDeinit(T, src_coll.column(T)[src_offset .. src_offset + count]);
                }

                // Process each entity: bump generation, append back to null pool
                for (0..count) |k| {
                    const entity = src_entities[src_offset + k];
                    const idx = entity.index;

                    self.generations[idx] += 1;
                    const new_entity = Entity{ .index = idx, .generation = self.generations[idx] };
                    const null_offset = try null_coll.appendEntity(new_entity);

                    self.collection_ids[idx] = 0;
                    self.offsets[idx] = null_offset;
                    self.flags[idx] &= ~PENDING_MOVE;
                }

                // Batch removeRun from source (no deinit — already handled)
                const moved = src_coll.removeRun(src_offset, count);
                for (moved, 0..) |moved_entity, r| {
                    self.offsets[moved_entity.index] = src_offset + @as(u32, @intCast(r));
                }
                return;
            }

            const dst_coll = getCollectionByIdx(self, dst_idx);

            if (src_idx == 0) {
                // Create: batch-append to destination
                const dest_base = try dst_coll.appendEntities(count);
                const src_entities = src_coll.entitySlice();

                // Bulk copy entity handles into destination
                @memcpy(
                    dst_coll.entitySlice()[dest_base .. dest_base + count],
                    src_entities[src_offset .. src_offset + count],
                );

                // Update metadata (per-entity — indices are non-contiguous)
                for (0..count) |k| {
                    const idx = src_entities[src_offset + k].index;
                    self.collection_ids[idx] = dst_idx;
                    self.offsets[idx] = dest_base + @as(u32, @intCast(k));
                    self.flags[idx] &= ~PENDING_MOVE;
                }

                // Batch removeRun from null collection
                const moved = src_coll.removeRun(src_offset, count);
                for (moved, 0..) |moved_entity, r| {
                    self.offsets[moved_entity.index] = src_offset + @as(u32, @intCast(r));
                }
                return;
            }

            // Move between user collections: batch migrate
            const SrcRow = collectionRowByIdx(src_idx);
            const DstRow = collectionRowByIdx(dst_idx);

            // Batch-append to destination (zero-init + construct)
            const dest_base = try dst_coll.appendEntities(count);
            const src_entities = src_coll.entitySlice();

            // Bulk copy entity handles
            @memcpy(
                dst_coll.entitySlice()[dest_base .. dest_base + count],
                src_entities[src_offset .. src_offset + count],
            );

            // Bulk copy shared components
            const Shared = SrcRow.intersect(DstRow);
            inline for (Shared.types) |T| {
                @memcpy(
                    dst_coll.column(T)[dest_base .. dest_base + count],
                    src_coll.column(T)[src_offset .. src_offset + count],
                );
            }

            // Destruct components being dropped (batch)
            const Dropped = SrcRow.subtract(&DstRow.types);
            inline for (comptime Dropped.deinitTypes()) |T| {
                src_coll.callDeinit(T, src_coll.column(T)[src_offset .. src_offset + count]);
            }

            // Update metadata for all entities in the run
            for (0..count) |k| {
                const entity = src_entities[src_offset + k];
                const idx = entity.index;
                self.collection_ids[idx] = dst_idx;
                self.offsets[idx] = dest_base + @as(u32, @intCast(k));
                self.flags[idx] &= ~PENDING_MOVE;
            }

            // Batch removeRun from source (no deinit — already handled)
            const moved = src_coll.removeRun(src_offset, count);
            for (moved, 0..) |moved_entity, r| {
                self.offsets[moved_entity.index] = src_offset + @as(u32, @intCast(r));
            }
        }

        // =============================================================
        // Internal helpers
        // =============================================================

        fn enqueueMoveRaw(self: *Self, entity: Entity, src_id: u8, dst_id: u8) !void {
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;
            if (self.collection_ids[idx] != src_id) return error.WrongCollection;

            self.flags[idx] |= PENDING_MOVE;
            try self.enqueue(src_id, dst_id, self.offsets[idx], 1);
        }

        fn enqueueMove(self: *Self, entity: Entity, comptime src: CollectionId, comptime dst: CollectionId) !void {
            const idx = entity.index;
            if (idx >= self.max_entities) return error.InvalidEntity;
            if (self.generations[idx] != entity.generation) return error.Stale;
            if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;
            if (self.collection_ids[idx] != internalIndex(src)) return error.WrongCollection;

            self.flags[idx] |= PENDING_MOVE;

            const src_id = internalIndex(src);
            const dst_id = internalIndex(dst);
            const src_offset = self.offsets[idx];

            try self.enqueue(src_id, dst_id, src_offset, 1);
        }

        /// Enqueue with RLE peek coalescing. If the last op in the queue has
        /// the same (src, dst) and the new offset is contiguous, extend it
        /// instead of pushing a new op.
        fn enqueue(self: *Self, src_id: u8, dst_id: u8, src_offset: u32, count: u32) !void {
            const can_peek = self.deferred_count > 0 and blk: {
                const last = &self.deferred_ops[self.deferred_count - 1];
                break :blk (last.src_id == src_id and
                    last.dst_id == dst_id and
                    last.src_offset + last.count == src_offset);
            };

            if (!can_peek and self.deferred_count >= self.deferred_capacity)
                return error.QueueFull;

            if (can_peek) {
                self.deferred_ops[self.deferred_count - 1].count += count;
            } else {
                self.deferred_ops[self.deferred_count] = .{
                    .src_id = src_id,
                    .dst_id = dst_id,
                    .src_offset = src_offset,
                    .count = count,
                };
                self.deferred_count += 1;

                // Track sort state
                if (src_offset < self.max_src_offsets[src_id]) {
                    self.needs_sort = true;
                } else {
                    self.max_src_offsets[src_id] = src_offset;
                }
            }
        }

        pub fn internalIndex(comptime id: CollectionId) u8 {
            return @intFromEnum(id) + 1;
        }

        fn getCollectionByIdx(self: *Self, comptime idx: u8) CollectionPtrType(idx) {
            if (idx == 0) return &self.collections._null;
            inline for (spec_fields, 0..) |field, i| {
                if (idx == i + 1) return &@field(self.collections, field.name);
            }
            unreachable;
        }

        fn CollectionPtrType(comptime idx: u8) type {
            @setEvalBranchQuota(100_000);
            if (idx == 0) return *Collection(Row(&.{}), .{});
            inline for (spec_fields, 0..) |field, i| {
                if (idx == i + 1) return *field.type;
            }
            unreachable;
        }

        fn collectionRowByIdx(comptime idx: u8) type {
            if (idx == 0) return Row(&.{});
            inline for (spec_fields, 0..) |field, i| {
                if (idx == i + 1) return field.type.RowType;
            }
            unreachable;
        }

        pub fn CollectionType(comptime id: CollectionId) type {
            return spec_fields[@intFromEnum(id)].type;
        }

        pub fn CollectionRow(comptime id: CollectionId) type {
            return spec_fields[@intFromEnum(id)].type.RowType;
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

const Position = struct { x: f32, y: f32, z: f32 };
const Velocity = struct { x: f32, y: f32, z: f32 };
const Health = struct {
    current: i32,
    max: i32,

    pub fn init(items: []Health) void {
        for (items) |*item| item.* = .{ .current = 100, .max = 100 };
    }

    pub fn deinit(_: std.mem.Allocator, items: []Health) void {
        _ = items;
    }
};

var tracked_deinit_counter: u32 = 0;
const Tracked = struct {
    value: u32,

    pub fn deinit(_: std.mem.Allocator, items: []Tracked) void {
        tracked_deinit_counter += @intCast(items.len);
    }
};

const MovementRow = Row(&.{ Position, Velocity });
const FullRow = Row(&.{ Position, Velocity, Health });
const PosOnlyRow = Row(&.{Position});
const TrackedRow = Row(&.{ Position, Tracked });

const spec_mod = @import("spec.zig");
const TestCtx = Context(spec_mod.MakeCollections(&.{
    spec_mod.col("active", Collection(FullRow, .{})),
    spec_mod.col("dead", Collection(PosOnlyRow, .{})),
    spec_mod.col("spawning", Collection(MovementRow, .{})),
    spec_mod.col("tracked", Collection(TrackedRow, .{})),
}));

test "init/deinit empty context" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();
    try testing.expectEqual(@as(usize, 0), ctx.entities(.active).len);
}

test "createOne" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.active);
    try testing.expect(!e.isNil());
    try ctx.flush();
    try testing.expectEqual(@as(usize, 1), ctx.entities(.active).len);
}

test "batch create" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const entities = try ctx.create(.active, 10);
    try testing.expectEqual(@as(usize, 10), entities.len);
    try ctx.flush();
    try testing.expectEqual(@as(usize, 10), ctx.entities(.active).len);
}

test "batch create — single deferred op" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    _ = try ctx.create(.active, 5);
    // Batch create should produce one deferred op, not 5
    try testing.expectEqual(@as(u32, 1), ctx.deferred_count);
}

test "create returns valid handle" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.active);
    try ctx.flush();
    try testing.expect(!ctx.isStale(e));
}

test "set/get after flush" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.active);
    try ctx.flush();

    try ctx.set(e, Position, .{ .x = 1, .y = 2, .z = 3 });
    const pos = try ctx.get(e, Position);
    try testing.expectEqual(@as(f32, 1), pos.x);
    try testing.expectEqual(@as(f32, 2), pos.y);
}

test "Health init called on create" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.active);
    try ctx.flush();

    const hp = try ctx.get(e, Health);
    try testing.expectEqual(@as(i32, 100), hp.current);
    try testing.expectEqual(@as(i32, 100), hp.max);
}

test "moveOne superset" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.spawning);
    try ctx.flush();

    try ctx.set(e, Position, .{ .x = 42, .y = 0, .z = 0 });
    try ctx.set(e, Velocity, .{ .x = 1, .y = 0, .z = 0 });

    // spawning (Pos, Vel) -> active (Pos, Vel, Health): superset, no strip needed
    try ctx.moveOneFrom(e, .spawning, .active);
    try ctx.flush();

    try testing.expectEqual(@as(usize, 0), ctx.entities(.spawning).len);
    try testing.expectEqual(@as(usize, 1), ctx.entities(.active).len);

    const pos = try ctx.get(e, Position);
    try testing.expectEqual(@as(f32, 42), pos.x);

    const hp = try ctx.get(e, Health);
    try testing.expectEqual(@as(i32, 100), hp.current);
}

test "batch move" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64, .deferred_queue_capacity = 64 });
    defer ctx.deinit();

    const created = try ctx.create(.spawning, 5);
    var handles: [5]Entity = undefined;
    @memcpy(&handles, created);
    try ctx.flush();

    for (handles, 0..) |e, i| {
        try ctx.set(e, Position, .{ .x = @floatFromInt(i), .y = 0, .z = 0 });
    }

    try ctx.moveFrom(&handles, .spawning, .active);
    try ctx.flush();

    try testing.expectEqual(@as(usize, 0), ctx.entities(.spawning).len);
    try testing.expectEqual(@as(usize, 5), ctx.entities(.active).len);

    // Verify all data survived
    for (handles, 0..) |e, i| {
        const pos = try ctx.get(e, Position);
        try testing.expectEqual(@as(f32, @floatFromInt(i)), pos.x);
    }
}

test "moveStripOne" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.active);
    try ctx.flush();

    try ctx.set(e, Position, .{ .x = 99, .y = 0, .z = 0 });

    // active (Pos, Vel, Health) -> dead (Pos): strips Velocity and Health
    try ctx.moveStripOneFrom(e, .active, .dead, &.{ Velocity, Health });
    try ctx.flush();

    try testing.expectEqual(@as(usize, 0), ctx.entities(.active).len);
    try testing.expectEqual(@as(usize, 1), ctx.entities(.dead).len);

    const pos = try ctx.get(e, Position);
    try testing.expectEqual(@as(f32, 99), pos.x);
}

test "destroyOne" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.active);
    try ctx.flush();
    try testing.expect(!ctx.isStale(e));

    try ctx.destroyOne(e);
    try ctx.flush();
    try testing.expect(ctx.isStale(e));
    try testing.expectEqual(@as(usize, 0), ctx.entities(.active).len);
}

test "batch destroy" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64, .deferred_queue_capacity = 64 });
    defer ctx.deinit();

    const created = try ctx.create(.active, 5);
    var handles: [5]Entity = undefined;
    @memcpy(&handles, created);
    try ctx.flush();

    try ctx.destroy(&handles);
    try ctx.flush();

    try testing.expectEqual(@as(usize, 0), ctx.entities(.active).len);
    for (handles) |e| try testing.expect(ctx.isStale(e));
}

test "destroy calls deinit" {
    tracked_deinit_counter = 0;
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.tracked);
    try ctx.flush();

    try ctx.destroyOne(e);
    try ctx.flush();
    try testing.expectEqual(@as(u32, 1), tracked_deinit_counter);
}

test "create reuses destroyed entity index" {
    // Use a small pool so destroyed entities are reused quickly
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 4, .deferred_queue_capacity = 8 });
    defer ctx.deinit();

    // Allocate all 4 entities
    const all = try ctx.create(.active, 4);
    var handles: [4]Entity = undefined;
    @memcpy(&handles, all);
    try ctx.flush();

    // Destroy one
    const old_index = handles[0].index;
    const old_gen = handles[0].generation;
    try ctx.destroyOne(handles[0]);
    try ctx.flush();

    // Now all slots are used except the destroyed one — next create must reuse it
    const e2 = try ctx.createOne(.active);
    try ctx.flush();

    try testing.expectEqual(old_index, e2.index);
    try testing.expect(e2.generation > old_gen);
}

test "stale entity detection" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.active);
    try ctx.flush();

    try ctx.destroyOne(e);
    try ctx.flush();

    try testing.expect(ctx.isStale(e));
    try testing.expectError(error.Stale, ctx.get(e, Position));
}

test "pending entity fails move" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.spawning);
    try ctx.flush();

    try ctx.moveOneFrom(e, .spawning, .active);
    try testing.expectError(error.PendingMove, ctx.moveOneFrom(e, .spawning, .active));
}

test "migration copies components" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.spawning);
    try ctx.flush();

    try ctx.set(e, Position, .{ .x = 1, .y = 2, .z = 3 });
    try ctx.set(e, Velocity, .{ .x = 10, .y = 20, .z = 30 });

    try ctx.moveOneFrom(e, .spawning, .active);
    try ctx.flush();

    const pos = try ctx.get(e, Position);
    const vel = try ctx.get(e, Velocity);
    try testing.expectEqual(@as(f32, 1), pos.x);
    try testing.expectEqual(@as(f32, 10), vel.x);
}

test "migration inits new components" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.spawning);
    try ctx.flush();

    try ctx.moveOneFrom(e, .spawning, .active);
    try ctx.flush();

    const hp = try ctx.get(e, Health);
    try testing.expectEqual(@as(i32, 100), hp.current);
}

test "migration deinits dropped components" {
    tracked_deinit_counter = 0;
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.tracked);
    try ctx.flush();

    try ctx.moveStripOneFrom(e, .tracked, .dead, &.{Tracked});
    try ctx.flush();

    try testing.expectEqual(@as(u32, 1), tracked_deinit_counter);
}

test "swap-remove metadata update" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e0 = try ctx.createOne(.active);
    const e1 = try ctx.createOne(.active);
    const e2 = try ctx.createOne(.active);
    try ctx.flush();

    try ctx.set(e0, Position, .{ .x = 0, .y = 0, .z = 0 });
    try ctx.set(e1, Position, .{ .x = 1, .y = 0, .z = 0 });
    try ctx.set(e2, Position, .{ .x = 2, .y = 0, .z = 0 });

    try ctx.destroyOne(e0);
    try ctx.flush();

    const p1 = try ctx.get(e1, Position);
    try testing.expectEqual(@as(f32, 1), p1.x);

    const p2 = try ctx.get(e2, Position);
    try testing.expectEqual(@as(f32, 2), p2.x);
}

test "large entity count" {
    var ctx = try TestCtx.init(testing.allocator, .{
        .max_entities = 2048,
        .deferred_queue_capacity = 2048,
    });
    defer ctx.deinit();

    // Batch create 1000 entities in one call
    const created = try ctx.create(.active, 1000);
    var entities: [1000]Entity = undefined;
    @memcpy(&entities, created);
    try ctx.flush();

    for (entities, 0..) |e, i| {
        try ctx.set(e, Position, .{ .x = @floatFromInt(i), .y = 0, .z = 0 });
    }

    // Batch destroy half
    try ctx.destroy(entities[0..500]);
    try ctx.flush();

    try testing.expectEqual(@as(usize, 500), ctx.entities(.active).len);

    for (entities[500..]) |e| {
        const pos = try ctx.get(e, Position);
        try testing.expect(pos.x >= 500);
    }
}

// ---------------------------------------------------------------------------
// isMoving tests
// ---------------------------------------------------------------------------

test "isMoving — false for live entity" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.active);
    try ctx.flush();
    try testing.expect(!ctx.isMoving(e));
}

test "isMoving — true after deferred move" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.spawning);
    try ctx.flush();

    try ctx.moveOneFrom(e, .spawning, .active);
    try testing.expect(ctx.isMoving(e));

    try ctx.flush();
    try testing.expect(!ctx.isMoving(e));
}

test "isMoving — true after deferred destroy" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.active);
    try ctx.flush();

    try ctx.destroyOne(e);
    try testing.expect(ctx.isMoving(e));
}

test "isMoving — false for stale entity" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOne(.active);
    try ctx.flush();
    try ctx.destroyOne(e);
    try ctx.flush();

    // Stale entity is not "moving"
    try testing.expect(!ctx.isMoving(e));
}

// ---------------------------------------------------------------------------
// Immediate operation tests
// ---------------------------------------------------------------------------

test "createImmediate — entity live immediately" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOneImmediate(.active);
    // No flush needed — entity is already in the collection
    try testing.expectEqual(@as(usize, 1), ctx.entities(.active).len);
    try testing.expect(!ctx.isStale(e));

    // Components are accessible immediately
    try ctx.set(e, Position, .{ .x = 42, .y = 0, .z = 0 });
    const pos = try ctx.get(e, Position);
    try testing.expectEqual(@as(f32, 42), pos.x);
}

test "createImmediate — Health init called" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOneImmediate(.active);
    const hp = try ctx.get(e, Health);
    try testing.expectEqual(@as(i32, 100), hp.current);
}

test "createImmediate — multiple" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e1 = try ctx.createOneImmediate(.active);
    const e2 = try ctx.createOneImmediate(.active);
    const e3 = try ctx.createOneImmediate(.spawning);

    try testing.expectEqual(@as(usize, 2), ctx.entities(.active).len);
    try testing.expectEqual(@as(usize, 1), ctx.entities(.spawning).len);
    try testing.expect(!ctx.isStale(e1));
    try testing.expect(!ctx.isStale(e2));
    try testing.expect(!ctx.isStale(e3));
}

test "moveImmediate — superset" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOneImmediate(.spawning);
    try ctx.set(e, Position, .{ .x = 7, .y = 0, .z = 0 });
    try ctx.set(e, Velocity, .{ .x = 3, .y = 0, .z = 0 });

    try ctx.moveImmediateFrom(e, .spawning, .active);

    try testing.expectEqual(@as(usize, 0), ctx.entities(.spawning).len);
    try testing.expectEqual(@as(usize, 1), ctx.entities(.active).len);

    // Data survived
    const pos = try ctx.get(e, Position);
    try testing.expectEqual(@as(f32, 7), pos.x);

    // Health initialized on arrival
    const hp = try ctx.get(e, Health);
    try testing.expectEqual(@as(i32, 100), hp.current);
}

test "moveStripImmediate" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOneImmediate(.active);
    try ctx.set(e, Position, .{ .x = 55, .y = 0, .z = 0 });

    try ctx.moveStripImmediateFrom(e, .active, .dead, &.{ Velocity, Health });

    try testing.expectEqual(@as(usize, 0), ctx.entities(.active).len);
    try testing.expectEqual(@as(usize, 1), ctx.entities(.dead).len);

    const pos = try ctx.get(e, Position);
    try testing.expectEqual(@as(f32, 55), pos.x);
}

test "moveStripImmediate — deinit called" {
    tracked_deinit_counter = 0;
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOneImmediate(.tracked);
    try ctx.moveStripImmediateFrom(e, .tracked, .dead, &.{Tracked});

    try testing.expectEqual(@as(u32, 1), tracked_deinit_counter);
}

test "destroyImmediate" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOneImmediate(.active);
    try testing.expectEqual(@as(usize, 1), ctx.entities(.active).len);

    try ctx.destroyImmediate(e);
    try testing.expectEqual(@as(usize, 0), ctx.entities(.active).len);
    try testing.expect(ctx.isStale(e));
}

test "destroyImmediate — deinit called" {
    tracked_deinit_counter = 0;
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e = try ctx.createOneImmediate(.tracked);
    try ctx.destroyImmediate(e);

    try testing.expectEqual(@as(u32, 1), tracked_deinit_counter);
}

test "destroyImmediate — entity reusable" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 4 });
    defer ctx.deinit();

    // Fill all slots
    const e1 = try ctx.createOneImmediate(.active);
    _ = try ctx.createOneImmediate(.active);
    _ = try ctx.createOneImmediate(.active);
    _ = try ctx.createOneImmediate(.active);

    // Destroy one
    try ctx.destroyImmediate(e1);

    // Should be able to create again
    const e5 = try ctx.createOneImmediate(.active);
    try testing.expect(!ctx.isStale(e5));
    try testing.expectEqual(@as(usize, 4), ctx.entities(.active).len);
}

test "immediate and deferred can coexist" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    // Create some immediately, some deferred
    const imm = try ctx.createOneImmediate(.active);
    const def = try ctx.createOne(.active);
    try ctx.flush();

    try testing.expectEqual(@as(usize, 2), ctx.entities(.active).len);
    try testing.expect(!ctx.isStale(imm));
    try testing.expect(!ctx.isStale(def));

    // Set data on both
    try ctx.set(imm, Position, .{ .x = 1, .y = 0, .z = 0 });
    try ctx.set(def, Position, .{ .x = 2, .y = 0, .z = 0 });

    const p1 = try ctx.get(imm, Position);
    const p2 = try ctx.get(def, Position);
    try testing.expectEqual(@as(f32, 1), p1.x);
    try testing.expectEqual(@as(f32, 2), p2.x);
}

test "swap-remove metadata correct after immediate destroy" {
    var ctx = try TestCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    const e0 = try ctx.createOneImmediate(.active);
    const e1 = try ctx.createOneImmediate(.active);
    const e2 = try ctx.createOneImmediate(.active);

    try ctx.set(e0, Position, .{ .x = 0, .y = 0, .z = 0 });
    try ctx.set(e1, Position, .{ .x = 1, .y = 0, .z = 0 });
    try ctx.set(e2, Position, .{ .x = 2, .y = 0, .z = 0 });

    try ctx.destroyImmediate(e0);

    // e1 and e2 should still be accessible
    const p1 = try ctx.get(e1, Position);
    const p2 = try ctx.get(e2, Position);
    try testing.expectEqual(@as(f32, 1), p1.x);
    try testing.expectEqual(@as(f32, 2), p2.x);
}

// ===========================================================================
// Re-entrant flush tests
// ===========================================================================

/// Component that holds another entity. On deinit, destroys that entity.
const LinkedEntity = struct {
    target: Entity = Entity.nil,

    pub const DeinitCtx = struct {
        ctx_ptr: *anyopaque,
        destroy_fn: *const fn (*anyopaque, Entity) void,
    };

    pub fn deinit(_: std.mem.Allocator, items: []LinkedEntity, dctx: *DeinitCtx) void {
        for (items) |item| {
            if (!item.target.isNil()) {
                dctx.destroy_fn(dctx.ctx_ptr, item.target);
            }
        }
    }
};

const LinkedRow = Row(&.{ Position, LinkedEntity });
const PlainRow = Row(&.{Position});

const ReentrantCtx = Context(spec_mod.MakeCollections(&.{
    spec_mod.col("linked", Collection(LinkedRow, .{})),
    spec_mod.col("plain", Collection(PlainRow, .{})),
}));

fn reentrantDestroyThunk(ctx_ptr: *anyopaque, entity: Entity) void {
    const ctx: *ReentrantCtx = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.isStale(entity)) {
        ctx.destroyOne(entity) catch {};
    }
}

test "re-entrant flush — deinit destroys another entity" {
    var ctx = try ReentrantCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    var dctx = LinkedEntity.DeinitCtx{
        .ctx_ptr = @ptrCast(&ctx),
        .destroy_fn = &reentrantDestroyThunk,
    };
    ctx.setDeinitCtx(LinkedEntity, &dctx);

    // Create entity B (the target)
    const b = try ctx.createOne(.plain);
    try ctx.flush();
    try testing.expect(!ctx.isStale(b));

    // Create entity A that links to B
    const a = try ctx.createOne(.linked);
    try ctx.flush();
    try ctx.set(a, LinkedEntity, .{ .target = b });

    // Destroy A — deinit fires, enqueues destroy of B.
    // Re-entrant flush should process both in one flush call.
    try ctx.destroyOne(a);
    try ctx.flush();

    try testing.expect(ctx.isStale(a));
    try testing.expect(ctx.isStale(b));
}

test "re-entrant flush — chain of three" {
    var ctx = try ReentrantCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    var dctx = LinkedEntity.DeinitCtx{
        .ctx_ptr = @ptrCast(&ctx),
        .destroy_fn = &reentrantDestroyThunk,
    };
    ctx.setDeinitCtx(LinkedEntity, &dctx);

    // C (plain) ← B (linked to C) ← A (linked to B)
    const c_ent = try ctx.createOne(.plain);
    const b = try ctx.createOne(.linked);
    const a = try ctx.createOne(.linked);
    try ctx.flush();

    try ctx.set(b, LinkedEntity, .{ .target = c_ent });
    try ctx.set(a, LinkedEntity, .{ .target = b });

    // Destroy A → deinit destroys B → deinit destroys C.
    // Three rounds of flush.
    try ctx.destroyOne(a);
    try ctx.flush();

    try testing.expect(ctx.isStale(a));
    try testing.expect(ctx.isStale(b));
    try testing.expect(ctx.isStale(c_ent));
}

test "re-entrant flush — deinit moves another entity" {
    const Mover = struct {
        target: Entity = Entity.nil,

        pub const DeinitCtx = struct {
            ctx_ptr: *anyopaque,
            move_fn: *const fn (*anyopaque, Entity) void,
        };

        pub fn deinit(_: std.mem.Allocator, items: []@This(), dctx: *DeinitCtx) void {
            for (items) |item| {
                if (!item.target.isNil()) {
                    dctx.move_fn(dctx.ctx_ptr, item.target);
                }
            }
        }
    };

    const MoverRow = Row(&.{ Position, Mover });
    const MoverCtx = Context(spec_mod.MakeCollections(&.{
        spec_mod.col("src", Collection(MoverRow, .{})),
        spec_mod.col("dst_a", Collection(PlainRow, .{})),
        spec_mod.col("dst_b", Collection(PlainRow, .{})),
    }));

    const moveThunk = struct {
        fn f(ctx_ptr: *anyopaque, entity: Entity) void {
            const mctx: *MoverCtx = @ptrCast(@alignCast(ctx_ptr));
            if (!mctx.isStale(entity)) {
                mctx.moveOneFrom(entity, .dst_a, .dst_b) catch {};
            }
        }
    }.f;

    var ctx = try MoverCtx.init(testing.allocator, .{ .max_entities = 64 });
    defer ctx.deinit();

    var dctx = Mover.DeinitCtx{
        .ctx_ptr = @ptrCast(&ctx),
        .move_fn = &moveThunk,
    };
    ctx.setDeinitCtx(Mover, &dctx);

    // Create target entity in dst_a
    const target = try ctx.createOne(.dst_a);
    // Create mover entity in src that will move target on deinit
    const mover = try ctx.createOne(.src);
    try ctx.flush();

    try ctx.set(mover, Mover, .{ .target = target });

    // Destroy mover → deinit moves target from dst_a to dst_b
    try ctx.destroyOne(mover);
    try ctx.flush();

    try testing.expect(ctx.isStale(mover));
    try testing.expect(!ctx.isStale(target));
    try testing.expect(ctx.isInCollection(target, .dst_b));
    try testing.expectEqual(@as(usize, 0), ctx.entities(.dst_a).len);
    try testing.expectEqual(@as(usize, 1), ctx.entities(.dst_b).len);
}
