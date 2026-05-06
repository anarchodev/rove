//! rove-files-server — per-instance file/deploy operations, designed
//! to run off the worker's h2 thread.
//!
//! ## Why this module exists
//!
//! Compile is the only part of the request-serving path that's
//! meaningfully expensive: a 20 KB `.mjs` takes ~5-20 ms to compile
//! with quickjs-ng. That's the entire per-request wall-clock budget
//! blown before a byte of user code runs. We can't put deploy behind
//! the penalty box — deploy is legitimately heavy, and it's initiated
//! by operators, not request handlers.
//!
//! The solution is an "infrastructure plane" subsystem: a separate
//! thread (later, possibly a separate process) that owns all the
//! compile + file-store I/O, so the h2 thread only handles
//! HTTP/2 framing + forwarding. In the MVP everything runs in the
//! same process; the worker calls this module via a thin proxy layer
//! whose wire contract is `/_system/files/{instance_id}/{op}`.
//!
//! ## What this module is (today)
//!
//! Just the operation functions. No thread, no h2, no socket. Each
//! function opens its own per-instance `{data_dir}/{instance_id}/
//! {files.db, file-blobs/}` pair, does one operation, and closes. This
//! keeps the module trivially testable in isolation — later slices
//! wrap these in a job queue + thread, then in an h2 server listening
//! on a loopback socket.
//!
//! ## Interaction with running workers
//!
//! SQLite opens with NOMUTEX, meaning one connection per thread. The
//! worker already holds long-running connections to `{files.db,
//! file-blobs/}` via its `TenantFiles` cache. When this module opens
//! a second connection on a different thread:
//!
//!   - Reads are always safe (WAL).
//!   - Writes (upload, deploy) are serialized by SQLite's internal
//!     database-level lock; the worker's `refreshDeployments` poll
//!     observes the new `deployment/current` on its next tick and
//!     reloads the bytecode map.
//!
//! There's a small window after a deploy where the worker is still
//! serving the old deployment. That's acceptable — deployments aren't
//! request-latency-critical and the stale window is bounded by the
//! refresh interval (2 s default).

const std = @import("std");
const kv_mod = @import("rove-kv");
const blob_mod = @import("rove-blob");
const files_mod = @import("rove-files");
const qjs = @import("rove-qjs");

pub const thread = @import("thread.zig");

pub const Error = error{
    InvalidInstanceId,
    InvalidPath,
    OutOfMemory,
    Io,
    CompileFailed,
    Kv,
    Blob,
    NotFound,
    InvalidManifest,
    CasConflict,
};

/// Maximum length for an instance id. Matches what the worker enforces
/// elsewhere — keeps path construction bounded.
pub const MAX_INSTANCE_ID_LEN: usize = 128;

fn validateInstanceId(id: []const u8) Error!void {
    if (id.len == 0 or id.len > MAX_INSTANCE_ID_LEN) return Error.InvalidInstanceId;
    for (id) |b| {
        const ok = (b >= 'a' and b <= 'z') or
            (b >= 'A' and b <= 'Z') or
            (b >= '0' and b <= '9') or
            b == '-' or b == '_';
        if (!ok) return Error.InvalidInstanceId;
    }
}

