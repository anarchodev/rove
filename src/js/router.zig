//! URL path → deployment module path resolver.
//!
//! Direct port of shift-js's `src/router.c`. The rule is simple:
//!
//!   - Strip query string (anything after the first `?`).
//!   - Strip leading and trailing slashes.
//!   - If the remainder is empty → module base is `"index"`.
//!   - Otherwise → module base is `"<remainder>/index"`.
//!
//! Examples:
//!
//!   "/"                → "index"
//!   "/foo"             → "foo/index"
//!   "/foo/bar"         → "foo/bar/index"
//!   "/foo/bar/"        → "foo/bar/index"
//!   "/foo?x=1"         → "foo/index"
//!
//! The returned module base has no file extension. Callers append the
//! extension (`.mjs` for handlers) and look the full key up in the
//! deployment's bytecode map. The router is pure and owns no state — the
//! only allocation is for the returned module string, which the caller
//! frees.
//!
//! The router is intentionally function-name-agnostic. Unlike shift-js's
//! `sjs_route_t`, it does not resolve which export to call — it only
//! splits the path from the query string and stores the raw query on the
//! `Route`. The query is opaque to the platform (surfaced to JS as
//! `request.query`); the invoked export is resolved from the
//! activation kind / resume target (`rpc_dispatch.parseDispatch`,
//! decisions.md §4.5).

const std = @import("std");

pub const Route = struct {
    /// Extension-less module base path, e.g. `"foo/bar/index"`.
    /// Owned by `allocator`. Caller frees via `deinit`.
    module_base: []const u8,
    /// Query string (everything after `?`), or null if the URL had
    /// none. Owned by `allocator`. Opaque to the platform — surfaced
    /// to the handler as `request.query`.
    query: ?[]const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Route) void {
        self.allocator.free(self.module_base);
        if (self.query) |q| self.allocator.free(q);
        self.* = undefined;
    }
};

/// Resolve a URL path to a deployment module base. Always succeeds
/// (the empty path resolves to `"index"`); OOM is the only error.
pub fn resolveRoute(allocator: std.mem.Allocator, url_path: []const u8) !Route {
    // Strip leading slashes.
    var start: usize = 0;
    while (start < url_path.len and url_path[start] == '/') start += 1;
    var rest = url_path[start..];

    // Split query string.
    var query_copy: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        const q_slice = rest[q + 1 ..];
        if (q_slice.len > 0) {
            const dup = try allocator.dupe(u8, q_slice);
            query_copy = dup;
        }
        rest = rest[0..q];
    }

    // Strip trailing slashes.
    while (rest.len > 0 and rest[rest.len - 1] == '/') rest = rest[0 .. rest.len - 1];

    const module_base = if (rest.len == 0)
        try allocator.dupe(u8, "index")
    else
        try std.fmt.allocPrint(allocator, "{s}/index", .{rest});
    errdefer allocator.free(module_base);

    return .{
        .module_base = module_base,
        .query = query_copy,
        .allocator = allocator,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectBase(url: []const u8, want: []const u8) !void {
    var r = try resolveRoute(testing.allocator, url);
    defer r.deinit();
    try testing.expectEqualStrings(want, r.module_base);
}

test "router: empty path → index" {
    try expectBase("", "index");
    try expectBase("/", "index");
    try expectBase("//", "index");
    try expectBase("///", "index");
}

test "router: single segment" {
    try expectBase("/foo", "foo/index");
    try expectBase("foo", "foo/index");
    try expectBase("/foo/", "foo/index");
}

test "router: multiple segments" {
    try expectBase("/foo/bar", "foo/bar/index");
    try expectBase("/api/users/list", "api/users/list/index");
}

test "router: trailing slashes stripped" {
    try expectBase("/foo/bar/", "foo/bar/index");
    try expectBase("/foo/bar///", "foo/bar/index");
}

test "router: query string stripped from module" {
    try expectBase("/foo?x=1", "foo/index");
    try expectBase("/?fn=whoami", "index");
    try expectBase("/a/b?c=d&e=f", "a/b/index");
}

test "router: query captured on route" {
    var r = try resolveRoute(testing.allocator, "/foo?x=1&y=2");
    defer r.deinit();
    try testing.expectEqualStrings("foo/index", r.module_base);
    try testing.expectEqualStrings("x=1&y=2", r.query.?);
}

test "router: empty query becomes null" {
    var r = try resolveRoute(testing.allocator, "/foo?");
    defer r.deinit();
    try testing.expectEqualStrings("foo/index", r.module_base);
    try testing.expect(r.query == null);
}

test "router: root with query" {
    var r = try resolveRoute(testing.allocator, "/?hello=world");
    defer r.deinit();
    try testing.expectEqualStrings("index", r.module_base);
    try testing.expectEqualStrings("hello=world", r.query.?);
}
