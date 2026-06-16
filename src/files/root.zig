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
//!   `deployment/current`         → `{id}` (next-id counter; files-server
//!                                  local only — Phase 5.5(e) F2-storage
//!                                  retired files.db replication, so this
//!                                  is a per-node hint, not the runtime
//!                                  release pointer; see `manifest_json`
//!                                  for where deployments actually live)
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
//! 2. Files-server snapshots the working tree via `assembleManifest`,
//!    JSON-encodes the result via `manifest_json.encode`, and stores
//!    the bytes in a per-tenant `deployments/` BlobBackend (key shape
//!    `{dep_id:020d}.json`). `deployment/current` in files.db tracks
//!    the next-id counter.
//! 3. Worker reads `_deploy/current` from the tenant's app.db (set by
//!    the release POST and replicated via raft), then fetches the
//!    matching manifest object from the `deployments/` BlobBackend
//!    and resolves each entry's bytecode through the file-blobs
//!    BlobBackend.
//!
//! ## Compile hook
//!
//! rove-files is quickjs-agnostic — it takes a `CompileFn` at construction
//! time. `rove-files-server` wires in a function that owns a `rove-qjs`
//! `Runtime` + `Context` and calls `compileToBytecode`. Tests use a
//! pass-through hook that returns the source unchanged, which is enough
//! to exercise the index + blob plumbing without pulling in quickjs.

const std = @import("std");

const kv = @import("raft-kv");
const blob_mod = @import("rove-blob");

pub const KvStore = kv.KvStore;
pub const BlobStore = blob_mod.BlobStore;

pub const manifest_json = @import("manifest_json.zig");
pub const app_manifest = @import("app_manifest.zig");

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

    /// Phase 5.5(e) F2-storage retired the replicate writeset and
    /// envelope type 3 — files-server's working tree is local-only
    /// (per-node files.db not replicated). The runtime release
    /// signal travels through the customer's app.db
    /// (`_deploy/current`, replicated via envelope 0); manifests
    /// themselves live in a per-tenant `deployments/` BlobBackend
    /// shared between nodes via the same backend the file-blobs use.

    fn kvPut(self: *FileStore, key: []const u8, value: []const u8) Error!void {
        self.kv.put(key, value) catch return Error.Kv;
    }

    /// Content-addressed PUT (method form): delegates to the free
    /// `putBlobIfMissingTo` so the stateless `stageDeployment` path
    /// shares the exact skip-if-present + race-retry behaviour.
    fn putBlobIfMissing(self: *FileStore, key: []const u8, bytes: []const u8) Error!void {
        return putBlobIfMissingTo(self.blob, key, bytes);
    }

    fn kvDelete(self: *FileStore, key: []const u8) Error!void {
        self.kv.delete(key) catch |err| switch (err) {
            error.NotFound => {},
            else => return Error.Kv,
        };
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
        self.putBlobIfMissing(&src_hex, source) catch return Error.Blob;

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

        self.putBlobIfMissing(&src_hex, bytes) catch return Error.Blob;
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
        self.putBlobIfMissing(out_bc_hex, bytecode) catch return Error.Blob;
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

    /// In-memory manifest type — re-export from `manifest_json` so
    /// callers that received `FileStore.Manifest` from the old binary
    /// path keep compiling. Phase 5.5(e) F2-storage moved both encode
    /// and decode there; this alias exists only because the wire-format
    /// transition is still in flight in some call sites.
    pub const Manifest = manifest_json.Manifest;

    /// Walk the working tree (`file/*` rows + `bytecode/{source}`
    /// cache) and produce a fresh `[]Entry` snapshot. Caller owns the
    /// returned slice and the per-entry `path` / `content_type`
    /// allocations — `freeEntries` releases them. Phase 5.5(e)
    /// F2-storage moved manifest persistence out of FileStore: callers
    /// take this snapshot, JSON-encode it via `manifest_json.encode`,
    /// and store the bytes in a per-tenant `deployments/` BlobBackend.
    pub fn assembleManifest(self: *FileStore) Error![]Entry {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
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

        return entries.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
    }

    /// Free a slice produced by `assembleManifest`.
    pub fn freeEntries(self: *FileStore, entries: []Entry) void {
        for (entries) |e| {
            self.allocator.free(e.path);
            self.allocator.free(e.content_type);
        }
        self.allocator.free(entries);
    }

    /// Read `deployment/current` (hex u64). Returns 0 when no deploy
    /// has shipped yet. Used by files-server to compute the next
    /// deployment id; not used by the worker (worker reads
    /// `_deploy/current` from the tenant's app.db, replicated via
    /// raft envelope 0).
    pub fn currentDeploymentId(self: *FileStore) Error!u64 {
        const cur = self.kv.get("deployment/current") catch |err| switch (err) {
            error.NotFound => return 0,
            else => return Error.Kv,
        };
        defer self.allocator.free(cur);
        return std.fmt.parseInt(u64, cur, 16) catch return Error.InvalidManifest;
    }

    /// Stamp `deployment/current = id_hex` in the local files.db.
    /// Files-server-only — the manifest itself lives in the per-tenant
    /// `deployments/` BlobBackend, not in files.db.
    pub fn setCurrentDeploymentId(self: *FileStore, id: u64) Error!void {
        var id_hex_buf: [16]u8 = undefined;
        const id_hex = std.fmt.bufPrint(&id_hex_buf, "{x:0>16}", .{id}) catch unreachable;
        try self.kvPut("deployment/current", id_hex);
    }
};

