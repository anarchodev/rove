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
//! Every request carries `Authorization: Bearer <jwt>`. The caller
//! supplies a `mint_jwt` callback at init time; HttpBlobStore
//! invokes it per fetch to get a fresh token. Keeps secret handling
//! and JWT crypto out of rove-blob (rove-jwt is application-level)
//! and means we don't have to manage token refresh windows here —
//! callers mint with whatever expiry they want; tokens that expire
//! between fetches are just re-minted on the next call.
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

/// Mint a fresh JWT (without the `Bearer ` prefix). HttpBlobStore
/// invokes this for each fetch and frees the result. Returning
/// `error.OutOfMemory` propagates as `Error.OutOfMemory`; any other
/// error surfaces as `Error.Io` since the caller has no token-mint
/// recovery path beyond "fail loud."
pub const MintJwtFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
) anyerror![]u8;

pub const HttpBlobStore = struct {
    allocator: std.mem.Allocator,
    /// libcurl handle. Owned when `easy_owned = true`; borrowed
    /// otherwise. Sharing one Easy across many `HttpBlobStore`s
    /// (via `Config.easy`) is the production posture: libcurl's
    /// internal connection + TLS-session cache is per-handle, so
    /// reusing one handle across all per-tenant manifest fetches
    /// on a worker keeps the connection warm. Threading: the
    /// handle is mutex-locked internally, so concurrent
    /// `request()` calls serialize at the curl level. Workers
    /// run their dispatch loop single-threaded, so this never
    /// contends inside one worker; cross-worker sharing would
    /// need pool semantics, which isn't a thing yet.
    easy: *curl.Easy,
    /// True when this HttpBlobStore created its own Easy in
    /// `init` and owns the lifetime; false when the caller
    /// supplied one via `Config.easy`. `deinit` skips the curl
    /// teardown in the borrowed case.
    easy_owned: bool,
    /// `https://host:port` (no trailing slash). Owned copy so the
    /// caller doesn't have to keep its source slice alive.
    base_url: []const u8,
    /// Tenant id. Owned copy. Inserted into every URL the backend
    /// builds.
    instance_id: []const u8,
    /// Per-fetch JWT minter. Borrowed; the caller keeps the
    /// underlying secret + closure alive for the backend's
    /// lifetime.
    mint_jwt: MintJwtFn,
    mint_ctx: ?*anyopaque,
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
        mint_jwt: MintJwtFn,
        mint_ctx: ?*anyopaque = null,
        /// Optional borrowed libcurl Easy handle. When non-null,
        /// the backend uses this instead of creating its own.
        /// Caller owns the lifetime — the backend's `deinit`
        /// does NOT close the handle. Sharing one Easy across
        /// every per-tenant `HttpBlobStore` on a worker is the
        /// production posture (see field doc above).
        easy: ?*curl.Easy = null,
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

        const ca_owned: ?[:0]const u8 = if (cfg.ca_bundle_path) |p|
            try allocator.dupeZ(u8, p)
        else
            null;
        errdefer if (ca_owned) |p| allocator.free(p);

        const easy_owned = cfg.easy == null;
        const easy = cfg.easy orelse try curl.Easy.init(allocator);
        errdefer if (easy_owned) easy.deinit();

        return .{
            .allocator = allocator,
            .easy = easy,
            .easy_owned = easy_owned,
            .base_url = base_url_owned,
            .instance_id = instance_id_owned,
            .mint_jwt = cfg.mint_jwt,
            .mint_ctx = cfg.mint_ctx,
            .ca_bundle_path = ca_owned,
            .verify_tls = cfg.verify_tls,
        };
    }

    pub fn deinit(self: *HttpBlobStore) void {
        if (self.easy_owned) self.easy.deinit();
        self.allocator.free(self.base_url);
        self.allocator.free(self.instance_id);
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

        // Mint per-fetch — tokens that expired between fetches just
        // get re-minted next call. Cost is one HMAC-SHA256, dominated
        // by the network roundtrip.
        const jwt = self.mint_jwt(self.mint_ctx, allocator) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.Io,
        };
        defer allocator.free(jwt);
        const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{jwt}) catch
            return Error.OutOfMemory;
        defer allocator.free(auth_header);

        const headers = [_]curl.Header{
            .{ .name = "Authorization", .value = auth_header },
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

/// One tenant's input to a batch manifest fetch — `(id, dep_id)`.
pub const BatchTenant = struct {
    id: []const u8,
    dep_id: u64,
};

/// One result row from a batch manifest fetch.
pub const BatchResult = struct {
    /// Owned. Caller frees via `BatchResult.deinit` or
    /// `freeBatchResults`.
    id: []u8,
    /// Owned. Null when the cluster store reported the manifest
    /// was missing for this `(id, dep_id)`. Caller treats null
    /// as `Error.NotFound` for that tenant + falls back to the
    /// existing per-tenant retry path.
    manifest: ?[]u8,

    pub fn deinit(self: *BatchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.manifest) |m| allocator.free(m);
        self.* = undefined;
    }
};

