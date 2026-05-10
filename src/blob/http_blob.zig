//! `HttpBlobStore` — read-only `BlobStore` that fetches manifests
//! from a files-server cluster over HTTP/2. Production.md #1.4 step
//! 4: loop46 worker swaps S3-direct manifest reads for queries
//! against the colocated files-server, where manifests live in
//! raft-replicated KV.
//!
//! ## URL shape
//!
//! Keys follow `manifest_json.manifestKey` — `{N:020d}.json` — so
//! the backend extracts the leading 20 decimal digits as `dep_id`,
//! reformats as hex, and hits:
//!
//!   `{base_url}/{instance_id}/deployments/{N:hex}/manifest.bin`
//!
//! Returns the raw bytes the server stored at
//! `deployment/{N:020x}/manifest` in the cluster store. Same bytes
//! `manifest_json.decode` would have parsed off S3 in the legacy
//! path.
//!
//! ## What's NOT supported
//!
//! Writes (`put` / `delete`) and existence checks (`exists`) all
//! return `error.NotImplemented`. The cluster owns manifest writes
//! end-to-end via raft — clients propose at the leader, never PUT
//! directly. Loop46 worker only ever calls `get`; the unimplemented
//! methods exist only to satisfy the `BlobStore` vtable.
//!
//! ## Auth
//!
//! Every request carries `Authorization: Bearer <jwt>`. The token
//! is supplied at init time and cached in the
//! pre-built `auth_header` string so the hot path doesn't re-format
//! per request. Loop46 worker mints these via the same shared HMAC
//! it hands the dashboard / CLI.
//!
//! ## TLS
//!
//! Production: `verify_tls = true`, system CA bundle. Smokes /
//! dev: `verify_tls = false` against the colocated files-server's
//! self-signed cert. The libcurl wrapper handles both.
//!
//! ## Threading
//!
//! `curl.Easy` is single-handle, mutex-protected internally. One
//! `HttpBlobStore` per tenant is wasteful but bounded; sharing a
//! single Easy across all tenants is the right optimization once
//! we measure contention. Today loop46 reads manifests rarely
//! (cold-start + each release POST), so a per-tenant handle is
//! fine.

const std = @import("std");
const root = @import("root.zig");
const curl = @import("curl.zig");

const Error = root.Error;

pub const HttpBlobStore = struct {
    allocator: std.mem.Allocator,
    /// Owned. One `Easy` (libcurl handle) per `HttpBlobStore` —
    /// see threading note above.
    easy: *curl.Easy,
    /// `https://host:port` (no trailing slash). Owned copy so the
    /// caller doesn't have to keep its source slice alive.
    base_url: []const u8,
    /// Tenant id. Owned copy. Inserted into every URL the backend
    /// builds.
    instance_id: []const u8,
    /// Pre-built `Bearer <jwt>` header value. Owned. The `Bearer ` prefix
    /// is part of the value, not the name.
    auth_header_value: []const u8,
    /// Path to a CA bundle file (or null for system bundle). Owned
    /// copy when non-null. Smokes against the dev self-signed cert
    /// pass the on-disk `ca-root.pem`.
    ca_bundle_path: ?[:0]const u8,
    /// TLS peer verification. Production: true. Dev / smoke against
    /// self-signed: false. Mutually exclusive with relying on
    /// `ca_bundle_path` — when verify_tls is false libcurl skips
    /// the bundle entirely.
    verify_tls: bool,

    pub const Config = struct {
        base_url: []const u8,
        instance_id: []const u8,
        /// JWT, *without* the `Bearer ` prefix — the backend adds it.
        jwt: []const u8,
        /// Optional CA bundle path. Null = libcurl's default
        /// (system trust store on Linux).
        ca_bundle_path: ?[]const u8 = null,
        verify_tls: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !HttpBlobStore {
        const base_url_owned = try allocator.dupe(u8, cfg.base_url);
        errdefer allocator.free(base_url_owned);

        const instance_id_owned = try allocator.dupe(u8, cfg.instance_id);
        errdefer allocator.free(instance_id_owned);

        const auth_header_owned = try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.jwt});
        errdefer allocator.free(auth_header_owned);

        const ca_owned: ?[:0]const u8 = if (cfg.ca_bundle_path) |p|
            try allocator.dupeZ(u8, p)
        else
            null;
        errdefer if (ca_owned) |p| allocator.free(p);

        const easy = try curl.Easy.init(allocator);
        errdefer easy.deinit();

        return .{
            .allocator = allocator,
            .easy = easy,
            .base_url = base_url_owned,
            .instance_id = instance_id_owned,
            .auth_header_value = auth_header_owned,
            .ca_bundle_path = ca_owned,
            .verify_tls = cfg.verify_tls,
        };
    }

    pub fn deinit(self: *HttpBlobStore) void {
        self.easy.deinit();
        self.allocator.free(self.base_url);
        self.allocator.free(self.instance_id);
        self.allocator.free(self.auth_header_value);
        if (self.ca_bundle_path) |p| self.allocator.free(p);
        self.* = undefined;
    }

    pub fn blobStore(self: *HttpBlobStore) root.BlobStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = root.BlobStore.VTable{
        .put = vt_put,
        .get = vt_get,
        .exists = vt_exists,
        .delete = vt_delete,
    };

    fn vt_put(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
        return error.NotImplemented;
    }

    fn vt_exists(_: *anyopaque, _: []const u8) anyerror!bool {
        return error.NotImplemented;
    }

    fn vt_delete(_: *anyopaque, _: []const u8) anyerror!void {
        return error.NotImplemented;
    }

    fn vt_get(ptr: *anyopaque, key: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *HttpBlobStore = @ptrCast(@alignCast(ptr));
        return self.fetch(allocator, key);
    }

    /// Translate a `{N:020d}.json` manifest key into the
    /// `manifest.bin` URL and fetch. Non-200 maps to
    /// `Error.NotFound` (404) or `Error.Io` (anything else).
    fn fetch(self: *HttpBlobStore, allocator: std.mem.Allocator, key: []const u8) Error![]u8 {
        const dep_id = parseManifestKey(key) orelse return Error.InvalidKey;

        // {base_url} + "/" + {instance_id} + "/deployments/" + 16
        // hex max + "/manifest.bin" = bounded; allocate.
        const url = std.fmt.allocPrint(
            allocator,
            "{s}/{s}/deployments/{x}/manifest.bin",
            .{ self.base_url, self.instance_id, dep_id },
        ) catch return Error.OutOfMemory;
        defer allocator.free(url);

        const headers = [_]curl.Header{
            .{ .name = "Authorization", .value = self.auth_header_value },
        };

        var resp = self.easy.request(allocator, .{
            .method = .GET,
            .url = url,
            .headers = &headers,
            .verify_tls = self.verify_tls,
            // Manifest fetches are on the request hot path; default
            // 15 s is generous. Tighten to 5 s — a manifest is a
            // few KB, anything past 5 s is a stuck connection or
            // a wedged files-server, and we'd rather surface that
            // than block.
            .timeout_ms = 5_000,
        }) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.Io,
        };
        // The body is allocator-owned; we'll either keep it (200
        // path) or free it. Use `defer` keyed off a sentinel.
        var body_taken = false;
        defer if (!body_taken) resp.deinit(allocator);

        switch (resp.status) {
            200 => {
                const body = resp.body orelse return Error.Io;
                body_taken = true;
                return body;
            },
            404 => return Error.NotFound,
            else => return Error.Io,
        }
    }
};