// ── Stateless deploy (no working-tree kv) ──────────────────────────────

/// One file's bytes + metadata for a stateless deploy. The caller (the
/// worker's `/_system/deploy` handler) supplies the raw bytes; there is
/// no persistent working-tree index.
pub const DeployInput = struct {
    path: []const u8,
    kind: Kind,
    /// Content-type to stamp on a `.static` entry. Ignored for handlers
    /// (their wire type comes from the response object at serve time).
    content_type: []const u8 = "",
    /// Handler source (compiled here) or static content bytes.
    bytes: []const u8,
};

/// Stateless deploy: compile + content-address + stamp a manifest with
/// NO persistent working-tree kv (unlike `FileStore`, which keeps a
/// `file/` + `bytecode/` index). For each input, write its blob
/// content-addressed (skip-if-present); for handlers also compile to
/// bytecode and write that blob. Then compute the content-addressed
/// deployment id over the entry set, encode the manifest JSON, and write
/// it to `manifest_backend` at `manifest_json.manifestKey`. Returns the
/// dep_id. Does NOT flip `_deploy/current` — release is a separate,
/// raft-replicated step.
///
/// `blob` is the tenant's file-blobs backend (source + bytecode);
/// `manifest_backend` is the tenant's `deployments/` backend. Idempotent
/// at the storage layer: identical inputs → identical dep_id → PUTs land
/// on the same keys with identical bytes.
///
/// Bounded to 256 entries (matches `computeDeploymentId`). Rejects
/// invalid or duplicate paths so the manifest is unambiguous.
pub fn stageDeployment(
    allocator: std.mem.Allocator,
    blob: BlobStore,
    manifest_backend: BlobStore,
    compile: CompileFn,
    compile_ctx: ?*anyopaque,
    inputs: []const DeployInput,
) Error!u64 {
    if (inputs.len > 256) return Error.InvalidManifest;

    // Validate + reject duplicate paths up front.
    for (inputs, 0..) |in_a, i| {
        try validatePath(in_a.path);
        if (in_a.path.len > MAX_PATH_LEN) return Error.InvalidPath;
        if (in_a.kind == .static and in_a.content_type.len > MAX_CT_LEN)
            return Error.InvalidPath;
        for (inputs[0..i]) |in_b| {
            if (std.mem.eql(u8, in_a.path, in_b.path)) return Error.InvalidManifest;
        }
    }

    const entries = allocator.alloc(FileStore.Entry, inputs.len) catch return Error.OutOfMemory;
    defer allocator.free(entries);

    for (inputs, 0..) |in, i| {
        var src_hex: [HASH_HEX_LEN]u8 = undefined;
        hashHex(in.bytes, &src_hex);
        try putBlobIfMissingTo(blob, &src_hex, in.bytes);

        var bc_hex: [HASH_HEX_LEN]u8 = @splat(0);
        if (in.kind == .handler) {
            // Filename must be NUL-terminated for quickjs.
            var fname_buf: [MAX_PATH_LEN + 1]u8 = undefined;
            @memcpy(fname_buf[0..in.path.len], in.path);
            fname_buf[in.path.len] = 0;
            const fname: [:0]const u8 = fname_buf[0..in.path.len :0];

            const bytecode = compile(compile_ctx, in.bytes, fname, allocator) catch
                return Error.CompileFailed;
            defer allocator.free(bytecode);
            hashHex(bytecode, &bc_hex);
            try putBlobIfMissingTo(blob, &bc_hex, bytecode);
        }

        entries[i] = .{
            .path = @constCast(in.path),
            .kind = in.kind,
            .content_type = @constCast(if (in.kind == .static) in.content_type else ""),
            .source_hex = src_hex,
            .bytecode_hex = bc_hex,
        };
    }

    const dep_id = manifest_json.computeDeploymentId(entries);
    const manifest_bytes = manifest_json.encode(allocator, dep_id, entries) catch
        return Error.OutOfMemory;
    defer allocator.free(manifest_bytes);

    var key_buf: [25]u8 = undefined;
    const key = manifest_json.manifestKey(&key_buf, dep_id);
    try putBlobIfMissingTo(manifest_backend, key, manifest_bytes);

    return dep_id;
}

