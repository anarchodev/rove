//! rove-blob — S3-backed blob storage for rove-files and rove-log.
//!
//! Blobs are opaque byte sequences addressed by ASCII string keys.
//! The store is S3-shaped (AWS / OVH / R2 / B2 / MinIO); a vtable
//! `BlobStore` interface lets consumers hold the store without
//! depending on the concrete S3 implementation.
//!
//! **What "blob" means here**: the content. rove-files hashes source
//! files to SHA-256 and passes `sha256_hex` as the key; rove-log uses
//! request-id-derived keys. This module does not impose a key schema —
//! any ASCII string that passes `validateKey` is accepted — but it
//! does enforce path-traversal safety.
//!
//! **What "key" means**: a short ASCII string. `/` is allowed as a
//! namespace separator (S3 keys are flat strings — `/` is the idiomatic
//! "folder" convention and SigV4 preserves it in the canonical path;
//! e.g. `bc/{hash}`). The validator rejects the escape/footgun shapes:
//! `..` (traversal), `\`, leading/trailing `/`, empty segments (`//`),
//! leading `.`, and non-printable bytes. Tenant confinement comes from
//! the fixed internal key prefix + the `..` rejection, NOT from banning
//! `/` — and no customer chooses a raw key anyway (uploads key by native
//! sha256).

const std = @import("std");

pub const s3 = @import("s3.zig");
pub const S3BlobStore = s3.S3BlobStore;
pub const sigv4 = @import("sigv4.zig");
pub const curl = @import("curl.zig");
pub const curl_multi = @import("curl_multi.zig");
pub const backend = @import("backend.zig");
pub const BlobBackend = backend.BlobBackend;
pub const BackendConfig = backend.BackendConfig;
pub const env = @import("env.zig");
pub const BlobBackendOwned = env.BlobBackendOwned;
pub const namespace = @import("namespace.zig");
pub const namespace_store = @import("namespace_store.zig");
pub const http_blob = @import("http_blob.zig");
pub const HttpBlobStore = http_blob.HttpBlobStore;
pub const coordinator = @import("coordinator.zig");
pub const BlobCoordinator = coordinator.BlobCoordinator;

pub const Error = error{
    /// The key contained characters that could escape the blob store's
    /// namespace (path separators, `..`, etc.) or was otherwise malformed.
    InvalidKey,
    /// Key does not exist in the store.
    NotFound,
    /// Backend-specific I/O error. The original error details are logged;
    /// the interface surface is deliberately coarse so callers treat all
    /// backends uniformly.
    Io,
    /// Transient backpressure from the backend — typically HTTP 503
    /// (S3 SlowDown / sharding events) or 429 (rate limit). Callers
    /// that retry (the blob coordinator's executor) should distinguish
    /// these from terminal failures; callers without retry semantics
    /// can treat this the same as `Io`.
    SlowDown,
    OutOfMemory,
};

/// Maximum key length we'll accept. 256 bytes is plenty for SHA-256
/// hex (64 chars) and request-id-style keys. Keeping this bounded
/// makes backends' path-construction math safe by construction.
pub const MAX_KEY_LEN: usize = 256;

/// Validate that `key` is safe to pass to any backend. Enforces:
///   - 1..MAX_KEY_LEN bytes
///   - printable ASCII only (0x20..0x7e)
///   - `/` allowed as a namespace separator, BUT no leading/trailing `/`
///     and no `//` (empty segments — an S3 footgun that makes
///     `prefix//key` a distinct object from `prefix/key`)
///   - no `\` (not a separator on S3; only invites path confusion)
///   - doesn't contain `..` as a substring (traversal — this, plus the
///     fixed internal key prefix, is what confines a key to its
///     namespace; `/` alone can only go deeper, never up or sideways)
///   - doesn't start with `.` (hidden-file shapes)
pub fn validateKey(key: []const u8) Error!void {
    if (key.len == 0 or key.len > MAX_KEY_LEN) return Error.InvalidKey;
    if (key[0] == '.') return Error.InvalidKey;
    if (key[0] == '/' or key[key.len - 1] == '/') return Error.InvalidKey;
    if (std.mem.indexOf(u8, key, "..") != null) return Error.InvalidKey;
    if (std.mem.indexOf(u8, key, "//") != null) return Error.InvalidKey;
    for (key) |b| {
        if (b < 0x20 or b > 0x7e) return Error.InvalidKey;
        if (b == '\\') return Error.InvalidKey;
    }
}

