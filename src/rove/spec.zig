const std = @import("std");
const Collection = @import("collection.zig").Collection;

/// Spec construction and merging utilities.
///
/// A spec is a type where each field maps a collection name to a Collection
/// type. Libraries produce spec types via `SpecType()` functions; users build
/// them with `MakeCollections`/`collection`.
///
/// `MergeCollections` combines multiple spec types into one. `Context` takes the
/// merged spec type and instantiates the collections.
///
/// Usage:
///   const AppSpec = rove.MakeCollections(&.{
///       rove.col("players", rove.Collection(PlayerRow, .{})),
///   });
///   const Spec = rove.MergeCollections(.{ h2.SpecType(.{}), AppSpec });
///   const Ctx = rove.Context(Spec);
///

/// Merge multiple spec types into a single spec type.
///
/// Input is a tuple of spec types. Each spec type is produced by `MakeCollections`
/// or by a library's `SpecType()` function.
///
/// Compile error if any field names collide across specs.
pub fn MergeCollections(comptime spec_types: anytype) type {
    @setEvalBranchQuota(100_000);

    const tuple_info = @typeInfo(@TypeOf(spec_types)).@"struct";

    comptime var total_fields: usize = 0;
    inline for (tuple_info.fields) |tf| {
        const SpecT = @field(spec_types, tf.name);
        total_fields += @typeInfo(SpecT).@"struct".fields.len;
    }

    comptime var merged_fields: [total_fields]std.builtin.Type.StructField = undefined;
    comptime var field_count: usize = 0;

    inline for (tuple_info.fields) |tf| {
        const SpecT = @field(spec_types, tf.name);
        const spec_fields = @typeInfo(SpecT).@"struct".fields;
        for (spec_fields) |sf| {
            for (merged_fields[0..field_count]) |existing| {
                if (std.mem.eql(u8, existing.name, sf.name)) {
                    @compileError("MergeCollections: duplicate collection name '" ++ sf.name ++ "'");
                }
            }
            merged_fields[field_count] = sf;
            field_count += 1;
        }
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = merged_fields[0..field_count],
        .decls = &.{},
        .is_tuple = false,
    } });
}

// ===========================================================================
// Spec construction helpers
// ===========================================================================

/// Create a spec field that maps a name to a Collection type.
///
///   rove.col("connections", Collection(conn_row, .{}))
///   rove.col("events", Collection(event_row, .{ .capacity = 256 }))
///
pub fn col(comptime name: [:0]const u8, comptime CollType: type) std.builtin.Type.StructField {
    return .{
        .name = name,
        .type = CollType,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(CollType),
    };
}

