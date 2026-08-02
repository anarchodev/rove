// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Offline resolution of the first-party `@rewind/*` package set for
//! `rewind test`. The 12 lifted libraries are embedded here (the same sources
//! the registry seed publishes); when an app's bundle `manifest.json` declares
//! an `@rewind/*` dependency, `build` produces the resolved package graph
//! (`packages` + `app_imports` + inline `/pkg/<hash>/` sources) and `mergeInto`
//! folds it into each test scenario's world — so a handler's
//! `import oidc from "@rewind/oidc"` resolves offline, with no per-scenario
//! inlining, through the SAME `package_resolver` prod uses.
//!
//! The pkg_hash here is a content hash (sha256 of the source) — offline needs
//! only INTERNAL consistency (app_imports[spec] == the package's hash; a
//! package's imports point at its deps' hashes), not registry-byte-match. A
//! scenario that inlines the identical source lands on the same hash and dedups
//! for free.

const std = @import("std");
const files = @import("rove-files");
const manifest = files.manifest_json;
const HASH_HEX_LEN = files.HASH_HEX_LEN;
const world = @import("world.zig");

const Embed = struct { spec: []const u8, src: []const u8 };

// The lifted first-party set. `@rewind/jwt` is the only intra-set dependency
// (imported by oauth + oidc); the transitive closure is discovered by scanning,
// so a future intra-set edge needs no change here.
const EMBEDS = [_]Embed{
    .{ .spec = "@rewind/jwt", .src = @embedFile("pkg_jwt") },
    .{ .spec = "@rewind/oauth", .src = @embedFile("pkg_oauth") },
    .{ .spec = "@rewind/cron", .src = @embedFile("pkg_cron") },
    .{ .spec = "@rewind/sessions", .src = @embedFile("pkg_sessions") },
    .{ .spec = "@rewind/retry", .src = @embedFile("pkg_retry") },
    .{ .spec = "@rewind/activitypub", .src = @embedFile("pkg_activitypub") },
    .{ .spec = "@rewind/email", .src = @embedFile("pkg_email") },
    .{ .spec = "@rewind/users", .src = @embedFile("pkg_users") },
    .{ .spec = "@rewind/oidc", .src = @embedFile("pkg_oidc") },
    .{ .spec = "@rewind/schedule", .src = @embedFile("pkg_schedule") },
    .{ .spec = "@rewind/segments", .src = @embedFile("pkg_segments") },
    .{ .spec = "@rewind/browser", .src = @embedFile("pkg_browser") },
};

pub const Graph = struct {
    packages: []const manifest.Package,
    app_imports: []const manifest.ImportEntry,
    pkg_sources: []const world.Source,
};

pub const Error = error{UnknownFirstParty} || std.mem.Allocator.Error;

fn findEmbed(spec: []const u8) ?Embed {
    for (EMBEDS) |e| if (std.mem.eql(u8, e.spec, spec)) return e;
    return null;
}

fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
}

fn hashHex(src: []const u8) [HASH_HEX_LEN]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(src, &digest, .{});
    var out: [HASH_HEX_LEN]u8 = undefined;
    const lut = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = lut[b >> 4];
        out[i * 2 + 1] = lut[b & 0xf];
    }
    return out;
}

// Canonical `@rewind/*` specs referenced by `src` that name a DIFFERENT
// embedded package. Deduped; entries are the embed's canonical spec literal.
fn scanDeps(a: std.mem.Allocator, self_spec: []const u8, src: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8){};
    var seen = std.StringHashMap(void).init(a);
    const needle = "@rewind/";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, needle)) |pos| {
        var j = pos + needle.len;
        while (j < src.len and isNameChar(src[j])) j += 1;
        i = j;
        const e = findEmbed(src[pos..j]) orelse continue;
        if (std.mem.eql(u8, e.spec, self_spec)) continue;
        if (seen.contains(e.spec)) continue;
        try seen.put(e.spec, {});
        try out.append(a, e.spec);
    }
    return out.toOwnedSlice(a);
}

