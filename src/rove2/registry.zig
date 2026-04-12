const std = @import("std");
const entity_mod = @import("entity.zig");
const row_mod = @import("row.zig");
const collection_mod = @import("collection.zig");
const Entity = entity_mod.Entity;
const Row = row_mod.Row;
const Collection = collection_mod.Collection;
const effectiveAlign = collection_mod.effectiveAlign;

pub const RegistryConfig = struct {
    max_entities: u32,
    deferred_queue_capacity: u32 = 256,
};

pub const Registry = struct {
    const Self = @This();

    // Entity metadata (SoA)
    generations: []u32,
    collection_ids: []u8, // 0 = null pool (free)
    offsets: []u32,
    flags: []u8,

    max_entities: u32,

    // Null pool — free entity slots
    null_pool: []Entity,
    null_count: u32,

    // Collection registry — collections register themselves
    next_collection_id: u8,

    // Deferred queue — type-erased recipe fn pointers
    deferred_ops: []DeferredOp,
    deferred_count: u32,
    deferred_capacity: u32,

    // Lifecycle context registry — type-erased, keyed by type name pointer
    deinit_ctx_entries: [MAX_CTX_ENTRIES]CtxEntry,
    deinit_ctx_count: u8,
    init_ctx_entries: [MAX_CTX_ENTRIES]CtxEntry,
    init_ctx_count: u8,

    // Registered collections — for retroactive context propagation
    collection_entries: [MAX_COLLECTIONS]CollectionEntry,
    collection_entry_count: u8,

    allocator: std.mem.Allocator,

    const PENDING_MOVE: u8 = 1;
    const MAX_CTX_ENTRIES: usize = 32;
    const MAX_COLLECTIONS: usize = 256;

    const CtxEntry = struct {
        /// @typeName(T).ptr — unique, stable identifier for the component type
        type_name_ptr: [*]const u8,
        ctx_ptr: *anyopaque,
    };

    const CollectionEntry = struct {
        /// Type-erased collection pointer
        ptr: *anyopaque,
        /// Comptime-generated fn: checks if collection contains a component type
        /// (by type name ptr), and if so, calls setDeinitCtx/setInitCtx on it.
        apply_deinit_ctx: *const fn (*anyopaque, [*]const u8, *anyopaque) void,
        apply_init_ctx: *const fn (*anyopaque, [*]const u8, *anyopaque) void,
    };

    /// A deferred operation. The execute fn captures the comptime-specialized
    /// recipe AND the runtime collection pointers (via the src_ptr/dst_ptr).
    pub const DeferredOp = struct {
        src_collection_id: u8,
        src_offset: u32,
        count: u32,
        /// Type-erased recipe. The fn receives the registry, the src/dst
        /// collection pointers (type-erased), offset, and count.
        execute: *const fn (*Self, *anyopaque, *anyopaque, u32, u32) anyerror!void,
        src_ptr: *anyopaque,
        dst_ptr: *anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator, config: RegistryConfig) !Self {
        const max = config.max_entities;

        const generations = try allocator.alloc(u32, max);
        @memset(generations, 0);

        const collection_ids = try allocator.alloc(u8, max);
        @memset(collection_ids, 0);

        const offsets = try allocator.alloc(u32, max);
        const flags = try allocator.alloc(u8, max);
        @memset(flags, 0);

        // Initialize null pool — all entities start free
        const null_pool = try allocator.alloc(Entity, max);
        for (0..max) |i| {
            null_pool[i] = .{ .index = @intCast(i), .generation = 0 };
            offsets[i] = @intCast(i);
        }

        const deferred_ops = try allocator.alloc(DeferredOp, config.deferred_queue_capacity);

        return .{
            .generations = generations,
            .collection_ids = collection_ids,
            .offsets = offsets,
            .flags = flags,
            .max_entities = max,
            .null_pool = null_pool,
            .null_count = max,
            .next_collection_id = 1, // 0 is reserved for null
            .deferred_ops = deferred_ops,
            .deferred_count = 0,
            .deferred_capacity = config.deferred_queue_capacity,
            .deinit_ctx_entries = undefined,
            .deinit_ctx_count = 0,
            .init_ctx_entries = undefined,
            .init_ctx_count = 0,
            .collection_entries = undefined,
            .collection_entry_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.generations);
        self.allocator.free(self.collection_ids);
        self.allocator.free(self.offsets);
        self.allocator.free(self.flags);
        self.allocator.free(self.null_pool);
        self.allocator.free(self.deferred_ops);
        self.* = undefined;
    }

    /// Register an already-created collection with the registry.
    /// Assigns an ID and propagates any registered init/deinit contexts.
    pub inline fn registerCollection(self: *Self, coll: anytype) void {
        const CollType = @typeInfo(@TypeOf(coll)).pointer.child;

        coll.registry_id = self.next_collection_id;
        self.next_collection_id += 1;

        // Apply any already-registered deinit contexts to this collection
        for (self.deinit_ctx_entries[0..self.deinit_ctx_count]) |entry| {
            applyDeinitCtxFn(CollType)(coll, entry.type_name_ptr, entry.ctx_ptr);
        }

        // Apply any already-registered init contexts to this collection
        for (self.init_ctx_entries[0..self.init_ctx_count]) |entry| {
            applyInitCtxFn(CollType)(coll, entry.type_name_ptr, entry.ctx_ptr);
        }

        // Store for retroactive propagation when new contexts are registered later
        self.collection_entries[self.collection_entry_count] = .{
            .ptr = @ptrCast(coll),
            .apply_deinit_ctx = applyDeinitCtxErased(CollType),
            .apply_init_ctx = applyInitCtxErased(CollType),
        };
        self.collection_entry_count += 1;
    }

    /// Register a deinit context for a component type. Propagates to all
    /// already-registered collections that contain the component, and will
    /// be applied to any collections registered in the future.
    pub inline fn setDeinitCtx(self: *Self, comptime T: type, ctx: *T.DeinitCtx) void {
        const entry = CtxEntry{
            .type_name_ptr = @typeName(T).ptr,
            .ctx_ptr = @ptrCast(ctx),
        };
        self.deinit_ctx_entries[self.deinit_ctx_count] = entry;
        self.deinit_ctx_count += 1;

        // Retroactively apply to all already-registered collections
        for (self.collection_entries[0..self.collection_entry_count]) |coll_entry| {
            coll_entry.apply_deinit_ctx(coll_entry.ptr, entry.type_name_ptr, entry.ctx_ptr);
        }
    }

    /// Register an init context for a component type.
    pub inline fn setInitCtx(self: *Self, comptime T: type, ctx: *T.InitCtx) void {
        const entry = CtxEntry{
            .type_name_ptr = @typeName(T).ptr,
            .ctx_ptr = @ptrCast(ctx),
        };
        self.init_ctx_entries[self.init_ctx_count] = entry;
        self.init_ctx_count += 1;

        for (self.collection_entries[0..self.collection_entry_count]) |coll_entry| {
            coll_entry.apply_init_ctx(coll_entry.ptr, entry.type_name_ptr, entry.ctx_ptr);
        }
    }

    /// Generate a typed "apply deinit ctx" function for a specific collection type.
    /// At comptime, iterates the collection's Row types. At runtime, matches by
    /// type name pointer and calls setDeinitCtx if found.
    fn applyDeinitCtxFn(comptime CollType: type) *const fn (*CollType, [*]const u8, *anyopaque) void {
        return &struct {
            fn apply(coll: *CollType, type_name_ptr: [*]const u8, ctx_ptr: *anyopaque) void {
                inline for (CollType.RowType.types) |T| {
                    if (comptime row_mod.componentDeinitNeedsCtx(T)) {
                        if (@typeName(T).ptr == type_name_ptr) {
                            coll.setDeinitCtx(T, @ptrCast(@alignCast(ctx_ptr)));
                        }
                    }
                }
            }
        }.apply;
    }

    /// Type-erased version for storage in collection_entries.
    fn applyDeinitCtxErased(comptime CollType: type) *const fn (*anyopaque, [*]const u8, *anyopaque) void {
        return &struct {
            fn apply(coll_raw: *anyopaque, type_name_ptr: [*]const u8, ctx_ptr: *anyopaque) void {
                const coll: *CollType = @ptrCast(@alignCast(coll_raw));
                applyDeinitCtxFn(CollType)(coll, type_name_ptr, ctx_ptr);
            }
        }.apply;
    }

    fn applyInitCtxFn(comptime CollType: type) *const fn (*CollType, [*]const u8, *anyopaque) void {
        return &struct {
            fn apply(coll: *CollType, type_name_ptr: [*]const u8, ctx_ptr: *anyopaque) void {
                inline for (CollType.RowType.types) |T| {
                    if (comptime row_mod.componentInitNeedsCtx(T)) {
                        if (@typeName(T).ptr == type_name_ptr) {
                            coll.setInitCtx(T, @ptrCast(@alignCast(ctx_ptr)));
                        }
                    }
                }
            }
        }.apply;
    }

    fn applyInitCtxErased(comptime CollType: type) *const fn (*anyopaque, [*]const u8, *anyopaque) void {
        return &struct {
            fn apply(coll_raw: *anyopaque, type_name_ptr: [*]const u8, ctx_ptr: *anyopaque) void {
                const coll: *CollType = @ptrCast(@alignCast(coll_raw));
                applyInitCtxFn(CollType)(coll, type_name_ptr, ctx_ptr);
            }
        }.apply;
    }

    // =============================================================
    // Create — immediate for now (entity is live right away)
    // =============================================================

    pub inline fn create(self: *Self, dst: anytype) !Entity {
        if (self.null_count == 0) return error.Full;
        self.null_count -= 1;
        const entity = self.null_pool[self.null_count];

        // appendEntity → appendEntities(1) handles zero-init + init()
        const offset = try dst.appendEntity(entity);

        self.collection_ids[entity.index] = dst.registry_id;
        self.offsets[entity.index] = offset;

        return entity;
    }

    // =============================================================
    // Destroy — deferred
    // =============================================================

    pub inline fn destroy(self: *Self, entity: Entity, src: anytype) !void {
        const SrcColl = @typeInfo(@TypeOf(src)).pointer.child;
        const idx = entity.index;
        if (idx >= self.max_entities) return error.InvalidEntity;
        if (self.generations[idx] != entity.generation) return error.Stale;
        if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;
        if (self.collection_ids[idx] != src.registry_id) return error.WrongCollection;

        self.flags[idx] |= PENDING_MOVE;

        const recipe = destroyRecipe(SrcColl);
        try self.enqueueOp(.{
            .src_collection_id = src.registry_id,
            .src_offset = self.offsets[idx],
            .count = 1,
            .execute = recipe,
            .src_ptr = @ptrCast(src),
            .dst_ptr = @ptrFromInt(1), // unused for destroy
        });
    }

    // =============================================================
    // moveFrom — the core primitive
    // =============================================================

    pub inline fn moveFrom(self: *Self, entity: Entity, src: anytype, dst: anytype) !void {
        const SrcColl = @typeInfo(@TypeOf(src)).pointer.child;
        const DstColl = @typeInfo(@TypeOf(dst)).pointer.child;
        const idx = entity.index;
        if (idx >= self.max_entities) return error.InvalidEntity;
        if (self.generations[idx] != entity.generation) return error.Stale;
        if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;
        if (self.collection_ids[idx] != src.registry_id) return error.WrongCollection;

        // Comptime validation: src row must be subset of dst row
        comptime {
            if (!SrcColl.RowType.isSubsetOf(DstColl.RowType)) {
                @compileError("moveFrom: source row is not a subset of destination row");
            }
        }

        self.flags[idx] |= PENDING_MOVE;

        // Lazily specialized recipe for this (SrcColl, DstColl) pair
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

    // =============================================================
    // moveAnyFrom — runtime source dispatch over a comptime set
    // =============================================================

    /// Move an entity to `dst` from whichever of `sources` it's currently in.
    /// `sources` is a tuple of collection pointers (e.g., `.{ &a, &b, &c }`).
    /// Only generates recipes for the (src, dst) pairs in the tuple — not N².
    /// Returns error.WrongCollection if the entity isn't in any of them.
    pub inline fn moveAnyFrom(self: *Self, entity: Entity, sources: anytype, dst: anytype) !void {
        const idx = entity.index;
        if (idx >= self.max_entities) return error.InvalidEntity;
        if (self.generations[idx] != entity.generation) return error.Stale;
        if (self.flags[idx] & PENDING_MOVE != 0) return error.PendingMove;

        const current_id = self.collection_ids[idx];
        const DstColl = @typeInfo(@TypeOf(dst)).pointer.child;

        // Unroll over the tuple — each branch is a comptime-known (SrcColl, DstColl) pair
        inline for (@typeInfo(@TypeOf(sources)).@"struct".fields) |field| {
            const src = @field(sources, field.name);
            const SrcColl = @typeInfo(@TypeOf(src)).pointer.child;

            // Comptime validation per pair
            comptime {
                if (!SrcColl.RowType.isSubsetOf(DstColl.RowType)) {
                    @compileError("moveAnyFrom: source row is not a subset of destination row");
                }
            }

            if (current_id == src.registry_id) {
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
                return;
            }
        }

        // Entity wasn't in any of the listed sources
        return error.WrongCollection;
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

            // Shift any ops enqueued during this round to the front
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

    pub inline fn get(self: *Self, entity: Entity, coll: anytype, comptime T: type) !*T {
        const idx = entity.index;
        if (idx >= self.max_entities) return error.InvalidEntity;
        if (self.generations[idx] != entity.generation) return error.Stale;
        if (self.collection_ids[idx] != coll.registry_id) return error.WrongCollection;
        return &coll.column(T)[self.offsets[idx]];
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

    /// Comptime-generated move recipe for (SrcColl, DstColl).
    /// Only instantiated if a moveFrom call site references this pair.
    fn moveRecipe(comptime SrcColl: type, comptime DstColl: type) *const fn (*Self, *anyopaque, *anyopaque, u32, u32) anyerror!void {
        const SrcRow = SrcColl.RowType;
        const DstRow = DstColl.RowType;

        const Shared = SrcRow.intersect(DstRow);
        const New = DstRow.subtract(&SrcRow.types);
        const Dropped = SrcRow.subtract(&DstRow.types);

        return &struct {
            fn execute(reg: *Self, src_raw: *anyopaque, dst_raw: *anyopaque, src_offset: u32, count: u32) anyerror!void {
                const src_coll: *SrcColl = @ptrCast(@alignCast(src_raw));
                const dst_coll: *DstColl = @ptrCast(@alignCast(dst_raw));

                // Reserve slots — no zero-init, no init
                const dest_base = try dst_coll.reserveSlots(count);
                const src_entities = src_coll.entitySlice();

                // Copy entity handles
                @memcpy(
                    dst_coll.entitySlice()[dest_base .. dest_base + count],
                    src_entities[src_offset .. src_offset + count],
                );

                // Copy shared components (no init needed — data comes from source)
                inline for (Shared.types) |T| {
                    @memcpy(
                        dst_coll.column(T)[dest_base .. dest_base + count],
                        src_coll.column(T)[src_offset .. src_offset + count],
                    );
                }

                // Zero-init + init only NEW components (not in source row)
                inline for (New.types) |T| {
                    if (@sizeOf(T) > 0) {
                        const col = dst_coll.column(T);
                        const bytes: [*]u8 = @ptrCast(col.ptr);
                        const byte_offset = dest_base * @sizeOf(T);
                        const byte_len = count * @sizeOf(T);
                        @memset(bytes[byte_offset .. byte_offset + byte_len], 0);
                    }
                }
                inline for (comptime New.initTypes()) |T| {
                    dst_coll.callInit(T, dst_coll.column(T)[dest_base .. dest_base + count]);
                }

                // Deinit dropped components (in source but not destination)
                inline for (comptime Dropped.deinitTypes()) |T| {
                    src_coll.callDeinit(T, src_coll.column(T)[src_offset .. src_offset + count]);
                }

                // Update registry metadata
                for (0..count) |k| {
                    const entity = src_entities[src_offset + k];
                    const idx = entity.index;
                    reg.collection_ids[idx] = dst_coll.registry_id;
                    reg.offsets[idx] = dest_base + @as(u32, @intCast(k));
                    reg.flags[idx] &= ~PENDING_MOVE;
                }

                // Remove from source — returns entities that were moved to fill gap
                const moved = src_coll.removeRun(src_offset, count);
                for (moved, 0..) |moved_entity, r| {
                    reg.offsets[moved_entity.index] = src_offset + @as(u32, @intCast(r));
                }
            }
        }.execute;
    }

    /// Comptime-generated destroy recipe.
    fn destroyRecipe(comptime SrcColl: type) *const fn (*Self, *anyopaque, *anyopaque, u32, u32) anyerror!void {
        const SrcRow = SrcColl.RowType;

        return &struct {
            fn execute(reg: *Self, src_raw: *anyopaque, _: *anyopaque, src_offset: u32, count: u32) anyerror!void {
                const src_coll: *SrcColl = @ptrCast(@alignCast(src_raw));
                const src_entities = src_coll.entitySlice();

                // Deinit all components
                inline for (comptime SrcRow.deinitTypes()) |T| {
                    src_coll.callDeinit(T, src_coll.column(T)[src_offset .. src_offset + count]);
                }

                // Return entities to null pool, bump generation
                for (0..count) |k| {
                    const entity = src_entities[src_offset + k];
                    const idx = entity.index;
                    reg.generations[idx] += 1;
                    reg.collection_ids[idx] = 0;
                    reg.flags[idx] &= ~PENDING_MOVE;
                    reg.null_pool[reg.null_count] = .{ .index = idx, .generation = reg.generations[idx] };
                    reg.null_count += 1;
                }

                // Remove from source
                const moved = src_coll.removeRun(src_offset, count);
                for (moved, 0..) |moved_entity, r| {
                    reg.offsets[moved_entity.index] = src_offset + @as(u32, @intCast(r));
                }
            }
        }.execute;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const Position = struct { x: f32, y: f32, z: f32 };
const Velocity = struct { x: f32, y: f32, z: f32 };
const Health = struct {
    current: i32,
    max: i32,

    pub fn init(items: []Health) void {
        for (items) |*item| {
            item.* = .{ .current = 100, .max = 100 };
        }
    }

    pub fn deinit(_: std.mem.Allocator, items: []Health) void {
        _ = items;
    }
};

test "minimal app" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    var spawning = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer spawning.deinit();
    reg.registerCollection(&spawning);

    var active = try Collection(Row(&.{ Position, Velocity }), .{}).init(testing.allocator);
    defer active.deinit();
    reg.registerCollection(&active);

    const e = try reg.create(&spawning);
    (try reg.get(e, &spawning, Position)).* = .{ .x = 1, .y = 2, .z = 0 };

    try reg.moveFrom(e, &spawning, &active);
    try reg.flush();

    try testing.expectEqual(@as(f32, 1), (try reg.get(e, &active, Position)).x);
    try testing.expectEqual(@as(u32, 0), spawning.count);
    try testing.expectEqual(@as(u32, 1), active.count);
}

test "create entity in standalone collection" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    var active = try Collection(Row(&.{ Position, Velocity }), .{}).init(testing.allocator);
    defer active.deinit();
    reg.registerCollection(&active);

    const e = try reg.create(&active);
    try testing.expect(!reg.isStale(e));
    try testing.expectEqual(@as(u32, 1), active.count);
}

test "moveFrom between standalone collections" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    var narrow = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer narrow.deinit();
    reg.registerCollection(&narrow);

    var wide = try Collection(Row(&.{ Position, Velocity }), .{}).init(testing.allocator);
    defer wide.deinit();
    reg.registerCollection(&wide);

    const e = try reg.create(&narrow);
    const pos_ptr = try reg.get(e, &narrow, Position);
    pos_ptr.* = .{ .x = 42, .y = 0, .z = 0 };

    try reg.moveFrom(e, &narrow, &wide);
    try reg.flush();

    try testing.expectEqual(@as(u32, 0), narrow.count);
    try testing.expectEqual(@as(u32, 1), wide.count);

    const pos = try reg.get(e, &wide, Position);
    try testing.expectEqual(@as(f32, 42), pos.x);
}

test "destroy entity" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();
    reg.registerCollection(&coll);

    const e = try reg.create(&coll);
    try reg.destroy(e, &coll);
    try reg.flush();

    try testing.expect(reg.isStale(e));
    try testing.expectEqual(@as(u32, 0), coll.count);
}

test "row-polymorphic system" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    var coll = try Collection(Row(&.{Position}).merge(Row(&.{Health})), .{}).init(testing.allocator);
    defer coll.deinit();
    reg.registerCollection(&coll);

    const e = try reg.create(&coll);
    const pos = try reg.get(e, &coll, Position);
    pos.* = .{ .x = 0, .y = 0, .z = 0 };

    applyGravity(&coll);

    try testing.expectEqual(@as(f32, -9.8), coll.column(Position)[0].y);

    const hp = try reg.get(e, &coll, Health);
    try testing.expectEqual(@as(i32, 100), hp.current);
}

