// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! P-CLI package-resolution client (rove#122) — the pure core of the
//! `rewind` CLI's package bridge.
//!
//! The customer declares loose `dependencies` in the bundle `manifest.json`
//! (`app_manifest.zig`); the CLI resolves them against the `@rewind`
//! registry app's `POST /v1/resolve` (`rewind-apps:registry/index.mjs`),
//! receiving the hash-locked graph as the manifest-v2 lockfile shape
//! `{packages[], app_imports}`. This module owns:
//!
//!   - `buildResolveRequest` — the `{dependencies, overrides}` request body.
//!   - `parseResolveResponse` — the registry response → an owned `Resolution`.
//!     Files carry `source_hash` only (source-only ingestion); bytecode is
//!     minted server-side at cut, never seen by the client.
//!   - `emitResolution` — the `resolution` JSON `/v1/deploy/cut` expects
//!     (files omitted; the deploy app joins the staged rows server-side and
//!     batch-compiles each package there).
//!
//! The wire shape is fixed by the engine and proven by
//! `scripts/smoke/pm_deploy_smoke.py` / `V2Cluster.deploy_with_packages`:
//! each package on the wire is `{spec, version, pkg_hash, imports[, files]}`
//! plus a top-level `app_imports` object — no `capabilities`/`private` on the
//! wire (the deploy app defaults them). Those two are parsed here for the
//! lockfile / author feedback, not sent to the engine.
//!
//! The resolved graph is owned by an arena on `Resolution` — the CLI is
//! short-lived, so one free at the end is the whole story.

const std = @import("std");

/// One loose package dependency from the bundle `manifest.json` — a
/// `@scope/pkg` specifier and its version `range` (`"^1.9"`, `"1.4.2"`,
/// `"*"`, …). The resolver turns the set into a hash-locked pin. Kept here
/// (not imported from the engine's `app_manifest.zig`) so this CLI module
/// stays std-only and standalone-testable; `app_manifest.validate` is the
/// engine-side shape backstop.
pub const Dependency = struct {
    spec: []const u8,
    range: []const u8,
};

/// One `{ specifier → pkg_hash }` edge — a package's own frozen `imports`
/// or the deployment's `app_imports`.
pub const ImportPair = struct {
    specifier: []const u8,
    pkg_hash: []const u8,
};

/// One package file, as the registry describes it: path + content hash of
/// the source. Bytecode is minted server-side at cut — the client never
/// carries it.
pub const PkgFile = struct {
    path: []const u8,
    source_hash: []const u8,
};

/// A resolved package version. `pkg_hash` is its content identity + the
/// `/pkg/<pkg_hash>/` virtual dir its files stage under. `imports` values
/// point at *dep* pkg_hashes (frozen at publish); `private` = not on the app
/// surface (reachable only through another package's imports).
pub const Package = struct {
    spec: []const u8,
    version: []const u8,
    pkg_hash: []const u8,
    files: []PkgFile,
    imports: []ImportPair,
    capabilities: [][]const u8,
    private: bool,
};

/// The resolved graph — the registry's `POST /v1/resolve` response, owned by
/// an arena. `deinit` frees everything at once.
pub const Resolution = struct {
    packages: []Package,
    app_imports: []ImportPair,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Resolution) void {
        self.arena.deinit();
    }
};

pub const Error = error{
    /// Response (or request inputs) not shaped as expected.
    BadResolution,
    /// The registry could not satisfy a range (its `422 unresolved`).
    Unresolved,
    ParseFailed,
    OutOfMemory,
};

// ── manifest input ──────────────────────────────────────────────────────────

/// Read the loose `dependencies` map from a bundle `manifest.json` into owned
/// `Dependency` entries (allocated in `a` — use an arena and free it
/// wholesale, as the CLI does). Absent `dependencies` → empty. A malformed
/// map (not an object, or a non-string / empty range) → `Error.BadResolution`.
pub fn readDependencies(a: std.mem.Allocator, manifest_bytes: []const u8) Error![]Dependency {
    var parsed = std.json.parseFromSlice(std.json.Value, a, manifest_bytes, .{}) catch
        return Error.ParseFailed;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return Error.BadResolution;
    const deps_val = root.object.get("dependencies") orelse return &.{};
    if (deps_val != .object) return Error.BadResolution;

    const out = try a.alloc(Dependency, deps_val.object.count());
    var it = deps_val.object.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        if (e.value_ptr.* != .string or e.value_ptr.string.len == 0) return Error.BadResolution;
        out[i] = .{
            .spec = try a.dupe(u8, e.key_ptr.*),
            .range = try a.dupe(u8, e.value_ptr.string),
        };
    }
    return out;
}