/// Helper context that owns per-call store handles. The CALLER must
/// allocate this on its own stack (NOT via struct-return from a
/// function), because `files_mod.FileStore` stores a `BlobStore`
/// vtable that points at `&self.blob_backend` — moving the struct
/// would leave that pointer dangling.
const InstanceCtx = struct {
    allocator: std.mem.Allocator,
    files_kv: *kv_mod.KvStore,
    blob_backend: blob_mod.BlobBackend,
    store: files_mod.FileStore,

    /// In-place construction. Must be called on a stack-local
    /// `InstanceCtx` — see struct doc for why.
    fn init(
        self: *InstanceCtx,
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        blob_cfg: blob_mod.BackendConfig,
        instance_id: []const u8,
        compile: files_mod.CompileFn,
        compile_ctx: ?*anyopaque,
    ) Error!void {
        try validateInstanceId(instance_id);

        // Make sure the instance directory exists. The tenant bootstrap
        // normally does this, but this module may be asked to upload
        // into an instance that was created moments ago — don't fail
        // just because the fs layer is slightly behind.
        const inst_dir = std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ data_dir, instance_id },
        ) catch return Error.OutOfMemory;
        defer allocator.free(inst_dir);
        std.fs.cwd().makePath(inst_dir) catch return Error.Io;

        const files_db_path = std.fmt.allocPrintSentinel(
            allocator,
            "{s}/{s}/files.db",
            .{ data_dir, instance_id },
            0,
        ) catch return Error.OutOfMemory;
        defer allocator.free(files_db_path);

        const files_blob_dir = std.fmt.allocPrint(
            allocator,
            "{s}/{s}/file-blobs",
            .{ data_dir, instance_id },
        ) catch return Error.OutOfMemory;
        defer allocator.free(files_blob_dir);

        self.allocator = allocator;
        self.files_kv = kv_mod.KvStore.open(allocator, files_db_path) catch
            return Error.Kv;
        errdefer self.files_kv.close();

        self.blob_backend = blob_mod.BlobBackend.openPerTenant(
            allocator,
            blob_cfg,
            files_blob_dir,
            instance_id,
            "file-blobs",
        ) catch return Error.Blob;
        errdefer self.blob_backend.deinit();

        // Take the BlobStore vtable ONLY AFTER `self.blob_backend` is
        // at its final address (inside `self`). That's the whole reason
        // this struct uses in-place init instead of return-by-value.
        self.store = files_mod.FileStore.init(
            allocator,
            self.files_kv,
            self.blob_backend.blobStore(),
            compile,
            compile_ctx,
        );
    }

    fn deinit(self: *InstanceCtx) void {
        self.blob_backend.deinit();
        self.files_kv.close();
    }
};

