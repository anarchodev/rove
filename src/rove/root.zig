pub const Row = @import("row.zig").Row;
pub const Entity = @import("entity.zig").Entity;
pub const Context = @import("context.zig").Context;
pub const ContextConfig = @import("context.zig").ContextConfig;
pub const Collection = @import("collection.zig").Collection;
pub const MergeCollections = @import("spec.zig").MergeCollections;
pub const col = @import("spec.zig").col;
pub const MakeCollections = @import("spec.zig").MakeCollections;
pub const CollectionRow = @import("spec.zig").CollectionRow;

test {
    _ = @import("row.zig");
    _ = @import("entity.zig");
    _ = @import("collection.zig");
    _ = @import("context.zig");
    _ = @import("spec.zig");
}