// ── import scanning (auto-pin) ───────────────────────────────────────────────

fn isIdentByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or b == '_' or b == '$';
}

/// True for a `@scope/name` package specifier (what the resolver routes). The
/// registry validates precisely; this is the loose CLI-side shape test that
/// distinguishes a package import from a relative (`./`), `__system/*`, or
/// non-`@` bare specifier.
fn isPackageSpec(s: []const u8) bool {
    if (s.len < 4 or s[0] != '@') return false;
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
    if (slash < 2 or slash + 1 >= s.len) return false;
    for (s) |ch| if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') return false;
    return true;
}

/// The quoted specifier a `from` / `import` keyword introduces, if any: skip
/// whitespace, an optional `(` (dynamic import), whitespace, then read a
/// single- or double-quoted string. Null if what follows isn't a quoted
/// specifier (so `important`, `arr.from(x)`, etc. don't match).
fn specifierAfter(source: []const u8, pos: usize) ?[]const u8 {
    var j = pos;
    while (j < source.len and (source[j] == ' ' or source[j] == '\t' or source[j] == '\n' or source[j] == '\r')) j += 1;
    if (j < source.len and source[j] == '(') {
        j += 1;
        while (j < source.len and (source[j] == ' ' or source[j] == '\t' or source[j] == '\n' or source[j] == '\r')) j += 1;
    }
    if (j >= source.len) return null;
    const q = source[j];
    if (q != '"' and q != '\'') return null;
    j += 1;
    const start = j;
    while (j < source.len and source[j] != q) j += 1;
    if (j >= source.len) return null; // unterminated
    return source[start..j];
}

/// The distinct `@scope/pkg` package specifiers `source` imports — the targets
/// of `import`/`export … from "…"`, bare `import "…"`, and dynamic
/// `import("…")`. A heuristic scan (not a full JS parse): finds the `from` /
/// `import` keywords at identifier boundaries and reads the specifier each
/// introduces. Relative / `__system/*` / non-`@` specifiers are ignored (not
/// packages). Owned by `a`; order is unspecified (grouped by keyword,
/// deduped) — the resolver consumes the set. The engine's compile-time import
/// validation is the real gate — a missed import fails the deploy loudly
/// rather than resolving wrong.
pub fn extractPackageImports(a: std.mem.Allocator, source: []const u8) Error![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(a);
    inline for (.{ "from", "import" }) |kw| {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, source, i, kw)) |idx| {
            i = idx + kw.len;
            const before: u8 = if (idx == 0) ' ' else source[idx - 1];
            // Left boundary: not mid-identifier, and not a member access
            // (`obj.from(...)` is a call, not an import).
            if (isIdentByte(before) or before == '.') continue;
            if (specifierAfter(source, idx + kw.len)) |spec| {
                if (isPackageSpec(spec) and !seen.contains(spec)) {
                    const owned = try a.dupe(u8, spec);
                    try seen.put(owned, {});
                    try out.append(a, owned);
                }
            }
        }
    }
    return out.toOwnedSlice(a) catch Error.OutOfMemory;
}

// ── request ───────────────────────────────────────────────────────────────

/// Build the `POST /v1/resolve` request body:
/// `{"dependencies":{spec:range,…},"overrides":{spec:version,…}}`.
/// `overrides` is emitted only when non-empty. Caller owns the returned bytes.
pub fn buildResolveRequest(
    a: std.mem.Allocator,
    deps: []const Dependency,
    overrides: []const Dependency,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    try out.appendSlice(a, "{\"dependencies\":");
    try writeStringMap(&out, a, deps);
    if (overrides.len > 0) {
        try out.appendSlice(a, ",\"overrides\":");
        try writeStringMap(&out, a, overrides);
    }
    try out.append(a, '}');
    return try out.toOwnedSlice(a);
}