fn applyGravity(coll: anytype) void {
    for (coll.column(Position)) |*pos| {
        pos.y -= 9.8;
    }
}

test "multiple moves then flush" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    var a = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer a.deinit();
    reg.registerCollection(&a);

    var b = try Collection(Row(&.{ Position, Velocity }), .{}).init(testing.allocator);
    defer b.deinit();
    reg.registerCollection(&b);

    var entities: [5]Entity = undefined;
    for (&entities, 0..) |*e, i| {
        e.* = try reg.create(&a);
        const pos = try reg.get(e.*, &a, Position);
        pos.* = .{ .x = @floatFromInt(i), .y = 0, .z = 0 };
    }

    for (entities) |e| {
        try reg.moveFrom(e, &a, &b);
    }
    try reg.flush();

    try testing.expectEqual(@as(u32, 0), a.count);
    try testing.expectEqual(@as(u32, 5), b.count);

    for (b.column(Position), 0..) |pos, i| {
        try testing.expectEqual(@as(f32, @floatFromInt(i)), pos.x);
    }
}

test "moveAnyFrom — entity in one of several sources" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    var init_coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer init_coll.deinit();
    reg.registerCollection(&init_coll);

    var pending = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer pending.deinit();
    reg.registerCollection(&pending);

    var active = try Collection(Row(&.{ Position, Velocity }), .{}).init(testing.allocator);
    defer active.deinit();
    reg.registerCollection(&active);

    var done = try Collection(Row(&.{ Position, Velocity }), .{}).init(testing.allocator);
    defer done.deinit();
    reg.registerCollection(&done);

    const e1 = try reg.create(&init_coll);
    (try reg.get(e1, &init_coll, Position)).x = 1;

    const e2 = try reg.create(&pending);
    (try reg.get(e2, &pending, Position)).x = 2;

    const e3 = try reg.create(&active);
    (try reg.get(e3, &active, Position)).x = 3;

    try reg.moveAnyFrom(e1, .{ &init_coll, &pending, &active }, &done);
    try reg.moveAnyFrom(e2, .{ &init_coll, &pending, &active }, &done);
    try reg.moveAnyFrom(e3, .{ &init_coll, &pending, &active }, &done);
    try reg.flush();

    try testing.expectEqual(@as(u32, 0), init_coll.count);
    try testing.expectEqual(@as(u32, 0), pending.count);
    try testing.expectEqual(@as(u32, 0), active.count);
    try testing.expectEqual(@as(u32, 3), done.count);

    try testing.expectEqual(@as(f32, 1), (try reg.get(e1, &done, Position)).x);
    try testing.expectEqual(@as(f32, 2), (try reg.get(e2, &done, Position)).x);
    try testing.expectEqual(@as(f32, 3), (try reg.get(e3, &done, Position)).x);
}