/// Inline qjs compiler used by `upload`. A fresh runtime+context per
/// call is correct but wasteful; the eventual thread pool will keep
/// one alive per worker thread. Matches the compile-hook pattern used
/// elsewhere in the codebase.
/// Per-deploy compile context. Owns one QJS runtime + context for the
/// whole deploy so cross-file module imports resolve through the same
/// module cache. The caller populates `path_sources` (path → raw
/// source bytes) before invoking `compile`; the QJS module loader
/// installed at init reads from this map to resolve sibling imports
/// at compile time.
///
/// Init-in-place (`init(self, alloc)`) instead of returning by value:
/// the loader's opaque pointer is `&self`, which must be stable for
/// the lifetime of the runtime. A return-by-value init would make
/// that pointer dangling on return.
const InlineCompiler = struct {
    runtime: qjs.Runtime,
    context: qjs.Context,
    /// Path → source bytes for the current deploy. Populated by
    /// `deployManifest` before any compile call. Slices are borrowed —
    /// caller keeps the underlying buffers alive until `deinit`.
    path_sources: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Reserved for `compileLoad` to allocate its NUL-terminated
    /// source buffer when QJS calls back into Zig. Not used elsewhere.
    loader_allocator: std.mem.Allocator,

    fn init(self: *InlineCompiler, allocator: std.mem.Allocator) Error!void {
        self.runtime = qjs.Runtime.init() catch return Error.OutOfMemory;
        errdefer self.runtime.deinit();
        self.context = self.runtime.newContext() catch return Error.OutOfMemory;
        errdefer self.context.deinit();
        self.path_sources = .empty;
        self.loader_allocator = allocator;
        // Install the module loader. Passing NULL for the normalize
        // hook lets QJS use its default `./` and `../` resolver, which
        // matches the canonical-path key shape rove's runtime loader
        // produces (`lib/foo` for `./lib/foo` from `index.mjs`).
        qjs.c.JS_SetModuleLoaderFunc(
            self.runtime.raw,
            null,
            compileLoad,
            self,
        );
    }

    fn deinit(self: *InlineCompiler) void {
        self.path_sources.deinit(self.loader_allocator);
        self.context.deinit();
        self.runtime.deinit();
    }

    /// Register `source` (borrowed) under `path` so cross-module
    /// imports referencing `path` can resolve during compile. Caller
    /// keeps the source bytes alive until `deinit`.
    fn putSource(self: *InlineCompiler, path: []const u8, source: []const u8) Error!void {
        self.path_sources.put(self.loader_allocator, path, source) catch return Error.OutOfMemory;
    }

    fn compile(
        ctx_opaque: ?*anyopaque,
        source: []const u8,
        filename: [:0]const u8,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *InlineCompiler = @ptrCast(@alignCast(ctx_opaque.?));
        const flags: qjs.EvalFlags = if (files_mod.isJsModule(filename))
            .{ .kind = .module }
        else
            .{};
        return self.context.compileToBytecode(source, filename, allocator, flags);
    }

    /// QJS module loader callback for the compile pass. Looks up the
    /// resolved path in `path_sources`, runs `JS_Eval` with
    /// `COMPILE_ONLY | TYPE_MODULE` to produce a module def QJS can
    /// link the importing module against. Cross-module compile errors
    /// surface back through the original `compileToBytecode` call as
    /// a QJS exception.
    fn compileLoad(
        ctx: ?*qjs.c.JSContext,
        name: [*c]const u8,
        opaque_ptr: ?*anyopaque,
    ) callconv(.c) ?*qjs.c.JSModuleDef {
        const self: *InlineCompiler = @ptrCast(@alignCast(opaque_ptr.?));
        const name_s = std.mem.span(name);
        const src = self.path_sources.get(name_s) orelse return null;

        const src_z = self.loader_allocator.allocSentinel(u8, src.len, 0) catch return null;
        defer self.loader_allocator.free(src_z);
        @memcpy(src_z, src);

        const flags = qjs.c.JS_EVAL_TYPE_MODULE | qjs.c.JS_EVAL_FLAG_COMPILE_ONLY;
        const fun_obj = qjs.c.JS_Eval(ctx, src_z.ptr, src.len, name, flags);
        if (qjs.c.JS_IsException(fun_obj)) return null;
        if (fun_obj.tag != qjs.c.JS_TAG_MODULE) {
            qjs.c.JS_FreeValue(ctx, fun_obj);
            return null;
        }
        const mod_def: ?*qjs.c.JSModuleDef = @ptrCast(@alignCast(fun_obj.u.ptr));
        // JS_Eval returned a held module value; QJS expects the
        // loader to return the module def directly (it owns its own
        // references). Drop the JSValue handle.
        qjs.c.JS_FreeValue(ctx, fun_obj);
        return mod_def;
    }
};


/// Hex string length for a SHA-256 digest. Callers of `putBlobByHash`
/// and `checkBlobs` must present claimed hashes as exactly this many
/// lowercase hex characters.
pub const HASH_HEX_LEN: usize = files_mod.HASH_HEX_LEN;

/// Returned by `checkBlobs`. For each input hash we report whether
/// the store already has it; `missing` is the subset the caller still
/// needs to upload. Owned by `allocator` passed in; free via `deinit`.
pub const CheckResult = struct {
    missing: [][]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CheckResult) void {
        for (self.missing) |h| self.allocator.free(h);
        self.allocator.free(self.missing);
        self.* = undefined;
    }
};

/// First leg of the content-addressed deploy protocol: given a list
/// of claimed hashes, tell the client which ones the blob store
/// doesn't have yet so it knows what to upload. Empty `missing` means
/// the client can skip straight to committing the manifest.
///
/// No files.db writes, so no raft propagation needed.
pub fn checkBlobs(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    instance_id: []const u8,
    hashes: []const []const u8,
) Error!CheckResult {
    var h: InstanceCtx = undefined;
    try h.init(allocator, data_dir, blob_cfg, instance_id, stubCompile, null);
    defer h.deinit();

    var list: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }

    for (hashes) |hash| {
        if (!isSha256Hex(hash)) return Error.InvalidManifest;
        const present = h.blob_backend.blobStore().exists(hash) catch return Error.Blob;
        if (present) continue;
        const copy = allocator.dupe(u8, hash) catch return Error.OutOfMemory;
        errdefer allocator.free(copy);
        list.append(allocator, copy) catch return Error.OutOfMemory;
    }

    const owned = list.toOwnedSlice(allocator) catch return Error.OutOfMemory;
    return .{ .missing = owned, .allocator = allocator };
}

