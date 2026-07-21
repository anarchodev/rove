//! Confine a module-resolution join to a deployment root. Production clamps
//! module resolution to the deployment root (package_resolver.resolveSpecifier
//! swallows over-popped `../` to the bare tail), so an offline loader must not
//! let a `../`-heavy specifier read a file outside the app tree — a path prod
//! could never serve. Shared by both offline loaders (the `rewind test` harness
//! and the `replay` shell).

const std = @import("std");

/// Join `s` onto `base_dir`, canonicalize `./`/`../`, and refuse the result if
/// it escapes `boundary` (an over-popped `../`, or a symlink target the resolve
/// pass would still place outside the tree). Returns the confined absolute
/// path, or null on escape.
pub fn confineUnderRoot(a: std.mem.Allocator, boundary: []const u8, base_dir: []const u8, s: []const u8) ?[]const u8 {
    const joined = std.fs.path.join(a, &.{ base_dir, s }) catch return null;
    const canon = std.fs.path.resolve(a, &.{joined}) catch return null;
    const boundary_canon = std.fs.path.resolve(a, &.{boundary}) catch return null;
    if (!std.mem.startsWith(u8, canon, boundary_canon)) return null;
    // The prefix must end at a path boundary, so `/app` doesn't match `/app-x`.
    if (canon.len > boundary_canon.len and canon[boundary_canon.len] != std.fs.path.sep) return null;
    return canon;
}

test "confineUnderRoot: within-root allowed, escape refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A sibling helper one level up (app-tree local) is allowed.
    try std.testing.expectEqualStrings(
        "/app/lib/x.mjs",
        confineUnderRoot(a, "/app", "/app/_tests", "../lib/x.mjs").?,
    );
    // The boundary itself resolves.
    try std.testing.expect(confineUnderRoot(a, "/app", "/app", "helper.mjs") != null);
    // Over-popped `../` past the deployment root is refused.
    try std.testing.expect(confineUnderRoot(a, "/app", "/app/_tests", "../../etc/passwd") == null);
    // A sibling dir sharing a name prefix must not match (`/app` vs `/app-x`).
    try std.testing.expect(confineUnderRoot(a, "/app", "/app", "../app-x/y.mjs") == null);
}
