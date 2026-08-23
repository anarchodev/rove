// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! JSON encoder / decoder for the per-deployment manifest stored in
//! S3 at `tenants/{id}/deployments/e{bc_version}/{dep_id:020d}.json` — one object per
//! deployment in a per-tenant `deployments/` BlobBackend.
//!
//! Wire shape (also the storage shape):
//!
//! ```json
//! {
//!   "v": 2,
//!   "deployment_id": 42,
//!   "entries": [
//!     {"path": "index.mjs",         "kind": "handler",
//!      "content_type": "",
//!      "hash":          "<source-sha256>",
//!      "bytecode_hash": "<bytecode-sha256>"},
//!     {"path": "_static/index.html","kind": "static",
//!      "content_type": "text/html; charset=utf-8",
//!      "hash":          "<content-sha256>"}
//!   ]
//! }
//! ```
//!
//! Notes on the schema:
//!
//! - `hash` is the source-blob hash (handlers) or content-blob hash
//!   (statics). Named `hash` (not `source_hash`) so the dashboard's
//!   reader (`web/admin/api.js`) matches.
//! - `bytecode_hash` is required for `handler` entries (worker fetches
//!   bytecode via this hash from the file-blobs BlobBackend) and
//!   omitted for `static` entries.
//! - `content_type` is the empty string for handlers (they're served
//!   via the JS dispatcher; the wire content-type comes from the
//!   handler's response object), and the manifest-stamped MIME for
//!   statics.
//! - `v` is the schema version (currently `2`). The decoder rejects
//!   anything that doesn't match.

const std = @import("std");
const root = @import("root.zig");

/// `v:2` — handlers/statics + the optional `packages` / `app_imports`
/// sections. The decoder rejects anything that isn't v2 and `encode`
/// always emits v2; pre-launch (no customers), a version bump is a
/// complete redeploy rather than a compatibility shim.
/// (A package-less deploy is simply a v2 manifest with no `packages`.)
pub const VERSION: u32 = 2;

pub const Error = error{
    InvalidManifest,
    OutOfMemory,
};

/// One file a package ships (path within the package + its hashes). The
/// populator stages the bytecode at `/pkg/<pkg_hash>/<path>`.
pub const PkgFile = struct {
    path: []const u8,
    bytecode_hex: [root.HASH_HEX_LEN]u8,
    source_hex: [root.HASH_HEX_LEN]u8,
};

/// One `{ specifier → dep pkg_hash }` resolution pair — used for both a
/// package's own `imports` and the deployment's `app_imports`.
pub const ImportEntry = struct {
    specifier: []const u8,
    pkg_hash_hex: [root.HASH_HEX_LEN]u8,
};

/// A resolved package version. `pkg_hash_hex` is its content identity +
/// the `/pkg/<pkg_hash>/` virtual dir its files live under. `imports`
/// values point at *dep* pkg_hashes (encapsulated, frozen-at-publish);
/// see `docs/architecture/package-resolution.md`.
pub const Package = struct {
    spec: []const u8,
    version: []const u8,
    pkg_hash_hex: [root.HASH_HEX_LEN]u8,
    files: []PkgFile,
    imports: []ImportEntry,
    capabilities: [][]const u8,
    private: bool,
};

/// In-memory manifest as the worker consumes it after
/// parsing. Owns its `entries` slice + each entry's `path` and
/// `content_type` allocations, plus the `packages` / `app_imports`
/// sections and every string they own. `packages`/`app_imports` are
/// empty for a package-less manifest.
pub const Manifest = struct {
    id: u64,
    entries: []root.Entry,
    packages: []Package = &.{},
    app_imports: []ImportEntry = &.{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Manifest) void {
        for (self.entries) |e| {
            self.allocator.free(e.path);
            self.allocator.free(e.content_type);
        }
        self.allocator.free(self.entries);
        for (self.packages) |p| {
            self.allocator.free(p.spec);
            self.allocator.free(p.version);
            for (p.files) |f| self.allocator.free(f.path);
            self.allocator.free(p.files);
            for (p.imports) |ie| self.allocator.free(ie.specifier);
            self.allocator.free(p.imports);
            for (p.capabilities) |cap| self.allocator.free(cap);
            self.allocator.free(p.capabilities);
        }
        self.allocator.free(self.packages);
        for (self.app_imports) |ie| self.allocator.free(ie.specifier);
        self.allocator.free(self.app_imports);
        self.* = undefined;
    }
};