/// Free-the-whole-slice helper. Frees each `BatchResult`'s owned
/// allocations and the outer slice. Use this at the end of cold-
/// start prefetch.
pub fn freeBatchResults(allocator: std.mem.Allocator, rows: []BatchResult) void {
    for (rows) |*r| r.deinit(allocator);
    allocator.free(rows);
}

/// Issue one `POST /_system/manifests/batch` call against the
/// configured files-server. Returns one `BatchResult` per input
/// tenant, in the order the server emitted them (the server
/// always echoes ids in the response so callers can map without
/// preserving index order).
///
/// `mint_jwt` is invoked once per call; reuses the same Easy
/// curl handle across calls for connection-warmth.
///
/// Wire format defined in `files_server/thread.zig::handleManifestsBatch`.
pub fn fetchBatch(
    self: *HttpBlobStore,
    allocator: std.mem.Allocator,
    tenants: []const BatchTenant,
) Error![]BatchResult {
    if (tenants.len > std.math.maxInt(u32)) return Error.InvalidKey;

    // Build the request body.
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(allocator);

    var count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_buf, @intCast(tenants.len), .little);
    try req.appendSlice(allocator, &count_buf);

    for (tenants) |t| {
        if (t.id.len > std.math.maxInt(u16)) return Error.InvalidKey;
        var id_len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &id_len_buf, @intCast(t.id.len), .little);
        try req.appendSlice(allocator, &id_len_buf);
        try req.appendSlice(allocator, t.id);
        var dep_id_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &dep_id_buf, t.dep_id, .little);
        try req.appendSlice(allocator, &dep_id_buf);
    }

    const url = std.fmt.allocPrint(allocator, "{s}/_system/manifests/batch", .{self.base_url}) catch
        return Error.OutOfMemory;
    defer allocator.free(url);

    const jwt = self.mint_jwt(self.mint_ctx, allocator) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.Io,
    };
    defer allocator.free(jwt);
    const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{jwt}) catch
        return Error.OutOfMemory;
    defer allocator.free(auth_header);

    const headers = [_]curl.Header{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/octet-stream" },
    };

    var resp = self.easy.request(allocator, .{
        .method = .POST,
        .url = url,
        .headers = &headers,
        .body = req.items,
        .verify_tls = self.verify_tls,
        // Cold-start prefetch can take a while at 10k tenants —
        // give it generous headroom (~1ms per tenant cluster
        // store get + protocol overhead). 60s = comfortable.
        .timeout_ms = 60_000,
    }) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.Io,
    };
    defer resp.deinit(allocator);

    if (resp.status != 200) return Error.Io;
    const body = resp.body orelse return Error.Io;

    return parseBatchResponse(allocator, body) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.Io,
    };
}

const ParseError = error{ Truncated, OutOfMemory };

