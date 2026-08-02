// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Per-importer `@scope/pkg` resolution — the pure resolution logic shared
//! by the production worker (`module_execution.zig`) and the offline
//! simulator (`src/replay/`), so the two can't drift on how a package
//! specifier maps to its bytecode/source key. Nothing here touches quickjs;
//! each build wraps these in its own `normalize` callback (prod serves the
//! resolved key from the bytecode map, the sim from the world's sources).
//!
//! `docs/architecture/package-resolution.md` §2, §4: the flat-surface /
//! encapsulated-internals guarantee is that resolution is keyed on the
//! *importer* — the same specifier resolves to the app's pinned version from
//! an app handler, and to the package's own frozen dep from inside a package.

const std = @import("std");
const files_mod = @import("rove-files");

/// Resolve `specifier` ("./helper.mjs", "../lib/util", or a bare path)
/// against `base` ("_api/kv/index.mjs") into a canonical deployment
/// path key. Writes into `scratch` and returns a subslice pointing
/// into it.
pub fn resolveSpecifier(base: []const u8, specifier: []const u8, scratch: []u8) []const u8 {
    // Bare / absolute specifiers pass through unchanged.
    if (!std.mem.startsWith(u8, specifier, "./") and !std.mem.startsWith(u8, specifier, "../")) {
        const n = @min(specifier.len, scratch.len);
        @memcpy(scratch[0..n], specifier[0..n]);
        return scratch[0..n];
    }

    // Determine the importing module's directory (everything before
    // the final '/'). Empty if the importer is at the root.
    var dir_len: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |slash| dir_len = slash;

    // Walk `specifier` applying "./" (skip) and "../" (pop one dir).
    var dir_end = dir_len;
    var rest = specifier;
    while (true) {
        if (std.mem.startsWith(u8, rest, "./")) {
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, "../")) {
            if (std.mem.lastIndexOfScalar(u8, base[0..dir_end], '/')) |prev_slash| {
                dir_end = prev_slash;
            } else {
                dir_end = 0;
            }
            rest = rest[3..];
        } else break;
    }

    var w: usize = 0;
    if (dir_end > 0) {
        const n = @min(dir_end, scratch.len);
        @memcpy(scratch[0..n], base[0..n]);
        w = n;
        if (w < scratch.len) {
            scratch[w] = '/';
            w += 1;
        }
    }
    const tail = @min(rest.len, scratch.len - w);
    @memcpy(scratch[w .. w + tail], rest[0..tail]);
    w += tail;
    return scratch[0..w];
}

/// Per-importer `@scope/pkg` resolution. Package modules live in
/// the deployment bytecode map under `/pkg/<pkg_hash>/…`; this maps a
/// bare specifier to the resolved package's entry key. Resolution is
/// keyed on the *importer* (`base`) — which is the whole flat-surface /
/// encapsulated-internals guarantee: the same specifier resolves to the
/// app's pinned version from an app handler, and to the package's own
/// frozen dep from inside a package. Owned by the tenant snapshot; slices
/// returned by `resolve` live as long as the maps (the whole request).
pub const PackageResolver = struct {
    /// bare specifier → package-virtual entry key, for app-context importers.
    app_imports: std.StringHashMapUnmanaged([]const u8),
    /// package-virtual dir ("/pkg/<hash>/") → that package's own
    /// {specifier → entry key} map (its encapsulated, frozen-at-publish deps).
    pkg_imports: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)),

    /// Resolve `specifier` for the module at `base`, or null to pass
    /// through (relative imports, `__system/*`, undeclared specifiers).
    pub fn resolve(self: *const PackageResolver, base: []const u8, specifier: []const u8) ?[]const u8 {
        if (packageDirOf(base)) |pkg_dir| {
            // Importer is a package → its own encapsulated imports.
            const inner = self.pkg_imports.getPtr(pkg_dir) orelse return null;
            return inner.get(specifier);
        }
        // Importer is an app handler → the flat app surface.
        return self.app_imports.get(specifier);
    }

    /// Free every owned key/value (buildResolver allocates them all).
    pub fn deinit(self: *PackageResolver, allocator: std.mem.Allocator) void {
        var ai = self.app_imports.iterator();
        while (ai.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        self.app_imports.deinit(allocator);
        var pi = self.pkg_imports.iterator();
        while (pi.next()) |e| {
            allocator.free(e.key_ptr.*);
            var inner = e.value_ptr;
            var ii = inner.iterator();
            while (ii.next()) |ie| {
                allocator.free(ie.key_ptr.*);
                allocator.free(ie.value_ptr.*);
            }
            inner.deinit(allocator);
        }
        self.pkg_imports.deinit(allocator);
    }
};

