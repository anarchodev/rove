//! rove-files — content-addressed file store + deployment index.
//!
//! rove-files tracks a tenant's deployable files — handler source + its
//! compiled bytecode today, plus raw static assets once Phase 2 lands.
//! The raw bytes live in a `BlobStore` (rove-blob); the *index* lives in
//! a `KvStore` (rove-kv) so it can be replicated via raft. This split
//! matters: blobs are big and immutable, so they belong in object storage
//! (S3 in production, fs in dev); the index is tiny and mutable, so it
//! rides along in the raft group that owns it.
//!
//! ## Data model
//!
//! Keys in the `KvStore` (all ASCII):
//!
//!   `file/{path}`                → `{source_sha256_hex}`
//!   `bytecode/{source_sha256}`   → `{bytecode_sha256_hex}` (compile cache)
//!   `deployment/{id}`            → binary manifest (see `Manifest` below)
//!   `deployment/current`         → `{id}` (the active deployment)
//!
//! Blobs in the `BlobStore`:
//!
//!   `{source_sha256_hex}`        → raw source bytes
//!   `{bytecode_sha256_hex}`      → serialized quickjs bytecode
//!
//! ## Workflow
//!
//! 1. Client uploads files: each `putSource(path, bytes)` hashes the
//!    source, writes the blob (if new), compiles to bytecode (if not
//!    already cached), writes the bytecode blob, and stamps
//!    `file/{path}` + `bytecode/{source_hash}` in the index.
//! 2. Client calls `deploy()`: the current `file/*` set is snapshotted
//!    into a new manifest. The manifest gets an id (monotonic integer
//!    encoded as hex) and `deployment/current` is updated.
//! 3. Worker fetches the current deployment: `loadCurrentDeployment()`
//!    returns the manifest; the worker resolves each entry's bytecode
//!    blob through the same `BlobStore`.
//!
//! ## Compile hook
//!
//! rove-files is quickjs-agnostic — it takes a `CompileFn` at construction
//! time. `rove-files-server` wires in a function that owns a `rove-qjs`
//! `Runtime` + `Context` and calls `compileToBytecode`. Tests use a
//! pass-through hook that returns the source unchanged, which is enough
//! to exercise the index + blob plumbing without pulling in quickjs.

const std = @import("std");

const kv = @import("rove-kv");
const blob_mod = @import("rove-blob");

pub const KvStore = kv.KvStore;
pub const BlobStore = blob_mod.BlobStore;

pub const Error = error{
    NotFound,
    InvalidManifest,
    InvalidPath,
    Kv,
    Blob,
    CompileFailed,
    OutOfMemory,
};

/// A compile hook. Given source bytes, returns a fresh allocator-owned
/// bytecode buffer. `ctx` is the opaque user pointer supplied at
/// `FileStore.init`. Implementations should return `error.CompileFailed`
/// for syntax errors; other errors propagate as-is.
pub const CompileFn = *const fn (
    ctx: ?*anyopaque,
    source: []const u8,
    filename: [:0]const u8,
    allocator: std.mem.Allocator,
) anyerror![]u8;

pub const HASH_HEX_LEN: usize = 64; // sha256 hex

/// Maximum file path length we'll accept. Keeps key construction bounded
/// and matches blob-key invariants from rove-blob.
pub const MAX_PATH_LEN: usize = 192;

