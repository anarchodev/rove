//! S3 backend for `BatchStore` (Phase 5.5 a, step 3a).
//!
//! Parallels `src/blob/s3.zig` — same SigV4 plumbing — but exposes
//! the `BatchStore` vtable instead of `BlobStore`. Two ops the
//! BlobStore doesn't have are central here:
//!
//!   - `getRange(key, offset, length)` — needed by the standalone
//!     log-server's /show endpoint to range-read a single record's
//!     line out of a `.ndjson` payload.
//!   - `list(prefix, after, max)` — needed by the indexer to walk
//!     the bucket for new sidecars. Wraps S3 ListObjectsV2 with
//!     `prefix=` + `start-after=`.
//!
//! Concurrency: NOT thread-safe. The worker shares one S3BatchStore
//! across worker threads only via the immutable BatchStore vtable
//! interface; each operation is a self-contained HTTP call against
//! the same `std.http.Client`. std.http.Client doesn't support
//! concurrent fetch, so the worker holds a per-thread store today.
//! When that becomes a bottleneck, switch to a connection pool;
//! the vtable shape doesn't change.
//!
//! Errors are coarse — every non-2xx (except 404 → NotFound, 206 →
//! partial content for getRange) collapses to `Error.Io` with the
//! underlying status logged. Mirrors S3BlobStore's posture.