test "moveAnyFrom — wrong collection returns error" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    var a = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer a.deinit();
    reg.registerCollection(&a);

    var b = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer b.deinit();
    reg.registerCollection(&b);

    var dst = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer dst.deinit();
    reg.registerCollection(&dst);

    const e = try reg.create(&a);
    try testing.expectError(error.WrongCollection, reg.moveAnyFrom(e, .{&b}, &dst));
}

// Component with side-effecting init/deinit for lifecycle verification
var init_counter: u32 = 0;
var deinit_counter: u32 = 0;

const Tracked = struct {
    value: u32,

    pub fn init(items: []Tracked) void {
        for (items) |*item| {
            item.value = 999;
        }
        init_counter += @intCast(items.len);
    }

    pub fn deinit(_: std.mem.Allocator, items: []Tracked) void {
        deinit_counter += @intCast(items.len);
    }
};

test "moveFrom — deinit fires on dropped components" {
    init_counter = 0;
    deinit_counter = 0;

    var reg = try Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    var wide = try Collection(Row(&.{ Position, Tracked }), .{}).init(testing.allocator);
    defer wide.deinit();
    reg.registerCollection(&wide);

    var narrow = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer narrow.deinit();
    reg.registerCollection(&narrow);

    const e = try reg.create(&wide);
    try testing.expectEqual(@as(u32, 1), init_counter);
    (try reg.get(e, &wide, Tracked)).value = 42;

    init_counter = 0;
    deinit_counter = 0;

    try reg.destroy(e, &wide);
    try reg.flush();

    try testing.expectEqual(@as(u32, 1), deinit_counter);
    try testing.expect(reg.isStale(e));
}