/// Second leg: the client PUTs raw bytes keyed by their SHA-256.
/// We hash the incoming bytes server-side and reject mismatch. This
/// is the trust boundary — once we've verified, the blob is
/// content-addressed and immutable; re-uploading identical bytes is a
/// no-op. No files.db writes; no raft hop.
pub fn putBlobByHash(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    instance_id: []const u8,
    claimed_hash: []const u8,
    bytes: []const u8,
) Error!void {
    if (!isSha256Hex(claimed_hash)) return Error.InvalidManifest;

    var actual: [HASH_HEX_LEN]u8 = undefined;
    sha256Hex(bytes, &actual);
    if (!std.mem.eql(u8, claimed_hash, &actual)) return Error.InvalidManifest;

    var h: InstanceCtx = undefined;
    try h.init(allocator, data_dir, blob_cfg, instance_id, stubCompile, null);
    defer h.deinit();

    h.blob_backend.blobStore().put(claimed_hash, bytes) catch return Error.Blob;
}

/// Lowercase-hex SHA-256 of `bytes`, into a 64-char buffer.
fn sha256Hex(bytes: []const u8, out: *[HASH_HEX_LEN]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

fn isSha256Hex(s: []const u8) bool {
    if (s.len != HASH_HEX_LEN) return false;
    for (s) |b| {
        const ok = (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f');
        if (!ok) return false;
    }
    return true;
}

/// Entry for `deployManifest`: one row in the incoming manifest,
/// referencing a blob by its content hash. `content_type` is
/// ignored for handlers (they always compile) and falls back to
/// the empty string when absent for statics.
pub const DeployEntry = struct {
    path: []const u8,
    hash: []const u8,
    kind: files_mod.Kind,
    content_type: []const u8 = "",
};

/// Returned by `deployManifest`. Carries the new deployment id and
/// the parent id it was based on (0 if this is the first). The
/// caller builds the HTTP response from these.
pub const DeployResult = struct {
    id: u64,
    parent_id: u64,
};

/// Third leg of the content-addressed deploy protocol: stamp a
/// manifest from client-provided (path, hash, kind, content_type)
/// entries. Blobs must already be in the BlobStore (uploaded via
/// `PUT /blobs/{hash}` in leg 2). Handlers get compiled server-side
/// — we fetch the source from the BlobStore, compile, and stamp
/// `bytecode/{src_hash}` alongside `file/{path}`.
///
/// Bulk deploys are always a full replacement of the working tree.
/// Old `file/*` entries not in the request are dropped. If you
/// want to update one file, send the full manifest with that file
/// changed — or use the single-file `putFileAndDeploy` convenience.
///
/// `expected_parent_id`:
///   - non-null  → CAS: require `deployment/current` (the local
///     next-id counter) to equal this value (0 means "no deployment
///     yet"). Rejects with `Error.CasConflict` if the tree has moved.
///   - null      → skip the check (client doesn't care about
///     concurrent deploys).
pub fn deployManifest(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    instance_id: []const u8,
    entries: []const DeployEntry,
    expected_parent_id: ?u64,
) Error!DeployResult {
    var compiler: InlineCompiler = undefined;
    try compiler.init(allocator);
    defer compiler.deinit();

    var h: InstanceCtx = undefined;
    try h.init(allocator, data_dir, blob_cfg, instance_id, InlineCompiler.compile, &compiler);
    defer h.deinit();

    // ── CAS check: read current deployment pointer BEFORE any write.
    //
    // `deployment/current` is files-server's local next-id counter
    // (NOT the runtime release pointer — that lives in the customer's
    // app.db at `_deploy/current`). For deploy CAS we want "did the
    // client base its parent_id on the same upload-tree we're about
    // to mutate?", so the local counter is the right comparison.
    const current_parsed: u64 = h.store.currentDeploymentId() catch |err|
        return mapCodeError(err);
    if (expected_parent_id) |want| {
        if (want != current_parsed) return Error.CasConflict;
    }

    // ── Full-replace: drop any existing file/* entries so paths
    // removed from the manifest actually disappear from the new
    // deployment. Bytecode cache entries stay — they're
    // content-addressed and may be reused by a later deploy.
    h.store.clearFileEntries() catch |err| return mapCodeError(err);

    // ── Pre-fetch all handler sources into the compile context so
    // cross-module imports can resolve at compile time. Without this
    // step a handler with `import "./lib/foo.mjs"` fails to compile
    // because QJS's module loader has no way to find the sibling
    // source. The fetched buffers are owned here and live until end
    // of deploy (compiler.deinit drops the registry; we free the
    // bytes ourselves). The double-fetch (here + inside
    // putSourceByHash below) is wasteful but limited to deploy-time
    // and bounded by the per-file 64 KB cap.
    var owned_sources: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_sources.items) |b| allocator.free(b);
        owned_sources.deinit(allocator);
    }
    for (entries) |entry| {
        if (entry.kind != .handler) continue;
        const src = h.store.blob.get(entry.hash, allocator) catch |err| switch (err) {
            error.NotFound => return Error.NotFound,
            else => return Error.Blob,
        };
        owned_sources.append(allocator, src) catch return Error.OutOfMemory;
        compiler.putSource(entry.path, src) catch return Error.OutOfMemory;
    }

    // ── Stamp each entry. putSourceByHash fetches the source blob
    // and compiles; putStaticByHash just verifies the blob is
    // present and stamps the index.
    for (entries) |entry| {
        switch (entry.kind) {
            .handler => h.store.putSourceByHash(entry.path, entry.hash) catch |err|
                return mapCodeError(err),
            .static => h.store.putStaticByHash(entry.path, entry.hash, entry.content_type) catch |err|
                return mapCodeError(err),
        }
    }

    const next_id = try writeManifestFromWorkingTree(allocator, &h, data_dir, blob_cfg, instance_id, current_parsed);
    return .{ .id = next_id, .parent_id = current_parsed };
}