/// `{spec:range, …}` from a `[]Dependency` (used for dependencies/overrides).
fn writeStringMap(out: *std.ArrayList(u8), a: std.mem.Allocator, entries: []const Dependency) Error!void {
    try out.append(a, '{');
    for (entries, 0..) |d, i| {
        if (i != 0) try out.append(a, ',');
        try writeJsonPair(out, a, d.spec, d.range);
    }
    try out.append(a, '}');
}

// ── response parsing ────────────────────────────────────────────────────────

/// Parse the registry's `/v1/resolve` response (`{packages[], app_imports}`)
/// into an owned `Resolution`. A `{"error":…}` body (e.g. the registry's
/// `422 unresolved`) → `Error.Unresolved`. Everything is duped into the
/// resolution's arena.
pub fn parseResolveResponse(gpa: std.mem.Allocator, json_bytes: []const u8) Error!Resolution {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Parsed into the arena; freed with it (no separate `parsed.deinit`).
    const parsed = std.json.parseFromSlice(std.json.Value, a, json_bytes, .{}) catch
        return Error.ParseFailed;
    const root = parsed.value;

    if (root != .object) return Error.BadResolution;
    const obj = root.object;

    if (obj.get("error") != null and obj.get("packages") == null) return Error.Unresolved;

    const pkgs_val = obj.get("packages") orelse return Error.BadResolution;
    if (pkgs_val != .array) return Error.BadResolution;

    const packages = try a.alloc(Package, pkgs_val.array.items.len);
    for (pkgs_val.array.items, 0..) |pv, i| {
        packages[i] = try parsePackage(a, pv);
    }

    const app_imports = try parseImportPairs(a, obj.get("app_imports"));

    return .{ .packages = packages, .app_imports = app_imports, .arena = arena };
}

fn parsePackage(a: std.mem.Allocator, v: std.json.Value) Error!Package {
    if (v != .object) return Error.BadResolution;
    const o = v.object;
    const spec = try dupField(a, o, "spec");
    const version = try dupField(a, o, "version");
    const pkg_hash = try dupField(a, o, "pkg_hash");

    const files_val = o.get("files") orelse return Error.BadResolution;
    if (files_val != .array) return Error.BadResolution;
    const files = try a.alloc(PkgFile, files_val.array.items.len);
    for (files_val.array.items, 0..) |fv, i| {
        if (fv != .object) return Error.BadResolution;
        files[i] = .{
            .path = try dupField(a, fv.object, "path"),
            .source_hash = try dupField(a, fv.object, "source_hash"),
        };
    }

    const imports = try parseImportPairs(a, o.get("imports"));

    var caps: [][]const u8 = &.{};
    if (o.get("capabilities")) |cv| {
        if (cv != .array) return Error.BadResolution;
        caps = try a.alloc([]const u8, cv.array.items.len);
        for (cv.array.items, 0..) |c, i| {
            if (c != .string) return Error.BadResolution;
            caps[i] = try a.dupe(u8, c.string);
        }
    }

    const private = if (o.get("private")) |pv| (pv == .bool and pv.bool) else false;

    return .{
        .spec = spec,
        .version = version,
        .pkg_hash = pkg_hash,
        .files = files,
        .imports = imports,
        .capabilities = caps,
        .private = private,
    };
}

/// Parse a `{specifier: pkg_hash}` object into owned `[]ImportPair`
/// (sorted by specifier for a stable wire). Null/absent → empty.
fn parseImportPairs(a: std.mem.Allocator, v: ?std.json.Value) Error![]ImportPair {
    const val = v orelse return &.{};
    if (val == .null) return &.{};
    if (val != .object) return Error.BadResolution;
    const pairs = try a.alloc(ImportPair, val.object.count());
    var it = val.object.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        if (e.value_ptr.* != .string) return Error.BadResolution;
        pairs[i] = .{
            .specifier = try a.dupe(u8, e.key_ptr.*),
            .pkg_hash = try a.dupe(u8, e.value_ptr.string),
        };
    }
    std.mem.sort(ImportPair, pairs, {}, lessImport);
    return pairs;
}

fn lessImport(_: void, x: ImportPair, y: ImportPair) bool {
    return std.mem.lessThan(u8, x.specifier, y.specifier);
}

fn dupField(a: std.mem.Allocator, o: std.json.ObjectMap, key: []const u8) Error![]const u8 {
    const v = o.get(key) orelse return Error.BadResolution;
    if (v != .string) return Error.BadResolution;
    return a.dupe(u8, v.string);
}