/// Encode `entries` (with deployment id `dep_id`) into a JSON object.
/// Returns owned bytes; caller frees. Doesn't allocate per-entry —
/// writes directly into the output buffer.
pub fn encode(
    allocator: std.mem.Allocator,
    dep_id: u64,
    entries: []const root.Entry,
    packages: []const Package,
    app_imports: []const ImportEntry,
) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var w = buf.writer(allocator);

    // dep_id is a content-addressed u64 (truncated sha-256). High-
    // bit-set hashes don't fit cleanly in JSON `integer` (i64 in the
    // std.json parser) so encode as a 16-char zero-padded hex string.
    try w.print("{{\"v\":{d},\"deployment_id\":\"{x:0>16}\",\"entries\":[", .{ VERSION, dep_id });
    for (entries, 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        const kind_str: []const u8 = if (e.kind == .handler) "handler" else "static";
        try w.writeAll("{\"path\":");
        try writeJsonString(&w, e.path);
        try w.print(",\"kind\":\"{s}\",\"content_type\":", .{kind_str});
        try writeJsonString(&w, e.content_type);
        try w.print(",\"hash\":\"{s}\"", .{e.source_hex});
        if (e.kind == .handler) {
            try w.print(",\"bytecode_hash\":\"{s}\"", .{e.bytecode_hex});
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');

    if (packages.len > 0) {
        try w.writeAll(",\"packages\":[");
        for (packages, 0..) |p, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"spec\":");
            try writeJsonString(&w, p.spec);
            try w.writeAll(",\"version\":");
            try writeJsonString(&w, p.version);
            try w.print(",\"pkg_hash\":\"{s}\",\"files\":[", .{p.pkg_hash_hex});
            for (p.files, 0..) |f, j| {
                if (j > 0) try w.writeByte(',');
                try w.writeAll("{\"path\":");
                try writeJsonString(&w, f.path);
                try w.print(",\"bytecode_hash\":\"{s}\",\"source_hash\":\"{s}\"}}", .{ f.bytecode_hex, f.source_hex });
            }
            try w.writeAll("],\"imports\":{");
            for (p.imports, 0..) |ie, j| {
                if (j > 0) try w.writeByte(',');
                try writeJsonString(&w, ie.specifier);
                try w.print(":\"{s}\"", .{ie.pkg_hash_hex});
            }
            try w.writeAll("},\"capabilities\":[");
            for (p.capabilities, 0..) |cap, j| {
                if (j > 0) try w.writeByte(',');
                try writeJsonString(&w, cap);
            }
            try w.writeByte(']');
            if (p.private) try w.writeAll(",\"private\":true");
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }

    if (app_imports.len > 0) {
        try w.writeAll(",\"app_imports\":{");
        for (app_imports, 0..) |ie, i| {
            if (i > 0) try w.writeByte(',');
            try writeJsonString(&w, ie.specifier);
            try w.print(":\"{s}\"", .{ie.pkg_hash_hex});
        }
        try w.writeByte('}');
    }

    try w.writeByte('}');
    return buf.toOwnedSlice(allocator);
}

/// Parse the JSON manifest produced by `encode`. The deployment id is
/// taken from the JSON body (`deployment_id`) rather than from the
/// caller — keeping a single source of truth so a manifest moved /
/// renamed / mis-keyed surfaces as a clear mismatch.
///
/// Returns an owned `Manifest`; caller calls `deinit`.
pub fn decode(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!Manifest {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{},
    ) catch return Error.InvalidManifest;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return Error.InvalidManifest,
    };

    const v_val = obj.get("v") orelse return Error.InvalidManifest;
    const v_num = switch (v_val) {
        .integer => |i| i,
        else => return Error.InvalidManifest,
    };
    if (v_num != @as(i64, VERSION)) return Error.InvalidManifest;

    const id_val = obj.get("deployment_id") orelse return Error.InvalidManifest;
    const id_str = switch (id_val) {
        .string => |s| s,
        else => return Error.InvalidManifest,
    };
    const id: u64 = std.fmt.parseInt(u64, id_str, 16) catch return Error.InvalidManifest;

    const entries_val = obj.get("entries") orelse return Error.InvalidManifest;
    const arr = switch (entries_val) {
        .array => |a| a,
        else => return Error.InvalidManifest,
    };

    var entries = allocator.alloc(root.Entry, arr.items.len) catch
        return Error.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (entries[0..filled]) |e| {
            allocator.free(e.path);
            allocator.free(e.content_type);
        }
        allocator.free(entries);
    }

    for (arr.items) |item| {
        const e_obj = switch (item) {
            .object => |o| o,
            else => return Error.InvalidManifest,
        };

        const path_val = e_obj.get("path") orelse return Error.InvalidManifest;
        const path_str = switch (path_val) {
            .string => |s| s,
            else => return Error.InvalidManifest,
        };
        const path_copy = allocator.dupe(u8, path_str) catch return Error.OutOfMemory;
        errdefer allocator.free(path_copy);

        const kind_val = e_obj.get("kind") orelse return Error.InvalidManifest;
        const kind_str = switch (kind_val) {
            .string => |s| s,
            else => return Error.InvalidManifest,
        };
        const kind: root.Kind = if (std.mem.eql(u8, kind_str, "handler"))
            .handler
        else if (std.mem.eql(u8, kind_str, "static"))
            .static
        else
            return Error.InvalidManifest;

        const ct_val = e_obj.get("content_type") orelse return Error.InvalidManifest;
        const ct_str = switch (ct_val) {
            .string => |s| s,
            else => return Error.InvalidManifest,
        };
        const ct_copy = allocator.dupe(u8, ct_str) catch return Error.OutOfMemory;
        errdefer allocator.free(ct_copy);

        const hash_val = e_obj.get("hash") orelse return Error.InvalidManifest;
        const hash_str = switch (hash_val) {
            .string => |s| s,
            else => return Error.InvalidManifest,
        };
        if (hash_str.len != root.HASH_HEX_LEN) return Error.InvalidManifest;
        var src_hex: [root.HASH_HEX_LEN]u8 = undefined;
        @memcpy(&src_hex, hash_str[0..root.HASH_HEX_LEN]);

        var bc_hex: [root.HASH_HEX_LEN]u8 = @splat(0);
        if (kind == .handler) {
            const bc_val = e_obj.get("bytecode_hash") orelse return Error.InvalidManifest;
            const bc_str = switch (bc_val) {
                .string => |s| s,
                else => return Error.InvalidManifest,
            };
            if (bc_str.len != root.HASH_HEX_LEN) return Error.InvalidManifest;
            @memcpy(&bc_hex, bc_str[0..root.HASH_HEX_LEN]);
        }

        entries[filled] = .{
            .path = path_copy,
            .kind = kind,
            .content_type = ct_copy,
            .source_hex = src_hex,
            .bytecode_hex = bc_hex,
        };
        filled += 1;
    }

    // Optional `packages` / `app_imports`. A manifest that omits both →
    // empty slices. Allocate 0-length (not `&.{}`) so the errdefers /
    // deinit free unconditionally.
    const packages = if (obj.get("packages")) |pv|
        try parsePackages(allocator, pv)
    else
        allocator.alloc(Package, 0) catch return Error.OutOfMemory;
    errdefer {
        for (packages) |p| freePackage(allocator, p);
        allocator.free(packages);
    }

    const app_imports = if (obj.get("app_imports")) |av|
        try parseImportMap(allocator, av)
    else
        allocator.alloc(ImportEntry, 0) catch return Error.OutOfMemory;

    return .{
        .id = id,
        .entries = entries,
        .packages = packages,
        .app_imports = app_imports,
        .allocator = allocator,
    };
}