pub const FileStore = struct {
    allocator: std.mem.Allocator,
    kv: *KvStore,
    blob: BlobStore,
    compile: CompileFn,
    compile_ctx: ?*anyopaque,

    pub fn init(
        allocator: std.mem.Allocator,
        kv_store: *KvStore,
        blob: BlobStore,
        compile: CompileFn,
        compile_ctx: ?*anyopaque,
    ) FileStore {
        return .{
            .allocator = allocator,
            .kv = kv_store,
            .blob = blob,
            .compile = compile,
            .compile_ctx = compile_ctx,
        };
    }

    // ── Source upload ─────────────────────────────────────────────────

    /// Upload a source file at `path`. Writes the source blob, compiles
    /// to bytecode (reusing the cache when the source hash matches an
    /// earlier compile), writes the bytecode blob, and updates the
    /// `file/{path}` and `bytecode/{source_hash}` index entries.
    ///
    /// Idempotent: uploading the same bytes under the same path is a
    /// no-op beyond re-stamping the index.
    pub fn putSource(
        self: *FileStore,
        path: []const u8,
        source: []const u8,
    ) Error!void {
        try validatePath(path);

        var src_hex: [HASH_HEX_LEN]u8 = undefined;
        hashHex(source, &src_hex);

        // Source blob first.
        self.blob.put(&src_hex, source) catch return Error.Blob;

        // Compile (or reuse cached bytecode hash).
        var bc_hex: [HASH_HEX_LEN]u8 = undefined;
        try self.ensureBytecode(path, source, &src_hex, &bc_hex);

        // Index updates.
        var file_key_buf: [5 + MAX_PATH_LEN]u8 = undefined;
        const file_key = std.fmt.bufPrint(&file_key_buf, "file/{s}", .{path}) catch
            return Error.InvalidPath;
        self.kv.put(file_key, &src_hex) catch return Error.Kv;
    }

    fn ensureBytecode(
        self: *FileStore,
        path: []const u8,
        source: []const u8,
        src_hex: *const [HASH_HEX_LEN]u8,
        out_bc_hex: *[HASH_HEX_LEN]u8,
    ) Error!void {
        var bc_key_buf: [9 + HASH_HEX_LEN]u8 = undefined;
        const bc_key = std.fmt.bufPrint(&bc_key_buf, "bytecode/{s}", .{src_hex}) catch
            unreachable;

        if (self.kv.get(bc_key)) |cached| {
            defer self.allocator.free(cached);
            if (cached.len == HASH_HEX_LEN) {
                @memcpy(out_bc_hex, cached[0..HASH_HEX_LEN]);
                return;
            }
            // Corrupt cache entry — fall through and recompile.
        } else |err| switch (err) {
            error.NotFound => {},
            else => return Error.Kv,
        }

        // Compile. Filename must be NUL-terminated for quickjs; build it.
        var fname_buf: [MAX_PATH_LEN + 1]u8 = undefined;
        if (path.len > MAX_PATH_LEN) return Error.InvalidPath;
        @memcpy(fname_buf[0..path.len], path);
        fname_buf[path.len] = 0;
        const fname: [:0]const u8 = fname_buf[0..path.len :0];

        const bytecode = self.compile(self.compile_ctx, source, fname, self.allocator) catch
            return Error.CompileFailed;
        defer self.allocator.free(bytecode);

        hashHex(bytecode, out_bc_hex);
        self.blob.put(out_bc_hex, bytecode) catch return Error.Blob;
        self.kv.put(bc_key, out_bc_hex) catch return Error.Kv;
    }

    /// Fetch the current source blob for `path`. Returns owned bytes.
    pub fn getSource(
        self: *FileStore,
        path: []const u8,
        allocator: std.mem.Allocator,
    ) Error![]u8 {
        try validatePath(path);
        var file_key_buf: [5 + MAX_PATH_LEN]u8 = undefined;
        const file_key = std.fmt.bufPrint(&file_key_buf, "file/{s}", .{path}) catch
            return Error.InvalidPath;
        const hex = self.kv.get(file_key) catch |err| switch (err) {
            error.NotFound => return Error.NotFound,
            else => return Error.Kv,
        };
        defer self.allocator.free(hex);
        if (hex.len != HASH_HEX_LEN) return Error.InvalidManifest;
        return self.blob.get(hex, allocator) catch Error.Blob;
    }

    /// Fetch the bytecode blob for `path`'s current source. Returns owned
    /// bytes.
    pub fn getBytecode(
        self: *FileStore,
        path: []const u8,
        allocator: std.mem.Allocator,
    ) Error![]u8 {
        try validatePath(path);
        var file_key_buf: [5 + MAX_PATH_LEN]u8 = undefined;
        const file_key = std.fmt.bufPrint(&file_key_buf, "file/{s}", .{path}) catch
            return Error.InvalidPath;
        const src_hex = self.kv.get(file_key) catch |err| switch (err) {
            error.NotFound => return Error.NotFound,
            else => return Error.Kv,
        };
        defer self.allocator.free(src_hex);
        if (src_hex.len != HASH_HEX_LEN) return Error.InvalidManifest;

        var bc_key_buf: [9 + HASH_HEX_LEN]u8 = undefined;
        const bc_key = std.fmt.bufPrint(&bc_key_buf, "bytecode/{s}", .{src_hex}) catch
            unreachable;
        const bc_hex = self.kv.get(bc_key) catch |err| switch (err) {
            error.NotFound => return Error.NotFound,
            else => return Error.Kv,
        };
        defer self.allocator.free(bc_hex);
        if (bc_hex.len != HASH_HEX_LEN) return Error.InvalidManifest;

        return self.blob.get(bc_hex, allocator) catch Error.Blob;
    }

    // ── Deployment ────────────────────────────────────────────────────

    pub const Entry = struct {
        path: []u8,
        source_hex: [HASH_HEX_LEN]u8,
        bytecode_hex: [HASH_HEX_LEN]u8,
    };

    pub const Manifest = struct {
        id: u64,
        entries: []Entry,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Manifest) void {
            for (self.entries) |e| self.allocator.free(e.path);
            self.allocator.free(self.entries);
            self.* = undefined;
        }
    };

    /// Snapshot the current working tree (`file/*`) into a new deployment.
    /// Assigns a monotonically increasing id (current + 1) and stores the
    /// manifest under `deployment/{id_hex}`, then updates
    /// `deployment/current`. Returns the new id.
    pub fn deploy(self: *FileStore) Error!u64 {
        // Collect all `file/*` entries.
        var entries: std.ArrayList(Entry) = .empty;
        defer {
            for (entries.items) |e| self.allocator.free(e.path);
            entries.deinit(self.allocator);
        }

        const scan = self.kv.prefix("file/", "", std.math.maxInt(u32)) catch
            return Error.Kv;
        var scan_mut = scan;
        defer scan_mut.deinit();

        for (scan.entries) |e| {
            if (e.key.len <= "file/".len) continue;
            const path = e.key["file/".len..];

            if (e.value.len != HASH_HEX_LEN) return Error.InvalidManifest;
            var src_hex: [HASH_HEX_LEN]u8 = undefined;
            @memcpy(&src_hex, e.value[0..HASH_HEX_LEN]);

            // Resolve bytecode hash via cache.
            var bc_key_buf: [9 + HASH_HEX_LEN]u8 = undefined;
            const bc_key = std.fmt.bufPrint(&bc_key_buf, "bytecode/{s}", .{src_hex}) catch
                unreachable;
            const bc_hex_bytes = self.kv.get(bc_key) catch |err| switch (err) {
                error.NotFound => return Error.NotFound,
                else => return Error.Kv,
            };
            defer self.allocator.free(bc_hex_bytes);
            if (bc_hex_bytes.len != HASH_HEX_LEN) return Error.InvalidManifest;
            var bc_hex: [HASH_HEX_LEN]u8 = undefined;
            @memcpy(&bc_hex, bc_hex_bytes[0..HASH_HEX_LEN]);

            const path_copy = self.allocator.dupe(u8, path) catch return Error.OutOfMemory;
            errdefer self.allocator.free(path_copy);
            entries.append(self.allocator, .{
                .path = path_copy,
                .source_hex = src_hex,
                .bytecode_hex = bc_hex,
            }) catch return Error.OutOfMemory;
        }

        // Determine next id.
        const next_id: u64 = blk: {
            const cur = self.kv.get("deployment/current") catch |err| switch (err) {
                error.NotFound => break :blk 1,
                else => return Error.Kv,
            };
            defer self.allocator.free(cur);
            const parsed = std.fmt.parseInt(u64, cur, 16) catch return Error.InvalidManifest;
            break :blk parsed + 1;
        };

        // Serialize + write manifest blob.
        const bytes = serializeManifest(self.allocator, entries.items) catch
            return Error.OutOfMemory;
        defer self.allocator.free(bytes);

        var id_hex_buf: [16]u8 = undefined;
        const id_hex = std.fmt.bufPrint(&id_hex_buf, "{x:0>16}", .{next_id}) catch unreachable;

        var dep_key_buf: [11 + 16]u8 = undefined;
        const dep_key = std.fmt.bufPrint(&dep_key_buf, "deployment/{s}", .{id_hex}) catch
            unreachable;

        self.kv.put(dep_key, bytes) catch return Error.Kv;
        self.kv.put("deployment/current", id_hex) catch return Error.Kv;
        return next_id;
    }

    /// Load the active deployment manifest. Caller must `deinit` the
    /// returned `Manifest`.
    pub fn loadCurrentDeployment(self: *FileStore) Error!Manifest {
        const cur = self.kv.get("deployment/current") catch |err| switch (err) {
            error.NotFound => return Error.NotFound,
            else => return Error.Kv,
        };
        defer self.allocator.free(cur);
        const id = std.fmt.parseInt(u64, cur, 16) catch return Error.InvalidManifest;
        return self.loadDeployment(id);
    }

    pub fn loadDeployment(self: *FileStore, id: u64) Error!Manifest {
        var id_hex_buf: [16]u8 = undefined;
        const id_hex = std.fmt.bufPrint(&id_hex_buf, "{x:0>16}", .{id}) catch unreachable;
        var dep_key_buf: [11 + 16]u8 = undefined;
        const dep_key = std.fmt.bufPrint(&dep_key_buf, "deployment/{s}", .{id_hex}) catch
            unreachable;
        const bytes = self.kv.get(dep_key) catch |err| switch (err) {
            error.NotFound => return Error.NotFound,
            else => return Error.Kv,
        };
        defer self.allocator.free(bytes);
        const entries = try parseManifest(self.allocator, bytes);
        return .{ .id = id, .entries = entries, .allocator = self.allocator };
    }
};