/// One compiled handler's content-addressed hashes (the result of
/// `compileAndStage`). `path` borrows the caller's input slice.
pub const CompiledFile = struct {
    path: []const u8,
    source_hex: [HASH_HEX_LEN]u8,
    bytecode_hex: [HASH_HEX_LEN]u8,
};

/// Batch-compile handler sources and content-address BOTH the source and
/// the bytecode blob into `blob` (the target tenant's file-blobs backend).
/// Returns one `CompiledFile` per input — the caller stamps the manifest
/// from these hashes (NO manifest is written here; that's the JS deploy
/// handler's job). This is the off-hot-path executor behind the
/// `platform.compile` primitive: compile is slow (so it runs on the
/// background `DeployThread`, not inline) but deterministic + idempotent
/// (so identical inputs → identical hashes → PUTs land on the same keys,
/// and replay needs no tape — it recomputes).
///
/// Every input is treated as a handler (compiled). Statics don't belong
/// here — the deploy handler stages those itself via a (cross-tenant)
/// `blob.put`. Bounded to 256 entries; rejects invalid/duplicate paths.
/// Caller owns the returned slice (free with the same allocator); each
/// `path` borrows the corresponding input.
pub fn compileAndStage(
    allocator: std.mem.Allocator,
    blob: BlobStore,
    compile: CompileFn,
    compile_ctx: ?*anyopaque,
    inputs: []const DeployInput,
) Error![]CompiledFile {
    if (inputs.len > 256) return Error.InvalidManifest;

    for (inputs, 0..) |in_a, i| {
        try validatePath(in_a.path);
        for (inputs[0..i]) |in_b| {
            if (std.mem.eql(u8, in_a.path, in_b.path)) return Error.InvalidManifest;
        }
    }

    const out = allocator.alloc(CompiledFile, inputs.len) catch return Error.OutOfMemory;
    errdefer allocator.free(out);

    for (inputs, 0..) |in, i| {
        var src_hex: [HASH_HEX_LEN]u8 = undefined;
        hashHex(in.bytes, &src_hex);
        try putBlobIfMissingTo(blob, &src_hex, in.bytes);

        // Filename must be NUL-terminated for quickjs.
        var fname_buf: [MAX_PATH_LEN + 1]u8 = undefined;
        @memcpy(fname_buf[0..in.path.len], in.path);
        fname_buf[in.path.len] = 0;
        const fname: [:0]const u8 = fname_buf[0..in.path.len :0];

        const bytecode = compile(compile_ctx, in.bytes, fname, allocator) catch
            return Error.CompileFailed;
        defer allocator.free(bytecode);

        var bc_hex: [HASH_HEX_LEN]u8 = undefined;
        hashHex(bytecode, &bc_hex);
        try putBlobIfMissingTo(blob, &bc_hex, bytecode);

        out[i] = .{ .path = in.path, .source_hex = src_hex, .bytecode_hex = bc_hex };
    }

    return out;
}