/// A deploy-time resolution context: just the `packages` +
/// `app_imports` sections of a manifest, wire-identical to their v2
/// manifest shapes. The deploy path carries this alongside a compile
/// batch so package imports resolve (= are validated + loadable) at
/// handler-compile time, and alongside a manifest stamp so the sections
/// bake into the deployment. Owns everything it holds — `deinit` frees.
pub const Resolution = struct {
    packages: []Package = &.{},
    app_imports: []ImportEntry = &.{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Resolution) void {
        for (self.packages) |p| freePackage(self.allocator, p);
        self.allocator.free(self.packages);
        for (self.app_imports) |ie| self.allocator.free(ie.specifier);
        self.allocator.free(self.app_imports);
        self.* = undefined;
    }
};

/// Decode a `{packages?, app_imports?}` JSON object (the resolution
/// side-channel of the deploy wire). Absent sections decode empty.
pub fn decodeResolution(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!Resolution {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return Error.InvalidManifest;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return Error.InvalidManifest,
    };

    const packages = if (obj.get("packages")) |pv|
        try parsePackages(allocator, pv)
    else
        allocator.alloc(Package, 0) catch return Error.OutOfMemory;
    errdefer {
        for (packages) |p| freePackage(allocator, p);
        allocator.free(packages);
    }

    const app_imports = if (obj.get("app_imports")) |av|
        try parseImportMap(allocator, av)
    else
        allocator.alloc(ImportEntry, 0) catch return Error.OutOfMemory;

    return .{ .packages = packages, .app_imports = app_imports, .allocator = allocator };
}

fn freePackage(allocator: std.mem.Allocator, p: Package) void {
    allocator.free(p.spec);
    allocator.free(p.version);
    for (p.files) |f| allocator.free(f.path);
    allocator.free(p.files);
    for (p.imports) |ie| allocator.free(ie.specifier);
    allocator.free(p.imports);
    for (p.capabilities) |cap| allocator.free(cap);
    allocator.free(p.capabilities);
}

fn dupeStr(allocator: std.mem.Allocator, val: ?std.json.Value) Error![]const u8 {
    const s = switch (val orelse return Error.InvalidManifest) {
        .string => |x| x,
        else => return Error.InvalidManifest,
    };
    return allocator.dupe(u8, s) catch return Error.OutOfMemory;
}

fn hex64(val: ?std.json.Value) Error![root.HASH_HEX_LEN]u8 {
    const s = switch (val orelse return Error.InvalidManifest) {
        .string => |x| x,
        else => return Error.InvalidManifest,
    };
    if (s.len != root.HASH_HEX_LEN) return Error.InvalidManifest;
    var out: [root.HASH_HEX_LEN]u8 = undefined;
    @memcpy(&out, s[0..root.HASH_HEX_LEN]);
    return out;
}

