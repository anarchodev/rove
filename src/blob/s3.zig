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
//! - (Multipart upload WAS here-listed as omitted; it shipped with
//!   blob-storage-plan §3.5 slice A — create/uploadPart/complete/
//!   abort/copyObject below — as the storage half of `blob.receive`.)
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
const curl_mod = @import("curl.zig");

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
    /// Process-wide libcurl handle pool. Each request acquires an
    /// Easy from the pool, runs the call, returns it. Previous
    /// design was one Easy per S3BlobStore — at 1k tenants × 4
    /// worker threads × 2 backends (file-blobs + manifest) per
    /// tenant that put 8000 persistent S3 connections per process,
    /// burning FDs + memory. The pool caps total concurrent S3
    /// requests at its size (default 64, env
    /// `ROVE_S3_POOL_SIZE`), and the per-request acquire-release
    /// is uncontended under steady load.
    pool: *curl_mod.EasyPool,

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

        const pool = curl_mod.defaultPool() catch return Error.Io;

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
            .pool = pool,
        };
    }

    pub fn deinit(self: *S3BlobStore) void {
        // Pool is process-wide; not freed here.
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
            // 503 (SlowDown — OVH bucket sharding, AWS throttling) and
            // 429 (rate limit) are transient — surface as SlowDown so
            // the blob coordinator's retry path can distinguish them
            // from terminal failures. Everything else stays Error.Io.
            if (resp.status == 503 or resp.status == 429) return Error.SlowDown;
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

    /// Build a presigned GET URL the caller can hand to a browser
    /// (typically as a `Location:` 302 target). The browser fetches
    /// directly from S3, so the worker never reads or buffers the
    /// bytes. Optional `response_content_type` is signed into the
    /// URL — S3 returns that exact Content-Type, overriding whatever
    /// is stored on the object (lets the worker pick the MIME type
    /// from its static manifest without re-PUTting historical blobs
    /// that didn't set Content-Type).
    ///
    /// Returns the full URL owned by `body_allocator`. Caller frees.
    pub fn presignGet(
        self: *S3BlobStore,
        key: []const u8,
        expires_secs: u32,
        response_content_type: ?[]const u8,
        body_allocator: std.mem.Allocator,
    ) ![]u8 {
        const scheme = if (self.config.use_tls) "https" else "http";
        const path = try std.fmt.allocPrint(
            body_allocator,
            "/{s}/{s}{s}",
            .{ self.config.bucket, self.config.key_prefix, key },
        );
        defer body_allocator.free(path);

        var ts_buf: [16]u8 = undefined;
        sigv4.formatAmzDate(&ts_buf, std.time.timestamp());

        return sigv4.presignGet(body_allocator, scheme, .{
            .method = "GET",
            .path = path,
            .host = self.config.endpoint,
            .access_key = self.config.access_key,
            .secret_key = self.config.secret_key,
            .region = self.config.region,
            .service = "s3",
            .timestamp = &ts_buf,
            .expires_secs = expires_secs,
            .response_content_type = response_content_type,
        });
    }

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
    fn request(self: *S3BlobStore, method: curl_mod.Method, key: []const u8, body: []const u8) !HttpResp {
        return self.requestAlloc(method, key, body, self.allocator);
    }

    /// Dispatch a request and return the full response body owned
    /// by `body_allocator`. Unbounded — S3 GETs return whatever was
    /// PUT, and rove-blob doesn't impose a size cap (rove-files
    /// has its own 1 MiB-per-static-file cap that gates uploads).
    fn requestAlloc(
        self: *S3BlobStore,
        method: curl_mod.Method,
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

        // Sign the request. Timestamp comes from the wall clock —
        // S3 enforces a 15-minute skew window.
        var ts_buf: [16]u8 = undefined;
        sigv4.formatAmzDate(&ts_buf, std.time.timestamp());

        var signed = try sigv4.sign(self.allocator, .{
            .method = methodName(method),
            .path = path,
            .host = self.config.endpoint,
            .body = body,
            .access_key = self.config.access_key,
            .secret_key = self.config.secret_key,
            .region = self.config.region,
            .service = "s3",
            .timestamp = &ts_buf,
        });
        defer signed.deinit(self.allocator);

        const headers = [_]curl_mod.Header{
            .{ .name = "x-amz-date", .value = signed.x_amz_date },
            .{ .name = "x-amz-content-sha256", .value = signed.x_amz_content_sha256 },
            .{ .name = "Authorization", .value = signed.authorization },
        };

        std.log.debug("rove-blob s3: → {s} {s}", .{ methodName(method), url });

        const easy = self.pool.acquire();
        defer self.pool.release(easy);
        var resp = easy.request(body_allocator, .{
            .method = method,
            .url = url,
            .headers = &headers,
            .body = body,
        }) catch |err| {
            std.log.warn(
                "rove-blob s3: {s} {s} failed: {s}",
                .{ methodName(method), url, @errorName(err) },
            );
            return Error.Io;
        };
        // HttpResp only carries status + body; headers would silently
        // leak otherwise.
        resp.deinitHeaders(body_allocator);

        return .{
            .status = resp.status,
            .body_owned = if (resp.body) |b| (if (b.len > 0) b else blk: {
                body_allocator.free(b);
                break :blk null;
            }) else null,
        };
    }

    fn methodName(m: curl_mod.Method) []const u8 {
        return switch (m) {
            .GET => "GET",
            .PUT => "PUT",
            .POST => "POST",
            .HEAD => "HEAD",
            .DELETE => "DELETE",
        };
    }

    // ── Multipart upload (blob-storage-plan §3.5 slice A; `docs/architecture/routing-and-ingress.md`) ──
    //
    // The storage half of `blob.receive`: an unbounded inbound body
    // streams up as ≥5 MiB parts under a TEMP key (the content hash
    // is unknown until the last byte), then `completeMultipartUpload`
    // + `copyObject` move the finished object to its content-addressed
    // home and `deleteObject` drops the temp. Synchronous (EasyPool)
    // like every other method here — the transport driver runs these
    // off the worker thread.
    //
    // S3 quirks encoded below, so callers don't relearn them:
    //  - Create/Complete/Copy can return HTTP 200 with an `<Error>`
    //    BODY (the infamous 200-error) — status alone is not success.
    //  - Every part except the last must be ≥ 5 MiB or Complete
    //    rejects with EntityTooSmall.
    //  - `x-amz-copy-source` is an x-amz-* header and therefore MUST
    //    be SigV4-signed (`extra_signed_headers`).

    pub const MULTIPART_MIN_PART_BYTES: usize = 5 * 1024 * 1024;

    /// Start a multipart upload at `key`. Returns the allocator-owned
    /// UploadId.
    pub fn createMultipartUpload(
        self: *S3BlobStore,
        key: []const u8,
        content_type: ?[]const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var resp = try self.requestExt(.{
            .method = .POST,
            .key = key,
            .query_wire = "uploads=",
            .content_type = content_type,
        }, allocator);
        defer resp.deinit(allocator);
        if (resp.status != 200 or bodyHasS3Error(resp.body_owned)) {
            std.log.warn(
                "rove-blob s3 multipart: create {s} status={d}: {s}",
                .{ key, resp.status, resp.bodySnippet() },
            );
            return Error.Io;
        }
        const body = resp.body_owned orelse return Error.Io;
        const upload_id = extractXmlText(body, "UploadId") orelse {
            std.log.warn("rove-blob s3 multipart: create {s}: no UploadId in response", .{key});
            return Error.Io;
        };
        return allocator.dupe(u8, upload_id);
    }

    /// Upload one part (1-based `part_number`). Returns the
    /// allocator-owned ETag (quoted, verbatim — Complete accepts it
    /// as-is).
    pub fn uploadPart(
        self: *S3BlobStore,
        key: []const u8,
        upload_id: []const u8,
        part_number: u32,
        bytes: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const query = try multipartQuery(self.allocator, upload_id, part_number);
        defer self.allocator.free(query);
        var resp = try self.requestExt(.{
            .method = .PUT,
            .key = key,
            .query_wire = query,
            .body = bytes,
            .capture_header = "etag",
        }, allocator);
        defer resp.deinit(allocator);
        if (resp.status != 200) {
            std.log.warn(
                "rove-blob s3 multipart: part {d} of {s} status={d}: {s}",
                .{ part_number, key, resp.status, resp.bodySnippet() },
            );
            return Error.Io;
        }
        const etag = resp.captured_header orelse {
            std.log.warn("rove-blob s3 multipart: part {d} of {s}: no ETag header", .{ part_number, key });
            return Error.Io;
        };
        return allocator.dupe(u8, etag);
    }

    /// Finish the upload. `etags[i]` is part `i+1`'s ETag from
    /// `uploadPart`.
    pub fn completeMultipartUpload(
        self: *S3BlobStore,
        key: []const u8,
        upload_id: []const u8,
        etags: []const []const u8,
    ) !void {
        var xml = std.ArrayList(u8){};
        defer xml.deinit(self.allocator);
        try xml.appendSlice(self.allocator, "<CompleteMultipartUpload>");
        for (etags, 1..) |etag, n| {
            const part = try std.fmt.allocPrint(
                self.allocator,
                "<Part><PartNumber>{d}</PartNumber><ETag>{s}</ETag></Part>",
                .{ n, etag },
            );
            defer self.allocator.free(part);
            try xml.appendSlice(self.allocator, part);
        }
        try xml.appendSlice(self.allocator, "</CompleteMultipartUpload>");

        const query = try multipartQuery(self.allocator, upload_id, null);
        defer self.allocator.free(query);
        var resp = try self.requestExt(.{
            .method = .POST,
            .key = key,
            .query_wire = query,
            .body = xml.items,
        }, self.allocator);
        defer resp.deinit(self.allocator);
        // Complete is the canonical 200-with-<Error>-body op.
        if (resp.status != 200 or bodyHasS3Error(resp.body_owned)) {
            std.log.warn(
                "rove-blob s3 multipart: complete {s} status={d}: {s}",
                .{ key, resp.status, resp.bodySnippet() },
            );
            return Error.Io;
        }
    }

    /// Abandon an in-flight upload (frees S3-side part storage).
    /// Idempotent enough for cleanup paths: 204 or 404 both succeed.
    pub fn abortMultipartUpload(
        self: *S3BlobStore,
        key: []const u8,
        upload_id: []const u8,
    ) !void {
        const query = try multipartQuery(self.allocator, upload_id, null);
        defer self.allocator.free(query);
        var resp = try self.requestExt(.{
            .method = .DELETE,
            .key = key,
            .query_wire = query,
        }, self.allocator);
        defer resp.deinit(self.allocator);
        if (resp.status != 204 and resp.status != 404) {
            std.log.warn(
                "rove-blob s3 multipart: abort {s} status={d}: {s}",
                .{ key, resp.status, resp.bodySnippet() },
            );
            return Error.Io;
        }
    }

    /// Server-side copy `src_key` → `dst_key` (both under this
    /// store's prefix). Zero bytes transit the caller — this is how
    /// a completed multipart upload at a temp key moves to its
    /// content-addressed home.
    pub fn copyObject(
        self: *S3BlobStore,
        src_key: []const u8,
        dst_key: []const u8,
    ) !void {
        const copy_source = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/{s}{s}",
            .{ self.config.bucket, self.config.key_prefix, src_key },
        );
        defer self.allocator.free(copy_source);
        var resp = try self.requestExt(.{
            .method = .PUT,
            .key = dst_key,
            .copy_source = copy_source,
        }, self.allocator);
        defer resp.deinit(self.allocator);
        // Copy is a 200-with-<Error>-body op too; success carries
        // <CopyObjectResult>.
        if (resp.status != 200 or bodyHasS3Error(resp.body_owned)) {
            std.log.warn(
                "rove-blob s3 multipart: copy {s} → {s} status={d}: {s}",
                .{ src_key, dst_key, resp.status, resp.bodySnippet() },
            );
            return Error.Io;
        }
    }

    /// `partNumber={n}&uploadId={id}` (or just `uploadId={id}`),
    /// percent-encoded once and used BOTH on the wire and (re-parsed)
    /// in the signature — upload ids can carry `+`/`/`/`=` which must
    /// encode identically in both places. Keys already sort
    /// (`partNumber` < `uploadId`).
    fn multipartQuery(
        allocator: std.mem.Allocator,
        upload_id: []const u8,
        part_number: ?u32,
    ) ![]u8 {
        var out = std.ArrayList(u8){};
        errdefer out.deinit(allocator);
        if (part_number) |n| {
            var nbuf: [24]u8 = undefined;
            const ns = std.fmt.bufPrint(&nbuf, "partNumber={d}&", .{n}) catch unreachable;
            try out.appendSlice(allocator, ns);
        }
        try out.appendSlice(allocator, "uploadId=");
        try sigv4.uriEncodeComponent(allocator, &out, upload_id);
        return out.toOwnedSlice(allocator);
    }

    /// `<Tag>text</Tag>` extraction — the only XML S3 makes us read.
    fn extractXmlText(body: []const u8, comptime tag: []const u8) ?[]const u8 {
        const open = "<" ++ tag ++ ">";
        const close = "</" ++ tag ++ ">";
        const start = (std.mem.indexOf(u8, body, open) orelse return null) + open.len;
        const end = std.mem.indexOfPos(u8, body, start, close) orelse return null;
        if (end <= start) return null;
        return body[start..end];
    }

    fn bodyHasS3Error(body: ?[]const u8) bool {
        const b = body orelse return false;
        return std.mem.indexOf(u8, b, "<Error>") != null;
    }

    const ExtOpts = struct {
        method: curl_mod.Method,
        key: []const u8,
        /// Query string EXACTLY as it goes on the wire (already
        /// percent-encoded). Signed via `query_canonical` after a
        /// sort-preserving pass — callers keep keys pre-sorted.
        query_wire: []const u8 = "",
        body: []const u8 = "",
        content_type: ?[]const u8 = null,
        /// Signed + sent `x-amz-copy-source` (CopyObject).
        copy_source: ?[]const u8 = null,
        /// Response header to capture (case-insensitive), returned
        /// on `ExtResp.captured_header`.
        capture_header: ?[]const u8 = null,
    };

    const ExtResp = struct {
        status: u16,
        body_owned: ?[]u8,
        captured_header: ?[]u8,

        fn bodySnippet(self: ExtResp) []const u8 {
            const body = self.body_owned orelse return "";
            return body[0..@min(body.len, 256)];
        }

        fn deinit(self: *ExtResp, allocator: std.mem.Allocator) void {
            if (self.body_owned) |b| allocator.free(b);
            if (self.captured_header) |h| allocator.free(h);
            self.* = undefined;
        }
    };

    /// `requestAlloc`'s general sibling: query strings, extra signed
    /// headers, response-header capture. Kept separate so the hot
    /// blob paths don't pay for the option soup.
    fn requestExt(
        self: *S3BlobStore,
        opts: ExtOpts,
        body_allocator: std.mem.Allocator,
    ) !ExtResp {
        const scheme = if (self.config.use_tls) "https" else "http";
        const qsep: []const u8 = if (opts.query_wire.len > 0) "?" else "";
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}://{s}/{s}/{s}{s}{s}{s}",
            .{ scheme, self.config.endpoint, self.config.bucket, self.config.key_prefix, opts.key, qsep, opts.query_wire },
        );
        defer self.allocator.free(url);

        const path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/{s}{s}",
            .{ self.config.bucket, self.config.key_prefix, opts.key },
        );
        defer self.allocator.free(path);

        var ts_buf: [16]u8 = undefined;
        sigv4.formatAmzDate(&ts_buf, std.time.timestamp());

        var extra: [1]sigv4.ExtraHeader = undefined;
        var extra_n: usize = 0;
        if (opts.copy_source) |cs| {
            extra[extra_n] = .{ .name = "x-amz-copy-source", .value = cs };
            extra_n += 1;
        }

        var signed = try sigv4.sign(self.allocator, .{
            .method = methodName(opts.method),
            .path = path,
            // The wire query is already percent-encoded with sorted
            // keys — sign it verbatim so wire and signature can't
            // drift on the encoding of uploadId.
            .query_canonical = opts.query_wire,
            .host = self.config.endpoint,
            .body = opts.body,
            .access_key = self.config.access_key,
            .secret_key = self.config.secret_key,
            .region = self.config.region,
            .service = "s3",
            .timestamp = &ts_buf,
            .extra_signed_headers = extra[0..extra_n],
        });
        defer signed.deinit(self.allocator);

        var headers_buf: [5]curl_mod.Header = undefined;
        var hn: usize = 0;
        headers_buf[hn] = .{ .name = "x-amz-date", .value = signed.x_amz_date };
        hn += 1;
        headers_buf[hn] = .{ .name = "x-amz-content-sha256", .value = signed.x_amz_content_sha256 };
        hn += 1;
        headers_buf[hn] = .{ .name = "Authorization", .value = signed.authorization };
        hn += 1;
        if (opts.copy_source) |cs| {
            headers_buf[hn] = .{ .name = "x-amz-copy-source", .value = cs };
            hn += 1;
        }
        if (opts.content_type) |ct| {
            headers_buf[hn] = .{ .name = "content-type", .value = ct };
            hn += 1;
        }

        std.log.debug("rove-blob s3: → {s} {s}", .{ methodName(opts.method), url });

        const easy = self.pool.acquire();
        defer self.pool.release(easy);
        var resp = easy.request(body_allocator, .{
            .method = opts.method,
            .url = url,
            .headers = headers_buf[0..hn],
            .body = opts.body,
        }) catch |err| {
            std.log.warn(
                "rove-blob s3: {s} {s} failed: {s}",
                .{ methodName(opts.method), url, @errorName(err) },
            );
            return Error.Io;
        };

        var captured: ?[]u8 = null;
        if (opts.capture_header) |want| {
            if (resp.header(want)) |v| captured = try body_allocator.dupe(u8, v);
        }
        resp.deinitHeaders(body_allocator);

        return .{
            .status = resp.status,
            .body_owned = if (resp.body) |b| (if (b.len > 0) b else blk: {
                body_allocator.free(b);
                break :blk null;
            }) else null,
            .captured_header = captured,
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