/// Resolve `specs` (an app's declared `@rewind/*` deps) + their transitive
/// intra-set deps into a package graph. `error.UnknownFirstParty` if a spec
/// isn't in the embedded first-party set.
pub fn build(a: std.mem.Allocator, specs: []const []const u8) Error!Graph {
    // BFS transitive closure over the embedded set (discovery order).
    var seen = std.StringHashMap(void).init(a);
    var queue = std.ArrayList([]const u8){};
    for (specs) |s| {
        const e = findEmbed(s) orelse return Error.UnknownFirstParty;
        if (seen.contains(e.spec)) continue;
        try seen.put(e.spec, {});
        try queue.append(a, e.spec);
    }
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const e = findEmbed(queue.items[qi]).?;
        for (try scanDeps(a, e.spec, e.src)) |d| {
            if (seen.contains(d)) continue;
            try seen.put(d, {});
            try queue.append(a, d);
        }
    }

    var pkgs = std.ArrayList(manifest.Package){};
    var psrc = std.ArrayList(world.Source){};
    for (queue.items) |spec| {
        const e = findEmbed(spec).?;
        const hash = hashHex(e.src);
        var imports = std.ArrayList(manifest.ImportEntry){};
        for (try scanDeps(a, e.spec, e.src)) |d| {
            const de = findEmbed(d).?;
            try imports.append(a, .{ .specifier = de.spec, .pkg_hash_hex = hashHex(de.src) });
        }
        try pkgs.append(a, .{
            .spec = e.spec,
            .version = "1.0.0",
            .pkg_hash_hex = hash,
            .files = &.{},
            .imports = try imports.toOwnedSlice(a),
            .capabilities = &.{},
            .private = false,
        });
        try psrc.append(a, .{
            .path = try std.fmt.allocPrint(a, "/pkg/{s}/index.mjs", .{hash[0..]}),
            .kind = "handler",
            .source = e.src,
        });
    }

    // app_imports: one entry per REQUESTED (direct) spec; transitive deps are
    // reached through each package's own `imports` (the encapsulation model).
    var ai = std.ArrayList(manifest.ImportEntry){};
    var ai_seen = std.StringHashMap(void).init(a);
    for (specs) |s| {
        const e = findEmbed(s).?;
        if (ai_seen.contains(e.spec)) continue;
        try ai_seen.put(e.spec, {});
        try ai.append(a, .{ .specifier = e.spec, .pkg_hash_hex = hashHex(e.src) });
    }

    return .{
        .packages = try pkgs.toOwnedSlice(a),
        .app_imports = try ai.toOwnedSlice(a),
        .pkg_sources = try psrc.toOwnedSlice(a),
    };
}

/// Additively fold `g` into `wv` (in arena `a`). A scenario that already
/// declares a specifier keeps its own (inline wins); packages/sources dedup by
/// content hash / path — an identical inline copy collapses automatically.
pub fn mergeInto(a: std.mem.Allocator, wv: *world.World, g: *const Graph) !void {
    var have_spec = std.StringHashMap(void).init(a);
    for (wv.app_imports) |e| try have_spec.put(e.specifier, {});
    var ai = std.ArrayList(manifest.ImportEntry){};
    try ai.appendSlice(a, wv.app_imports);
    for (g.app_imports) |e| if (!have_spec.contains(e.specifier)) try ai.append(a, e);
    wv.app_imports = try ai.toOwnedSlice(a);

    var have_hash = std.StringHashMap(void).init(a);
    for (wv.packages) |*p| try have_hash.put(p.pkg_hash_hex[0..], {});
    var pk = std.ArrayList(manifest.Package){};
    try pk.appendSlice(a, wv.packages);
    for (g.packages) |*p| if (!have_hash.contains(p.pkg_hash_hex[0..])) try pk.append(a, p.*);
    wv.packages = try pk.toOwnedSlice(a);

    var have_path = std.StringHashMap(void).init(a);
    for (wv.pkg_sources) |s| try have_path.put(s.path, {});
    var ps = std.ArrayList(world.Source){};
    try ps.appendSlice(a, wv.pkg_sources);
    for (g.pkg_sources) |s| if (!have_path.contains(s.path)) try ps.append(a, s);
    wv.pkg_sources = try ps.toOwnedSlice(a);
}

test "build: transitive closure + hash consistency" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const g = try build(arena.allocator(), &.{"@rewind/oidc"});
    // oidc pulls in jwt transitively → 2 packages, 1 app import.
    try std.testing.expectEqual(@as(usize, 1), g.app_imports.len);
    try std.testing.expectEqualStrings("@rewind/oidc", g.app_imports[0].specifier);
    try std.testing.expectEqual(@as(usize, 2), g.packages.len);
    try std.testing.expectEqual(@as(usize, 2), g.pkg_sources.len);
    // the oidc package's frozen import points at jwt's content hash.
    var oidc_pkg: ?manifest.Package = null;
    var jwt_pkg: ?manifest.Package = null;
    for (g.packages) |p| {
        if (std.mem.eql(u8, p.spec, "@rewind/oidc")) oidc_pkg = p;
        if (std.mem.eql(u8, p.spec, "@rewind/jwt")) jwt_pkg = p;
    }
    try std.testing.expect(oidc_pkg != null and jwt_pkg != null);
    try std.testing.expectEqual(@as(usize, 1), oidc_pkg.?.imports.len);
    try std.testing.expectEqualSlices(u8, jwt_pkg.?.pkg_hash_hex[0..], oidc_pkg.?.imports[0].pkg_hash_hex[0..]);
    // app_import hash matches the oidc package identity.
    try std.testing.expectEqualSlices(u8, oidc_pkg.?.pkg_hash_hex[0..], g.app_imports[0].pkg_hash_hex[0..]);
}

test "build: unknown spec errors" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(Error.UnknownFirstParty, build(arena.allocator(), &.{"@rewind/nope"}));
}

test "build: leaf package has no imports" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // @rewind/segments is a true leaf (no intra-set imports; cf. cron→schedule).
    const g = try build(arena.allocator(), &.{"@rewind/segments"});
    try std.testing.expectEqual(@as(usize, 1), g.packages.len);
    try std.testing.expectEqual(@as(usize, 0), g.packages[0].imports.len);
}