/// Parse a `{ specifier: pkg_hash }` object into `[]ImportEntry` (used
/// for a package's `imports` and the deployment's `app_imports`).
fn parseImportMap(allocator: std.mem.Allocator, val: std.json.Value) Error![]ImportEntry {
    const obj = switch (val) {
        .object => |o| o,
        else => return Error.InvalidManifest,
    };
    var list: std.ArrayList(ImportEntry) = .empty;
    errdefer {
        for (list.items) |ie| allocator.free(ie.specifier);
        list.deinit(allocator);
    }
    var it = obj.iterator();
    while (it.next()) |kv| {
        const hash = try hex64(kv.value_ptr.*);
        const spec = allocator.dupe(u8, kv.key_ptr.*) catch return Error.OutOfMemory;
        errdefer allocator.free(spec);
        list.append(allocator, .{ .specifier = spec, .pkg_hash_hex = hash }) catch return Error.OutOfMemory;
    }
    return list.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

fn parseFiles(allocator: std.mem.Allocator, val: ?std.json.Value) Error![]PkgFile {
    const arr = switch (val orelse return Error.InvalidManifest) {
        .array => |a| a,
        else => return Error.InvalidManifest,
    };
    var list: std.ArrayList(PkgFile) = .empty;
    errdefer {
        for (list.items) |f| allocator.free(f.path);
        list.deinit(allocator);
    }
    for (arr.items) |item| {
        const o = switch (item) {
            .object => |x| x,
            else => return Error.InvalidManifest,
        };
        const bc = try hex64(o.get("bytecode_hash"));
        const src = try hex64(o.get("source_hash"));
        const path = try dupeStr(allocator, o.get("path"));
        errdefer allocator.free(path);
        list.append(allocator, .{ .path = path, .bytecode_hex = bc, .source_hex = src }) catch
            return Error.OutOfMemory;
    }
    return list.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

fn parseCapabilities(allocator: std.mem.Allocator, val: ?std.json.Value) Error![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |c| allocator.free(c);
        list.deinit(allocator);
    }
    if (val) |v| {
        const arr = switch (v) {
            .array => |a| a,
            else => return Error.InvalidManifest,
        };
        for (arr.items) |item| {
            const s = switch (item) {
                .string => |x| x,
                else => return Error.InvalidManifest,
            };
            const c = allocator.dupe(u8, s) catch return Error.OutOfMemory;
            errdefer allocator.free(c);
            list.append(allocator, c) catch return Error.OutOfMemory;
        }
    }
    return list.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

fn parsePackages(allocator: std.mem.Allocator, val: std.json.Value) Error![]Package {
    const arr = switch (val) {
        .array => |a| a,
        else => return Error.InvalidManifest,
    };
    var list: std.ArrayList(Package) = .empty;
    errdefer {
        for (list.items) |p| freePackage(allocator, p);
        list.deinit(allocator);
    }
    for (arr.items) |item| {
        const o = switch (item) {
            .object => |x| x,
            else => return Error.InvalidManifest,
        };
        const pkg_hash = try hex64(o.get("pkg_hash"));
        var private = false;
        if (o.get("private")) |pv| switch (pv) {
            .bool => |b| private = b,
            else => {},
        };
        const spec = try dupeStr(allocator, o.get("spec"));
        errdefer allocator.free(spec);
        const version = try dupeStr(allocator, o.get("version"));
        errdefer allocator.free(version);
        const files = try parseFiles(allocator, o.get("files"));
        errdefer {
            for (files) |f| allocator.free(f.path);
            allocator.free(files);
        }
        const imports = try parseImportMap(allocator, o.get("imports") orelse return Error.InvalidManifest);
        errdefer {
            for (imports) |ie| allocator.free(ie.specifier);
            allocator.free(imports);
        }
        const caps = try parseCapabilities(allocator, o.get("capabilities"));
        errdefer {
            for (caps) |c| allocator.free(c);
            allocator.free(caps);
        }
        list.append(allocator, .{
            .spec = spec,
            .version = version,
            .pkg_hash_hex = pkg_hash,
            .files = files,
            .imports = imports,
            .capabilities = caps,
            .private = private,
        }) catch return Error.OutOfMemory;
    }
    return list.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |b| {
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                try w.print("\\u{x:0>4}", .{b});
            },
            else => try w.writeByte(b),
        }
    }
    try w.writeByte('"');
}

/// `{dep_id:020d}.json` — the canonical key under each tenant's
/// `deployments/` BlobBackend prefix. With content-addressed dep_ids
/// (truncated sha-256, see `computeDeploymentId` below), the
/// lexicographic order is content-bound rather than chronological;
/// chronology lives in the per-tenant release history side table.
/// Where a deployment's manifest lives: `e{bc}/{dep_id}.json`.
///
/// The engine segment is what makes dropping bytecode from `dep_id` safe. Two
/// engine builds compiling one source tree now agree on the `dep_id` — that is
/// the point — so without it they would write DIFFERENT manifests, naming
/// different bytecode hashes, to one key. A rolling deploy spanning an engine
/// bump is exactly that situation, and the loser's nodes would fetch bytecode
/// their engine cannot read.
///
/// Grouping by engine rather than suffixing it also makes a superseded build's
/// artifacts a prefix, which is what a future sweep wants (decisions.md §11.7
/// records the GC as an accepted cost).
pub fn manifestKey(buf: *[MANIFEST_KEY_MAX]u8, bc_version: u8, dep_id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "e{d:0>3}/{d:0>20}.json", .{ bc_version, dep_id }) catch unreachable;
}