/// Snapshot the working tree, JSON-encode it as the manifest for
/// `current + 1`, write it to the per-tenant `deployments/`
/// BlobBackend, and bump the local next-id counter. Returns the
/// new deployment id.
///
/// Caller must have already mutated the working tree (clearFileEntries
/// + putSourceByHash / putStaticByHash) and verified CAS. This helper
/// exists so the deploy paths share the manifest-write tail.
fn writeManifestFromWorkingTree(
    allocator: std.mem.Allocator,
    h: *InstanceCtx,
    data_dir: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    instance_id: []const u8,
    current_id: u64,
) Error!u64 {
    const next_id = current_id + 1;

    const entries = h.store.assembleManifest() catch |err| return mapCodeError(err);
    defer h.store.freeEntries(entries);

    const json_bytes = files_mod.manifest_json.encode(allocator, next_id, entries) catch
        return Error.OutOfMemory;
    defer allocator.free(json_bytes);

    var manifest_be = openManifestBackend(allocator, data_dir, blob_cfg, instance_id) catch
        return Error.Blob;
    defer manifest_be.deinit();

    var key_buf: [25]u8 = undefined;
    const key = files_mod.manifest_json.manifestKey(&key_buf, next_id);
    manifest_be.blobStore().put(key, json_bytes) catch return Error.Blob;

    h.store.setCurrentDeploymentId(next_id) catch |err| return mapCodeError(err);
    return next_id;
}

/// Open a per-tenant BlobBackend for manifest objects (subdir
/// `deployments`). Caller frees with `deinit`. Wires through the
/// same `BackendConfig` as the file-blobs backend so leader and
/// followers see identical keys (fs: `{data_dir}/{id}/deployments/`,
/// s3: `{base}{id}/deployments/`).
fn openManifestBackend(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    instance_id: []const u8,
) !blob_mod.BlobBackend {
    const fs_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/deployments",
        .{ data_dir, instance_id },
    );
    defer allocator.free(fs_dir);
    return blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        fs_dir,
        instance_id,
        "deployments",
    );
}