// ── Vtable interface ───────────────────────────────────────────────────

pub const BlobStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (ptr: *anyopaque, key: []const u8, bytes: []const u8) anyerror!void,
        get: *const fn (ptr: *anyopaque, key: []const u8, allocator: std.mem.Allocator) anyerror![]u8,
        exists: *const fn (ptr: *anyopaque, key: []const u8) anyerror!bool,
        delete: *const fn (ptr: *anyopaque, key: []const u8) anyerror!void,
    };

    /// Store `bytes` under `key`. Overwrites any existing value atomically
    /// on backends that can (fs uses rename-into-place). Validates key.
    pub fn put(self: BlobStore, key: []const u8, bytes: []const u8) !void {
        try validateKey(key);
        return self.vtable.put(self.ptr, key, bytes);
    }

    /// Fetch the value for `key`. Returns owned bytes (caller frees with
    /// `allocator.free`). Returns `Error.NotFound` if the key is unknown.
    pub fn get(
        self: BlobStore,
        key: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        try validateKey(key);
        return self.vtable.get(self.ptr, key, allocator);
    }

    /// True if the key exists in the store. Non-existent keys return
    /// false rather than an error; I/O failures still surface.
    pub fn exists(self: BlobStore, key: []const u8) !bool {
        try validateKey(key);
        return self.vtable.exists(self.ptr, key);
    }

    /// Remove `key` from the store. Idempotent: deleting a non-existent
    /// key is a no-op success.
    pub fn delete(self: BlobStore, key: []const u8) !void {
        try validateKey(key);
        return self.vtable.delete(self.ptr, key);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "validateKey accepts plausible blob keys" {
    try validateKey("abcd");
    try validateKey("a" ** 256);
    try validateKey("sha256:0123456789abcdef");
    try validateKey("request-42-tape");
    try validateKey("mixed_case-and.dots_ok_in_middle"); // dot in middle ok
    try validateKey("hex-64chars-" ++ ("0" ** 52));
    // `/` is a namespace separator (S3-idiomatic; the bc/ + pkg/ layouts).
    try validateKey("bc/" ++ ("0" ** 64));
    try validateKey("pkg/" ++ ("a" ** 64) ++ "/index.mjs");
    try validateKey("deployments/00000000000000000001.json");
}

test "validateKey allows `/` but rejects the escape/footgun shapes" {
    // Confinement is the `..` reject + fixed prefix, not banning `/`.
    try testing.expectError(Error.InvalidKey, validateKey(""));
    try testing.expectError(Error.InvalidKey, validateKey("a" ** 257));
    try testing.expectError(Error.InvalidKey, validateKey("."));
    try testing.expectError(Error.InvalidKey, validateKey(".."));
    try testing.expectError(Error.InvalidKey, validateKey(".hidden"));
    try testing.expectError(Error.InvalidKey, validateKey("a\\b")); // backslash still out
    try testing.expectError(Error.InvalidKey, validateKey("foo../bar")); // traversal
    try testing.expectError(Error.InvalidKey, validateKey("../etc/passwd"));
    try testing.expectError(Error.InvalidKey, validateKey("/leading")); // leading slash
    try testing.expectError(Error.InvalidKey, validateKey("trailing/")); // trailing slash
    try testing.expectError(Error.InvalidKey, validateKey("a//b")); // empty segment
}

test "validateKey rejects non-printable bytes" {
    const with_null = [_]u8{ 'a', 0, 'b' };
    try testing.expectError(Error.InvalidKey, validateKey(&with_null));
    const with_newline = [_]u8{ 'a', '\n', 'b' };
    try testing.expectError(Error.InvalidKey, validateKey(&with_newline));
    const high_ascii = [_]u8{ 'a', 0x80, 'b' };
    try testing.expectError(Error.InvalidKey, validateKey(&high_ascii));
}

test {
    _ = @import("sigv4.zig");
    _ = @import("s3.zig");
    _ = @import("backend.zig");
    _ = @import("http_blob.zig");
    _ = @import("curl_multi.zig");
    _ = @import("coordinator.zig");
    _ = @import("namespace.zig");
    _ = @import("namespace_store.zig");
    _ = @import("reservation.zig");
}