/// `e000/` + 20 digits + `.json`.
pub const MANIFEST_KEY_MAX: usize = 5 + 20 + 5;

/// Largest item count the canonical `computeDeploymentId` ordering accepts,
/// applied to each of the three lists it sorts (entries, packages, app
/// imports). The limit lives beside the sort rather than at each caller
/// because exceeding it is *unsound*, not merely invalid: the sort indexes
/// fixed buffers, so a caller that forgot the check would write past them in
/// a build where `assert` compiles out. `computeDeploymentId` therefore fails
/// closed on its own inputs and no caller can forget.
pub const MAX_CANONICAL_ITEMS: usize = 256;

/// Compute a deploy id from the manifest's entry list.
///
/// dep_id is sha-256 of a canonical encoding of the entries
/// list, truncated to 64 bits. Same content → same id automatically;
/// re-deploys of identical bytes are no-ops at the storage level (PUT
/// to the same S3 key with identical bytes). Different content → new
/// id, no overwrites, no ambiguity for the worker's reload path.
///
/// Truncation to 64 bits keeps the wire format unchanged (still 20
/// hex chars in the manifest key, 16 in `_deploy/current`). Per-
/// tenant birthday-paradox collision risk for 1B deploys ≈ 5e-2 —
/// not zero but well below the engineering cost of widening every
/// dep_id field to a string. Cross-tenant collisions don't matter
/// (the namespace is per-tenant).
///
/// Canonical encoding: entries sorted by path; each entry encoded as
/// `path|kind|content_type|hash|bytecode_hash` (NUL-separated). NOT
/// the JSON wire format — JSON ordering is not load-bearing in the
/// wire format (decoder accepts any order), so two manifests with
/// the same content but different encode-order would otherwise hash
/// to different ids.
pub fn computeDeploymentId(
    entries: []const root.Entry,
    packages: []const Package,
    app_imports: []const ImportEntry,
) Error!u64 {
    if (entries.len > MAX_CANONICAL_ITEMS or
        packages.len > MAX_CANONICAL_ITEMS or
        app_imports.len > MAX_CANONICAL_ITEMS) return Error.InvalidManifest;

    var sorted_indices: [MAX_CANONICAL_ITEMS]usize = undefined;
    const n = entries.len;
    for (0..n) |i| sorted_indices[i] = i;
    const idx_slice = sorted_indices[0..n];
    std.mem.sort(usize, idx_slice, entries, struct {
        fn lt(ctx: []const root.Entry, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, ctx[a].path, ctx[b].path);
        }
    }.lt);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (idx_slice) |i| {
        const e = entries[i];
        hasher.update(e.path);
        hasher.update(&.{0});
        hasher.update(if (e.kind == .handler) "handler" else "static");
        hasher.update(&.{0});
        hasher.update(e.content_type);
        hasher.update(&.{0});
        hasher.update(&e.source_hex);
        hasher.update(&.{0});
        // Bytecode is DELIBERATELY absent. It is a derived artifact keyed by
        // engine build — `JS_ReadObject` rejects a payload written by a
        // different `BC_VERSION` — so hashing it made a deployment's identity
        // move when the engine moved, with the source unchanged. `dep_id` is
        // source identity; the compile lives under `manifestKey`'s engine
        // segment (decisions.md §11.7).
    }

    // `pkg_hash` is the package's content identity (over its files +
    // imports), so hashing (spec, version, pkg_hash) captures each package
    // version fully — no nested sort. Skipped entirely when there are no
    // packages (cheap common case).
    if (packages.len > 0 or app_imports.len > 0) {
        var pkg_idx: [MAX_CANONICAL_ITEMS]usize = undefined;
        for (0..packages.len) |i| pkg_idx[i] = i;
        const pkg_slice = pkg_idx[0..packages.len];
        std.mem.sort(usize, pkg_slice, packages, struct {
            fn lt(ctx: []const Package, a: usize, b: usize) bool {
                const c = std.mem.order(u8, ctx[a].spec, ctx[b].spec);
                if (c != .eq) return c == .lt;
                const cv = std.mem.order(u8, ctx[a].version, ctx[b].version);
                if (cv != .eq) return cv == .lt;
                return std.mem.lessThan(u8, &ctx[a].pkg_hash_hex, &ctx[b].pkg_hash_hex);
            }
        }.lt);
        for (pkg_slice) |i| {
            const p = packages[i];
            hasher.update(p.spec);
            hasher.update(&.{0});
            hasher.update(p.version);
            hasher.update(&.{0});
            hasher.update(&p.pkg_hash_hex);
            hasher.update(&.{0});
        }

        var ai_idx: [MAX_CANONICAL_ITEMS]usize = undefined;
        for (0..app_imports.len) |i| ai_idx[i] = i;
        const ai_slice = ai_idx[0..app_imports.len];
        std.mem.sort(usize, ai_slice, app_imports, struct {
            fn lt(ctx: []const ImportEntry, a: usize, b: usize) bool {
                return std.mem.lessThan(u8, ctx[a].specifier, ctx[b].specifier);
            }
        }.lt);
        for (ai_slice) |i| {
            hasher.update(app_imports[i].specifier);
            hasher.update(&.{0});
            hasher.update(&app_imports[i].pkg_hash_hex);
            hasher.update(&.{0});
        }
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    // First 8 bytes, big-endian → u64.
    return std.mem.readInt(u64, digest[0..8], .big);
}

