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
    blob_backend: blob_mod.FilesystemBlobStore,
    store: files_mod.FileStore,

    /// In-place construction. Must be called on a stack-local
    /// `InstanceCtx` — see struct doc for why.
    fn init(
        self: *InstanceCtx,
        allocator: std.mem.Allocator,
        data_dir: []const u8,
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

        self.blob_backend = blob_mod.FilesystemBlobStore.open(allocator, files_blob_dir) catch
            return Error.Blob;
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
const InlineCompiler = struct {
    runtime: qjs.Runtime,
    context: qjs.Context,

    fn init() Error!InlineCompiler {
        var rt = qjs.Runtime.init() catch return Error.OutOfMemory;
        errdefer rt.deinit();
        const ctx = rt.newContext() catch return Error.OutOfMemory;
        return .{ .runtime = rt, .context = ctx };
    }

    fn deinit(self: *InlineCompiler) void {
        self.context.deinit();
        self.runtime.deinit();
    }

    fn compile(
        ctx_opaque: ?*anyopaque,
        source: []const u8,
        filename: [:0]const u8,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *InlineCompiler = @ptrCast(@alignCast(ctx_opaque.?));
        const flags: qjs.EvalFlags = if (std.mem.endsWith(u8, filename, ".mjs"))
            .{ .kind = .module }
        else
            .{};
        return self.context.compileToBytecode(source, filename, allocator, flags);
    }
};

/// Upload a single source file into the tenant's working tree.
/// Compiles the source, stores the source+bytecode blobs, updates the
/// `file/{path}` index entry. Idempotent — re-uploading identical
/// bytes is a no-op beyond restamping the index.
pub fn uploadFile(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance_id: []const u8,
    path: []const u8,
    source: []const u8,
) Error!void {
    var compiler = try InlineCompiler.init();
    defer compiler.deinit();

    var h: InstanceCtx = undefined;
    try h.init(allocator, data_dir, instance_id, InlineCompiler.compile, &compiler);
    defer h.deinit();

    h.store.putSource(path, source) catch |err| return mapCodeError(err);
}

/// Upload a static file — raw bytes at `path`, stored under its stored
/// content-type. Unlike `uploadFile`, there's no compile step: static
/// assets are served verbatim.
pub fn uploadStatic(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance_id: []const u8,
    path: []const u8,
    bytes: []const u8,
    content_type: []const u8,
) Error!void {
    var h: InstanceCtx = undefined;
    try h.init(allocator, data_dir, instance_id, stubCompile, null);
    defer h.deinit();

    h.store.putStatic(path, bytes, content_type) catch |err| return mapCodeError(err);
}

/// Upload-and-deploy an admin single-file write. Infers kind from the
/// path prefix (`_code/` → handler, `_static/` → static) and commits a
/// fresh deployment in the same call. Returns the new deployment id.
///
/// Anything outside the `_code/` / `_static/` prefixes is rejected with
/// `Error.InvalidPath`. Customers can't claim top-level `_`-prefixed
/// paths — the policy lives at the edge (request handler or admin UI).
pub fn putFileAndDeploy(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance_id: []const u8,
    path: []const u8,
    body: []const u8,
    content_type: []const u8,
) Error!u64 {
    if (std.mem.startsWith(u8, path, "_code/")) {
        var compiler = try InlineCompiler.init();
        defer compiler.deinit();
        var h: InstanceCtx = undefined;
        try h.init(allocator, data_dir, instance_id, InlineCompiler.compile, &compiler);
        defer h.deinit();
        h.store.putSource(path, body) catch |err| return mapCodeError(err);
        return h.store.deploy() catch |err| mapCodeError(err);
    } else if (std.mem.startsWith(u8, path, "_static/")) {
        var h: InstanceCtx = undefined;
        try h.init(allocator, data_dir, instance_id, stubCompile, null);
        defer h.deinit();
        h.store.putStatic(path, body, content_type) catch |err| return mapCodeError(err);
        return h.store.deploy() catch |err| mapCodeError(err);
    } else {
        return Error.InvalidPath;
    }
}

/// Snapshot the current working tree into a new deployment and swap
/// `deployment/current`. Returns the new deployment id.
pub fn deploy(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance_id: []const u8,
) Error!u64 {
    // Deploy doesn't actually compile, but FileStore.init demands a
    // non-null compile hook. Give it a stub that errors out — if it
    // ever gets called during deploy, something's wrong.
    var h: InstanceCtx = undefined;
    try h.init(allocator, data_dir, instance_id, stubCompile, null);
    defer h.deinit();

    return h.store.deploy() catch |err| mapCodeError(err);
}

/// Fetch a source blob by its content hash. Read-only — used by the
/// bundle/replay path where the browser asks for the JS source
/// corresponding to a deployment entry.
pub fn getSourceByHash(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
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

    var blob_backend = blob_mod.FilesystemBlobStore.open(allocator, files_blob_dir) catch
        return Error.Blob;
    defer blob_backend.deinit();

    return blob_backend.blobStore().get(source_hash_hex, allocator) catch
        Error.NotFound;
}

/// Load a deployment's manifest (list of entries with source + bytecode
/// hashes). Read-only. Used by the bundle/replay path to enumerate the
/// files the browser may need to fetch.
pub fn loadDeployment(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance_id: []const u8,
    deployment_id: u64,
) Error!files_mod.FileStore.Manifest {
    var h: InstanceCtx = undefined;
    try h.init(allocator, data_dir, instance_id, stubCompile, null);
    defer h.deinit();

    return h.store.loadDeployment(deployment_id) catch |err| mapCodeError(err);
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

    try uploadFile(allocator, data_dir, "acme", "index.js",
        "response.body = 'hi';",
    );
    const dep_id = try deploy(allocator, data_dir, "acme");
    try testing.expect(dep_id > 0);

    var manifest = try loadDeployment(allocator, data_dir, "acme", dep_id);
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

    try uploadFile(allocator, data_dir, "acme", "a.js", "1 + 2;");
    const dep1 = try deploy(allocator, data_dir, "acme");
    var m1 = try loadDeployment(allocator, data_dir, "acme", dep1);
    defer m1.deinit();
    const hash_a1 = m1.entries[0].source_hex;

    // Re-upload identical bytes → same source hash.
    try uploadFile(allocator, data_dir, "acme", "a.js", "1 + 2;");
    const dep2 = try deploy(allocator, data_dir, "acme");
    var m2 = try loadDeployment(allocator, data_dir, "acme", dep2);
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
    try uploadFile(allocator, data_dir, "acme", "index.js", source);
    const dep = try deploy(allocator, data_dir, "acme");

    var manifest = try loadDeployment(allocator, data_dir, "acme", dep);
    defer manifest.deinit();
    const hash = &manifest.entries[0].source_hex;

    const fetched = try getSourceByHash(allocator, data_dir, "acme", hash);
    defer allocator.free(fetched);
    try testing.expectEqualStrings(source, fetched);
}

test "uploadFile rejects invalid instance id" {
    const allocator = testing.allocator;
    try testing.expectError(
        Error.InvalidInstanceId,
        uploadFile(allocator, "/tmp/rove-cs-inv", "", "a.js", "1;"),
    );
    try testing.expectError(
        Error.InvalidInstanceId,
        uploadFile(allocator, "/tmp/rove-cs-inv", "../etc", "a.js", "1;"),
    );
}

test "multi-file deployment manifest lists every entry" {
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator);
    defer {
        std.fs.cwd().deleteTree(data_dir) catch {};
        allocator.free(data_dir);
    }

    try uploadFile(allocator, data_dir, "acme", "index.js", "1;");
    try uploadFile(allocator, data_dir, "acme", "api/users.mjs",
        "export function list(req) { return { status: 200, body: 'ok' }; }",
    );
    const dep = try deploy(allocator, data_dir, "acme");
    var manifest = try loadDeployment(allocator, data_dir, "acme", dep);
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