/// The entry-module key for a package: `/pkg/<pkg_hash>/index.mjs`.
fn pkgEntryKey(allocator: std.mem.Allocator, pkg_hash_hex: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/pkg/{s}/index.mjs", .{pkg_hash_hex});
}

/// The virtual-dir key for a package: `/pkg/<pkg_hash>/` (the `pkg_imports` key).
fn pkgDirKey(allocator: std.mem.Allocator, pkg_hash_hex: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/pkg/{s}/", .{pkg_hash_hex});
}

/// Build a `PackageResolver` from a manifest's (or a deploy-time
/// `Resolution`'s) package sections. `app_imports` becomes the
/// flat app surface; each package's `imports` becomes its encapsulated
/// per-importer map (keyed by its `/pkg/<hash>/` dir). Values are entry
/// keys (`/pkg/<dep_hash>/index.mjs`). Caller owns the result —
/// `resolver.deinit(allocator)` frees it. On error, everything allocated
/// so far is freed.
pub fn buildResolver(
    allocator: std.mem.Allocator,
    packages: []const files_mod.manifest_json.Package,
    app_imports: []const files_mod.manifest_json.ImportEntry,
) !PackageResolver {
    var r = PackageResolver{ .app_imports = .empty, .pkg_imports = .empty };
    errdefer r.deinit(allocator);

    for (app_imports) |ie| {
        const spec = try allocator.dupe(u8, ie.specifier);
        errdefer allocator.free(spec);
        const key = try pkgEntryKey(allocator, &ie.pkg_hash_hex);
        errdefer allocator.free(key);
        try r.app_imports.put(allocator, spec, key);
    }

    for (packages) |p| {
        var inner: std.StringHashMapUnmanaged([]const u8) = .empty;
        // On failure mid-package, free `inner`'s own entries before the
        // outer errdefer (which only knows the packages already in the map).
        errdefer {
            var it = inner.iterator();
            while (it.next()) |e| {
                allocator.free(e.key_ptr.*);
                allocator.free(e.value_ptr.*);
            }
            inner.deinit(allocator);
        }
        for (p.imports) |ie| {
            const spec = try allocator.dupe(u8, ie.specifier);
            errdefer allocator.free(spec);
            const val = try pkgEntryKey(allocator, &ie.pkg_hash_hex);
            errdefer allocator.free(val);
            try inner.put(allocator, spec, val);
        }
        const dir = try pkgDirKey(allocator, &p.pkg_hash_hex);
        errdefer allocator.free(dir);
        try r.pkg_imports.put(allocator, dir, inner);
    }
    return r;
}

