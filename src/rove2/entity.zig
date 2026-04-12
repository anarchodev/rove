const std = @import("std");

pub const Entity = struct {
    index: u32,
    generation: u32,

    /// Sentinel for "no entity" — uses maxInt(u32) so that zero-initialized
    /// entity handles ({0, 0}) remain valid (principle 12).
    pub const nil = Entity{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn eql(a: Entity, b: Entity) bool {
        return a.index == b.index and a.generation == b.generation;
    }

    pub fn isNil(self: Entity) bool {
        return self.index == nil.index;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "nil sentinel is not zero" {
    const e = Entity{ .index = 0, .generation = 0 };
    try testing.expect(!e.isNil());
    try testing.expect(Entity.nil.isNil());
}

test "eql" {
    const a = Entity{ .index = 1, .generation = 2 };
    const b = Entity{ .index = 1, .generation = 2 };
    const c = Entity{ .index = 1, .generation = 3 };
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
}

test "nil eql" {
    try testing.expect(Entity.nil.eql(Entity.nil));
    try testing.expect(!Entity.nil.eql(Entity{ .index = 0, .generation = 0 }));
}