fn parseBatchResponse(allocator: std.mem.Allocator, body: []const u8) ParseError![]BatchResult {
    if (body.len < 4) return ParseError.Truncated;
    const count = std.mem.readInt(u32, body[0..4], .little);
    if (count > 1_000_000) return ParseError.Truncated;

    const out = try allocator.alloc(BatchResult, count);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |*r| r.deinit(allocator);
        allocator.free(out);
    }

    var pos: usize = 4;
    while (filled < count) : (filled += 1) {
        if (body.len < pos + 2) return ParseError.Truncated;
        const id_len = std.mem.readInt(u16, body[pos..][0..2], .little);
        pos += 2;
        if (body.len < pos + id_len + 4) return ParseError.Truncated;
        const id_owned = try allocator.dupe(u8, body[pos .. pos + id_len]);
        pos += id_len;
        const mf_len = std.mem.readInt(u32, body[pos..][0..4], .little);
        pos += 4;
        if (body.len < pos + mf_len) {
            allocator.free(id_owned);
            return ParseError.Truncated;
        }
        const manifest_owned: ?[]u8 = if (mf_len == 0) null else try allocator.dupe(u8, body[pos .. pos + mf_len]);
        pos += mf_len;

        out[filled] = .{ .id = id_owned, .manifest = manifest_owned };
    }
    return out;
}

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

fn fakeMint(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    return allocator.dupe(u8, "fake.jwt.token");
}

test "HttpBlobStore: init + deinit (no I/O, no curl call)" {
    var be = try HttpBlobStore.init(testing.allocator, .{
        .base_url = "https://files.loop46.localhost:9090",
        .instance_id = "acme",
        .mint_jwt = fakeMint,
        .ca_bundle_path = null,
        .verify_tls = false,
    });
    defer be.deinit();
    try testing.expectEqualStrings("acme", be.instance_id);
    try testing.expectEqualStrings("https://files.loop46.localhost:9090", be.base_url);
    _ = be.blobStore();
}

test "parseBatchResponse: round-trips count + id + manifest" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, 2, .little);
    try buf.appendSlice(testing.allocator, &hdr);

    // Entry 0: id="acme", manifest="HELLO"
    var u16_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &u16_buf, 4, .little);
    try buf.appendSlice(testing.allocator, &u16_buf);
    try buf.appendSlice(testing.allocator, "acme");
    var u32_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &u32_buf, 5, .little);
    try buf.appendSlice(testing.allocator, &u32_buf);
    try buf.appendSlice(testing.allocator, "HELLO");

    // Entry 1: id="missing", manifest absent (mf_len=0)
    std.mem.writeInt(u16, &u16_buf, 7, .little);
    try buf.appendSlice(testing.allocator, &u16_buf);
    try buf.appendSlice(testing.allocator, "missing");
    std.mem.writeInt(u32, &u32_buf, 0, .little);
    try buf.appendSlice(testing.allocator, &u32_buf);

    const rows = try parseBatchResponse(testing.allocator, buf.items);
    defer freeBatchResults(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("acme", rows[0].id);
    try testing.expectEqualStrings("HELLO", rows[0].manifest.?);
    try testing.expectEqualStrings("missing", rows[1].id);
    try testing.expect(rows[1].manifest == null);
}

test "parseBatchResponse: rejects truncated body" {
    const body = [_]u8{ 0x05, 0, 0, 0, 0x03, 0 }; // count=5, then truncated
    try testing.expectError(error.Truncated, parseBatchResponse(testing.allocator, &body));
}

test "HttpBlobStore: writes return NotImplemented" {
    var be = try HttpBlobStore.init(testing.allocator, .{
        .base_url = "https://x",
        .instance_id = "t",
        .mint_jwt = fakeMint,
        .verify_tls = false,
    });
    defer be.deinit();
    const bs = be.blobStore();
    try testing.expectError(error.NotImplemented, bs.put("k", "v"));
    try testing.expectError(error.NotImplemented, bs.exists("k"));
    try testing.expectError(error.NotImplemented, bs.delete("k"));
}
