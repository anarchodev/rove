//! S3-compatible object-store backend for `rove-blob`.
//!
//! Implements the `BlobStore` vtable against any S3-compatible
//! HTTPS endpoint via path-style addressing. Tested target is OVH
//! Object Storage (`s3.{region}.io.cloud.ovh.net` for the
//! "high-performance" tier and `s3.{region}.cloud.ovh.net` for
//! standard) but the SigV4 wire format is identical across AWS,
//! MinIO, Cloudflare R2, Backblaze B2, etc.
//!
//! Path-style only in v1: `https://{endpoint}/{bucket}/{key}`. Most
//! S3 services accept both path-style and virtual-host-style; OVH
//! supports both. Path-style is the simpler default and avoids DNS
//! complications when bucket names contain dots (rare, but real).
//!
//! Concurrency: NOT thread-safe. Each `*S3BlobStore` owns one
//! `std.http.Client` reused across calls (so TLS handshake +
//! TCP connect happen once, not per-op — the smoke went from
//! ~500ms × 6 ops to one handshake + amortized request cost).
//! Multi-threaded callers should hold per-thread instances, the
//! same model the per-tenant SQLite handles use elsewhere in rove.
//!
//! What's deliberately NOT here:
//! - Multipart upload (single PUT only — capped at S3's 5 GiB
//!   per-object hard limit, which is well above any blob size we
//!   produce today).
//! - Server-side encryption headers (S3 SSE / SSE-KMS). Loop46's
//!   own page-encryption (PLAN Phase 9) handles this client-side;
//!   no need for S3-side enc on top.
//! - Listing operations. The blob store is keyed by hash; we never
//!   enumerate. Enumeration would also be expensive at scale.
//! - Retry logic. Caller (rove-files / rove-log apply) retries via
//!   the raft state machine — a failed blob fetch on one apply
//!   pass will retry on the next.

const std = @import("std");
const root = @import("root.zig");
const sigv4 = @import("sigv4.zig");

const Error = root.Error;

pub const Config = struct {
    /// Hostname of the S3 endpoint. NO scheme, NO trailing slash.
    /// Examples:
    ///   - OVH high-perf: `s3.gra.io.cloud.ovh.net`
    ///   - OVH standard:  `s3.gra.cloud.ovh.net`
    ///   - AWS:           `s3.us-east-1.amazonaws.com`
    ///   - MinIO local:   `localhost:9000`
    endpoint: []const u8,
    /// Region for the SigV4 signing scope. Must match the endpoint
    /// region — the signing key is bucket-region-bound.
    region: []const u8,
    /// Bucket name. Path-style: appears as the first URI segment.
    bucket: []const u8,
    /// Optional key prefix prepended to every operation. Lets one
    /// shared bucket host many tenants (each with its own prefix
    /// like `{instance_id}/file-blobs/`) without mutating
    /// `validateKey` to permit slashes inside the user-supplied
    /// hash. Empty = no prefix. The prefix may contain slashes
    /// (e.g. `{tenant}/file-blobs/`); the SigV4 path canonicalizer
    /// preserves them.
    key_prefix: []const u8 = "",
    /// AWS access key id.
    access_key: []const u8,
    /// AWS secret access key. Never sent on the wire.
    secret_key: []const u8,
    /// True for `https://`; false for `http://` (DEV ONLY — local
    /// MinIO smoke tests). Production must use TLS.
    use_tls: bool = true,
};