// ── Helpers ────────────────────────────────────────────────────────────

/// Content-addressed PUT: skip if the key already exists. Lets multiple
/// cluster nodes bootstrap the same shared S3 backend concurrently
/// without conflicting on PUT for identical bytes (some object stores
/// reject overlapping conditional writes for the same key — OVH OS in
/// particular). Retries up to ~1s on PUT errors so the loser of a race
/// waits for the winner's write to land + become visible via exists().
fn putBlobIfMissingTo(blob: BlobStore, key: []const u8, bytes: []const u8) Error!void {
    if (blob.exists(key) catch false) return;
    var attempt: u8 = 0;
    while (attempt < 6) : (attempt += 1) {
        blob.put(key, bytes) catch {
            // Exponential backoff (50ms, 100ms, … 800ms) then re-check;
            // identical content means whoever wins is fine.
            const delay_ms: u64 = @as(u64, 50) << @as(u6, @intCast(attempt));
            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
            if (blob.exists(key) catch false) return;
            continue;
        };
        return;
    }
    return Error.Blob;
}

fn hashHex(bytes: []const u8, out: *[HASH_HEX_LEN]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
}

/// True when `path` should be evaluated as an ES module (`.mjs`)
/// rather than a classic script (`.js` or anything else). Single
/// source of truth for the module/script choice — every JS compiler
/// hook in the tree (worker, files-server, dual-worker example) uses
/// this to set `qjs.EvalFlags.kind`.
pub fn isJsModule(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".mjs");
}

/// True when `path` is a JavaScript handler source file by extension
/// (`.mjs` or `.js`). Used by the deploy/upload paths to classify
/// uploads as `Kind.handler` and by file walkers (rove-files-cli) to
/// pick out compileable sources.
pub fn isJsSource(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".mjs") or
        std.mem.endsWith(u8, path, ".js");
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

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Test-only in-memory `BlobStore`. The vtable interface makes a
/// per-test stand-in cheap; production stores are S3-only and require
/// real bucket creds.
const MemBlobStore = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) MemBlobStore {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *MemBlobStore) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    fn blobStore(self: *MemBlobStore) blob_mod.BlobStore {
        return .{ .ptr = self, .vtable = &.{
            .put = vtPut,
            .get = vtGet,
            .exists = vtExists,
            .delete = vtDelete,
        } };
    }

    fn vtPut(ptr: *anyopaque, key: []const u8, bytes: []const u8) anyerror!void {
        const self: *MemBlobStore = @ptrCast(@alignCast(ptr));
        const v = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(v);
        const gop = try self.map.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
        }
        gop.value_ptr.* = v;
    }

    fn vtGet(ptr: *anyopaque, key: []const u8, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *MemBlobStore = @ptrCast(@alignCast(ptr));
        const v = self.map.get(key) orelse return blob_mod.Error.NotFound;
        return allocator.dupe(u8, v);
    }

    fn vtExists(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self: *MemBlobStore = @ptrCast(@alignCast(ptr));
        return self.map.contains(key);
    }

    fn vtDelete(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *MemBlobStore = @ptrCast(@alignCast(ptr));
        if (self.map.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
    }
};

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
    blob_store: MemBlobStore,

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

        return .{
            .allocator = allocator,
            .tmp_path = tmp_path,
            .kv = kvs,
            .blob_store = MemBlobStore.init(allocator),
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

test "assembleManifest produces an entry per file/* row" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    var code = fx.fileStore();

    try code.putSource("a.js", "A");
    try code.putSource("b.js", "B");
    try code.setCurrentDeploymentId(1);

    const entries = try code.assembleManifest();
    defer code.freeEntries(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("a.js", entries[0].path);
    try testing.expectEqualStrings("b.js", entries[1].path);
    try testing.expectEqual(@as(u64, 1), try code.currentDeploymentId());
}

test "currentDeploymentId returns 0 when no deploy yet" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    var code = fx.fileStore();
    try testing.expectEqual(@as(u64, 0), try code.currentDeploymentId());
}

