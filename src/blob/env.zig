//! Operator-facing env-driven `BackendConfig` loader. Lives in
//! rove-blob (not in loop46) so every binary that owns blob storage
//! — `loop46`, `files-server-standalone`, `log-server-standalone` —
//! reads the same env vars and produces the same shape. Standardizes
//! the deploy contract:
//!
//! ```
//! BLOB_BACKEND=fs                                # default; fs only
//! BLOB_BACKEND=s3
//! S3_ENDPOINT=https://...
//! S3_REGION=...
//! S3_BUCKET=...
//! S3_KEY_PREFIX_BASE=prod/                       # optional, "" by default
//! S3_USE_TLS=1                                   # optional, 1 by default
//! AWS_ACCESS_KEY_ID=...
//! AWS_SECRET_ACCESS_KEY=...
//! ```
//!
//! `loadFromEnv` returns a structured `LoadError` rather than calling
//! `std.process.exit` so each binary can format its own error message
//! consistently with the rest of its CLI surface.

const std = @import("std");
const backend = @import("backend.zig");

pub const ENV_BLOB_BACKEND = "BLOB_BACKEND";
pub const ENV_S3_ENDPOINT = "S3_ENDPOINT";
pub const ENV_S3_REGION = "S3_REGION";
pub const ENV_S3_BUCKET = "S3_BUCKET";
pub const ENV_S3_KEY_PREFIX_BASE = "S3_KEY_PREFIX_BASE";
pub const ENV_S3_USE_TLS = "S3_USE_TLS";
pub const ENV_AWS_AK = "AWS_ACCESS_KEY_ID";
pub const ENV_AWS_SK = "AWS_SECRET_ACCESS_KEY";

pub const LoadError = error{
    UnknownBackend,
    MissingS3Endpoint,
    MissingS3Region,
    MissingS3Bucket,
    MissingS3AccessKey,
    MissingS3SecretKey,
    OutOfMemory,
};

/// Owns the env-allocated strings that back a `.s3` `BackendConfig`.
/// `cfg` is the pointer-stable view callers pass to spawn / Worker /
/// ApplyCtx; `deinit` frees the underlying strings AFTER all consumers
/// have finished with them.
pub const BlobBackendOwned = struct {
    cfg: backend.BackendConfig,
    /// Owned strings backing `cfg.s3` when `cfg == .s3`. All `null`
    /// for the `.fs` variant.
    endpoint: ?[]u8 = null,
    region: ?[]u8 = null,
    bucket: ?[]u8 = null,
    key_prefix_base: ?[]u8 = null,
    access_key: ?[]u8 = null,
    secret_key: ?[]u8 = null,

    pub fn deinit(self: *BlobBackendOwned, allocator: std.mem.Allocator) void {
        if (self.endpoint) |s| allocator.free(s);
        if (self.region) |s| allocator.free(s);
        if (self.bucket) |s| allocator.free(s);
        if (self.key_prefix_base) |s| allocator.free(s);
        if (self.access_key) |s| allocator.free(s);
        if (self.secret_key) |s| allocator.free(s);
    }
};

/// Read an optional env var, returning null when unset or
/// invalid-utf8. Allocator-owned slice; caller frees on Some.
pub fn envOpt(allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}!?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        error.InvalidWtf8 => null,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Build a `BlobBackendOwned` from process env. Defaults to `.fs` when
/// `BLOB_BACKEND` is unset or `fs`. Returns specific `LoadError`
/// values for missing required s3 settings so each binary can print
/// its own diagnostic.
pub fn loadFromEnv(allocator: std.mem.Allocator) LoadError!BlobBackendOwned {
    const kind_owned = (try envOpt(allocator, ENV_BLOB_BACKEND)) orelse {
        return .{ .cfg = .fs };
    };
    defer allocator.free(kind_owned);

    if (std.mem.eql(u8, kind_owned, "fs")) return .{ .cfg = .fs };
    if (!std.mem.eql(u8, kind_owned, "s3")) return LoadError.UnknownBackend;

    const endpoint = (try envOpt(allocator, ENV_S3_ENDPOINT)) orelse return LoadError.MissingS3Endpoint;
    errdefer allocator.free(endpoint);
    const region = (try envOpt(allocator, ENV_S3_REGION)) orelse return LoadError.MissingS3Region;
    errdefer allocator.free(region);
    const bucket = (try envOpt(allocator, ENV_S3_BUCKET)) orelse return LoadError.MissingS3Bucket;
    errdefer allocator.free(bucket);
    const access_key = (try envOpt(allocator, ENV_AWS_AK)) orelse return LoadError.MissingS3AccessKey;
    errdefer allocator.free(access_key);
    const secret_key = (try envOpt(allocator, ENV_AWS_SK)) orelse return LoadError.MissingS3SecretKey;
    errdefer allocator.free(secret_key);

    const key_prefix_base = (try envOpt(allocator, ENV_S3_KEY_PREFIX_BASE)) orelse
        try allocator.dupe(u8, "");
    errdefer allocator.free(key_prefix_base);

    const use_tls = blk: {
        const v = (try envOpt(allocator, ENV_S3_USE_TLS)) orelse break :blk true;
        defer allocator.free(v);
        if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false")) break :blk false;
        break :blk true;
    };

    return .{
        .cfg = .{ .s3 = .{
            .endpoint = endpoint,
            .region = region,
            .bucket = bucket,
            .key_prefix_base = key_prefix_base,
            .access_key = access_key,
            .secret_key = secret_key,
            .use_tls = use_tls,
        } },
        .endpoint = endpoint,
        .region = region,
        .bucket = bucket,
        .key_prefix_base = key_prefix_base,
        .access_key = access_key,
        .secret_key = secret_key,
    };
}

/// Render a `LoadError` into the env-var name the operator needs to
/// set. Used by callers to print "BLOB_BACKEND=s3 requires {name}"
/// messages without listing every error explicitly.
pub fn errorEnvName(err: LoadError) ?[]const u8 {
    return switch (err) {
        LoadError.MissingS3Endpoint => ENV_S3_ENDPOINT,
        LoadError.MissingS3Region => ENV_S3_REGION,
        LoadError.MissingS3Bucket => ENV_S3_BUCKET,
        LoadError.MissingS3AccessKey => ENV_AWS_AK,
        LoadError.MissingS3SecretKey => ENV_AWS_SK,
        LoadError.UnknownBackend, LoadError.OutOfMemory => null,
    };
}