const std = @import("std");
const sigv4 = @import("rove-blob").sigv4;
const curl_mod = @import("rove-blob").curl;
const batch_store_mod = @import("batch_store.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = batch_store_mod.Error;

pub const Config = struct {
    /// Hostname of the S3 endpoint (no scheme, no trailing slash).
    /// E.g. `s3.us-west-or.io.cloud.ovh.us`. The init scrubs a
    /// pasted `https://` / trailing `/` so config-from-env stays
    /// forgiving.
    endpoint: []const u8,
    /// SigV4 signing region (must match the endpoint region).
    region: []const u8,
    /// Bucket name. Path-style: appears as the first URI segment.
    bucket: []const u8,
    /// Optional key prefix prepended to every operation (and stripped
    /// off list responses). Lets one bucket host many environments
    /// (e.g. `prod/`, `staging/`) without colliding. May contain `/`.
    /// Empty = no prefix.
    key_prefix: []const u8 = "",
    access_key: []const u8,
    secret_key: []const u8,
    /// True for `https://` (production); false for `http://` (DEV
    /// ONLY — local MinIO). Production must use TLS.
    use_tls: bool = true,
};

pub const S3BatchStore = struct {
    allocator: std.mem.Allocator,
    /// All `[]const u8` fields are allocator-duplicated copies; the
    /// caller's `Config` strings need only outlive `init`.
    config: Config,
    /// libcurl easy handle. Reuse keeps TLS warm across calls. Not
    /// thread-safe — single-thread access only (the worker's
    /// background flusher serializes through one thread).
    curl: *curl_mod.Easy,

    pub fn init(allocator: std.mem.Allocator, config: Config) !*S3BatchStore {
        if (config.endpoint.len == 0) return Error.Io;
        if (config.bucket.len == 0) return Error.Io;
        if (config.region.len == 0) return Error.Io;
        if (config.access_key.len == 0) return Error.Io;
        if (config.secret_key.len == 0) return Error.Io;

        // Strip leniently — operators paste full URLs from S3 dashboards.
        var ep = config.endpoint;
        if (std.mem.startsWith(u8, ep, "https://")) ep = ep["https://".len..];
        if (std.mem.startsWith(u8, ep, "http://")) ep = ep["http://".len..];
        if (ep.len > 0 and ep[ep.len - 1] == '/') ep = ep[0 .. ep.len - 1];
        if (ep.len == 0) return Error.Io;

        curl_mod.globalInit();
        const curl_easy = curl_mod.Easy.init(allocator) catch return Error.Io;
        errdefer curl_easy.deinit();

        const self = try allocator.create(S3BatchStore);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .config = .{
                .endpoint = try allocator.dupe(u8, ep),
                .region = try allocator.dupe(u8, config.region),
                .bucket = try allocator.dupe(u8, config.bucket),
                .key_prefix = try allocator.dupe(u8, config.key_prefix),
                .access_key = try allocator.dupe(u8, config.access_key),
                .secret_key = try allocator.dupe(u8, config.secret_key),
                .use_tls = config.use_tls,
            },
            .curl = curl_easy,
        };
        return self;
    }

    pub fn deinit(self: *S3BatchStore) void {
        self.curl.deinit();
        self.allocator.free(self.config.endpoint);
        self.allocator.free(self.config.region);
        self.allocator.free(self.config.bucket);
        self.allocator.free(self.config.key_prefix);
        self.allocator.free(self.config.access_key);
        self.allocator.free(self.config.secret_key);
        const a = self.allocator;
        a.destroy(self);
    }

    pub fn batchStore(self: *S3BatchStore) batch_store_mod.BatchStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: batch_store_mod.BatchStore.VTable = .{
        .put = vPut,
        .get = vGet,
        .getRange = vGetRange,
        .list = vList,
    };

    // ── vtable impls ─────────────────────────────────────────────────

    fn vPut(ptr: *anyopaque, key: []const u8, bytes: []const u8) anyerror!void {
        const self: *S3BatchStore = @ptrCast(@alignCast(ptr));
        const resp = try self.requestAlloc(.PUT, key, "", bytes, null, self.allocator);
        defer if (resp.body) |b| self.allocator.free(b);
        if (resp.status != 200 and resp.status != 201) {
            std.log.warn(
                "log s3: PUT {s}/{s}{s} → {d} body={s}",
                .{ self.config.bucket, self.config.key_prefix, key, resp.status, resp.bodySnippet() },
            );
            return Error.Io;
        }
    }

    fn vGet(ptr: *anyopaque, key: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *S3BatchStore = @ptrCast(@alignCast(ptr));
        const resp = try self.requestAlloc(.GET, key, "", "", null, allocator);
        if (resp.status == 404) {
            if (resp.body) |b| allocator.free(b);
            return Error.NotFound;
        }
        if (resp.status != 200) {
            std.log.warn(
                "log s3: GET {s}/{s}{s} → {d} body={s}",
                .{ self.config.bucket, self.config.key_prefix, key, resp.status, resp.bodySnippet() },
            );
            if (resp.body) |b| allocator.free(b);
            return Error.Io;
        }
        return resp.body orelse &.{};
    }

    fn vGetRange(
        ptr: *anyopaque,
        key: []const u8,
        offset: u64,
        length: u32,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *S3BatchStore = @ptrCast(@alignCast(ptr));
        var range_buf: [64]u8 = undefined;
        const range_val = try std.fmt.bufPrint(
            &range_buf,
            "bytes={d}-{d}",
            .{ offset, offset + length - 1 },
        );
        const resp = try self.requestAlloc(.GET, key, "", "", range_val, allocator);
        if (resp.status == 404) {
            if (resp.body) |b| allocator.free(b);
            return Error.NotFound;
        }
        // S3 returns 206 Partial Content for range reads, 200 if the
        // range covers the whole object.
        if (resp.status != 206 and resp.status != 200) {
            std.log.warn(
                "log s3: GET {s}/{s}{s} (range {s}) → {d} body={s}",
                .{ self.config.bucket, self.config.key_prefix, key, range_val, resp.status, resp.bodySnippet() },
            );
            if (resp.body) |b| allocator.free(b);
            return Error.Io;
        }
        return resp.body orelse &.{};
    }

    /// ListObjectsV2 against `{bucket}/?list-type=2&prefix=...&
    /// start-after=...&max-keys=N`. Returns just the `<Key>` values
    /// (with our config.key_prefix stripped) in lexical order.
    /// `after` is exclusive — caller passes the cursor key returned
    /// by the previous page; the indexer uses `""` to start from
    /// the beginning.
    fn vList(
        ptr: *anyopaque,
        prefix: []const u8,
        after: []const u8,
        max: u32,
        allocator: std.mem.Allocator,
    ) anyerror![][]const u8 {
        const self: *S3BatchStore = @ptrCast(@alignCast(ptr));

        // The wire prefix + start-after are `{config.key_prefix}{caller-arg}`.
        const wire_prefix = try std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ self.config.key_prefix, prefix },
        );
        defer allocator.free(wire_prefix);
        const wire_after = if (after.len == 0) "" else try std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ self.config.key_prefix, after },
        );
        defer if (wire_after.len > 0) allocator.free(wire_after);

        // Build a canonicalized query string once and use it in BOTH
        // the wire URL and the sigv4 input. Values are URI-encoded
        // (every byte outside the unreserved set → `%XY`, including
        // `/`); keys are unreserved-only so they pass through. Pairs
        // are emitted in alphabetical key order, which is what SigV4
        // canonical-query requires.
        //
        // Why share one encoded string across URL + sigv4: std.http
        // serializes the URL it receives without further encoding;
        // OVH (and AWS) canonicalize what they receive on the wire by
        // RE-encoding any non-unreserved bytes. If we sent raw
        // `prefix=smoke/...` the server would canonicalize to
        // `prefix=smoke%2F...` while our local sigv4 (consuming raw)
        // would also canonicalize to `prefix=smoke%2F...` — this
        // worked in isolation against curl. With std.http, the
        // signature still mismatched (unconfirmed cause; safer to
        // pin both sides to the same already-encoded string).
        var query_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer query_buf.deinit(allocator);
        try query_buf.appendSlice(allocator, "list-type=2");
        if (max > 0) {
            const ms = try std.fmt.allocPrint(allocator, "&max-keys={d}", .{max});
            defer allocator.free(ms);
            try query_buf.appendSlice(allocator, ms);
        }
        if (wire_prefix.len > 0) {
            try query_buf.appendSlice(allocator, "&prefix=");
            try uriEncodeInto(allocator, &query_buf, wire_prefix);
        }
        if (wire_after.len > 0) {
            try query_buf.appendSlice(allocator, "&start-after=");
            try uriEncodeInto(allocator, &query_buf, wire_after);
        }

        // LIST hits the bucket root (`/bucket/`) with the prefix
        // entirely in the query string — NOT in the path. Pass an
        // empty key + skip the key_prefix concat by routing through
        // the override-path branch.
        const root_path = try std.fmt.allocPrint(allocator, "/{s}/", .{self.config.bucket});
        defer allocator.free(root_path);
        // Wire URL needs the query appended after `?`. The query
        // string is already in canonical form (alphabetical + fully
        // URI-encoded) — same bytes go in the URL, in the
        // `Uri.query.percent_encoded`, and in the signer's
        // `query_canonical` hook so AWS's wire→canonical
        // transformation matches our local sigv4 input exactly.
        const root_url = try std.fmt.allocPrint(allocator, "{s}://{s}{s}?{s}", .{
            if (self.config.use_tls) "https" else "http",
            self.config.endpoint,
            root_path,
            query_buf.items,
        });
        defer allocator.free(root_url);

        const resp = try self.requestAllocCanonical(
            .GET,
            root_url,
            root_path,
            query_buf.items,
            "",
            null,
            allocator,
        );
        if (resp.status != 200) {
            std.log.warn(
                "log s3: LIST {s}/?{s} → {d} body={s}",
                .{ self.config.bucket, query_buf.items, resp.status, resp.bodySnippet() },
            );
            if (resp.body) |b| allocator.free(b);
            return Error.Io;
        }
        defer if (resp.body) |b| allocator.free(b);

        return parseKeysFromXml(allocator, resp.body orelse "", self.config.key_prefix);
    }

    // ── Wire transport ────────────────────────────────────────────────

    const HttpResp = struct {
        status: u16,
        body: ?[]u8,

        fn bodySnippet(self: HttpResp) []const u8 {
            const body = self.body orelse return "";
            return body[0..@min(body.len, 256)];
        }
    };

    /// Single-object dispatch (PUT/GET/HEAD/DELETE). URL +
    /// sig path = `/bucket/{key_prefix}{key}`. For LIST go through
    /// `requestAllocOverride` directly.
    fn requestAlloc(
        self: *S3BatchStore,
        method: curl_mod.Method,
        key: []const u8,
        query: []const u8,
        body: []const u8,
        range: ?[]const u8,
        body_allocator: std.mem.Allocator,
    ) !HttpResp {
        const scheme = if (self.config.use_tls) "https" else "http";
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}://{s}/{s}/{s}{s}{s}{s}",
            .{
                scheme,
                self.config.endpoint,
                self.config.bucket,
                self.config.key_prefix,
                key,
                if (query.len > 0) "?" else "",
                query,
            },
        );
        defer self.allocator.free(url);
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/{s}{s}",
            .{ self.config.bucket, self.config.key_prefix, key },
        );
        defer self.allocator.free(path);
        return self.requestAllocOverride(method, url, path, query, body, range, body_allocator);
    }

    /// Lower-level dispatch — caller supplies the URL + sig path.
    /// Used by LIST so the path stays `/bucket/` (no key_prefix in
    /// the URL — the prefix lives entirely in the query string).
    /// Caller's `query` is treated as raw (parsed + re-encoded by
    /// sigv4); for already-canonicalized queries use
    /// `requestAllocCanonical` instead.
    fn requestAllocOverride(
        self: *S3BatchStore,
        method: curl_mod.Method,
        url: []const u8,
        path: []const u8,
        query: []const u8,
        body: []const u8,
        range: ?[]const u8,
        body_allocator: std.mem.Allocator,
    ) !HttpResp {
        return self.dispatchSigned(method, url, path, query, null, body, range, body_allocator);
    }

    /// Same as `requestAllocOverride` but treats `query_canon` as
    /// already canonical (skips sigv4's parse + re-encode pass). The
    /// same string lands in the wire URL.
    fn requestAllocCanonical(
        self: *S3BatchStore,
        method: curl_mod.Method,
        url: []const u8,
        path: []const u8,
        query_canon: []const u8,
        body: []const u8,
        range: ?[]const u8,
        body_allocator: std.mem.Allocator,
    ) !HttpResp {
        return self.dispatchSigned(method, url, path, query_canon, query_canon, body, range, body_allocator);
    }

    fn dispatchSigned(
        self: *S3BatchStore,
        method: curl_mod.Method,
        url: []const u8,
        path: []const u8,
        query_raw: []const u8,
        query_canonical: ?[]const u8,
        body: []const u8,
        range: ?[]const u8,
        body_allocator: std.mem.Allocator,
    ) !HttpResp {
        var ts_buf: [16]u8 = undefined;
        sigv4.formatAmzDate(&ts_buf, std.time.timestamp());

        var signed = try sigv4.sign(self.allocator, .{
            .method = methodName(method),
            .path = path,
            .query = query_raw,
            .query_canonical = query_canonical,
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

        std.log.debug("log s3: → {s} {s} body_size={d}", .{ methodName(method), url, body.len });

        const resp = self.curl.request(body_allocator, .{
            .method = method,
            .url = url,
            .headers = &headers,
            .body = body,
            .range = range,
        }) catch |err| {
            std.log.warn(
                "log s3: {s} {s} failed: {s}",
                .{ methodName(method), url, @errorName(err) },
            );
            return Error.Io;
        };

        return .{
            .status = resp.status,
            .body = if (resp.body) |b| (if (b.len > 0) b else blk: {
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
};

// ── XML parsing for ListObjectsV2 ───────────────────────────────────

/// Walk `<Key>...</Key>` elements out of a ListObjectsV2 response and
/// return the keys with `key_prefix` stripped (so callers see the
/// same `prefix` they passed to `list`). XML is parsed with a tight
/// substring scan rather than a real parser — the response shape is
/// stable + tiny per element. No CDATA, no namespaces, no entities.
fn parseKeysFromXml(
    allocator: std.mem.Allocator,
    xml: []const u8,
    key_prefix: []const u8,
) ![][]const u8 {
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }

    const open = "<Key>";
    const close = "</Key>";
    var i: usize = 0;
    while (i < xml.len) {
        const start = std.mem.indexOfPos(u8, xml, i, open) orelse break;
        const after_open = start + open.len;
        const end = std.mem.indexOfPos(u8, xml, after_open, close) orelse break;
        const wire_key = xml[after_open..end];
        const stripped = if (std.mem.startsWith(u8, wire_key, key_prefix))
            wire_key[key_prefix.len..]
        else
            wire_key;
        const dup = try allocator.dupe(u8, stripped);
        errdefer allocator.free(dup);
        try keys.append(allocator, dup);
        i = end + close.len;
    }
    return keys.toOwnedSlice(allocator);
}

/// Percent-encode for use as a query string value, per the SigV4
/// canonical-query rules. Encodes EVERY byte that isn't in the
/// unreserved set — including `/` (which becomes `%2F`). The signed
/// canonical query string and the wire URL must match exactly, so
/// the same encoder produces both.
fn uriEncodeInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    s: []const u8,
) !void {
    for (s) |b| {
        const unreserved = (b >= 'A' and b <= 'Z') or
            (b >= 'a' and b <= 'z') or
            (b >= '0' and b <= '9') or
            b == '-' or b == '_' or b == '.' or b == '~';
        if (unreserved) {
            try out.append(allocator, b);
        } else {
            try out.appendSlice(allocator, "%");
            const hex = "0123456789ABCDEF";
            try out.append(allocator, hex[b >> 4]);
            try out.append(allocator, hex[b & 0x0f]);
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "parseKeysFromXml extracts keys + strips prefix" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<ListBucketResult>
        \\  <Name>bucket</Name>
        \\  <Prefix>logs/</Prefix>
        \\  <Contents><Key>logs/acme/00000001/b1.idx.json</Key><Size>123</Size></Contents>
        \\  <Contents><Key>logs/acme/00000001/b1.ndjson</Key><Size>456</Size></Contents>
        \\  <Contents><Key>logs/globex/00000001/g1.idx.json</Key><Size>789</Size></Contents>
        \\</ListBucketResult>
    ;
    const keys = try parseKeysFromXml(testing.allocator, xml, "logs/");
    defer batch_store_mod.freeListResult(testing.allocator, keys);
    try testing.expectEqual(@as(usize, 3), keys.len);
    try testing.expectEqualStrings("acme/00000001/b1.idx.json", keys[0]);
    try testing.expectEqualStrings("acme/00000001/b1.ndjson", keys[1]);
    try testing.expectEqualStrings("globex/00000001/g1.idx.json", keys[2]);
}

test "parseKeysFromXml empty response returns empty slice" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<ListBucketResult><Name>b</Name><KeyCount>0</KeyCount></ListBucketResult>
    ;
    const keys = try parseKeysFromXml(testing.allocator, xml, "");
    defer batch_store_mod.freeListResult(testing.allocator, keys);
    try testing.expectEqual(@as(usize, 0), keys.len);
}

test "uriEncodeInto encodes slashes + everything outside unreserved set" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try uriEncodeInto(testing.allocator, &out, "acme/00000001/foo bar=baz");
    try testing.expectEqualStrings(
        "acme%2F00000001%2Ffoo%20bar%3Dbaz",
        out.items,
    );
}

test "init: rejects empty endpoint / bucket / region / keys" {
    try testing.expectError(Error.Io, S3BatchStore.init(testing.allocator, .{
        .endpoint = "",
        .region = "r",
        .bucket = "b",
        .access_key = "ak",
        .secret_key = "sk",
    }));
    try testing.expectError(Error.Io, S3BatchStore.init(testing.allocator, .{
        .endpoint = "ep",
        .region = "",
        .bucket = "b",
        .access_key = "ak",
        .secret_key = "sk",
    }));
    try testing.expectError(Error.Io, S3BatchStore.init(testing.allocator, .{
        .endpoint = "ep",
        .region = "r",
        .bucket = "",
        .access_key = "ak",
        .secret_key = "sk",
    }));
    try testing.expectError(Error.Io, S3BatchStore.init(testing.allocator, .{
        .endpoint = "ep",
        .region = "r",
        .bucket = "b",
        .access_key = "",
        .secret_key = "sk",
    }));
    try testing.expectError(Error.Io, S3BatchStore.init(testing.allocator, .{
        .endpoint = "ep",
        .region = "r",
        .bucket = "b",
        .access_key = "ak",
        .secret_key = "",
    }));
}

test "init: strips scheme + trailing slash from endpoint" {
    var s = try S3BatchStore.init(testing.allocator, .{
        .endpoint = "https://s3.example.com/",
        .region = "r",
        .bucket = "b",
        .access_key = "ak",
        .secret_key = "sk",
    });
    defer s.deinit();
    try testing.expectEqualStrings("s3.example.com", s.config.endpoint);
}