const testing = std.testing;

test "encode + decode round-trip" {
    var entries = [_]root.Entry{
        .{
            .path = @constCast("index.mjs"),
            .kind = .handler,
            .content_type = @constCast(""),
            .source_hex = @splat('a'),
            .bytecode_hex = @splat('b'),
        },
        .{
            .path = @constCast("_static/x.html"),
            .kind = .static,
            .content_type = @constCast("text/html; charset=utf-8"),
            .source_hex = @splat('c'),
            .bytecode_hex = @splat(0),
        },
    };

    const bytes = try encode(testing.allocator, 7, &entries, &.{}, &.{});
    defer testing.allocator.free(bytes);

    var m = try decode(testing.allocator, bytes);
    defer m.deinit();

    try testing.expectEqual(@as(u64, 7), m.id);
    try testing.expectEqual(@as(usize, 2), m.entries.len);
    try testing.expectEqualStrings("index.mjs", m.entries[0].path);
    try testing.expectEqual(root.Kind.handler, m.entries[0].kind);
    try testing.expectEqualSlices(u8, &@as([root.HASH_HEX_LEN]u8, @splat('a')), &m.entries[0].source_hex);
    try testing.expectEqualSlices(u8, &@as([root.HASH_HEX_LEN]u8, @splat('b')), &m.entries[0].bytecode_hex);
    try testing.expectEqualStrings("_static/x.html", m.entries[1].path);
    try testing.expectEqual(root.Kind.static, m.entries[1].kind);
    try testing.expectEqualStrings("text/html; charset=utf-8", m.entries[1].content_type);
}

test "decode rejects wrong version" {
    const bytes = "{\"v\":99,\"deployment_id\":\"0000000000000001\",\"entries\":[]}";
    try testing.expectError(Error.InvalidManifest, decode(testing.allocator, bytes));
}

test "decode rejects missing bytecode_hash on handler" {
    const bytes = "{\"v\":2,\"deployment_id\":\"0000000000000001\",\"entries\":[" ++
        "{\"path\":\"x.mjs\",\"kind\":\"handler\",\"content_type\":\"\"," ++
        "\"hash\":\"" ++ ("a" ** 64) ++ "\"}]}";
    try testing.expectError(Error.InvalidManifest, decode(testing.allocator, bytes));
}

test "decode allows missing bytecode_hash on static" {
    const bytes = "{\"v\":2,\"deployment_id\":\"0000000000000001\",\"entries\":[" ++
        "{\"path\":\"_static/x.html\",\"kind\":\"static\",\"content_type\":\"text/html\"," ++
        "\"hash\":\"" ++ ("c" ** 64) ++ "\"}]}";
    var m = try decode(testing.allocator, bytes);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 1), m.entries.len);
    try testing.expectEqual(root.Kind.static, m.entries[0].kind);
}

test "manifestKey produces zero-padded {N:020d}.json" {
    var buf: [MANIFEST_KEY_MAX]u8 = undefined;
    // The engine segment is part of the key, not decoration: two builds
    // compiling one source tree now agree on the dep_id, so without it they
    // would write different manifests to the same object.
    try testing.expectEqualStrings("e025/00000000000000000001.json", manifestKey(&buf, 25, 1));
    try testing.expectEqualStrings("e027/00000000000000004242.json", manifestKey(&buf, 27, 4242));
    // One dep_id, two engines, two keys — the property the whole split rests on.
    var buf2: [MANIFEST_KEY_MAX]u8 = undefined;
    try testing.expect(!std.mem.eql(u8, manifestKey(&buf, 25, 7), manifestKey(&buf2, 27, 7)));
}

test "computeDeploymentId: same entries → same id (idempotent)" {
    var entries = [_]root.Entry{
        .{
            .path = @constCast("index.mjs"),
            .kind = .handler,
            .content_type = @constCast(""),
            .source_hex = @splat('a'),
            .bytecode_hex = @splat('b'),
        },
        .{
            .path = @constCast("_static/x.html"),
            .kind = .static,
            .content_type = @constCast("text/html"),
            .source_hex = @splat('c'),
            .bytecode_hex = @splat(0),
        },
    };
    const id_a = try computeDeploymentId(&entries, &.{}, &.{});
    const id_b = try computeDeploymentId(&entries, &.{}, &.{});
    try testing.expectEqual(id_a, id_b);
}