// ── Helpers ────────────────────────────────────────────────────────────

fn hashHex(bytes: []const u8, out: *[HASH_HEX_LEN]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
}

/// Reject paths that would collide with our own key prefixes, contain
/// NULs, or are absurdly long. Paths are handler module paths like
/// `handlers/index.js`; we allow `/` (unlike blob keys) but not `..`.
fn validatePath(path: []const u8) Error!void {
    if (path.len == 0 or path.len > MAX_PATH_LEN) return Error.InvalidPath;
    if (std.mem.indexOf(u8, path, "..") != null) return Error.InvalidPath;
    if (path[0] == '/') return Error.InvalidPath;
    for (path) |b| {
        if (b < 0x20 or b > 0x7e) return Error.InvalidPath;
    }
}

// Manifest binary format:
//   [u32 count]
//   for each entry:
//     [u16 path_len][path bytes][64 source_hex][64 bytecode_hex]
//
// Little-endian. Unit-tested below.
fn serializeManifest(
    allocator: std.mem.Allocator,
    entries: []const FileStore.Entry,
) error{OutOfMemory}![]u8 {
    var total: usize = 4;
    for (entries) |e| total += 2 + e.path.len + HASH_HEX_LEN * 2;

    const out = try allocator.alloc(u8, total);
    var i: usize = 0;
    std.mem.writeInt(u32, out[i..][0..4], @intCast(entries.len), .little);
    i += 4;
    for (entries) |e| {
        std.mem.writeInt(u16, out[i..][0..2], @intCast(e.path.len), .little);
        i += 2;
        @memcpy(out[i..][0..e.path.len], e.path);
        i += e.path.len;
        @memcpy(out[i..][0..HASH_HEX_LEN], &e.source_hex);
        i += HASH_HEX_LEN;
        @memcpy(out[i..][0..HASH_HEX_LEN], &e.bytecode_hex);
        i += HASH_HEX_LEN;
    }
    return out;
}