test "setCurrentDeploymentId round-trips through currentDeploymentId" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    var code = fx.fileStore();
    try code.setCurrentDeploymentId(42);
    try testing.expectEqual(@as(u64, 42), try code.currentDeploymentId());
}

test "isJsModule: only .mjs is a module" {
    try testing.expect(isJsModule("a.mjs"));
    try testing.expect(isJsModule("nested/path/index.mjs"));
    try testing.expect(!isJsModule("a.js"));
    try testing.expect(!isJsModule("index.js"));
    try testing.expect(!isJsModule("a.html"));
    try testing.expect(!isJsModule("mjs")); // no leading dot
    try testing.expect(!isJsModule(""));
}

test "isJsSource: .mjs and .js" {
    try testing.expect(isJsSource("a.mjs"));
    try testing.expect(isJsSource("a.js"));
    try testing.expect(isJsSource("deep/index.mjs"));
    try testing.expect(isJsSource("deep/index.js"));
    try testing.expect(!isJsSource("a.html"));
    try testing.expect(!isJsSource("a.css"));
    try testing.expect(!isJsSource("ajs")); // no dot
    try testing.expect(!isJsSource(""));
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
    // the core validator lets it through so it can form `_static/*`,
    // `_404/*`, `_triggers/*`, etc.
    try validatePath("_static/index.html");
    try validatePath("_404/index.mjs");
    try validatePath("_triggers/audit.mjs");
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

test "assembleManifest produces mixed handler + static entries with content-types" {
    var fx = try TestFixture.init(testing.allocator);
    defer fx.deinit();
    var fs = fx.fileStore();

    try fs.putSource("index.mjs", "export default () => 42;");
    try fs.putStatic("_static/style.css", "body { color: red; }", "text/css");

    const entries = try fs.assembleManifest();
    defer fs.freeEntries(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);

    // Entries sorted by key → "_static/style.css" then "index.mjs"
    // (underscore < lowercase letters in ASCII).
    try testing.expectEqualStrings("_static/style.css", entries[0].path);
    try testing.expectEqual(Kind.static, entries[0].kind);
    try testing.expectEqualStrings("text/css", entries[0].content_type);
    const zeros: [HASH_HEX_LEN]u8 = @splat(0);
    try testing.expectEqualSlices(u8, &zeros, &entries[0].bytecode_hex);

    try testing.expectEqualStrings("index.mjs", entries[1].path);
    try testing.expectEqual(Kind.handler, entries[1].kind);
    try testing.expectEqualStrings("", entries[1].content_type);
}

test {
    _ = manifest_json;
    _ = app_manifest;
}

// ── stageDeployment (stateless deploy) tests ───────────────────────────

test "stageDeployment: stages handler + static, writes manifest, content-addressed id" {
    const a = testing.allocator;
    var blob = MemBlobStore.init(a);
    defer blob.deinit();
    var mani = MemBlobStore.init(a);
    defer mani.deinit();

    const inputs = [_]DeployInput{
        .{ .path = "index.mjs", .kind = .handler, .bytes = "export default () => 1;" },
        .{ .path = "_static/x.html", .kind = .static, .content_type = "text/html; charset=utf-8", .bytes = "<h1>hi</h1>" },
    };
    const dep_id = try stageDeployment(a, blob.blobStore(), mani.blobStore(), passthroughCompile, null, &inputs);

    // Manifest written + decodes to our two entries (input order preserved).
    var key_buf: [25]u8 = undefined;
    const key = manifest_json.manifestKey(&key_buf, dep_id);
    const mbytes = try mani.blobStore().get(key, a);
    defer a.free(mbytes);
    var m = try manifest_json.decode(a, mbytes);
    defer m.deinit();
    try testing.expectEqual(dep_id, m.id);
    try testing.expectEqual(@as(usize, 2), m.entries.len);
    try testing.expectEqualStrings("index.mjs", m.entries[0].path);
    try testing.expectEqual(Kind.handler, m.entries[0].kind);
    try testing.expectEqualStrings("_static/x.html", m.entries[1].path);
    try testing.expectEqual(Kind.static, m.entries[1].kind);
    try testing.expectEqualStrings("text/html; charset=utf-8", m.entries[1].content_type);

    // Source blobs present for both; bytecode blob present only for the handler.
    try testing.expect(try blob.blobStore().exists(&m.entries[0].source_hex));
    try testing.expect(try blob.blobStore().exists(&m.entries[0].bytecode_hex));
    try testing.expect(try blob.blobStore().exists(&m.entries[1].source_hex));
    const zero: [HASH_HEX_LEN]u8 = @splat(0);
    try testing.expectEqualSlices(u8, &zero, &m.entries[1].bytecode_hex);
}

test "stageDeployment: idempotent — identical inputs yield the same dep_id" {
    const a = testing.allocator;
    var b = MemBlobStore.init(a);
    defer b.deinit();
    var m = MemBlobStore.init(a);
    defer m.deinit();
    const inputs = [_]DeployInput{.{ .path = "index.mjs", .kind = .handler, .bytes = "x" }};
    const id1 = try stageDeployment(a, b.blobStore(), m.blobStore(), passthroughCompile, null, &inputs);
    const id2 = try stageDeployment(a, b.blobStore(), m.blobStore(), passthroughCompile, null, &inputs);
    try testing.expectEqual(id1, id2);
}

test "stageDeployment: different content yields a different dep_id" {
    const a = testing.allocator;
    var b = MemBlobStore.init(a);
    defer b.deinit();
    var m = MemBlobStore.init(a);
    defer m.deinit();
    const in_a = [_]DeployInput{.{ .path = "index.mjs", .kind = .handler, .bytes = "one" }};
    const in_b = [_]DeployInput{.{ .path = "index.mjs", .kind = .handler, .bytes = "two" }};
    const id_a = try stageDeployment(a, b.blobStore(), m.blobStore(), passthroughCompile, null, &in_a);
    const id_b = try stageDeployment(a, b.blobStore(), m.blobStore(), passthroughCompile, null, &in_b);
    try testing.expect(id_a != id_b);
}

test "stageDeployment: compile failure surfaces as CompileFailed" {
    const a = testing.allocator;
    var b = MemBlobStore.init(a);
    defer b.deinit();
    var m = MemBlobStore.init(a);
    defer m.deinit();
    const inputs = [_]DeployInput{.{ .path = "bad.mjs", .kind = .handler, .bytes = "syntax(" }};
    try testing.expectError(Error.CompileFailed, stageDeployment(a, b.blobStore(), m.blobStore(), failingCompile, null, &inputs));
}

test "stageDeployment: rejects duplicate paths" {
    const a = testing.allocator;
    var b = MemBlobStore.init(a);
    defer b.deinit();
    var m = MemBlobStore.init(a);
    defer m.deinit();
    const inputs = [_]DeployInput{
        .{ .path = "index.mjs", .kind = .handler, .bytes = "a" },
        .{ .path = "index.mjs", .kind = .handler, .bytes = "b" },
    };
    try testing.expectError(Error.InvalidManifest, stageDeployment(a, b.blobStore(), m.blobStore(), passthroughCompile, null, &inputs));
}

test "stageDeployment: rejects path traversal" {
    const a = testing.allocator;
    var b = MemBlobStore.init(a);
    defer b.deinit();
    var m = MemBlobStore.init(a);
    defer m.deinit();
    const inputs = [_]DeployInput{.{ .path = "../etc/passwd", .kind = .static, .bytes = "x" }};
    try testing.expectError(Error.InvalidPath, stageDeployment(a, b.blobStore(), m.blobStore(), passthroughCompile, null, &inputs));
}

// ── compileAndStage (batch compile → per-file hashes) tests ────────────

test "compileAndStage: stages source + bytecode blobs, returns hashes" {
    const a = testing.allocator;
    var blob = MemBlobStore.init(a);
    defer blob.deinit();

    const inputs = [_]DeployInput{
        .{ .path = "index.mjs", .kind = .handler, .bytes = "export default () => 1;" },
        .{ .path = "api/index.mjs", .kind = .handler, .bytes = "export default () => 2;" },
    };
    const out = try compileAndStage(a, blob.blobStore(), passthroughCompile, null, &inputs);
    defer a.free(out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("index.mjs", out[0].path);
    try testing.expectEqualStrings("api/index.mjs", out[1].path);
    // Both the source AND bytecode blobs landed for every handler.
    for (out) |cf| {
        try testing.expect(try blob.blobStore().exists(&cf.source_hex));
        try testing.expect(try blob.blobStore().exists(&cf.bytecode_hex));
    }
    // Distinct sources → distinct source hashes (and distinct bytecode).
    try testing.expect(!std.mem.eql(u8, &out[0].source_hex, &out[1].source_hex));
    try testing.expect(!std.mem.eql(u8, &out[0].bytecode_hex, &out[1].bytecode_hex));
}

test "compileAndStage: idempotent — identical inputs yield identical hashes" {
    const a = testing.allocator;
    var blob = MemBlobStore.init(a);
    defer blob.deinit();
    const inputs = [_]DeployInput{.{ .path = "index.mjs", .kind = .handler, .bytes = "x" }};

    const o1 = try compileAndStage(a, blob.blobStore(), passthroughCompile, null, &inputs);
    defer a.free(o1);
    const o2 = try compileAndStage(a, blob.blobStore(), passthroughCompile, null, &inputs);
    defer a.free(o2);
    try testing.expectEqualSlices(u8, &o1[0].source_hex, &o2[0].source_hex);
    try testing.expectEqualSlices(u8, &o1[0].bytecode_hex, &o2[0].bytecode_hex);
}

test "compileAndStage: compile failure surfaces as CompileFailed" {
    const a = testing.allocator;
    var blob = MemBlobStore.init(a);
    defer blob.deinit();
    const inputs = [_]DeployInput{.{ .path = "bad.mjs", .kind = .handler, .bytes = "syntax(" }};
    try testing.expectError(Error.CompileFailed, compileAndStage(a, blob.blobStore(), failingCompile, null, &inputs));
}

test "compileAndStage: rejects duplicate + traversal paths" {
    const a = testing.allocator;
    var blob = MemBlobStore.init(a);
    defer blob.deinit();
    const dup = [_]DeployInput{
        .{ .path = "index.mjs", .kind = .handler, .bytes = "a" },
        .{ .path = "index.mjs", .kind = .handler, .bytes = "b" },
    };
    try testing.expectError(Error.InvalidManifest, compileAndStage(a, blob.blobStore(), passthroughCompile, null, &dup));
    const bad = [_]DeployInput{.{ .path = "../x.mjs", .kind = .handler, .bytes = "a" }};
    try testing.expectError(Error.InvalidPath, compileAndStage(a, blob.blobStore(), passthroughCompile, null, &bad));
}
