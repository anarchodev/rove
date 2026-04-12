const std = @import("std");

pub const entity_mod = @import("entity.zig");
pub const row_mod = @import("row.zig");
pub const collection_mod = @import("collection.zig");
pub const registry_mod = @import("registry.zig");

pub const Entity = entity_mod.Entity;
pub const Row = row_mod.Row;
pub const Collection = collection_mod.Collection;
pub const Registry = registry_mod.Registry;
pub const effectiveAlign = collection_mod.effectiveAlign;

test {
    _ = entity_mod;
    _ = row_mod;
    _ = collection_mod;
    _ = registry_mod;
}