fn parseManifest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error![]FileStore.Entry {
    if (bytes.len < 4) return Error.InvalidManifest;
    var i: usize = 0;
    const count = std.mem.readInt(u32, bytes[i..][0..4], .little);
    i += 4;

    const out = allocator.alloc(FileStore.Entry, count) catch return Error.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |e| allocator.free(e.path);
        allocator.free(out);
    }

    while (filled < count) : (filled += 1) {
        if (i + 2 > bytes.len) return Error.InvalidManifest;
        const path_len = std.mem.readInt(u16, bytes[i..][0..2], .little);
        i += 2;
        if (i + path_len + HASH_HEX_LEN * 2 > bytes.len) return Error.InvalidManifest;

        const path = allocator.dupe(u8, bytes[i .. i + path_len]) catch
            return Error.OutOfMemory;
        i += path_len;

        var src_hex: [HASH_HEX_LEN]u8 = undefined;
        @memcpy(&src_hex, bytes[i..][0..HASH_HEX_LEN]);
        i += HASH_HEX_LEN;
        var bc_hex: [HASH_HEX_LEN]u8 = undefined;
        @memcpy(&bc_hex, bytes[i..][0..HASH_HEX_LEN]);
        i += HASH_HEX_LEN;

        out[filled] = .{ .path = path, .source_hex = src_hex, .bytecode_hex = bc_hex };
    }
    return out;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const fs_backend = blob_mod.fs;

