const std = @import("std");
const row_mod = @import("row.zig");
const entity_mod = @import("entity.zig");
const Entity = entity_mod.Entity;
const Row = row_mod.Row;

/// Returns the effective byte alignment for a component type. If the type
/// declares `pub const alignment`, that value is used; otherwise @alignOf(T).
/// Components requiring SIMD alignment should declare e.g. `pub const alignment = 32;`
pub fn effectiveAlign(comptime T: type) comptime_int {
    return if (@hasDecl(T, "alignment")) @field(T, "alignment") else @alignOf(T);
}

/// Convert a byte alignment to std.mem.Alignment (log2 enum) for use with
/// the allocator's alignedAlloc.
fn toAlignment(comptime bytes: comptime_int) std.mem.Alignment {
    return @enumFromInt(std.math.log2_int(usize, bytes));
}

pub const CollectionOptions = struct {
    /// Fixed capacity. When set, the collection pre-allocates at init and
    /// never grows. appendEntity returns error.Full when at capacity.
    /// When null (default), the collection grows dynamically.
    capacity: ?u32 = null,
};

/// SoA storage typed by a comptime Row. Each component type in the row
/// gets its own contiguous, properly aligned array. Entities are stored
/// alongside as handles.
///
/// Components may declare `pub const alignment = N;` to request over-aligned
/// column storage (e.g. 32 for AVX, 64 for AVX-512). Column base pointers
/// are guaranteed to satisfy this alignment.
///
/// Usage:
///   // Dynamic growth (default)
///   var coll = try Collection(MyRow, .{}).init(allocator);
///
///   // Fixed capacity — one allocation at init, never grows
///   var coll = try Collection(MyRow, .{ .capacity = 1024 }).init(allocator);
///
pub fn Collection(comptime R: type, comptime options: CollectionOptions) type {
    if (!@hasDecl(R, "types") or !@hasDecl(R, "len")) {
        @compileError("Collection requires a Row type");
    }

    return struct {
        const Self = @This();

        /// The Row type this collection is parameterized on.
        pub const RowType = R;

        /// The options this collection was created with.
        pub const opts = options;

        entities: ?[*]Entity,
        columns: [R.len]?[*]u8,
        count: u32,
        capacity: u32,
        allocator: std.mem.Allocator,

        // Lifecycle context pointers (one per component slot, null if not needed)
        init_ctxs: [R.len]?*anyopaque,
        deinit_ctxs: [R.len]?*anyopaque,

        /// Create a new collection. For fixed-capacity collections, this
        /// performs the single up-front allocation. For dynamic collections,
        /// no allocation occurs until the first append.
        pub fn init(allocator: std.mem.Allocator) !Self {
            var self = Self{
                .entities = null,
                .columns = [_]?[*]u8{null} ** R.len,
                .count = 0,
                .capacity = 0,
                .allocator = allocator,
                .init_ctxs = [_]?*anyopaque{null} ** R.len,
                .deinit_ctxs = [_]?*anyopaque{null} ** R.len,
            };
            if (options.capacity) |cap| {
                try self.allocateStorage(cap);
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            // Call batch deinit for every live entity
            inline for (comptime R.deinitTypes()) |T| {
                const idx = comptime columnIndex(T);
                if (self.columns[idx]) |raw| {
                    self.callDeinit(T, alignedSlice(T, raw, self.count));
                }
            }

            // Free entity array
            if (self.entities) |e| {
                self.allocator.free(e[0..self.capacity]);
            }

            // Free each column with correct alignment
            inline for (R.types, 0..) |T, i| {
                if (self.columns[i]) |raw| {
                    freeColumn(T, self.allocator, raw, self.capacity);
                }
            }

            self.* = undefined;
        }

        /// Returns a typed, properly aligned slice for the given component.
        /// Compile error if T is not in this collection's row.
        pub fn column(self: *const Self, comptime T: type) []align(effectiveAlign(T)) T {
            const idx = comptime columnIndex(T);
            const ptr = self.columns[idx] orelse return emptyAlignedSlice(T);
            return alignedSlice(T, ptr, self.count);
        }

        /// Returns the entity handles for all live entities.
        pub fn entitySlice(self: *const Self) []Entity {
            const ptr = self.entities orelse return &[_]Entity{};
            return ptr[0..self.count];
        }

        /// Register a typed init context for a component. The component must
        /// declare `pub const InitCtx = SomeType` and its init must accept
        /// `*InitCtx` as the second parameter.
        pub fn setInitCtx(self: *Self, comptime T: type, ctx: *T.InitCtx) void {
            const idx = comptime columnIndex(T);
            self.init_ctxs[idx] = @ptrCast(ctx);
        }

        /// Register a typed deinit context for a component.
        pub fn setDeinitCtx(self: *Self, comptime T: type, ctx: *T.DeinitCtx) void {
            const idx = comptime columnIndex(T);
            self.deinit_ctxs[idx] = @ptrCast(ctx);
        }

        /// Pre-allocate storage for at least `min_capacity` entities.
        /// For fixed-capacity collections, returns error.Full if min_capacity
        /// exceeds the fixed capacity.
        pub fn ensureCapacity(self: *Self, min_capacity: u32) !void {
            if (min_capacity <= self.capacity) return;

            if (options.capacity) |cap| {
                if (min_capacity > cap) return error.Full;
                // Fixed collection is already fully allocated at init
                return;
            }

            try self.allocateStorage(nextPow2(min_capacity));
        }

        /// Add a single entity. Convenience wrapper around appendEntities.
        pub fn appendEntity(self: *Self, entity: Entity) !u32 {
            const offset = try self.appendEntities(1);
            self.entities.?[offset] = entity;
            return offset;
        }

        /// Batch-append `count` entities. Zero-inits all component slots and
        /// calls batch init(). Returns the starting offset. Entity handles
        /// must be written by the caller into `entitySlice()[offset..offset+count]`.
        pub fn appendEntities(self: *Self, count: u32) !u32 {
            const needed = self.count + count;
            if (needed > self.capacity) {
                if (options.capacity != null) {
                    return error.Full;
                }
                var new_cap = if (self.capacity == 0) @as(u32, 8) else self.capacity;
                while (new_cap < needed) new_cap *= 2;
                try self.allocateStorage(new_cap);
            }

            const offset = self.count;

            // Zero-init all component slots for the batch (byte-level zero)
            inline for (R.types, 0..) |T, i| {
                if (@sizeOf(T) > 0) {
                    const raw: [*]u8 = self.columns[i].?;
                    const byte_offset = offset * @sizeOf(T);
                    const byte_len = count * @sizeOf(T);
                    @memset(raw[byte_offset .. byte_offset + byte_len], 0);
                }
            }

            // Call batch init() on components that have it
            inline for (comptime R.initTypes()) |T| {
                const idx = comptime columnIndex(T);
                const typed = alignedPtr(T, self.columns[idx].?);
                self.callInit(T, typed[offset .. offset + count]);
            }

            self.count += count;
            return offset;
        }

        /// Remove a single entity at `offset`. Calls batch deinit on its
        /// components. Convenience wrapper around removeRun.
        pub fn swapRemove(self: *Self, offset: u32) ?Entity {
            // Call deinit on the removed entity's components
            inline for (comptime R.deinitTypes()) |T| {
                const idx = comptime columnIndex(T);
                const typed = alignedPtr(T, self.columns[idx].?);
                self.callDeinit(T, typed[offset .. offset + 1]);
            }

            const moved = self.removeRun(offset, 1);
            return if (moved.len > 0) moved[0] else null;
        }

        /// Remove a contiguous run of `run_count` entities starting at `start_offset`.
        /// Fills the gap by copying min(run_count, entities_after_run) entities from
        /// the tail. Does NOT call deinit — caller handles that. Returns a slice of
        /// entities that were moved (the tail entities that filled the gap), so the
        /// caller can update metadata.
        pub fn removeRun(self: *Self, start_offset: u32, run_count: u32) []const Entity {
            std.debug.assert(start_offset + run_count <= self.count);

            const n = self.count;
            const after_run = n - start_offset - run_count;
            const copy_count = @min(run_count, after_run);

            if (copy_count > 0) {
                const src_start = n - copy_count;
                const ents = self.entities.?;
                @memcpy(ents[start_offset .. start_offset + copy_count], ents[src_start .. src_start + copy_count]);
                inline for (R.types, 0..) |T, i| {
                    const typed = alignedPtr(T, self.columns[i].?);
                    @memcpy(typed[start_offset .. start_offset + copy_count], typed[src_start .. src_start + copy_count]);
                }
            }

            self.count -= run_count;

            if (copy_count > 0) {
                return self.entities.?[start_offset .. start_offset + copy_count];
            }
            return &[_]Entity{};
        }

        // ---------------------------------------------------------------
        // Internal helpers
        // ---------------------------------------------------------------

        /// Call batch init with or without context, depending on the component type.
        /// If a context is required but not registered, the init is skipped.
        pub fn callInit(self: *Self, comptime T: type, items: []T) void {
            if (comptime row_mod.componentInitNeedsCtx(T)) {
                const idx = comptime columnIndex(T);
                const raw = self.init_ctxs[idx] orelse return;
                T.init(items, @ptrCast(@alignCast(raw)));
            } else {
                T.init(items);
            }
        }

        /// Call batch deinit with or without context, depending on the component type.
        /// If a context is required but not registered, the deinit is skipped.
        pub fn callDeinit(self: *Self, comptime T: type, items: []T) void {
            if (comptime row_mod.componentDeinitNeedsCtx(T)) {
                const idx = comptime columnIndex(T);
                const raw = self.deinit_ctxs[idx] orelse return;
                T.deinit(self.allocator, items, @ptrCast(@alignCast(raw)));
            } else {
                T.deinit(self.allocator, items);
            }
        }

        /// Allocate (or reallocate) storage for `new_cap` entities.
        fn allocateStorage(self: *Self, new_cap: u32) !void {
            const new_entities = try self.allocator.alloc(Entity, new_cap);
            if (self.entities) |old| {
                @memcpy(new_entities[0..self.count], old[0..self.count]);
                self.allocator.free(old[0..self.capacity]);
            }
            self.entities = new_entities.ptr;

            inline for (R.types, 0..) |T, i| {
                const new_col = try self.allocator.alignedAlloc(T, comptime toAlignment(effectiveAlign(T)), new_cap);
                if (self.columns[i]) |old_raw| {
                    @memcpy(new_col[0..self.count], alignedSlice(T, old_raw, self.count));
                    freeColumn(T, self.allocator, old_raw, self.capacity);
                }
                self.columns[i] = @ptrCast(new_col.ptr);
            }

            self.capacity = new_cap;
        }

        fn columnIndex(comptime T: type) comptime_int {
            inline for (R.types, 0..) |U, i| {
                if (U == T) return i;
            }
            @compileError("Component " ++ @typeName(T) ++ " is not in this collection's row");
        }

        fn alignedPtr(comptime T: type, raw: [*]u8) [*]align(effectiveAlign(T)) T {
            const A = comptime effectiveAlign(T);
            return @ptrCast(@as([*]align(A) u8, @alignCast(raw)));
        }

        fn alignedSlice(comptime T: type, raw: [*]u8, len: u32) []align(effectiveAlign(T)) T {
            return alignedPtr(T, raw)[0..len];
        }

        fn emptyAlignedSlice(comptime T: type) []align(effectiveAlign(T)) T {
            const A = comptime effectiveAlign(T);
            const empty: [*]align(A) T = @ptrFromInt(A);
            return empty[0..0];
        }

        fn freeColumn(comptime T: type, allocator: std.mem.Allocator, raw: [*]u8, capacity: u32) void {
            allocator.free(alignedPtr(T, raw)[0..capacity]);
        }

        fn nextPow2(v: u32) u32 {
            if (v == 0) return 1;
            var n = v - 1;
            n |= n >> 1;
            n |= n >> 2;
            n |= n >> 4;
            n |= n >> 8;
            n |= n >> 16;
            return n + 1;
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
        for (items) |*item| {
            item.* = .{ .current = 100, .max = 100 };
        }
    }

    pub fn deinit(_: std.mem.Allocator, items: []Health) void {
        _ = items;
    }
};
const Tag = struct {};

var deinit_counter: u32 = 0;
const Tracked = struct {
    value: u32,

    pub fn deinit(_: std.mem.Allocator, items: []Tracked) void {
        deinit_counter += @intCast(items.len);
    }
};

const SimdVec = struct {
    data: [8]f32,
    pub const alignment = 32;
};

fn makeEntity(index: u32) Entity {
    return .{ .index = index, .generation = 0 };
}

// ---------------------------------------------------------------------------
// Dynamic collection tests
// ---------------------------------------------------------------------------

test "init/deinit empty" {
    var coll = try Collection(Row(&.{ Position, Velocity }), .{}).init(testing.allocator);
    defer coll.deinit();
    try testing.expectEqual(@as(u32, 0), coll.count);
}

test "appendEntity single" {
    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();

    const offset = try coll.appendEntity(makeEntity(42));
    try testing.expectEqual(@as(u32, 0), offset);
    try testing.expectEqual(@as(u32, 1), coll.count);
    try testing.expect(coll.entitySlice()[0].eql(makeEntity(42)));
}

test "column access — write and read" {
    var coll = try Collection(Row(&.{ Position, Velocity }), .{}).init(testing.allocator);
    defer coll.deinit();

    const offset = try coll.appendEntity(makeEntity(0));
    coll.column(Position)[offset] = .{ .x = 1, .y = 2, .z = 3 };
    coll.column(Velocity)[offset] = .{ .x = 10, .y = 20, .z = 30 };

    try testing.expectEqual(@as(f32, 1), coll.column(Position)[offset].x);
    try testing.expectEqual(@as(f32, 20), coll.column(Velocity)[offset].y);
}

test "zero-init" {
    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();

    _ = try coll.appendEntity(makeEntity(0));
    const pos = coll.column(Position)[0];
    try testing.expectEqual(@as(f32, 0), pos.x);
    try testing.expectEqual(@as(f32, 0), pos.y);
    try testing.expectEqual(@as(f32, 0), pos.z);
}

test "init called" {
    var coll = try Collection(Row(&.{ Position, Health }), .{}).init(testing.allocator);
    defer coll.deinit();

    _ = try coll.appendEntity(makeEntity(0));
    const hp = coll.column(Health)[0];
    try testing.expectEqual(@as(i32, 100), hp.current);
    try testing.expectEqual(@as(i32, 100), hp.max);
}

test "append multiple" {
    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();

    for (0..5) |i| {
        const offset = try coll.appendEntity(makeEntity(@intCast(i)));
        coll.column(Position)[offset] = .{ .x = @floatFromInt(i), .y = 0, .z = 0 };
    }
    try testing.expectEqual(@as(u32, 5), coll.count);
    try testing.expectEqual(@as(f32, 3), coll.column(Position)[3].x);
}

test "ensureCapacity" {
    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();

    try coll.ensureCapacity(100);
    try testing.expect(coll.capacity >= 100);

    for (0..100) |i| {
        _ = try coll.appendEntity(makeEntity(@intCast(i)));
    }
    try testing.expectEqual(@as(u32, 100), coll.count);
}

test "growth — exceed initial capacity" {
    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();

    for (0..20) |i| {
        const offset = try coll.appendEntity(makeEntity(@intCast(i)));
        coll.column(Position)[offset] = .{ .x = @floatFromInt(i), .y = 0, .z = 0 };
    }
    try testing.expectEqual(@as(u32, 20), coll.count);
    try testing.expectEqual(@as(f32, 0), coll.column(Position)[0].x);
    try testing.expectEqual(@as(f32, 19), coll.column(Position)[19].x);
}

test "swapRemove last" {
    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();

    _ = try coll.appendEntity(makeEntity(0));
    _ = try coll.appendEntity(makeEntity(1));

    const moved = coll.swapRemove(1);
    try testing.expectEqual(@as(?Entity, null), moved);
    try testing.expectEqual(@as(u32, 1), coll.count);
}

test "swapRemove middle" {
    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();

    for (0..3) |i| {
        const offset = try coll.appendEntity(makeEntity(@intCast(i)));
        coll.column(Position)[offset] = .{ .x = @floatFromInt(i), .y = 0, .z = 0 };
    }

    const moved = coll.swapRemove(0);
    try testing.expect(moved != null);
    try testing.expect(moved.?.eql(makeEntity(2)));
    try testing.expectEqual(@as(u32, 2), coll.count);
    try testing.expectEqual(@as(f32, 2), coll.column(Position)[0].x);
}

test "swapRemove calls deinit" {
    deinit_counter = 0;
    var coll = try Collection(Row(&.{Tracked}), .{}).init(testing.allocator);
    defer coll.deinit();

    _ = try coll.appendEntity(makeEntity(0));
    _ = try coll.appendEntity(makeEntity(1));

    _ = coll.swapRemove(0);
    try testing.expectEqual(@as(u32, 1), deinit_counter);
}

test "column slice length" {
    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();

    for (0..5) |i| _ = try coll.appendEntity(makeEntity(@intCast(i)));
    try testing.expectEqual(@as(usize, 5), coll.column(Position).len);

    _ = coll.swapRemove(2);
    try testing.expectEqual(@as(usize, 4), coll.column(Position).len);

    _ = coll.swapRemove(0);
    try testing.expectEqual(@as(usize, 3), coll.column(Position).len);
}

test "ZST component" {
    var coll = try Collection(Row(&.{ Tag, Position }), .{}).init(testing.allocator);
    defer coll.deinit();

    _ = try coll.appendEntity(makeEntity(0));
    try testing.expectEqual(@as(u32, 1), coll.count);
    try testing.expectEqual(@as(usize, 1), coll.column(Tag).len);
}

test "empty row" {
    var coll = try Collection(Row(&.{}), .{}).init(testing.allocator);
    defer coll.deinit();

    _ = try coll.appendEntity(makeEntity(0));
    _ = try coll.appendEntity(makeEntity(1));
    try testing.expectEqual(@as(u32, 2), coll.count);
    try testing.expect(coll.entitySlice()[0].eql(makeEntity(0)));
}

test "deinit calls component deinit" {
    deinit_counter = 0;
    {
        var coll = try Collection(Row(&.{Tracked}), .{}).init(testing.allocator);
        _ = try coll.appendEntity(makeEntity(0));
        _ = try coll.appendEntity(makeEntity(1));
        _ = try coll.appendEntity(makeEntity(2));
        coll.deinit();
    }
    try testing.expectEqual(@as(u32, 3), deinit_counter);
}

test "single component row" {
    var coll = try Collection(Row(&.{Position}), .{}).init(testing.allocator);
    defer coll.deinit();

    const offset = try coll.appendEntity(makeEntity(0));
    coll.column(Position)[offset] = .{ .x = 42, .y = 0, .z = 0 };
    try testing.expectEqual(@as(f32, 42), coll.column(Position)[0].x);
}

test "large batch" {
    var coll = try Collection(Row(&.{ Position, Velocity }), .{}).init(testing.allocator);
    defer coll.deinit();

    for (0..1000) |i| {
        const offset = try coll.appendEntity(makeEntity(@intCast(i)));
        coll.column(Position)[offset] = .{ .x = @floatFromInt(i), .y = 0, .z = 0 };
    }
    try testing.expectEqual(@as(u32, 1000), coll.count);
    try testing.expectEqual(@as(f32, 999), coll.column(Position)[999].x);
    try testing.expectEqual(@as(f32, 0), coll.column(Position)[0].x);
}

test "RowType exposed" {
    const R = Row(&.{ Position, Velocity });
    const C = Collection(R, .{});
    try testing.expect(C.RowType == R);
}

test "SIMD alignment — column base pointer is aligned" {
    var coll = try Collection(Row(&.{SimdVec}), .{}).init(testing.allocator);
    defer coll.deinit();

    _ = try coll.appendEntity(makeEntity(0));
    _ = try coll.appendEntity(makeEntity(1));

    const col = coll.column(SimdVec);
    try testing.expect(col.len == 2);
    try testing.expect(@intFromPtr(col.ptr) % 32 == 0);
}

test "SIMD alignment — survives growth" {
    var coll = try Collection(Row(&.{ SimdVec, Position }), .{}).init(testing.allocator);
    defer coll.deinit();

    for (0..20) |i| {
        const offset = try coll.appendEntity(makeEntity(@intCast(i)));
        coll.column(SimdVec)[offset].data[0] = @floatFromInt(i);
    }

    const col = coll.column(SimdVec);
    try testing.expect(@intFromPtr(col.ptr) % 32 == 0);
    try testing.expectEqual(@as(f32, 0), col[0].data[0]);
    try testing.expectEqual(@as(f32, 19), col[19].data[0]);
}

test "mixed aligned and unaligned components" {
    var coll = try Collection(Row(&.{ Position, SimdVec }), .{}).init(testing.allocator);
    defer coll.deinit();

    const offset = try coll.appendEntity(makeEntity(0));
    coll.column(Position)[offset] = .{ .x = 1, .y = 2, .z = 3 };
    coll.column(SimdVec)[offset].data[0] = 42;

    try testing.expectEqual(@as(f32, 1), coll.column(Position)[0].x);
    try testing.expectEqual(@as(f32, 42), coll.column(SimdVec)[0].data[0]);
    try testing.expect(@intFromPtr(coll.column(SimdVec).ptr) % 32 == 0);
}

// ---------------------------------------------------------------------------
// Fixed-capacity collection tests
// ---------------------------------------------------------------------------

test "fixed — init pre-allocates" {
    var coll = try Collection(Row(&.{Position}), .{ .capacity = 16 }).init(testing.allocator);
    defer coll.deinit();

    try testing.expectEqual(@as(u32, 16), coll.capacity);
    try testing.expectEqual(@as(u32, 0), coll.count);
}

test "fixed — append up to capacity" {
    var coll = try Collection(Row(&.{Position}), .{ .capacity = 4 }).init(testing.allocator);
    defer coll.deinit();

    for (0..4) |i| {
        const offset = try coll.appendEntity(makeEntity(@intCast(i)));
        coll.column(Position)[offset] = .{ .x = @floatFromInt(i), .y = 0, .z = 0 };
    }
    try testing.expectEqual(@as(u32, 4), coll.count);
    try testing.expectEqual(@as(f32, 3), coll.column(Position)[3].x);
}

test "fixed — append beyond capacity returns Full" {
    var coll = try Collection(Row(&.{Position}), .{ .capacity = 2 }).init(testing.allocator);
    defer coll.deinit();

    _ = try coll.appendEntity(makeEntity(0));
    _ = try coll.appendEntity(makeEntity(1));

    const result = coll.appendEntity(makeEntity(2));
    try testing.expectError(error.Full, result);
    try testing.expectEqual(@as(u32, 2), coll.count);
}

test "fixed — swapRemove then re-append" {
    var coll = try Collection(Row(&.{Position}), .{ .capacity = 2 }).init(testing.allocator);
    defer coll.deinit();

    _ = try coll.appendEntity(makeEntity(0));
    _ = try coll.appendEntity(makeEntity(1));
    _ = coll.swapRemove(0);

    // Should have room for one more
    _ = try coll.appendEntity(makeEntity(2));
    try testing.expectEqual(@as(u32, 2), coll.count);
}

test "fixed — ensureCapacity within cap" {
    var coll = try Collection(Row(&.{Position}), .{ .capacity = 64 }).init(testing.allocator);
    defer coll.deinit();

    try coll.ensureCapacity(32); // within cap, no-op
    try testing.expectEqual(@as(u32, 64), coll.capacity);
}

test "fixed — ensureCapacity beyond cap returns Full" {
    var coll = try Collection(Row(&.{Position}), .{ .capacity = 16 }).init(testing.allocator);
    defer coll.deinit();

    const result = coll.ensureCapacity(32);
    try testing.expectError(error.Full, result);
}

test "fixed — with init/deinit components" {
    deinit_counter = 0;
    {
        var coll = try Collection(Row(&.{ Health, Tracked }), .{ .capacity = 8 }).init(testing.allocator);
        _ = try coll.appendEntity(makeEntity(0));
        _ = try coll.appendEntity(makeEntity(1));

        // Verify Health.init was called
        try testing.expectEqual(@as(i32, 100), coll.column(Health)[0].current);
        try testing.expectEqual(@as(i32, 100), coll.column(Health)[1].current);

        coll.deinit();
    }
    try testing.expectEqual(@as(u32, 2), deinit_counter);
}

test "fixed — SIMD aligned" {
    var coll = try Collection(Row(&.{SimdVec}), .{ .capacity = 32 }).init(testing.allocator);
    defer coll.deinit();

    _ = try coll.appendEntity(makeEntity(0));
    try testing.expect(@intFromPtr(coll.column(SimdVec).ptr) % 32 == 0);
}

test "fixed — deinit empty is safe" {
    var coll = try Collection(Row(&.{ Position, Health }), .{ .capacity = 16 }).init(testing.allocator);
    coll.deinit();
}