// ── leaves-first ordering ───────────────────────────────────────────────────

/// Reorder `res.packages` leaves-first: every package's in-set dependencies
/// (its `imports` values that name another package in the set) precede it, so
/// the deploy stages a package only after the deps it imports are staged +
/// compilable (quickjs resolves imports at compile — `pm_deploy_smoke.py`).
/// Errors on a cycle (packages are a content-addressed DAG).
pub fn topoSort(res: *Resolution) Error!void {
    const a = res.arena.allocator();
    const n = res.packages.len;

    var idx = std.StringHashMap(usize).init(a);
    for (res.packages, 0..) |p, i| try idx.put(p.pkg_hash, i);

    const state = try a.alloc(VisitState, n);
    @memset(state, .unvisited);
    var order: std.ArrayListUnmanaged(usize) = .empty;
    try order.ensureTotalCapacity(a, n);
    for (0..n) |i| try dfsVisit(res, &idx, state, &order, a, i);

    const sorted = try a.alloc(Package, n);
    for (order.items, 0..) |src, dst| sorted[dst] = res.packages[src];
    res.packages = sorted;
}

const VisitState = enum { unvisited, visiting, done };

fn dfsVisit(
    res: *const Resolution,
    idx: *const std.StringHashMap(usize),
    state: []VisitState,
    order: *std.ArrayListUnmanaged(usize),
    a: std.mem.Allocator,
    i: usize,
) Error!void {
    switch (state[i]) {
        .done => return,
        .visiting => return Error.BadResolution, // cycle
        .unvisited => {},
    }
    state[i] = .visiting;
    for (res.packages[i].imports) |imp| {
        if (idx.get(imp.pkg_hash)) |di| try dfsVisit(res, idx, state, order, a, di);
    }
    state[i] = .done;
    try order.append(a, i);
}

// ── wire emission ───────────────────────────────────────────────────────────

/// Emit the `resolution` JSON the deploy app consumes on `/v1/deploy/cut`:
/// every package carries `{spec, version, pkg_hash, imports}` and no
/// `files` — the deploy app joins the staged `_workspace_pkg/` rows
/// server-side (hashes stay server-authoritative) and batch-compiles each
/// package there. No `capabilities`/`private` on the wire (the deploy app
/// defaults them).
pub fn emitResolution(
    a: std.mem.Allocator,
    res: *const Resolution,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    try out.appendSlice(a, "{\"packages\":[");
    for (res.packages, 0..) |p, pi| {
        if (pi != 0) try out.append(a, ',');
        try out.appendSlice(a, "{\"spec\":");
        try writeJsonString(&out, a, p.spec);
        try out.appendSlice(a, ",\"version\":");
        try writeJsonString(&out, a, p.version);
        try out.appendSlice(a, ",\"pkg_hash\":");
        try writeJsonString(&out, a, p.pkg_hash);
        try out.appendSlice(a, ",\"imports\":");
        try writeImportObject(&out, a, p.imports);
        try out.append(a, '}');
    }
    try out.appendSlice(a, "],\"app_imports\":");
    try writeImportObject(&out, a, res.app_imports);
    try out.append(a, '}');
    return try out.toOwnedSlice(a);
}

fn writeImportObject(out: *std.ArrayList(u8), a: std.mem.Allocator, imports: []const ImportPair) Error!void {
    try out.append(a, '{');
    for (imports, 0..) |ie, i| {
        if (i != 0) try out.append(a, ',');
        try writeJsonPair(out, a, ie.specifier, ie.pkg_hash);
    }
    try out.append(a, '}');
}

fn writeJsonPair(out: *std.ArrayList(u8), a: std.mem.Allocator, key: []const u8, val: []const u8) Error!void {
    try writeJsonString(out, a, key);
    try out.append(a, ':');
    try writeJsonString(out, a, val);
}