/// Pass-through compiler for tests: "bytecode" is just `"bc:" ++ source`.
/// Good enough to exercise the cache — different source yields different
/// bytecode, identical source yields identical bytecode.
fn passthroughCompile(
    _: ?*anyopaque,
    source: []const u8,
    _: [:0]const u8,
    allocator: std.mem.Allocator,
) anyerror![]u8 {
    const prefix = "bc:";
    const out = try allocator.alloc(u8, prefix.len + source.len);
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..], source);
    return out;
}

/// Failing compiler for the CompileFailed test.
fn failingCompile(
    _: ?*anyopaque,
    _: []const u8,
    _: [:0]const u8,
    _: std.mem.Allocator,
) anyerror![]u8 {
    return error.SyntaxError;
}

const TestFixture = struct {
    allocator: std.mem.Allocator,
    tmp_path: []u8,
    kv: *KvStore,
    blob_store: fs_backend.FilesystemBlobStore,

    fn init(allocator: std.mem.Allocator) !TestFixture {
        const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/rove-files-test-{x}", .{seed});
        errdefer allocator.free(tmp_path);

        std.fs.cwd().deleteTree(tmp_path) catch {};
        try std.fs.cwd().makePath(tmp_path);

        const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/idx.db", .{tmp_path}, 0);
        defer allocator.free(db_path);
        const kvs = try KvStore.open(allocator, db_path);
        errdefer kvs.close();

        const blob_path = try std.fmt.allocPrint(allocator, "{s}/blobs", .{tmp_path});
        defer allocator.free(blob_path);
        const bs = try fs_backend.FilesystemBlobStore.open(allocator, blob_path);

        return .{
            .allocator = allocator,
            .tmp_path = tmp_path,
            .kv = kvs,
            .blob_store = bs,
        };
    }

    fn deinit(self: *TestFixture) void {
        self.blob_store.deinit();
        self.kv.close();
        std.fs.cwd().deleteTree(self.tmp_path) catch {};
        self.allocator.free(self.tmp_path);
    }

    fn fileStore(self: *TestFixture) FileStore {
        return FileStore.init(
            self.allocator,
            self.kv,
            self.blob_store.blobStore(),
            passthroughCompile,
            null,
        );
    }
};

test "putSource writes blob + index and round-trips via getSource" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    var code = fx.fileStore();

    try code.putSource("handlers/index.js", "export default () => 42;");

    const got = try code.getSource("handlers/index.js", testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("export default () => 42;", got);
}

test "getBytecode returns compiled blob for current file" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    var code = fx.fileStore();

    try code.putSource("a.js", "1 + 1");
    const bc = try code.getBytecode("a.js", testing.allocator);
    defer testing.allocator.free(bc);
    try testing.expectEqualStrings("bc:1 + 1", bc);
}

test "bytecode cache is reused across identical source" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();

    var calls: usize = 0;
    const CountingCompile = struct {
        fn run(
            ctx: ?*anyopaque,
            source: []const u8,
            _: [:0]const u8,
            allocator: std.mem.Allocator,
        ) anyerror![]u8 {
            const counter: *usize = @ptrCast(@alignCast(ctx.?));
            counter.* += 1;
            const out = try allocator.alloc(u8, source.len);
            @memcpy(out, source);
            return out;
        }
    };

    var code = FileStore.init(
        testing.allocator,
        fx.kv,
        fx.blob_store.blobStore(),
        CountingCompile.run,
        &calls,
    );

    try code.putSource("a.js", "const x = 1;");
    try code.putSource("b.js", "const x = 1;"); // same source → cache hit
    try code.putSource("c.js", "const y = 2;"); // different → compile

    try testing.expectEqual(@as(usize, 2), calls);
}

test "compile failure surfaces as CompileFailed" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    var code = FileStore.init(
        testing.allocator,
        fx.kv,
        fx.blob_store.blobStore(),
        failingCompile,
        null,
    );

    try testing.expectError(Error.CompileFailed, code.putSource("bad.js", "@@@"));
}