/// Upload a single source file into the tenant's working tree.
/// Compiles the source, stores the source+bytecode blobs, updates the
/// `file/{path}` index entry. Idempotent — re-uploading identical
/// bytes is a no-op beyond restamping the index.
pub fn uploadFile(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    instance_id: []const u8,
    path: []const u8,
    source: []const u8,
) Error!void {
    var compiler: InlineCompiler = undefined;
    try compiler.init(allocator);
    defer compiler.deinit();

    var h: InstanceCtx = undefined;
    try h.init(allocator, data_dir, blob_cfg, instance_id, InlineCompiler.compile, &compiler);
    defer h.deinit();

    h.store.putSource(path, source) catch |err| return mapCodeError(err);
}

/// Upload a static file — raw bytes at `path`, stored under its stored
/// content-type. Unlike `uploadFile`, there's no compile step: static
/// assets are served verbatim.
pub fn uploadStatic(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    instance_id: []const u8,
    path: []const u8,
    bytes: []const u8,
    content_type: []const u8,
) Error!void {
    var h: InstanceCtx = undefined;
    try h.init(allocator, data_dir, blob_cfg, instance_id, stubCompile, null);
    defer h.deinit();

    h.store.putStatic(path, bytes, content_type) catch |err| return mapCodeError(err);
}

/// Upload-and-deploy an admin single-file write. Infers kind from the
/// path and commits a fresh deployment in the same call. Returns the
/// new deployment id.
///
/// Kind rules:
///   - `_static/<path>`            → static (raw bytes, served verbatim)
///   - top-level `<path>.mjs`/`.js` → handler (compiled to bytecode)
///   - anything else               → `Error.InvalidPath`
///
/// `_static/` wins over the extension check, so a file like
/// `_static/foo.mjs` is served as bytes — the customer chose to put it
/// under the static prefix.
pub fn putFileAndDeploy(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    instance_id: []const u8,
    path: []const u8,
    body: []const u8,
    content_type: []const u8,
) Error!u64 {
    const kind: files_mod.Kind = blk: {
        if (std.mem.startsWith(u8, path, "_static/")) break :blk .static;
        if (files_mod.isJsSource(path)) break :blk .handler;
        return Error.InvalidPath;
    };

    if (kind == .handler) {
        var compiler: InlineCompiler = undefined;
        try compiler.init(allocator);
        defer compiler.deinit();
        var h: InstanceCtx = undefined;
        try h.init(allocator, data_dir, blob_cfg, instance_id, InlineCompiler.compile, &compiler);
        defer h.deinit();
        h.store.putSource(path, body) catch |err| return mapCodeError(err);
        const cur = h.store.currentDeploymentId() catch |err| return mapCodeError(err);
        return writeManifestFromWorkingTree(allocator, &h, data_dir, blob_cfg, instance_id, cur);
    } else {
        var h: InstanceCtx = undefined;
        try h.init(allocator, data_dir, blob_cfg, instance_id, stubCompile, null);
        defer h.deinit();
        h.store.putStatic(path, body, content_type) catch |err| return mapCodeError(err);
        const cur = h.store.currentDeploymentId() catch |err| return mapCodeError(err);
        return writeManifestFromWorkingTree(allocator, &h, data_dir, blob_cfg, instance_id, cur);
    }
}

/// Snapshot the current working tree into a new deployment manifest
/// and bump the local next-id counter. Returns the new deployment id.
/// The manifest lands in the per-tenant `deployments/` BlobBackend;
/// activating it on the worker is a separate `/_system/release` call.
pub fn deploy(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    instance_id: []const u8,
) Error!u64 {
    // Deploy doesn't actually compile, but FileStore.init demands a
    // non-null compile hook. Give it a stub that errors out — if it
    // ever gets called during deploy, something's wrong.
    var h: InstanceCtx = undefined;
    try h.init(allocator, data_dir, blob_cfg, instance_id, stubCompile, null);
    defer h.deinit();

    const cur = h.store.currentDeploymentId() catch |err| return mapCodeError(err);
    return writeManifestFromWorkingTree(allocator, &h, data_dir, blob_cfg, instance_id, cur);
}