test "moveFrom — init fires on new components, shared components copied" {
    init_counter = 0;
    deinit_counter = 0;

    var reg = try Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    var narrow = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer narrow.deinit();
    reg.registerCollection(&narrow);

    var wide = try Collection(Row(&.{ Position, Tracked }), .{}).init(testing.allocator);
    defer wide.deinit();
    reg.registerCollection(&wide);

    const e = try reg.create(&narrow);
    (try reg.get(e, &narrow, Position)).x = 77;

    init_counter = 0;

    try reg.moveFrom(e, &narrow, &wide);
    try reg.flush();

    const pos = try reg.get(e, &wide, Position);
    try testing.expectEqual(@as(f32, 77), pos.x);

    const tracked = try reg.get(e, &wide, Tracked);
    try testing.expectEqual(@as(u32, 999), tracked.value);
    try testing.expectEqual(@as(u32, 1), init_counter);
}

test "moveAnyFrom — lifecycle through multiple sources" {
    init_counter = 0;
    deinit_counter = 0;

    var reg = try Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    var src_a = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer src_a.deinit();
    reg.registerCollection(&src_a);

    var src_b = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer src_b.deinit();
    reg.registerCollection(&src_b);

    var dst = try Collection(Row(&.{ Position, Tracked }), .{}).init(testing.allocator);
    defer dst.deinit();
    reg.registerCollection(&dst);

    const e1 = try reg.create(&src_a);
    (try reg.get(e1, &src_a, Position)).x = 10;

    const e2 = try reg.create(&src_b);
    (try reg.get(e2, &src_b, Position)).x = 20;

    init_counter = 0;

    try reg.moveAnyFrom(e1, .{ &src_a, &src_b }, &dst);
    try reg.moveAnyFrom(e2, .{ &src_a, &src_b }, &dst);
    try reg.flush();

    try testing.expectEqual(@as(u32, 2), dst.count);
    try testing.expectEqual(@as(f32, 10), (try reg.get(e1, &dst, Position)).x);
    try testing.expectEqual(@as(f32, 20), (try reg.get(e2, &dst, Position)).x);
    try testing.expectEqual(@as(u32, 2), init_counter);
    try testing.expectEqual(@as(u32, 999), (try reg.get(e1, &dst, Tracked)).value);
    try testing.expectEqual(@as(u32, 999), (try reg.get(e2, &dst, Tracked)).value);
}