/// Reify a spec struct type from an array of fields built with `collection`.
pub fn MakeCollections(comptime fields: []const std.builtin.Type.StructField) type {
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

/// Extract the Row type for a named collection from a spec type.
pub fn CollectionRow(comptime Spec: type, comptime name: []const u8) type {
    for (@typeInfo(Spec).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            return f.type.RowType;
        }
    }
    @compileError("spec has no collection named '" ++ name ++ "'");
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const Row = @import("row.zig").Row;
const Coll = Collection;

const Position = struct { x: f32, y: f32, z: f32 };
const Velocity = struct { x: f32, y: f32, z: f32 };
const Health = struct { current: i32, max: i32 };
const Tag = struct {};

test "MergeCollections — two specs" {
    const SpecA = MakeCollections(&.{col("active", Coll(Row(&.{ Position, Velocity }), .{}))});
    const SpecB = MakeCollections(&.{col("dead", Coll(Row(&.{Position}), .{}))});
    const Merged = MergeCollections(.{ SpecA, SpecB });

    try testing.expect(@hasField(Merged, "active"));
    try testing.expect(@hasField(Merged, "dead"));
}

test "MergeCollections — three specs" {
    const Merged = MergeCollections(.{
        MakeCollections(&.{col("a", Coll(Row(&.{Position}), .{}))}),
        MakeCollections(&.{col("b", Coll(Row(&.{Velocity}), .{}))}),
        MakeCollections(&.{col("c", Coll(Row(&.{Health}), .{}))}),
    });

    try testing.expect(@hasField(Merged, "a"));
    try testing.expect(@hasField(Merged, "b"));
    try testing.expect(@hasField(Merged, "c"));
}

test "MergeCollections — empty spec" {
    const Merged = MergeCollections(.{
        MakeCollections(&.{col("active", Coll(Row(&.{Position}), .{}))}),
        MakeCollections(&.{}),
    });
    try testing.expect(@hasField(Merged, "active"));
}

test "MergeCollections — single spec passthrough" {
    const Merged = MergeCollections(.{
        MakeCollections(&.{col("active", Coll(Row(&.{Position}), .{}))}),
    });
    try testing.expect(@hasField(Merged, "active"));
}

test "MergeCollections — result works with Context" {
    const Context = @import("context.zig").Context;
    const Spec = MergeCollections(.{
        MakeCollections(&.{col("active", Coll(Row(&.{ Position, Velocity }), .{}))}),
        MakeCollections(&.{col("dead", Coll(Row(&.{Position}), .{}))}),
    });
    const Ctx = Context(Spec);
    var ctx = try Ctx.init(testing.allocator, .{ .max_entities = 16 });
    defer ctx.deinit();

    const e = try ctx.createOne(.active);
    try ctx.flush();
    try testing.expect(!ctx.isStale(e));
    try testing.expectEqual(@as(usize, 1), ctx.entities(.active).len);
}

test "MergeCollections — library spec simulation" {
    const IoSpec = MakeCollections(&.{
        col("connections", Coll(Row(&.{Position}), .{})),
        col("read_results", Coll(Row(&.{ Position, Velocity }), .{})),
        col("_read_pending", Coll(Row(&.{ Position, Velocity, Health }), .{})),
    });
    const AppSpec = MakeCollections(&.{col("players", Coll(Row(&.{Tag}), .{}))});
    const Merged = MergeCollections(.{ IoSpec, AppSpec });

    try testing.expect(@hasField(Merged, "connections"));
    try testing.expect(@hasField(Merged, "read_results"));
    try testing.expect(@hasField(Merged, "_read_pending"));
    try testing.expect(@hasField(Merged, "players"));
}

test "MakeCollections — basic" {
    const S = MakeCollections(&.{
        col("active", Coll(Row(&.{ Position, Velocity }), .{})),
        col("dead", Coll(Row(&.{Position}), .{})),
    });

    try testing.expect(@hasField(S, "active"));
    try testing.expect(@hasField(S, "dead"));
}

test "MakeCollections — conditional fields via concatenation" {
    const base = .{
        col("always", Coll(Row(&.{Position}), .{})),
    };
    const conditional = .{
        col("sometimes", Coll(Row(&.{Velocity}), .{})),
    };

    const WithBoth = MakeCollections(&(base ++ conditional));
    const WithoutConditional = MakeCollections(&base);

    try testing.expect(@hasField(WithBoth, "always"));
    try testing.expect(@hasField(WithBoth, "sometimes"));
    try testing.expect(@hasField(WithoutConditional, "always"));
    try testing.expect(!@hasField(WithoutConditional, "sometimes"));
}

test "MakeCollections — works with Context" {
    const Context = @import("context.zig").Context;
    const LibSpec = MakeCollections(&.{
        col("connections", Coll(Row(&.{Position}), .{})),
        col("events", Coll(Row(&.{Velocity}), .{})),
    });
    const AppSpec = MakeCollections(&.{col("players", Coll(Row(&.{Health}), .{}))});
    const Spec = MergeCollections(.{ LibSpec, AppSpec });

    const Ctx = Context(Spec);
    var ctx = try Ctx.init(testing.allocator, .{ .max_entities = 16 });
    defer ctx.deinit();

    const c = try ctx.createOne(.connections);
    const p = try ctx.createOne(.players);
    try ctx.flush();
    try testing.expect(!ctx.isStale(c));
    try testing.expect(!ctx.isStale(p));
}