test "putSource overwrites existing file with new hash" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    var code = fx.fileStore();

    try code.putSource("a.js", "v1");
    try code.putSource("a.js", "v2");

    const got = try code.getSource("a.js", testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("v2", got);
}

test "deploy snapshots current files and assigns id=1 then 2" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    var code = fx.fileStore();

    try code.putSource("a.js", "A");
    try code.putSource("b.js", "B");

    const id1 = try code.deploy();
    try testing.expectEqual(@as(u64, 1), id1);

    try code.putSource("a.js", "A2");
    const id2 = try code.deploy();
    try testing.expectEqual(@as(u64, 2), id2);
}

test "loadCurrentDeployment returns manifest with all entries" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    var code = fx.fileStore();

    try code.putSource("a.js", "A");
    try code.putSource("sub/b.js", "BB");
    _ = try code.deploy();

    var m = try code.loadCurrentDeployment();
    defer m.deinit();

    try testing.expectEqual(@as(u64, 1), m.id);
    try testing.expectEqual(@as(usize, 2), m.entries.len);

    // kv.range returns entries sorted by key — so "a.js" then "sub/b.js".
    try testing.expectEqualStrings("a.js", m.entries[0].path);
    try testing.expectEqualStrings("sub/b.js", m.entries[1].path);
}

test "loadCurrentDeployment returns NotFound when no deploy yet" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    var code = fx.fileStore();

    try code.putSource("a.js", "A");
    try testing.expectError(Error.NotFound, code.loadCurrentDeployment());
}

test "old deployments remain addressable by id after new deploy" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    var code = fx.fileStore();

    try code.putSource("a.js", "v1");
    _ = try code.deploy();
    try code.putSource("a.js", "v2");
    _ = try code.deploy();

    var old = try code.loadDeployment(1);
    defer old.deinit();
    try testing.expectEqual(@as(usize, 1), old.entries.len);

    // Source hash in the old manifest should match sha256("v1").
    var expected: [HASH_HEX_LEN]u8 = undefined;
    hashHex("v1", &expected);
    try testing.expectEqualSlices(u8, &expected, &old.entries[0].source_hex);
}

test "validatePath rejects traversal, absolute, empty, control chars" {
    try testing.expectError(Error.InvalidPath, validatePath(""));
    try testing.expectError(Error.InvalidPath, validatePath("/abs"));
    try testing.expectError(Error.InvalidPath, validatePath("a/../b"));
    try testing.expectError(Error.InvalidPath, validatePath("..")); // contains ..
    const with_nul = [_]u8{ 'a', 0, 'b' };
    try testing.expectError(Error.InvalidPath, validatePath(&with_nul));
    try validatePath("handlers/index.js");
    try validatePath("a.js");
    try validatePath("deep/nested/path/file.js");
}

test "serialize + parse manifest round-trip" {
    var entries = [_]FileStore.Entry{
        .{
            .path = @constCast("a.js"),
            .source_hex = [_]u8{'a'} ** HASH_HEX_LEN,
            .bytecode_hex = [_]u8{'1'} ** HASH_HEX_LEN,
        },
        .{
            .path = @constCast("deep/path/b.js"),
            .source_hex = [_]u8{'b'} ** HASH_HEX_LEN,
            .bytecode_hex = [_]u8{'2'} ** HASH_HEX_LEN,
        },
    };

    const bytes = try serializeManifest(testing.allocator, &entries);
    defer testing.allocator.free(bytes);

    const parsed = try parseManifest(testing.allocator, bytes);
    defer {
        for (parsed) |e| testing.allocator.free(e.path);
        testing.allocator.free(parsed);
    }

    try testing.expectEqual(@as(usize, 2), parsed.len);
    try testing.expectEqualStrings("a.js", parsed[0].path);
    try testing.expectEqualStrings("deep/path/b.js", parsed[1].path);
    try testing.expectEqualSlices(u8, &entries[0].source_hex, &parsed[0].source_hex);
    try testing.expectEqualSlices(u8, &entries[1].bytecode_hex, &parsed[1].bytecode_hex);
}

test "parseManifest rejects truncated input" {
    try testing.expectError(Error.InvalidManifest, parseManifest(testing.allocator, &[_]u8{}));
    // count=5, but no entries follow
    try testing.expectError(
        Error.InvalidManifest,
        parseManifest(testing.allocator, &[_]u8{ 5, 0, 0, 0 }),
    );
}