test "setDeinitCtx — propagates to registered collections" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    const Resource = struct {
        handle: u32,

        pub const DeinitCtx = u32; // just a counter for testing

        pub fn deinit(_: std.mem.Allocator, items: []@This(), ctx: *u32) void {
            ctx.* += @intCast(items.len);
        }
    };

    var counter: u32 = 0;

    var coll = try Collection(Row(&.{ Position, Resource }), .{}).init(testing.allocator);
    defer coll.deinit();

    // Register context BEFORE collection — forward propagation
    reg.setDeinitCtx(Resource, &counter);
    reg.registerCollection(&coll);

    const e = try reg.create(&coll);
    (try reg.get(e, &coll, Resource)).handle = 42;

    try reg.destroy(e, &coll);
    try reg.flush();

    // DeinitCtx should have been called
    try testing.expectEqual(@as(u32, 1), counter);
}

test "setDeinitCtx — retroactive propagation" {
    var reg = try Registry.init(testing.allocator, .{ .max_entities = 16 });
    defer reg.deinit();

    const Resource = struct {
        handle: u32,

        pub const DeinitCtx = u32;

        pub fn deinit(_: std.mem.Allocator, items: []@This(), ctx: *u32) void {
            ctx.* += @intCast(items.len);
        }
    };

    var counter: u32 = 0;

    var coll = try Collection(Row(&.{ Position, Resource }), .{}).init(testing.allocator);
    defer coll.deinit();

    // Register collection BEFORE context — retroactive propagation
    reg.registerCollection(&coll);
    reg.setDeinitCtx(Resource, &counter);

    const e = try reg.create(&coll);
    try reg.destroy(e, &coll);
    try reg.flush();

    try testing.expectEqual(@as(u32, 1), counter);
}
