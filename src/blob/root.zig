//! rove-blob — pluggable blob storage for rove-code and rove-log.
//!
//! Blobs are opaque byte sequences addressed by ASCII string keys.
//! Phase 1a ships a filesystem backend only. Phase 6 adds an S3
//! backend for production deployments. The vtable abstraction lets
//! both backends slot in behind the same type without rebuilding the
//! consumers.
//!
//! **What "blob" means here**: the content. rove-code hashes source
//! files to SHA-256 and passes `sha256_hex` as the key; rove-log uses
//! request-id-derived keys. This module does not impose a key schema —
//! any ASCII string that passes `validateKey` is accepted — but it
//! does enforce path-traversal safety.
//!
//! **What "key" means**: a short ASCII string. The validator rejects
//! path separators (`/`, `\`), parent-dir references (`..`), leading
//! dots, and non-printable bytes. Backends may further restrict.

const std = @import("std");

pub const fs = @import("fs.zig");
pub const FilesystemBlobStore = fs.FilesystemBlobStore;

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
    OutOfMemory,
};

/// Maximum key length we'll accept. 256 bytes is plenty for SHA-256
/// hex (64 chars) and request-id-style keys. Keeping this bounded
/// makes backends' path-construction math safe by construction.
pub const MAX_KEY_LEN: usize = 256;

/// Validate that `key` is safe to pass to any backend. Enforces:
///   - 1..MAX_KEY_LEN bytes
///   - printable ASCII only (0x20..0x7e)
///   - no `/` or `\` (path separators)
///   - not `.` or `..` literally
///   - doesn't contain `..` as a substring (defensive against
///     constructions like `foo../bar`)
///   - doesn't start with `.` (hidden files, defense-in-depth on fs
///     backends)
pub fn validateKey(key: []const u8) Error!void {
    if (key.len == 0 or key.len > MAX_KEY_LEN) return Error.InvalidKey;
    if (key[0] == '.') return Error.InvalidKey;
    if (std.mem.indexOf(u8, key, "..") != null) return Error.InvalidKey;
    for (key) |b| {
        if (b < 0x20 or b > 0x7e) return Error.InvalidKey;
        if (b == '/' or b == '\\') return Error.InvalidKey;
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
}

test "validateKey rejects path-traversal patterns" {
    try testing.expectError(Error.InvalidKey, validateKey(""));
    try testing.expectError(Error.InvalidKey, validateKey("a" ** 257));
    try testing.expectError(Error.InvalidKey, validateKey("."));
    try testing.expectError(Error.InvalidKey, validateKey(".."));
    try testing.expectError(Error.InvalidKey, validateKey(".hidden"));
    try testing.expectError(Error.InvalidKey, validateKey("a/b"));
    try testing.expectError(Error.InvalidKey, validateKey("a\\b"));
    try testing.expectError(Error.InvalidKey, validateKey("foo../bar"));
    try testing.expectError(Error.InvalidKey, validateKey("../etc/passwd"));
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
    _ = @import("fs.zig");
}