test "computeDeploymentId: entry order doesn't matter (sorts by path)" {
    var entries_a = [_]root.Entry{
        .{
            .path = @constCast("a.mjs"), .kind = .handler,
            .content_type = @constCast(""),
            .source_hex = @splat('1'), .bytecode_hex = @splat('2'),
        },
        .{
            .path = @constCast("b.mjs"), .kind = .handler,
            .content_type = @constCast(""),
            .source_hex = @splat('3'), .bytecode_hex = @splat('4'),
        },
    };
    var entries_b = [_]root.Entry{
        .{
            .path = @constCast("b.mjs"), .kind = .handler,
            .content_type = @constCast(""),
            .source_hex = @splat('3'), .bytecode_hex = @splat('4'),
        },
        .{
            .path = @constCast("a.mjs"), .kind = .handler,
            .content_type = @constCast(""),
            .source_hex = @splat('1'), .bytecode_hex = @splat('2'),
        },
    };
    try testing.expectEqual(
        try computeDeploymentId(&entries_a, &.{}, &.{}),
        try computeDeploymentId(&entries_b, &.{}, &.{}),
    );
}

test "computeDeploymentId: bytecode does NOT change the id, source does" {
    // The inversion decisions.md §11.7 makes. This test used to assert the
    // opposite — that different bytecode yielded a different id — which is
    // exactly the coupling that made a deployment's identity move when the
    // engine moved with the source unchanged.
    var entries_a = [_]root.Entry{.{
        .path = @constCast("index.mjs"), .kind = .handler,
        .content_type = @constCast(""),
        .source_hex = @splat('a'), .bytecode_hex = @splat('b'),
    }};
    var entries_b = [_]root.Entry{.{
        .path = @constCast("index.mjs"), .kind = .handler,
        .content_type = @constCast(""),
        .source_hex = @splat('a'), .bytecode_hex = @splat('c'), // recompiled
    }};
    try testing.expectEqual(
        try computeDeploymentId(&entries_a, &.{}, &.{}),
        try computeDeploymentId(&entries_b, &.{}, &.{}),
    );

    // …and source still does, or the id would identify nothing.
    var entries_c = [_]root.Entry{.{
        .path = @constCast("index.mjs"), .kind = .handler,
        .content_type = @constCast(""),
        .source_hex = @splat('z'), .bytecode_hex = @splat('b'),
    }};
    try testing.expect(
        try computeDeploymentId(&entries_a, &.{}, &.{}) != try computeDeploymentId(&entries_c, &.{}, &.{}),
    );
}

test "computeDeploymentId: empty entries is stable" {
    const empty: []const root.Entry = &.{};
    const id_a = try computeDeploymentId(empty, &.{}, &.{});
    const id_b = try computeDeploymentId(empty, &.{}, &.{});
    try testing.expectEqual(id_a, id_b);
}

test "computeDeploymentId: over-long lists are rejected, not written past the sort buffer" {
    // The counts below are client-supplied in production (the `resolution`
    // a deploy carries), so exceeding the canonical ordering's capacity has
    // to be a refusal. It used to be `std.debug.assert`, which a ReleaseFast
    // build compiles out — leaving an out-of-bounds write into the sort's
    // fixed index buffer.
    const over = MAX_CANONICAL_ITEMS + 1;

    const pkgs = try testing.allocator.alloc(Package, over);
    defer testing.allocator.free(pkgs);
    for (pkgs) |*pk| pk.* = .{
        .spec = "@x/y",
        .version = "1.0.0",
        .pkg_hash_hex = @splat('a'),
        .files = &.{},
        .imports = &.{},
        .capabilities = &.{},
        .private = false,
    };
    try testing.expectError(Error.InvalidManifest, computeDeploymentId(&.{}, pkgs, &.{}));

    const imports = try testing.allocator.alloc(ImportEntry, over);
    defer testing.allocator.free(imports);
    for (imports) |*ie| ie.* = .{ .specifier = "@x/y", .pkg_hash_hex = @splat('a') };
    try testing.expectError(Error.InvalidManifest, computeDeploymentId(&.{}, &.{}, imports));

    const entries = try testing.allocator.alloc(root.Entry, over);
    defer testing.allocator.free(entries);
    for (entries) |*e| e.* = .{
        .path = "index.mjs",
        .kind = .handler,
        .content_type = "",
        .source_hex = @splat('a'),
        .bytecode_hex = @splat('b'),
    };
    try testing.expectError(Error.InvalidManifest, computeDeploymentId(entries, &.{}, &.{}));
}

// ── package manager: manifest v2 ───────────────────────────────────

fn findPkg(m: Manifest, spec: []const u8) ?Package {
    for (m.packages) |p| if (std.mem.eql(u8, p.spec, spec)) return p;
    return null;
}

