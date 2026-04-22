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

/// Maximum content-type length stored on a file. MIME strings in the
/// wild stay well under this.
pub const MAX_CT_LEN: usize = 255;

/// What a file slot holds. `handler` = JS source that also gets compiled
/// to bytecode and served by dispatch. `static` = opaque bytes served
/// verbatim with their stored content-type.
pub const Kind = enum(u8) {
    handler = 0,
    static = 1,
};

pub const FileStore = struct {
    allocator: std.mem.Allocator,
    kv: *KvStore,
    blob: BlobStore,
    compile: CompileFn,
    compile_ctx: ?*anyopaque,
    /// Optional raft-replication target. When non-null, every kv
    /// put/delete this FileStore performs is mirrored into the
    /// writeset so the caller can propose it through raft — the
    /// follower applies the same ops against its own copy of
    /// `{instance}/files.db`. Blob bytes are NOT replicated this
    /// way (they'd blow the raft entry size for large static
    /// assets); multi-node deployments rely on a shared BlobStore
    /// backend (path B — shared filesystem or S3).
    ///
    /// Null for: bootstrap deploys (each node runs the same
    /// deterministic sequence independently) and tests. Non-null
    /// for: signup's `deployStarterContent`, the files-server's
    /// single-file PUT + bulk deploy endpoints.
    replicate: ?*kv.WriteSet = null,

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

    /// Attach a writeset that mirrors every kv put/delete for the
    /// remaining lifetime of this FileStore. Callers that need raft
    /// replication construct the writeset, call this, drive their
    /// deploy, and then propose the writeset. Pass null to detach.
    pub fn setReplicate(self: *FileStore, ws: ?*kv.WriteSet) void {
        self.replicate = ws;
    }

    /// Internal put that tees through to the replicate writeset when
    /// one is attached. Every FileStore put/delete must go through
    /// these helpers (not self.kv directly) for follower correctness.
    fn kvPut(self: *FileStore, key: []const u8, value: []const u8) Error!void {
        self.kv.put(key, value) catch return Error.Kv;
        if (self.replicate) |ws| ws.addPut(key, value) catch return Error.OutOfMemory;
    }

    fn kvDelete(self: *FileStore, key: []const u8) Error!void {
        self.kv.delete(key) catch |err| switch (err) {
            error.NotFound => {},
            else => return Error.Kv,
        };
        if (self.replicate) |ws| ws.addDelete(key) catch return Error.OutOfMemory;
    }

    // ── Source upload ─────────────────────────────────────────────────

    /// Upload a JS source file at `path`. Writes the source blob, compiles
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
        try self.writeFileEntry(path, .handler, "", &src_hex);
    }

    /// Upload a static file at `path`. Writes the raw bytes as a content-
    /// addressed blob and stamps `file/{path}` with the supplied content-
    /// type. Skips compile entirely — static entries carry no bytecode.
    pub fn putStatic(
        self: *FileStore,
        path: []const u8,
        bytes: []const u8,
        content_type: []const u8,
    ) Error!void {
        try validatePath(path);
        if (content_type.len > MAX_CT_LEN) return Error.InvalidPath;

        var src_hex: [HASH_HEX_LEN]u8 = undefined;
        hashHex(bytes, &src_hex);

        self.blob.put(&src_hex, bytes) catch return Error.Blob;
        try self.writeFileEntry(path, .static, content_type, &src_hex);
    }

    /// Hash-addressed variant of `putSource`: the source blob is
    /// already in the BlobStore (uploaded by the client via
    /// `PUT /blobs/{hash}`). We fetch it, compile to bytecode, and
    /// stamp the index. Returns `Error.NotFound` if the blob isn't
    /// in the store — the caller should have verified hashes via
    /// `/blobs/check` first.
    pub fn putSourceByHash(
        self: *FileStore,
        path: []const u8,
        src_hex: []const u8,
    ) Error!void {
        try validatePath(path);
        if (src_hex.len != HASH_HEX_LEN) return Error.InvalidManifest;

        const source = self.blob.get(src_hex, self.allocator) catch |err| switch (err) {
            error.NotFound => return Error.NotFound,
            else => return Error.Blob,
        };
        defer self.allocator.free(source);

        var src_hex_fixed: [HASH_HEX_LEN]u8 = undefined;
        @memcpy(&src_hex_fixed, src_hex);

        var bc_hex: [HASH_HEX_LEN]u8 = undefined;
        try self.ensureBytecode(path, source, &src_hex_fixed, &bc_hex);
        try self.writeFileEntry(path, .handler, "", &src_hex_fixed);
    }

    /// Hash-addressed variant of `putStatic`: the blob is already
    /// uploaded, so we just stamp the index. No compile, no blob
    /// write. Returns `Error.NotFound` if the blob is missing.
    pub fn putStaticByHash(
        self: *FileStore,
        path: []const u8,
        src_hex: []const u8,
        content_type: []const u8,
    ) Error!void {
        try validatePath(path);
        if (src_hex.len != HASH_HEX_LEN) return Error.InvalidManifest;
        if (content_type.len > MAX_CT_LEN) return Error.InvalidPath;

        const present = self.blob.exists(src_hex) catch return Error.Blob;
        if (!present) return Error.NotFound;

        var src_hex_fixed: [HASH_HEX_LEN]u8 = undefined;
        @memcpy(&src_hex_fixed, src_hex);
        try self.writeFileEntry(path, .static, content_type, &src_hex_fixed);
    }

    /// Drop every `file/*` entry from the working tree. Used by the
    /// bulk deploy path to clear stale paths before stamping the
    /// new manifest — the deploy is always a full-replace, never a
    /// merge. Mirrored through the replicate writeset if attached.
    pub fn clearFileEntries(self: *FileStore) Error!void {
        const scan = self.kv.prefix("file/", "", std.math.maxInt(u32)) catch
            return Error.Kv;
        var scan_mut = scan;
        defer scan_mut.deinit();
        for (scan.entries) |e| {
            try self.kvDelete(e.key);
        }
    }

    fn writeFileEntry(
        self: *FileStore,
        path: []const u8,
        kind: Kind,
        content_type: []const u8,
        src_hex: *const [HASH_HEX_LEN]u8,
    ) Error!void {
        var file_key_buf: [5 + MAX_PATH_LEN]u8 = undefined;
        const file_key = std.fmt.bufPrint(&file_key_buf, "file/{s}", .{path}) catch
            return Error.InvalidPath;

        var val_buf: [2 + MAX_CT_LEN + HASH_HEX_LEN]u8 = undefined;
        const val = encodeFileValue(&val_buf, kind, content_type, src_hex);
        try self.kvPut(file_key, val);
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
        try self.kvPut(bc_key, out_bc_hex);
    }

    /// Fetch the current source blob for `path`. Returns owned bytes.
    /// Works for both `handler` (JS source) and `static` (raw bytes).
    pub fn getSource(
        self: *FileStore,
        path: []const u8,
        allocator: std.mem.Allocator,
    ) Error![]u8 {
        var decoded = try self.loadFileEntry(path);
        defer decoded.deinit();
        return self.blob.get(&decoded.source_hex, allocator) catch Error.Blob;
    }

    /// Fetch the bytecode blob for `path`'s current source. Returns owned
    /// bytes. `Error.NotFound` when `path` doesn't exist or is static.
    pub fn getBytecode(
        self: *FileStore,
        path: []const u8,
        allocator: std.mem.Allocator,
    ) Error![]u8 {
        var decoded = try self.loadFileEntry(path);
        defer decoded.deinit();
        if (decoded.kind != .handler) return Error.NotFound;

        var bc_key_buf: [9 + HASH_HEX_LEN]u8 = undefined;
        const bc_key = std.fmt.bufPrint(&bc_key_buf, "bytecode/{s}", .{decoded.source_hex}) catch
            unreachable;
        const bc_hex = self.kv.get(bc_key) catch |err| switch (err) {
            error.NotFound => return Error.NotFound,
            else => return Error.Kv,
        };
        defer self.allocator.free(bc_hex);
        if (bc_hex.len != HASH_HEX_LEN) return Error.InvalidManifest;

        return self.blob.get(bc_hex, allocator) catch Error.Blob;
    }

    /// Read-and-decode the `file/{path}` slot. The returned value borrows
    /// nothing from the kv backing store (content_type is copied into the
    /// heap-allocated `storage` field — caller must `freeFileEntry`).
    pub const FileEntry = struct {
        kind: Kind,
        content_type: []u8,
        source_hex: [HASH_HEX_LEN]u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *FileEntry) void {
            self.allocator.free(self.content_type);
            self.* = undefined;
        }
    };

    pub fn stat(self: *FileStore, path: []const u8) Error!FileEntry {
        return self.loadFileEntry(path);
    }

    fn loadFileEntry(self: *FileStore, path: []const u8) Error!FileEntry {
        try validatePath(path);
        var file_key_buf: [5 + MAX_PATH_LEN]u8 = undefined;
        const file_key = std.fmt.bufPrint(&file_key_buf, "file/{s}", .{path}) catch
            return Error.InvalidPath;
        const raw = self.kv.get(file_key) catch |err| switch (err) {
            error.NotFound => return Error.NotFound,
            else => return Error.Kv,
        };
        defer self.allocator.free(raw);
        const view = try decodeFileValue(raw);
        const ct_copy = self.allocator.dupe(u8, view.content_type) catch
            return Error.OutOfMemory;
        return .{
            .kind = view.kind,
            .content_type = ct_copy,
            .source_hex = view.source_hex,
            .allocator = self.allocator,
        };
    }

    // ── Deployment ────────────────────────────────────────────────────

    pub const Entry = struct {
        path: []u8,
        kind: Kind,
        content_type: []u8,
        source_hex: [HASH_HEX_LEN]u8,
        /// All-zero when `kind != .handler`.
        bytecode_hex: [HASH_HEX_LEN]u8,
    };

    pub const Manifest = struct {
        id: u64,
        entries: []Entry,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Manifest) void {
            for (self.entries) |e| {
                self.allocator.free(e.path);
                self.allocator.free(e.content_type);
            }
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
            for (entries.items) |e| {
                self.allocator.free(e.path);
                self.allocator.free(e.content_type);
            }
            entries.deinit(self.allocator);
        }

        const scan = self.kv.prefix("file/", "", std.math.maxInt(u32)) catch
            return Error.Kv;
        var scan_mut = scan;
        defer scan_mut.deinit();

        for (scan.entries) |e| {
            if (e.key.len <= "file/".len) continue;
            const path = e.key["file/".len..];

            const view = try decodeFileValue(e.value);

            // Resolve bytecode hash via cache for handlers; statics
            // carry zero-bytes to keep the manifest entry shape uniform.
            var bc_hex: [HASH_HEX_LEN]u8 = @splat(0);
            if (view.kind == .handler) {
                var bc_key_buf: [9 + HASH_HEX_LEN]u8 = undefined;
                const bc_key = std.fmt.bufPrint(&bc_key_buf, "bytecode/{s}", .{view.source_hex}) catch
                    unreachable;
                const bc_hex_bytes = self.kv.get(bc_key) catch |err| switch (err) {
                    error.NotFound => return Error.NotFound,
                    else => return Error.Kv,
                };
                defer self.allocator.free(bc_hex_bytes);
                if (bc_hex_bytes.len != HASH_HEX_LEN) return Error.InvalidManifest;
                @memcpy(&bc_hex, bc_hex_bytes[0..HASH_HEX_LEN]);
            }

            const path_copy = self.allocator.dupe(u8, path) catch return Error.OutOfMemory;
            errdefer self.allocator.free(path_copy);
            const ct_copy = self.allocator.dupe(u8, view.content_type) catch
                return Error.OutOfMemory;
            errdefer self.allocator.free(ct_copy);
            entries.append(self.allocator, .{
                .path = path_copy,
                .kind = view.kind,
                .content_type = ct_copy,
                .source_hex = view.source_hex,
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

        try self.kvPut(dep_key, bytes);
        try self.kvPut("deployment/current", id_hex);
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

/// Canonical allowed path: lowercase letters, digits, and `-_./`. Reject
/// traversal, empty segments, percent-encoded slashes, absolute paths,
/// and control bytes. Matches §2.4 of the product plan.
pub fn validatePath(path: []const u8) Error!void {
    if (path.len == 0 or path.len > MAX_PATH_LEN) return Error.InvalidPath;
    if (path[0] == '/') return Error.InvalidPath;
    if (std.mem.indexOf(u8, path, "..") != null) return Error.InvalidPath;
    if (std.mem.indexOf(u8, path, "//") != null) return Error.InvalidPath;

    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        const b = path[i];
        // Percent-encoded slash check: `%2f` / `%2F`.
        if (b == '%' and i + 2 < path.len) {
            const h2 = path[i + 2];
            if (path[i + 1] == '2' and (h2 == 'f' or h2 == 'F')) {
                return Error.InvalidPath;
            }
        }
        const ok = (b >= 'a' and b <= 'z') or
            (b >= '0' and b <= '9') or
            b == '-' or b == '_' or b == '.' or b == '/';
        if (!ok) return Error.InvalidPath;
    }
}

// ── file/{path} value encoding ────────────────────────────────────────
//
// Layout:
//   [u8 kind] [u8 ct_len] [ct_len bytes content-type] [64 source_hex]
//
// Min 66 bytes (no content-type), max 66 + MAX_CT_LEN.

const FileValueView = struct {
    kind: Kind,
    content_type: []const u8, // borrowed from the input buffer
    source_hex: [HASH_HEX_LEN]u8,
};

fn encodeFileValue(
    buf: []u8,
    kind: Kind,
    content_type: []const u8,
    src_hex: *const [HASH_HEX_LEN]u8,
) []u8 {
    std.debug.assert(content_type.len <= MAX_CT_LEN);
    const total = 2 + content_type.len + HASH_HEX_LEN;
    std.debug.assert(buf.len >= total);
    buf[0] = @intFromEnum(kind);
    buf[1] = @intCast(content_type.len);
    @memcpy(buf[2 .. 2 + content_type.len], content_type);
    @memcpy(buf[2 + content_type.len ..][0..HASH_HEX_LEN], src_hex);
    return buf[0..total];
}

fn decodeFileValue(value: []const u8) Error!FileValueView {
    if (value.len < 2 + HASH_HEX_LEN) return Error.InvalidManifest;
    const kind: Kind = switch (value[0]) {
        0 => .handler,
        1 => .static,
        else => return Error.InvalidManifest,
    };
    const ct_len = value[1];
    if (value.len != 2 + ct_len + HASH_HEX_LEN) return Error.InvalidManifest;
    var out: FileValueView = .{
        .kind = kind,
        .content_type = value[2 .. 2 + ct_len],
        .source_hex = undefined,
    };
    @memcpy(&out.source_hex, value[2 + ct_len ..][0..HASH_HEX_LEN]);
    return out;
}

// Manifest binary format (version 2):
//   [u8 version=2]
//   [u32 count]
//   for each entry:
//     [u16 path_len][path bytes]
//     [u8 kind]
//     [u8 ct_len][ct bytes]
//     [64 source_hex][64 bytecode_hex]
//
// Little-endian. `bytecode_hex` is all-zero for static entries.
const MANIFEST_VERSION: u8 = 2;

fn serializeManifest(
    allocator: std.mem.Allocator,
    entries: []const FileStore.Entry,
) error{OutOfMemory}![]u8 {
    var total: usize = 1 + 4;
    for (entries) |e| {
        total += 2 + e.path.len + 1 + 1 + e.content_type.len + HASH_HEX_LEN * 2;
    }

    const out = try allocator.alloc(u8, total);
    var i: usize = 0;
    out[i] = MANIFEST_VERSION;
    i += 1;
    std.mem.writeInt(u32, out[i..][0..4], @intCast(entries.len), .little);
    i += 4;
    for (entries) |e| {
        std.mem.writeInt(u16, out[i..][0..2], @intCast(e.path.len), .little);
        i += 2;
        @memcpy(out[i..][0..e.path.len], e.path);
        i += e.path.len;
        out[i] = @intFromEnum(e.kind);
        i += 1;
        out[i] = @intCast(e.content_type.len);
        i += 1;
        @memcpy(out[i..][0..e.content_type.len], e.content_type);
        i += e.content_type.len;
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
    if (bytes.len < 5) return Error.InvalidManifest;
    var i: usize = 0;
    if (bytes[i] != MANIFEST_VERSION) return Error.InvalidManifest;
    i += 1;
    const count = std.mem.readInt(u32, bytes[i..][0..4], .little);
    i += 4;

    const out = allocator.alloc(FileStore.Entry, count) catch return Error.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |e| {
            allocator.free(e.path);
            allocator.free(e.content_type);
        }
        allocator.free(out);
    }

    while (filled < count) : (filled += 1) {
        if (i + 2 > bytes.len) return Error.InvalidManifest;
        const path_len = std.mem.readInt(u16, bytes[i..][0..2], .little);
        i += 2;
        if (i + path_len + 2 > bytes.len) return Error.InvalidManifest;

        const path = allocator.dupe(u8, bytes[i .. i + path_len]) catch
            return Error.OutOfMemory;
        errdefer allocator.free(path);
        i += path_len;

        const kind: Kind = switch (bytes[i]) {
            0 => .handler,
            1 => .static,
            else => return Error.InvalidManifest,
        };
        i += 1;
        const ct_len = bytes[i];
        i += 1;
        if (i + ct_len + HASH_HEX_LEN * 2 > bytes.len) return Error.InvalidManifest;
        const ct = allocator.dupe(u8, bytes[i .. i + ct_len]) catch
            return Error.OutOfMemory;
        i += ct_len;

        var src_hex: [HASH_HEX_LEN]u8 = undefined;
        @memcpy(&src_hex, bytes[i..][0..HASH_HEX_LEN]);
        i += HASH_HEX_LEN;
        var bc_hex: [HASH_HEX_LEN]u8 = undefined;
        @memcpy(&bc_hex, bytes[i..][0..HASH_HEX_LEN]);
        i += HASH_HEX_LEN;

        out[filled] = .{
            .path = path,
            .kind = kind,
            .content_type = ct,
            .source_hex = src_hex,
            .bytecode_hex = bc_hex,
        };
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

test "validatePath rejects uppercase, double-slash, percent-encoded slash" {
    try testing.expectError(Error.InvalidPath, validatePath("Foo.js"));
    try testing.expectError(Error.InvalidPath, validatePath("foo//bar"));
    try testing.expectError(Error.InvalidPath, validatePath("foo/%2fbar"));
    try testing.expectError(Error.InvalidPath, validatePath("foo/%2Fbar"));
    try testing.expectError(Error.InvalidPath, validatePath("foo bar"));
    try testing.expectError(Error.InvalidPath, validatePath("foo?bar"));
    // Leading underscore is reserved by policy at a higher layer, but
    // the core validator lets it through so it can form `_static/*` etc.
    try validatePath("_static/index.html");
    try validatePath("_code/_404/index.mjs");
}

test "putStatic stores raw bytes + content-type, no bytecode" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    var fs = fx.fileStore();

    const html = "<!doctype html><h1>hi</h1>";
    try fs.putStatic("_static/index.html", html, "text/html");

    const got = try fs.getSource("_static/index.html", testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(html, got);

    try testing.expectError(Error.NotFound, fs.getBytecode("_static/index.html", testing.allocator));

    var stat_e = try fs.stat("_static/index.html");
    defer stat_e.deinit();
    try testing.expectEqual(Kind.static, stat_e.kind);
    try testing.expectEqualStrings("text/html", stat_e.content_type);
}

test "deploy produces mixed handler + static manifest with content-types" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    var fs = fx.fileStore();

    try fs.putSource("index.mjs", "export default () => 42;");
    try fs.putStatic("_static/style.css", "body { color: red; }", "text/css");

    _ = try fs.deploy();
    var m = try fs.loadCurrentDeployment();
    defer m.deinit();
    try testing.expectEqual(@as(usize, 2), m.entries.len);

    // Entries sorted by key → "_static/style.css" then "index.mjs"
    // (underscore < lowercase letters in ASCII).
    try testing.expectEqualStrings("_static/style.css", m.entries[0].path);
    try testing.expectEqual(Kind.static, m.entries[0].kind);
    try testing.expectEqualStrings("text/css", m.entries[0].content_type);
    // Static bytecode hash is all-zero.
    const zeros: [HASH_HEX_LEN]u8 = @splat(0);
    try testing.expectEqualSlices(u8, &zeros, &m.entries[0].bytecode_hex);

    try testing.expectEqualStrings("index.mjs", m.entries[1].path);
    try testing.expectEqual(Kind.handler, m.entries[1].kind);
    try testing.expectEqualStrings("", m.entries[1].content_type);
}

test "serialize + parse manifest round-trip" {
    var entries = [_]FileStore.Entry{
        .{
            .path = @constCast("a.js"),
            .kind = .handler,
            .content_type = @constCast(""),
            .source_hex = [_]u8{'a'} ** HASH_HEX_LEN,
            .bytecode_hex = [_]u8{'1'} ** HASH_HEX_LEN,
        },
        .{
            .path = @constCast("_static/b.css"),
            .kind = .static,
            .content_type = @constCast("text/css"),
            .source_hex = [_]u8{'b'} ** HASH_HEX_LEN,
            .bytecode_hex = [_]u8{0} ** HASH_HEX_LEN,
        },
    };

    const bytes = try serializeManifest(testing.allocator, &entries);
    defer testing.allocator.free(bytes);

    const parsed = try parseManifest(testing.allocator, bytes);
    defer {
        for (parsed) |e| {
            testing.allocator.free(e.path);
            testing.allocator.free(e.content_type);
        }
        testing.allocator.free(parsed);
    }

    try testing.expectEqual(@as(usize, 2), parsed.len);
    try testing.expectEqualStrings("a.js", parsed[0].path);
    try testing.expectEqual(Kind.handler, parsed[0].kind);
    try testing.expectEqualStrings("", parsed[0].content_type);
    try testing.expectEqualStrings("_static/b.css", parsed[1].path);
    try testing.expectEqual(Kind.static, parsed[1].kind);
    try testing.expectEqualStrings("text/css", parsed[1].content_type);
    try testing.expectEqualSlices(u8, &entries[0].source_hex, &parsed[0].source_hex);
    try testing.expectEqualSlices(u8, &entries[1].bytecode_hex, &parsed[1].bytecode_hex);
}

test "parseManifest rejects wrong version + truncated input" {
    try testing.expectError(Error.InvalidManifest, parseManifest(testing.allocator, &[_]u8{}));
    // Version 1 is no longer accepted.
    try testing.expectError(
        Error.InvalidManifest,
        parseManifest(testing.allocator, &[_]u8{ 1, 0, 0, 0, 0 }),
    );
    // Version 2, count=5, but no entries follow.
    try testing.expectError(
        Error.InvalidManifest,
        parseManifest(testing.allocator, &[_]u8{ MANIFEST_VERSION, 5, 0, 0, 0 }),
    );
}
