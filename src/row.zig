const std = @import("std");

/// A Row is a comptime set of component types, sorted by @typeName and deduplicated.
/// It represents an archetype — the fixed set of components a collection stores.
///
/// Usage:
///   const MyRow = Row(&.{ Position, Velocity, Health });
///   const Subset = Row(&.{ Position, Velocity });
///   comptime { assert(Subset.isSubsetOf(MyRow)); }
///
pub fn Row(comptime input: []const type) type {
    const sorted = comptime sortAndDedup(input);
    return struct {
        /// The canonical sorted, deduplicated component types.
        pub const types: [sorted.len]type = sorted;

        /// Number of component types in this row.
        pub const len: usize = sorted.len;

        /// Returns true if this row contains the given component type.
        pub fn contains(comptime T: type) bool {
            inline for (types) |U| {
                if (U == T) return true;
            }
            return false;
        }

        /// Returns true if every component in this row is also in Other.
        pub fn isSubsetOf(comptime Other: type) bool {
            inline for (types) |T| {
                if (!Other.contains(T)) return false;
            }
            return true;
        }

        /// Returns true if both rows contain exactly the same component types.
        pub fn equal(comptime Other: type) bool {
            if (len != Other.len) return false;
            inline for (types, Other.types) |A, B| {
                if (A != B) return false;
            }
            return true;
        }

        /// Returns a new Row that is the union of this row and Other.
        pub fn merge(comptime Other: type) type {
            return Row(&(types ++ Other.types));
        }

        /// Returns a new Row with the given types removed.
        pub fn subtract(comptime remove: []const type) type {
            comptime {
                var kept: [len]type = undefined;
                var count: usize = 0;
                for (types) |T| {
                    if (!typeIn(T, remove)) {
                        kept[count] = T;
                        count += 1;
                    }
                }
                return Row(kept[0..count]);
            }
        }

        /// Returns true if T has a `pub fn init() T` declaration.
        pub fn hasInit(comptime T: type) bool {
            return componentHasInit(T);
        }

        /// Returns true if T has a `pub fn deinit(*T) void` declaration.
        pub fn hasDeinit(comptime T: type) bool {
            return componentHasDeinit(T);
        }

        /// Returns the subset of this row's types that have an init method.
        pub fn initTypes() []const type {
            comptime {
                var buf: [len]type = undefined;
                var count: usize = 0;
                for (types) |T| {
                    if (componentHasInit(T)) {
                        buf[count] = T;
                        count += 1;
                    }
                }
                return buf[0..count];
            }
        }

        /// Returns the subset of this row's types that have a deinit method.
        pub fn deinitTypes() []const type {
            comptime {
                var buf: [len]type = undefined;
                var count: usize = 0;
                for (types) |T| {
                    if (componentHasDeinit(T)) {
                        buf[count] = T;
                        count += 1;
                    }
                }
                return buf[0..count];
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn typeIn(comptime needle: type, comptime haystack: []const type) bool {
    for (haystack) |T| {
        if (T == needle) return true;
    }
    return false;
}

fn componentHasInit(comptime T: type) bool {
    if (!@hasDecl(T, "init")) return false;
    const info = @typeInfo(@TypeOf(@field(T, "init")));
    if (info != .@"fn") return false;
    const f = info.@"fn";
    if (f.params.len != 0) return false;
    if (f.return_type != T) return false;
    return true;
}

fn componentHasDeinit(comptime T: type) bool {
    if (!@hasDecl(T, "deinit")) return false;
    const info = @typeInfo(@TypeOf(@field(T, "deinit")));
    if (info != .@"fn") return false;
    const f = info.@"fn";
    if (f.params.len != 1) return false;
    if (f.params[0].type != *T) return false;
    if (f.return_type != void) return false;
    return true;
}

fn typeNameLessThan(comptime a: type, comptime b: type) bool {
    return std.mem.order(u8, @typeName(a), @typeName(b)) == .lt;
}

fn sortAndDedup(comptime input: []const type) [dedupLen(input)]type {
    comptime {
        if (input.len == 0) return .{};

        // Copy to mutable buffer
        var buf: [input.len]type = undefined;
        @memcpy(&buf, input);

        // Insertion sort by @typeName
        for (1..buf.len) |i| {
            const key = buf[i];
            var j: usize = i;
            while (j > 0 and typeNameLessThan(key, buf[j - 1])) {
                buf[j] = buf[j - 1];
                j -= 1;
            }
            buf[j] = key;
        }

        // Deduplicate adjacent
        var out: [buf.len]type = undefined;
        out[0] = buf[0];
        var count: usize = 1;
        for (1..buf.len) |i| {
            if (buf[i] != out[count - 1]) {
                out[count] = buf[i];
                count += 1;
            }
        }

        // Return fixed-size result
        var result: [dedupLen(input)]type = undefined;
        @memcpy(&result, out[0..count]);
        return result;
    }
}

fn dedupLen(comptime input: []const type) usize {
    comptime {
        if (input.len == 0) return 0;

        var buf: [input.len]type = undefined;
        @memcpy(&buf, input);

        // Sort
        for (1..buf.len) |i| {
            const key = buf[i];
            var j: usize = i;
            while (j > 0 and typeNameLessThan(key, buf[j - 1])) {
                buf[j] = buf[j - 1];
                j -= 1;
            }
            buf[j] = key;
        }

        // Count unique
        var count: usize = 1;
        for (1..buf.len) |i| {
            if (buf[i] != buf[i - 1]) count += 1;
        }
        return count;
    }
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

// Test component types
const Position = struct { x: f32, y: f32, z: f32 };
const Velocity = struct { x: f32, y: f32, z: f32 }; // same layout, different type
const Health = struct {
    current: i32,
    max: i32,

    pub fn init() Health {
        return .{ .current = 100, .max = 100 };
    }

    pub fn deinit(self: *Health) void {
        _ = self;
    }
};
const Tag = struct {}; // zero-sized

test "basic construction" {
    const R = Row(&.{ Position, Velocity });
    try expectEqual(2, R.len);
    try expect(R.contains(Position));
    try expect(R.contains(Velocity));
}

test "sort invariant — order does not matter" {
    try expect(Row(&.{ Velocity, Position }).equal(Row(&.{ Position, Velocity })));
}

test "deduplication" {
    const R = Row(&.{ Position, Velocity, Position });
    try expectEqual(2, R.len);
    try expect(R.equal(Row(&.{ Position, Velocity })));
}

test "empty row" {
    const R = Row(&.{});
    try expectEqual(0, R.len);
}

test "single element" {
    const R = Row(&.{Position});
    try expectEqual(1, R.len);
    try expect(R.contains(Position));
}

test "contains — positive" {
    try expect(Row(&.{ Position, Velocity }).contains(Position));
}

test "contains — negative" {
    try expect(!Row(&.{ Position, Velocity }).contains(Health));
}

test "merge — disjoint" {
    const M = Row(&.{Position}).merge(Row(&.{Velocity}));
    try expect(M.equal(Row(&.{ Position, Velocity })));
}

test "merge — overlapping" {
    const M = Row(&.{ Position, Velocity }).merge(Row(&.{ Velocity, Health }));
    try expect(M.equal(Row(&.{ Position, Velocity, Health })));
}

test "merge — identical" {
    const M = Row(&.{ Position, Velocity }).merge(Row(&.{ Position, Velocity }));
    try expect(M.equal(Row(&.{ Position, Velocity })));
}

test "subtract — partial" {
    const S = Row(&.{ Position, Velocity, Health }).subtract(&.{Velocity});
    try expect(S.equal(Row(&.{ Position, Health })));
}

test "subtract — all" {
    const S = Row(&.{ Position, Velocity }).subtract(&.{ Position, Velocity });
    try expectEqual(0, S.len);
}

test "subtract — none present" {
    const S = Row(&.{ Position, Velocity }).subtract(&.{Health});
    try expect(S.equal(Row(&.{ Position, Velocity })));
}

test "isSubsetOf — true" {
    try expect(Row(&.{Position}).isSubsetOf(Row(&.{ Position, Velocity })));
}

test "isSubsetOf — false" {
    try expect(!Row(&.{ Position, Velocity }).isSubsetOf(Row(&.{Position})));
}

test "isSubsetOf — equal sets" {
    try expect(Row(&.{ Position, Velocity }).isSubsetOf(Row(&.{ Position, Velocity })));
}

test "isSubsetOf — empty is subset of anything" {
    try expect(Row(&.{}).isSubsetOf(Row(&.{Position})));
}

test "equal — true" {
    try expect(Row(&.{ Position, Velocity }).equal(Row(&.{ Velocity, Position })));
}

test "equal — false" {
    try expect(!Row(&.{ Position, Velocity }).equal(Row(&.{ Position, Health })));
}

test "lifecycle — hasInit" {
    try expect(Row(&.{Health}).hasInit(Health));
    try expect(!Row(&.{Position}).hasInit(Position));
}

test "lifecycle — hasDeinit" {
    try expect(Row(&.{Health}).hasDeinit(Health));
    try expect(!Row(&.{Position}).hasDeinit(Position));
}

test "lifecycle — initTypes" {
    const R = Row(&.{ Position, Health, Velocity });
    const inits = R.initTypes();
    try expectEqual(1, inits.len);
    try expect(inits[0] == Health);
}

test "lifecycle — deinitTypes" {
    const R = Row(&.{ Position, Health, Velocity });
    const deinits = R.deinitTypes();
    try expectEqual(1, deinits.len);
    try expect(deinits[0] == Health);
}

test "nominal identity — same layout different type" {
    // Position and Velocity have identical layouts but are different types
    try expect(!Row(&.{Position}).equal(Row(&.{Velocity})));
    const R = Row(&.{ Position, Velocity });
    try expectEqual(2, R.len);
}

test "merge commutativity" {
    const AB = Row(&.{Position}).merge(Row(&.{Velocity}));
    const BA = Row(&.{Velocity}).merge(Row(&.{Position}));
    try expect(AB.equal(BA));
}

test "chained operations" {
    const Full = Row(&.{Position}).merge(Row(&.{ Velocity, Health }));
    const Stripped = Full.subtract(&.{Health});
    try expect(Stripped.equal(Row(&.{ Position, Velocity })));
    try expect(Stripped.isSubsetOf(Full));
    try expect(!Full.isSubsetOf(Stripped));
}

test "zero-sized component" {
    const R = Row(&.{ Tag, Position });
    try expectEqual(2, R.len);
    try expect(R.contains(Tag));
}