test "v2: encode+decode round-trip with packages + app_imports" {
    var entries = [_]root.Entry{.{
        .path = @constCast("index.mjs"), .kind = .handler,
        .content_type = @constCast(""),
        .source_hex = @splat('a'), .bytecode_hex = @splat('b'),
    }};
    var oidc_files = [_]PkgFile{
        .{ .path = @constCast("index.mjs"), .bytecode_hex = @splat('1'), .source_hex = @splat('2') },
        .{ .path = @constCast("lib/token.mjs"), .bytecode_hex = @splat('3'), .source_hex = @splat('4') },
    };
    var oidc_imports = [_]ImportEntry{
        .{ .specifier = @constCast("@rewind/jwt"), .pkg_hash_hex = @splat('J') },
    };
    var oidc_caps = [_][]const u8{ @constCast("kv"), @constCast("crypto") };
    var jwt_files = [_]PkgFile{
        .{ .path = @constCast("index.mjs"), .bytecode_hex = @splat('5'), .source_hex = @splat('6') },
    };
    var packages = [_]Package{
        .{ .spec = @constCast("@rewind/oidc"), .version = @constCast("2.3.1"), .pkg_hash_hex = @splat('O'), .files = &oidc_files, .imports = &oidc_imports, .capabilities = &oidc_caps, .private = false },
        .{ .spec = @constCast("@rewind/jwt"), .version = @constCast("1.4.0"), .pkg_hash_hex = @splat('J'), .files = &jwt_files, .imports = &.{}, .capabilities = &.{}, .private = true },
    };
    var app_imports = [_]ImportEntry{
        .{ .specifier = @constCast("@rewind/oidc"), .pkg_hash_hex = @splat('O') },
    };

    const bytes = try encode(testing.allocator, 42, &entries, &packages, &app_imports);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"v\":2") != null);

    var m = try decode(testing.allocator, bytes);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 1), m.entries.len);
    try testing.expectEqual(@as(usize, 2), m.packages.len);
    try testing.expectEqual(@as(usize, 1), m.app_imports.len);

    const oidc = findPkg(m, "@rewind/oidc") orelse return error.MissingPackage;
    try testing.expectEqualStrings("2.3.1", oidc.version);
    try testing.expectEqualSlices(u8, &@as([root.HASH_HEX_LEN]u8, @splat('O')), &oidc.pkg_hash_hex);
    try testing.expectEqual(@as(usize, 2), oidc.files.len);
    try testing.expectEqualStrings("index.mjs", oidc.files[0].path);
    try testing.expectEqualStrings("lib/token.mjs", oidc.files[1].path);
    try testing.expectEqual(@as(usize, 1), oidc.imports.len);
    try testing.expectEqualStrings("@rewind/jwt", oidc.imports[0].specifier);
    try testing.expectEqualSlices(u8, &@as([root.HASH_HEX_LEN]u8, @splat('J')), &oidc.imports[0].pkg_hash_hex);
    try testing.expectEqual(@as(usize, 2), oidc.capabilities.len);
    try testing.expectEqual(false, oidc.private);

    const jwt = findPkg(m, "@rewind/jwt") orelse return error.MissingPackage;
    try testing.expectEqual(true, jwt.private);
    try testing.expectEqual(@as(usize, 0), jwt.imports.len);
    try testing.expectEqual(@as(usize, 0), jwt.capabilities.len);

    try testing.expectEqualStrings("@rewind/oidc", m.app_imports[0].specifier);
    try testing.expectEqualSlices(u8, &@as([root.HASH_HEX_LEN]u8, @splat('O')), &m.app_imports[0].pkg_hash_hex);
}

test "v2: decode rejects v1 (no back-compat — complete redeploy)" {
    const bytes = "{\"v\":1,\"deployment_id\":\"0000000000000001\",\"entries\":[]}";
    try testing.expectError(Error.InvalidManifest, decode(testing.allocator, bytes));
}

test "v2: a package-less deploy has no packages/app_imports sections" {
    var entries = [_]root.Entry{.{
        .path = @constCast("index.mjs"), .kind = .handler,
        .content_type = @constCast(""),
        .source_hex = @splat('a'), .bytecode_hex = @splat('b'),
    }};
    const id_no_pkg = try computeDeploymentId(&entries, &.{}, &.{});

    const bytes = try encode(testing.allocator, id_no_pkg, &entries, &.{}, &.{});
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"v\":2") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "packages") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "app_imports") == null);

    // Adding a package must change the dep_id (content-addressed).
    var files = [_]PkgFile{.{ .path = @constCast("index.mjs"), .bytecode_hex = @splat('1'), .source_hex = @splat('2') }};
    var pkgs = [_]Package{.{ .spec = @constCast("@rewind/jwt"), .version = @constCast("1.0.0"), .pkg_hash_hex = @splat('J'), .files = &files, .imports = &.{}, .capabilities = &.{}, .private = false }};
    const id_with_pkg = try computeDeploymentId(&entries, &pkgs, &.{});
    try testing.expect(id_no_pkg != id_with_pkg);
}

test "v2: rejects a package missing pkg_hash" {
    const bytes = "{\"v\":2,\"deployment_id\":\"0000000000000001\",\"entries\":[]," ++
        "\"packages\":[{\"spec\":\"@rewind/x\",\"version\":\"1.0.0\"," ++
        "\"files\":[],\"imports\":{}}]}";
    try testing.expectError(Error.InvalidManifest, decode(testing.allocator, bytes));
}