pub const S3BlobStore = struct {
    allocator: std.mem.Allocator,
    /// All `[]const u8` fields are allocator-duplicated copies. The
    /// caller's `Config` strings need only outlive the `init` call —
    /// the store is self-contained afterwards. This removes the
    /// lifetime trap that bites callers who build per-tenant configs
    /// from short-lived allocations (e.g. a per-request key prefix).
    config: Config,
    /// Shared HTTP client. One per S3BlobStore instance — keeps
    /// the TLS session + TCP connection alive across put/get/exists/
    /// delete so we don't pay handshake cost on every op. The Client
    /// struct itself is just a holder for the connection pool +
    /// allocator; the real cost (TCP connect + TLS handshake + CA
    /// bundle scan) is paid on first fetch.
    http: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, config: Config) !S3BlobStore {
        if (config.endpoint.len == 0) {
            std.log.warn("rove-blob s3.init: endpoint is empty", .{});
            return Error.Io;
        }
        if (config.bucket.len == 0) {
            std.log.warn("rove-blob s3.init: bucket is empty", .{});
            return Error.Io;
        }
        if (config.region.len == 0) {
            std.log.warn("rove-blob s3.init: region is empty", .{});
            return Error.Io;
        }
        if (config.access_key.len == 0) {
            std.log.warn("rove-blob s3.init: access_key is empty", .{});
            return Error.Io;
        }
        if (config.secret_key.len == 0) {
            std.log.warn("rove-blob s3.init: secret_key is empty", .{});
            return Error.Io;
        }
        // Endpoint should NOT include scheme — we add it from
        // `use_tls`. Strip leniently if the operator pasted a URL
        // (every OVH / AWS doc shows the endpoint with `https://`
        // prefix, so this is the most-frequent first-time mistake).
        var ep = config.endpoint;
        if (std.mem.startsWith(u8, ep, "https://")) {
            ep = ep["https://".len..];
        } else if (std.mem.startsWith(u8, ep, "http://")) {
            ep = ep["http://".len..];
        }
        // Strip trailing slash if present.
        if (ep.len > 0 and ep[ep.len - 1] == '/') ep = ep[0 .. ep.len - 1];
        if (ep.len == 0) {
            std.log.warn("rove-blob s3.init: endpoint resolved to empty after stripping scheme", .{});
            return Error.Io;
        }

        // Dupe every config string so callers don't have to track
        // lifetimes. Use errdefer in declaration order so a later
        // failure cleans up earlier dupes.
        const endpoint_owned = try allocator.dupe(u8, ep);
        errdefer allocator.free(endpoint_owned);
        const region_owned = try allocator.dupe(u8, config.region);
        errdefer allocator.free(region_owned);
        const bucket_owned = try allocator.dupe(u8, config.bucket);
        errdefer allocator.free(bucket_owned);
        const key_prefix_owned = try allocator.dupe(u8, config.key_prefix);
        errdefer allocator.free(key_prefix_owned);
        const access_key_owned = try allocator.dupe(u8, config.access_key);
        errdefer allocator.free(access_key_owned);
        const secret_key_owned = try allocator.dupe(u8, config.secret_key);
        errdefer allocator.free(secret_key_owned);

        return .{
            .allocator = allocator,
            .config = .{
                .endpoint = endpoint_owned,
                .region = region_owned,
                .bucket = bucket_owned,
                .key_prefix = key_prefix_owned,
                .access_key = access_key_owned,
                .secret_key = secret_key_owned,
                .use_tls = config.use_tls,
            },
            .http = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *S3BlobStore) void {
        self.http.deinit();
        self.allocator.free(self.config.endpoint);
        self.allocator.free(self.config.region);
        self.allocator.free(self.config.bucket);
        self.allocator.free(self.config.key_prefix);
        self.allocator.free(self.config.access_key);
        self.allocator.free(self.config.secret_key);
        self.* = undefined;
    }

    pub fn blobStore(self: *S3BlobStore) root.BlobStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ── vtable impls ───────────────────────────────────────────────────

    fn vPut(ptr: *anyopaque, key: []const u8, bytes: []const u8) anyerror!void {
        const self: *S3BlobStore = @ptrCast(@alignCast(ptr));
        const resp = try self.request(.PUT, key, bytes);
        defer if (resp.body_owned) |b| self.allocator.free(b);
        if (resp.status != 200 and resp.status != 201) {
            std.log.warn(
                "rove-blob s3: PUT {s}/{s} → status={d} body={s}",
                .{ self.config.bucket, key, resp.status, resp.bodySnippet() },
            );
            return Error.Io;
        }
    }

    fn vGet(
        ptr: *anyopaque,
        key: []const u8,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *S3BlobStore = @ptrCast(@alignCast(ptr));
        const resp = try self.requestAlloc(.GET, key, "", allocator);
        if (resp.status == 404) {
            if (resp.body_owned) |b| allocator.free(b);
            return Error.NotFound;
        }
        if (resp.status != 200) {
            std.log.warn(
                "rove-blob s3: GET {s}/{s} → status={d} body={s}",
                .{ self.config.bucket, key, resp.status, resp.bodySnippet() },
            );
            if (resp.body_owned) |b| allocator.free(b);
            return Error.Io;
        }
        return resp.body_owned orelse &.{};
    }

    fn vExists(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self: *S3BlobStore = @ptrCast(@alignCast(ptr));
        const resp = try self.request(.HEAD, key, "");
        defer if (resp.body_owned) |b| self.allocator.free(b);
        if (resp.status == 200) return true;
        if (resp.status == 404) return false;
        std.log.warn(
            "rove-blob s3: HEAD {s}/{s} → status={d}",
            .{ self.config.bucket, key, resp.status },
        );
        return Error.Io;
    }

    fn vDelete(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *S3BlobStore = @ptrCast(@alignCast(ptr));
        const resp = try self.request(.DELETE, key, "");
        defer if (resp.body_owned) |b| self.allocator.free(b);
        // 204 = deleted; 404 = already gone (idempotent success per
        // BlobStore contract); 200 = some implementations return.
        if (resp.status == 204 or resp.status == 200 or resp.status == 404) return;
        std.log.warn(
            "rove-blob s3: DELETE {s}/{s} → status={d} body={s}",
            .{ self.config.bucket, key, resp.status, resp.bodySnippet() },
        );
        return Error.Io;
    }

    const vtable: root.BlobStore.VTable = .{
        .put = vPut,
        .get = vGet,
        .exists = vExists,
        .delete = vDelete,
    };

    // ── Wire transport ───────────────────────────────────────────────

    /// Internal response wrapper. `body_owned` is null when the
    /// caller doesn't care about the body (PUT / HEAD / DELETE
    /// responses we only check the status of); allocator-owned
    /// when caller asked via `requestAlloc`.
    const HttpResp = struct {
        status: u16,
        body_owned: ?[]u8,

        fn bodySnippet(self: HttpResp) []const u8 {
            const body = self.body_owned orelse return "";
            return body[0..@min(body.len, 256)];
        }
    };

    /// Internal: dispatch a request and discard the body (returns
    /// status only, plus a small captured snippet for logging on
    /// non-2xx). For GET we use `requestAlloc` instead.
    fn request(self: *S3BlobStore, method: std.http.Method, key: []const u8, body: []const u8) !HttpResp {
        return self.requestAlloc(method, key, body, self.allocator);
    }

    /// Dispatch a request and return the full response body owned
    /// by `body_allocator`. Unbounded — S3 GETs return whatever was
    /// PUT, and rove-blob doesn't impose a size cap (rove-files
    /// has its own 1 MiB-per-static-file cap that gates uploads).
    fn requestAlloc(
        self: *S3BlobStore,
        method: std.http.Method,
        key: []const u8,
        body: []const u8,
        body_allocator: std.mem.Allocator,
    ) !HttpResp {
        // Build the URL: scheme://endpoint/bucket/{prefix}{key}
        const scheme = if (self.config.use_tls) "https" else "http";
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}://{s}/{s}/{s}{s}",
            .{ scheme, self.config.endpoint, self.config.bucket, self.config.key_prefix, key },
        );
        defer self.allocator.free(url);

        // Path piece used by SigV4 canonicalization.
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/{s}{s}",
            .{ self.config.bucket, self.config.key_prefix, key },
        );
        defer self.allocator.free(path);

        // Host piece: SigV4 wants the literal `Host:` value, which
        // for a default port is just the hostname.
        const host = self.config.endpoint;

        // Sign the request. Timestamp comes from the wall clock —
        // S3 enforces a 15-minute skew window.
        var ts_buf: [16]u8 = undefined;
        sigv4.formatAmzDate(&ts_buf, std.time.timestamp());

        var signed = try sigv4.sign(self.allocator, .{
            .method = methodName(method),
            .path = path,
            .host = host,
            .body = body,
            .access_key = self.config.access_key,
            .secret_key = self.config.secret_key,
            .region = self.config.region,
            .service = "s3",
            .timestamp = &ts_buf,
        });
        defer signed.deinit(self.allocator);

        const headers = [_]std.http.Header{
            .{ .name = "x-amz-date", .value = signed.x_amz_date },
            .{ .name = "x-amz-content-sha256", .value = signed.x_amz_content_sha256 },
            .{ .name = "Authorization", .value = signed.authorization },
        };

        const uri = std.Uri.parse(url) catch return Error.Io;

        // For HEAD we don't need to capture body; for GET we want it
        // verbatim. PUT / DELETE responses are typically empty or
        // small XML errors — capture a snippet for diagnostics.
        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer body_buf.deinit(body_allocator);
        var aw = std.Io.Writer.Allocating.fromArrayList(body_allocator, &body_buf);

        std.log.debug("rove-blob s3: → {s} {s}", .{ methodName(method), url });

        // HEAD goes through the low-level request/send/receiveHead
        // path so we never touch the body reader. Two stdlib bugs
        // make `fetch()` unusable for HEAD in zig 0.15.2:
        //
        //   1. With `response_writer` set, fetch picks
        //      `readerDecompressing`, which doesn't check
        //      `method.responseHasBody()` and blocks reading
        //      Content-Length bytes that never come (60s OVH idle
        //      stall observed pre-c94eb64).
        //   2. With `response_writer = null`, fetch picks the
        //      `response.reader(&.{})` branch, which returns
        //      `Reader.ending` — a `@constCast` of a `const` global.
        //      `discardRemaining` then writes `r.seek = r.end` into
        //      `.rodata` and segfaults in ReleaseSafe / ReleaseFast.
        //
        // The workaround: for HEAD, send the request, read the head,
        // and return the status. No body reader is constructed.
        if (method == .HEAD) {
            return self.requestHead(uri, &headers);
        }

        const result = self.http.fetch(.{
            .location = .{ .uri = uri },
            .method = method,
            .payload = if (body.len > 0) body else null,
            .extra_headers = &headers,
            .response_writer = &aw.writer,
            .redirect_behavior = @enumFromInt(0),
        }) catch |err| {
            std.log.warn(
                "rove-blob s3: fetch {s} {s} failed: {s}",
                .{ methodName(method), url, @errorName(err) },
            );
            return Error.Io;
        };

        const body_owned = aw.toOwnedSlice() catch return Error.OutOfMemory;
        return .{
            .status = @intFromEnum(result.status),
            .body_owned = if (body_owned.len > 0) body_owned else null,
        };
    }

    /// HEAD via `client.request()` + `sendBodiless()` + `receiveHead()`.
    /// Bypasses `fetch()`, which is broken for HEAD in zig 0.15.2 (see
    /// the comment in `requestAlloc`). Returns just the status; HEAD
    /// responses carry no body we care about for `exists()` /
    /// `delete()` validation.
    fn requestHead(
        self: *S3BlobStore,
        uri: std.Uri,
        extra_headers: []const std.http.Header,
    ) !HttpResp {
        var req = self.http.request(.HEAD, uri, .{
            .extra_headers = extra_headers,
            .redirect_behavior = @enumFromInt(0),
        }) catch |err| {
            std.log.warn("rove-blob s3: HEAD request init failed: {s}", .{@errorName(err)});
            return Error.Io;
        };
        defer req.deinit();

        req.sendBodiless() catch |err| {
            std.log.warn("rove-blob s3: HEAD send failed: {s}", .{@errorName(err)});
            return Error.Io;
        };

        var redirect_buf: [256]u8 = undefined;
        const response = req.receiveHead(&redirect_buf) catch |err| {
            std.log.warn("rove-blob s3: HEAD receiveHead failed: {s}", .{@errorName(err)});
            return Error.Io;
        };

        return .{
            .status = @intFromEnum(response.head.status),
            .body_owned = null,
        };
    }

    fn methodName(m: std.http.Method) []const u8 {
        return switch (m) {
            .GET => "GET",
            .PUT => "PUT",
            .HEAD => "HEAD",
            .DELETE => "DELETE",
            else => "GET",
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "init: strips scheme leniently from endpoint" {
    var s = try S3BlobStore.init(testing.allocator, .{
        .endpoint = "https://s3.gra.io.cloud.ovh.net",
        .region = "gra",
        .bucket = "b",
        .access_key = "a",
        .secret_key = "s",
    });
    defer s.deinit();
    try testing.expectEqualStrings("s3.gra.io.cloud.ovh.net", s.config.endpoint);

    var s2 = try S3BlobStore.init(testing.allocator, .{
        .endpoint = "http://localhost:9000",
        .region = "us-east-1",
        .bucket = "b",
        .access_key = "a",
        .secret_key = "s",
        .use_tls = false,
    });
    defer s2.deinit();
    try testing.expectEqualStrings("localhost:9000", s2.config.endpoint);
}

test "init: strips trailing slash" {
    var s = try S3BlobStore.init(testing.allocator, .{
        .endpoint = "s3.gra.io.cloud.ovh.net/",
        .region = "gra",
        .bucket = "b",
        .access_key = "a",
        .secret_key = "s",
    });
    defer s.deinit();
    try testing.expectEqualStrings("s3.gra.io.cloud.ovh.net", s.config.endpoint);
}

test "init: strips both scheme and trailing slash" {
    var s = try S3BlobStore.init(testing.allocator, .{
        .endpoint = "https://s3.gra.io.cloud.ovh.net/",
        .region = "gra",
        .bucket = "b",
        .access_key = "a",
        .secret_key = "s",
    });
    defer s.deinit();
    try testing.expectEqualStrings("s3.gra.io.cloud.ovh.net", s.config.endpoint);
}

test "init: rejects empty access_key" {
    try testing.expectError(Error.Io, S3BlobStore.init(testing.allocator, .{
        .endpoint = "s3.gra.io.cloud.ovh.net",
        .region = "gra",
        .bucket = "b",
        .access_key = "",
        .secret_key = "s",
    }));
}

test "init: rejects empty region" {
    try testing.expectError(Error.Io, S3BlobStore.init(testing.allocator, .{
        .endpoint = "s3.gra.io.cloud.ovh.net",
        .region = "",
        .bucket = "b",
        .access_key = "a",
        .secret_key = "s",
    }));
}

test "init: rejects empty endpoint or bucket" {
    try testing.expectError(Error.Io, S3BlobStore.init(testing.allocator, .{
        .endpoint = "",
        .region = "gra",
        .bucket = "b",
        .access_key = "a",
        .secret_key = "s",
    }));
    try testing.expectError(Error.Io, S3BlobStore.init(testing.allocator, .{
        .endpoint = "s3.gra.io.cloud.ovh.net",
        .region = "gra",
        .bucket = "",
        .access_key = "a",
        .secret_key = "s",
    }));
}

test "init: accepts well-formed OVH config" {
    var s = try S3BlobStore.init(testing.allocator, .{
        .endpoint = "s3.gra.io.cloud.ovh.net",
        .region = "gra",
        .bucket = "loop46-blobs",
        .access_key = "AKIAEXAMPLE",
        .secret_key = "secretEXAMPLE",
    });
    defer s.deinit();
    // blobStore() returns a usable interface — we exercise put/get
    // round-trip in scripts/s3_blob_smoke.sh.
    _ = s.blobStore();
}

test "init: accepts dev TLS-off MinIO config" {
    var s = try S3BlobStore.init(testing.allocator, .{
        .endpoint = "localhost:9000",
        .region = "us-east-1",
        .bucket = "test-bucket",
        .access_key = "minioadmin",
        .secret_key = "minioadmin",
        .use_tls = false,
    });
    defer s.deinit();
}