/// Fetch a source blob by its content hash. Read-only — used by the
/// bundle/replay path where the browser asks for the JS source
/// corresponding to a deployment entry.
pub fn getSourceByHash(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    instance_id: []const u8,
    source_hash_hex: []const u8,
) Error![]u8 {
    try validateInstanceId(instance_id);

    const files_blob_dir = std.fmt.allocPrint(
        allocator,
        "{s}/{s}/file-blobs",
        .{ data_dir, instance_id },
    ) catch return Error.OutOfMemory;
    defer allocator.free(files_blob_dir);

    var blob_backend = blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        files_blob_dir,
        instance_id,
        "file-blobs",
    ) catch return Error.Blob;
    defer blob_backend.deinit();

    return blob_backend.blobStore().get(source_hash_hex, allocator) catch
        Error.NotFound;
}

/// Load a deployment's manifest (list of entries with source + bytecode
/// hashes). Read-only. Used by the bundle/replay path to enumerate the
/// files the browser may need to fetch. Reads JSON from the per-tenant
/// `deployments/` BlobBackend.
pub fn loadDeployment(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    instance_id: []const u8,
    deployment_id: u64,
) Error!files_mod.manifest_json.Manifest {
    try validateInstanceId(instance_id);

    var manifest_be = openManifestBackend(allocator, data_dir, blob_cfg, instance_id) catch
        return Error.Blob;
    defer manifest_be.deinit();

    var key_buf: [25]u8 = undefined;
    const key = files_mod.manifest_json.manifestKey(&key_buf, deployment_id);
    const json_bytes = manifest_be.blobStore().get(key, allocator) catch |err| switch (err) {
        error.NotFound => return Error.NotFound,
        else => return Error.Blob,
    };
    defer allocator.free(json_bytes);

    return files_mod.manifest_json.decode(allocator, json_bytes) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.InvalidManifest,
    };
}

/// Load the latest manifest files-server has on file (the local
/// next-id counter's previous value). Used by the bundle / replay
/// path's "what's the deployment?" query. Returns `Error.NotFound`
/// when no deploy has shipped yet.
pub fn loadCurrentManifest(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    instance_id: []const u8,
) Error!files_mod.manifest_json.Manifest {
    var h: InstanceCtx = undefined;
    try h.init(allocator, data_dir, blob_cfg, instance_id, stubCompile, null);
    defer h.deinit();
    const cur = h.store.currentDeploymentId() catch |err| return mapCodeError(err);
    if (cur == 0) return Error.NotFound;
    return loadDeployment(allocator, data_dir, blob_cfg, instance_id, cur);
}

pub const FileContent = struct {
    kind: files_mod.Kind,
    content_type: []u8,
    bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FileContent) void {
        self.allocator.free(self.content_type);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Read a file from the tenant's working tree by path (i.e. whatever
/// the last `putSource`/`putStatic` wrote, regardless of deployment).
/// For handlers this returns the JS source bytes.
pub fn readFileByPath(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    instance_id: []const u8,
    path: []const u8,
) Error!FileContent {
    var h: InstanceCtx = undefined;
    try h.init(allocator, data_dir, blob_cfg, instance_id, stubCompile, null);
    defer h.deinit();

    var info = h.store.stat(path) catch |err| return mapCodeError(err);
    defer info.deinit();

    const bytes = h.store.getSource(path, allocator) catch |err| return mapCodeError(err);
    errdefer allocator.free(bytes);
    const ct = allocator.dupe(u8, info.content_type) catch return Error.OutOfMemory;
    return .{
        .kind = info.kind,
        .content_type = ct,
        .bytes = bytes,
        .allocator = allocator,
    };
}

fn stubCompile(
    _: ?*anyopaque,
    _: []const u8,
    _: [:0]const u8,
    _: std.mem.Allocator,
) anyerror![]u8 {
    return error.CompileNotSupported;
}

fn mapCodeError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        error.InvalidPath => Error.InvalidPath,
        error.NotFound => Error.NotFound,
        error.InvalidManifest => Error.InvalidManifest,
        error.CompileFailed => Error.CompileFailed,
        error.Kv => Error.Kv,
        error.Blob => Error.Blob,
        else => Error.Kv, // conservative catch-all
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeTempDir(allocator: std.mem.Allocator) ![]u8 {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    const path = try std.fmt.allocPrint(allocator, "/tmp/rove-cs-{x}", .{seed});
    std.fs.cwd().deleteTree(path) catch {};
    try std.fs.cwd().makePath(path);
    return path;
}

test "uploadFile + loadDeployment round trip" {
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator);
    defer {
        std.fs.cwd().deleteTree(data_dir) catch {};
        allocator.free(data_dir);
    }

    try uploadFile(allocator, data_dir, .fs, "acme", "index.js",
        "response.body = 'hi';",
    );
    const dep_id = try deploy(allocator, data_dir, .fs, "acme");
    try testing.expect(dep_id > 0);

    var manifest = try loadDeployment(allocator, data_dir, .fs, "acme", dep_id);
    defer manifest.deinit();

    try testing.expectEqual(@as(usize, 1), manifest.entries.len);
    try testing.expectEqualStrings("index.js", manifest.entries[0].path);
}