/// Parse `{N:020d}.json` (the format `manifest_json.manifestKey`
/// produces) and return `N`. Returns null on shape mismatch.
fn parseManifestKey(key: []const u8) ?u64 {
    if (key.len != 25) return null;
    if (!std.mem.endsWith(u8, key, ".json")) return null;
    const digits = key[0..20];
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "parseManifestKey: zero-padded decimal" {
    try testing.expectEqual(@as(?u64, 1), parseManifestKey("00000000000000000001.json"));
    try testing.expectEqual(@as(?u64, 4242), parseManifestKey("00000000000000004242.json"));
    try testing.expectEqual(@as(?u64, 0), parseManifestKey("00000000000000000000.json"));
}

test "parseManifestKey: rejects malformed" {
    try testing.expectEqual(@as(?u64, null), parseManifestKey("short.json"));
    try testing.expectEqual(@as(?u64, null), parseManifestKey("00000000000000000001.txt"));
    try testing.expectEqual(@as(?u64, null), parseManifestKey("notanumber0000000000.json"));
    try testing.expectEqual(@as(?u64, null), parseManifestKey(""));
}

test "HttpBlobStore: init + deinit (no I/O, no curl call)" {
    var be = try HttpBlobStore.init(testing.allocator, .{
        .base_url = "https://files.loop46.localhost:9090",
        .instance_id = "acme",
        .jwt = "fake.jwt.token",
        .ca_bundle_path = null,
        .verify_tls = false,
    });
    defer be.deinit();
    try testing.expectEqualStrings("Bearer fake.jwt.token", be.auth_header_value);
    try testing.expectEqualStrings("acme", be.instance_id);
    try testing.expectEqualStrings("https://files.loop46.localhost:9090", be.base_url);
    _ = be.blobStore();
}

test "HttpBlobStore: writes return NotImplemented" {
    var be = try HttpBlobStore.init(testing.allocator, .{
        .base_url = "https://x",
        .instance_id = "t",
        .jwt = "j",
        .verify_tls = false,
    });
    defer be.deinit();
    const bs = be.blobStore();
    try testing.expectError(error.NotImplemented, bs.put("k", "v"));
    try testing.expectError(error.NotImplemented, bs.exists("k"));
    try testing.expectError(error.NotImplemented, bs.delete("k"));
}
