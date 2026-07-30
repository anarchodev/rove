//! Reading and writing the storage-namespace marker (`namespace.zig` holds the
//! grammar). Split from it so the grammar file stays `std`-only and the
//! operator CLI — which links no system libraries — shares the same key name
//! and the same segment rules instead of restating them.

const std = @import("std");
const root = @import("root.zig");
const namespace = @import("namespace.zig");

/// Read the marker through a store scoped to `key_prefix_base`. Returns the
/// segment (possibly empty). A missing marker is `MarkerMissing`, NOT an empty
/// segment — the two mean opposite things, and conflating them would hand a
/// fresh cluster the previous lifetime's keys. Caller owns the result.
pub fn read(allocator: std.mem.Allocator, store: root.BlobStore) ![]u8 {
    if (!try store.exists(namespace.MARKER_KEY)) return namespace.Error.MarkerMissing;
    const raw = try store.get(namespace.MARKER_KEY, allocator);
    errdefer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    try namespace.validate(trimmed);
    if (trimmed.len == raw.len) return raw;
    const owned = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return owned;
}

/// Write the marker through a store scoped to `key_prefix_base`.
pub fn write(store: root.BlobStore, segment: []const u8) !void {
    try namespace.validate(segment);
    try store.put(namespace.MARKER_KEY, segment);
}

/// Open a store at the base prefix and read the marker. This is the one
/// storage access that happens BEFORE the generation is known, which is why it
/// touches only the marker and nothing under a generation. Caller owns the
/// returned segment.
pub fn resolve(allocator: std.mem.Allocator, cfg: root.BackendConfig) ![]u8 {
    var marker_store = try root.BlobBackend.openS3(allocator, .{
        .endpoint = cfg.endpoint,
        .region = cfg.region,
        .bucket = cfg.bucket,
        .key_prefix = cfg.key_prefix_base,
        .access_key = cfg.access_key,
        .secret_key = cfg.secret_key,
        .use_tls = cfg.use_tls,
    });
    defer marker_store.deinit();
    return read(allocator, marker_store.blobStore());
}