test "uploadFile produces stable hashes for identical input" {
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator);
    defer {
        std.fs.cwd().deleteTree(data_dir) catch {};
        allocator.free(data_dir);
    }

    try uploadFile(allocator, data_dir, .fs, "acme", "a.js", "1 + 2;");
    const dep1 = try deploy(allocator, data_dir, .fs, "acme");
    var m1 = try loadDeployment(allocator, data_dir, .fs, "acme", dep1);
    defer m1.deinit();
    const hash_a1 = m1.entries[0].source_hex;

    // Re-upload identical bytes → same source hash.
    try uploadFile(allocator, data_dir, .fs, "acme", "a.js", "1 + 2;");
    const dep2 = try deploy(allocator, data_dir, .fs, "acme");
    var m2 = try loadDeployment(allocator, data_dir, .fs, "acme", dep2);
    defer m2.deinit();
    const hash_a2 = m2.entries[0].source_hex;

    try testing.expectEqualSlices(u8, &hash_a1, &hash_a2);
}

test "getSourceByHash fetches the exact bytes" {
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator);
    defer {
        std.fs.cwd().deleteTree(data_dir) catch {};
        allocator.free(data_dir);
    }

    const source = "response.body = 'hash me';";
    try uploadFile(allocator, data_dir, .fs, "acme", "index.js", source);
    const dep = try deploy(allocator, data_dir, .fs, "acme");

    var manifest = try loadDeployment(allocator, data_dir, .fs, "acme", dep);
    defer manifest.deinit();
    const hash = &manifest.entries[0].source_hex;

    const fetched = try getSourceByHash(allocator, data_dir, .fs, "acme", hash);
    defer allocator.free(fetched);
    try testing.expectEqualStrings(source, fetched);
}

test "uploadFile rejects invalid instance id" {
    const allocator = testing.allocator;
    try testing.expectError(
        Error.InvalidInstanceId,
        uploadFile(allocator, "/tmp/rove-cs-inv", .fs, "", "a.js", "1;"),
    );
    try testing.expectError(
        Error.InvalidInstanceId,
        uploadFile(allocator, "/tmp/rove-cs-inv", .fs, "../etc", "a.js", "1;"),
    );
}

test "multi-file deployment manifest lists every entry" {
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator);
    defer {
        std.fs.cwd().deleteTree(data_dir) catch {};
        allocator.free(data_dir);
    }

    try uploadFile(allocator, data_dir, .fs, "acme", "index.js", "1;");
    try uploadFile(allocator, data_dir, .fs, "acme", "api/users.mjs",
        "export function list(req) { return { status: 200, body: 'ok' }; }",
    );
    const dep = try deploy(allocator, data_dir, .fs, "acme");
    var manifest = try loadDeployment(allocator, data_dir, .fs, "acme", dep);
    defer manifest.deinit();

    try testing.expectEqual(@as(usize, 2), manifest.entries.len);

    // Order is determined by rove-kv's range scan; check by set membership.
    var saw_index = false;
    var saw_users = false;
    for (manifest.entries) |e| {
        if (std.mem.eql(u8, e.path, "index.js")) saw_index = true;
        if (std.mem.eql(u8, e.path, "api/users.mjs")) saw_users = true;
    }
    try testing.expect(saw_index and saw_users);
}