/// `/pkg/<hash>/lib/x.mjs` → `/pkg/<hash>/` (the package's virtual dir,
/// the `pkg_imports` key). Null when `base` isn't a package-virtual path.
pub fn packageDirOf(base: []const u8) ?[]const u8 {
    const prefix = "/pkg/";
    if (!std.mem.startsWith(u8, base, prefix)) return null;
    const rest = base[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return base[0 .. prefix.len + slash + 1]; // include the trailing '/'
}

// ── resolution tests ────────────────────────────────────────

const testing = std.testing;

test "resolveSpecifier: bare passthrough + relative resolution (regression)" {
    var buf: [512]u8 = undefined;
    // Bare / builtin specifiers pass through unchanged.
    try testing.expectEqualStrings("@rewind/oidc", resolveSpecifier("index.mjs", "@rewind/oidc", &buf));
    try testing.expectEqualStrings("__system/x", resolveSpecifier("index.mjs", "__system/x", &buf));
    // Relative resolution against the importer's dir.
    try testing.expectEqualStrings("lib/util.mjs", resolveSpecifier("index.mjs", "./lib/util.mjs", &buf));
    try testing.expectEqualStrings("util.mjs", resolveSpecifier("lib/index.mjs", "../util.mjs", &buf));
    // A package's internal relative import stays within its /pkg/<hash>/ dir.
    try testing.expectEqualStrings("/pkg/OIDC/lib/token.mjs", resolveSpecifier("/pkg/OIDC/index.mjs", "./lib/token.mjs", &buf));
}

test "packageDirOf: extracts the package-virtual dir" {
    try testing.expectEqualStrings("/pkg/abc/", packageDirOf("/pkg/abc/index.mjs").?);
    try testing.expectEqualStrings("/pkg/abc/", packageDirOf("/pkg/abc/lib/token.mjs").?);
    try testing.expect(packageDirOf("index.mjs") == null);
    try testing.expect(packageDirOf("_triggers/users/index.mjs") == null);
    try testing.expect(packageDirOf("/pkg/abc") == null); // no file segment
}

test "PackageResolver: app vs package importer (flat surface + encapsulation)" {
    const a = testing.allocator;
    var app_imports: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer app_imports.deinit(a);
    try app_imports.put(a, "@rewind/oidc", "/pkg/OIDC/index.mjs");
    try app_imports.put(a, "@rewind/jwt", "/pkg/JWT19/index.mjs"); // app pins jwt 1.9

    var oidc_imports: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer oidc_imports.deinit(a);
    try oidc_imports.put(a, "@rewind/jwt", "/pkg/JWT14/index.mjs"); // oidc's OWN frozen jwt 1.4

    var pkg_imports: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty;
    defer pkg_imports.deinit(a);
    try pkg_imports.put(a, "/pkg/OIDC/", oidc_imports);

    const r = PackageResolver{ .app_imports = app_imports, .pkg_imports = pkg_imports };

    // App handler → the flat app surface.
    try testing.expectEqualStrings("/pkg/OIDC/index.mjs", r.resolve("index.mjs", "@rewind/oidc").?);
    try testing.expectEqualStrings("/pkg/JWT19/index.mjs", r.resolve("index.mjs", "@rewind/jwt").?);
    // Inside oidc, @rewind/jwt resolves to oidc's OWN pinned jwt 1.4 — the
    // encapsulation guarantee (app pins 1.9, oidc keeps 1.4).
    try testing.expectEqualStrings("/pkg/JWT14/index.mjs", r.resolve("/pkg/OIDC/index.mjs", "@rewind/jwt").?);
    // A package file deeper than index still resolves via its dir key.
    try testing.expectEqualStrings("/pkg/JWT14/index.mjs", r.resolve("/pkg/OIDC/lib/token.mjs", "@rewind/jwt").?);
    // Undeclared / builtin specifiers pass through (null → normalize falls
    // to resolveSpecifier): __system/*, unknown app dep, unknown pkg dep.
    try testing.expect(r.resolve("index.mjs", "__system/scheduler_tick") == null);
    try testing.expect(r.resolve("index.mjs", "@rewind/unknown") == null);
    try testing.expect(r.resolve("/pkg/OIDC/index.mjs", "@rewind/unknown") == null);
    // An importer under an unknown /pkg/ dir → null (no import map).
    try testing.expect(r.resolve("/pkg/NOPE/index.mjs", "@rewind/jwt") == null);
}