/// Minimal JSON string escaping — quotes, backslash, and control chars.
/// Package specs / versions / hashes / paths are ASCII, so this covers them;
/// kept self-contained so this module has no cross-deps beyond std.
fn writeJsonString(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) Error!void {
    try out.append(a, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => {
                if (ch < 0x20) {
                    var buf: [6]u8 = undefined;
                    const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch unreachable;
                    try out.appendSlice(a, esc);
                } else {
                    try out.append(a, ch);
                }
            },
        }
    }
    try out.append(a, '"');
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "readDependencies: parses the manifest dependencies map; absent → empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const deps = try readDependencies(a,
        \\{"name":"app","version":"1.0.0","dependencies":{"@rewind/jwt":"^1.9","@rewind/oidc":"*"}}
    );
    try testing.expectEqual(@as(usize, 2), deps.len);
    var saw = false;
    for (deps) |d| if (std.mem.eql(u8, d.spec, "@rewind/jwt")) {
        saw = true;
        try testing.expectEqualStrings("^1.9", d.range);
    };
    try testing.expect(saw);

    const none = try readDependencies(a, "{\"name\":\"x\",\"version\":\"1\"}");
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "extractPackageImports: finds @scope/pkg imports, ignores the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\import { greet } from "@rewind/greet";
        \\import "@rewind/side";
        \\const dyn = await import('@rewind/dyn');
        \\export { thing } from "@scope/re";
        \\import local from "./local.mjs";
        \\import sys from "__system/next";
        \\import { greet as g2 } from "@rewind/greet"; // duplicate
        \\const s = "@fake/notimported";           // a bare string, not an import
        \\const x = arr.from("@method/call");        // member call, not an import
    ;
    // Order is keyword-grouped (all `from`-clauses, then bare/dynamic
    // `import`s), deduped — the resolver consumes the set, not the order.
    const got = try extractPackageImports(a, src);
    try testing.expectEqual(@as(usize, 4), got.len);
    var set = std.StringHashMap(void).init(a);
    for (got) |s| try set.put(s, {});
    try testing.expect(set.contains("@rewind/greet"));
    try testing.expect(set.contains("@rewind/side"));
    try testing.expect(set.contains("@rewind/dyn"));
    try testing.expect(set.contains("@scope/re"));
    try testing.expect(!set.contains("@fake/notimported"));
    try testing.expect(!set.contains("@method/call"));
}

test "extractPackageImports: none in a package-free handler" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try extractPackageImports(arena.allocator(),
        \\export default function () { return "hi"; }
        \\import "./util.mjs";
    );
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "readDependencies: malformed dependencies → BadResolution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(Error.BadResolution, readDependencies(a,
        \\{"dependencies":["@rewind/jwt"]}
    ));
    try testing.expectError(Error.BadResolution, readDependencies(a,
        \\{"dependencies":{"@rewind/jwt":42}}
    ));
}

test "buildResolveRequest: deps only, then with overrides" {
    const deps = [_]Dependency{
        .{ .spec = "@rewind/jwt", .range = "^1.9" },
        .{ .spec = "@rewind/oidc", .range = "*" },
    };
    {
        const body = try buildResolveRequest(testing.allocator, &deps, &.{});
        defer testing.allocator.free(body);
        try testing.expectEqualStrings(
            "{\"dependencies\":{\"@rewind/jwt\":\"^1.9\",\"@rewind/oidc\":\"*\"}}",
            body,
        );
    }
    {
        const ov = [_]Dependency{.{ .spec = "@rewind/jwt", .range = "1.9.3" }};
        const body = try buildResolveRequest(testing.allocator, &deps, &ov);
        defer testing.allocator.free(body);
        try testing.expectEqualStrings(
            "{\"dependencies\":{\"@rewind/jwt\":\"^1.9\",\"@rewind/oidc\":\"*\"}," ++
                "\"overrides\":{\"@rewind/jwt\":\"1.9.3\"}}",
            body,
        );
    }
}

test "parseResolveResponse: parses packages + app_imports; encapsulation + private" {
    // app binds jwt@1.9; oidc (app surface) freezes its own jwt@1.4 (private).
    const json =
        \\{"packages":[
        \\ {"spec":"@rewind/jwt","version":"1.9.0","pkg_hash":"aa","files":[{"path":"index.mjs","source_hash":"s9"}],"imports":{},"capabilities":["crypto"],"private":false},
        \\ {"spec":"@rewind/oidc","version":"2.0.0","pkg_hash":"bb","files":[{"path":"index.mjs","source_hash":"so"}],"imports":{"@rewind/jwt":"cc"},"capabilities":["crypto","http"],"private":false},
        \\ {"spec":"@rewind/jwt","version":"1.4.0","pkg_hash":"cc","files":[{"path":"index.mjs","source_hash":"s4"}],"imports":{},"capabilities":["crypto"],"private":true}
        \\],"app_imports":{"@rewind/jwt":"aa","@rewind/oidc":"bb"}}
    ;
    var res = try parseResolveResponse(testing.allocator, json);
    defer res.deinit();

    try testing.expectEqual(@as(usize, 3), res.packages.len);
    try testing.expectEqual(@as(usize, 2), res.app_imports.len);
    // app_imports sorted by specifier.
    try testing.expectEqualStrings("@rewind/jwt", res.app_imports[0].specifier);
    try testing.expectEqualStrings("aa", res.app_imports[0].pkg_hash);

    // The oidc package encapsulates jwt@1.4 (hash cc) via its imports.
    const oidc = res.packages[1];
    try testing.expectEqualStrings("@rewind/oidc", oidc.spec);
    try testing.expectEqual(@as(usize, 1), oidc.imports.len);
    try testing.expectEqualStrings("@rewind/jwt", oidc.imports[0].specifier);
    try testing.expectEqualStrings("cc", oidc.imports[0].pkg_hash);

    // The nested jwt@1.4 is private; files carry source_hash, no bytecode yet.
    const jwt14 = res.packages[2];
    try testing.expect(jwt14.private);
    try testing.expectEqualStrings("s4", jwt14.files[0].source_hash);
    try testing.expectEqualStrings("crypto", jwt14.capabilities[0]);
}

test "parseResolveResponse: an error body → Unresolved" {
    try testing.expectError(Error.Unresolved, parseResolveResponse(testing.allocator,
        \\{"error":"resolve failed","code":"unresolved","spec":"@rewind/ghost"}
    ));
}

test "emitResolution: the files-less lockfile skeleton (the deploy app joins staged rows)" {
    const json =
        \\{"packages":[
        \\ {"spec":"@rewind/jwt","version":"1.9.0","pkg_hash":"aa","files":[{"path":"index.mjs","source_hash":"s9"}],"imports":{}}
        \\],"app_imports":{"@rewind/jwt":"aa"}}
    ;
    var res = try parseResolveResponse(testing.allocator, json);
    defer res.deinit();

    const wire = try emitResolution(testing.allocator, &res);
    defer testing.allocator.free(wire);
    try testing.expectEqualStrings(
        "{\"packages\":[{\"spec\":\"@rewind/jwt\",\"version\":\"1.9.0\"," ++
            "\"pkg_hash\":\"aa\",\"imports\":{}}]," ++
            "\"app_imports\":{\"@rewind/jwt\":\"aa\"}}",
        wire,
    );
}

test "topoSort: orders deps before importers (leaves first)" {
    // oidc (hash bb) imports jwt (hash aa); the response lists oidc first.
    const json =
        \\{"packages":[
        \\ {"spec":"@rewind/oidc","version":"2.0.0","pkg_hash":"bb","files":[{"path":"index.mjs","source_hash":"so"}],"imports":{"@rewind/jwt":"aa"}},
        \\ {"spec":"@rewind/jwt","version":"1.9.0","pkg_hash":"aa","files":[{"path":"index.mjs","source_hash":"s9"}],"imports":{}}
        \\],"app_imports":{"@rewind/oidc":"bb"}}
    ;
    var res = try parseResolveResponse(testing.allocator, json);
    defer res.deinit();
    try topoSort(&res);
    // jwt (leaf) must come before oidc (its importer).
    try testing.expectEqualStrings("aa", res.packages[0].pkg_hash);
    try testing.expectEqualStrings("bb", res.packages[1].pkg_hash);
}

test "topoSort: a cycle is rejected" {
    const json =
        \\{"packages":[
        \\ {"spec":"@x/a","version":"1.0.0","pkg_hash":"aa","files":[{"path":"i.mjs","source_hash":"s1"}],"imports":{"@x/b":"bb"}},
        \\ {"spec":"@x/b","version":"1.0.0","pkg_hash":"bb","files":[{"path":"i.mjs","source_hash":"s2"}],"imports":{"@x/a":"aa"}}
        \\],"app_imports":{"@x/a":"aa"}}
    ;
    var res = try parseResolveResponse(testing.allocator, json);
    defer res.deinit();
    try testing.expectError(Error.BadResolution, topoSort(&res));
}
