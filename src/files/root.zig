// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! rove-files — content-addressed deploy staging + manifest model.
//!
//! The staging layer under every deploy: compile handler sources to
//! quickjs bytecode and content-address BOTH blobs (source + bytecode)
//! into the tenant's `file-blobs` BlobBackend (S3 in production, shared
//! by every node). The *manifest* — which paths exist, their kinds, and
//! which blob hashes back them — is modeled here (`Entry`) and
//! encoded/decoded by `manifest_json`: deployments are immutable JSON
//! objects in the per-tenant `deployments/` BlobBackend, and the runtime
//! release pointer is `_deploy/current` in the tenant's app.db
//! (replicated via raft envelope 0).
//!
//! Two callers stage deploys:
//! - the worker's `DeployThread` (`/_system/deploy` → `platform.*`
//!   primitives → `compileAndStage`) for real deploys;
//! - `starter.zig` for the baked starter / genesis-admin bundles at
//!   tenant create.
//!
//! Blob keys are the hex sha-256 of the bytes:
//!
//!   `{source_sha256_hex}`        → raw source / static bytes
//!   `bc/{bytecode_sha256_hex}`   → serialized quickjs bytecode — the
//!                                  `bc/` namespace is writable ONLY by
//!                                  `compileAndStage` (see BC_KEY_PREFIX:
//!                                  the JS_ReadObject trust boundary)
//!
//! There is deliberately NO source-keyed compile cache. quickjs
//! resolves + LOADS every module import at compile time (compile is the
//! validation gate — it fails when an import can't resolve against the
//! deploy's package resolution), and it bakes the module's OWN filename
//! into the bytecode as the base that imports re-resolve against at
//! every runtime load. So bytecode = f(source, filename) — a
//! `source → bytecode` memo would skip the per-deploy import validation
//! and conflate same-source files compiled under different names (a
//! package vs an app copy). Every deploy recompiles; blob PUTs dedup
//! content-addressed (`putBlobIfMissingTo`) and the runtime
//! `BytecodeCache` dedups in memory by bytecode hash. See
//! docs/architecture/package-compile-caching.md before adding any compile
//! memoization here.
//!
//! ## Compile hook
//!
//! rove-files is quickjs-agnostic — `compileAndStage` takes a
//! `CompileFn`. The worker's deploy thread wires in a function that
//! owns a `rove-qjs` `Runtime` + `Context` and calls
//! `compileToBytecode`. Tests use a pass-through hook that returns the
//! source unchanged, which is enough to exercise the staging plumbing
//! without pulling in quickjs.

const std = @import("std");

const blob_mod = @import("rove-blob");

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
/// bytecode buffer. `ctx` is the opaque user pointer supplied alongside
/// the hook. Implementations should return `error.CompileFailed` for
/// syntax errors; other errors propagate as-is.
pub const CompileFn = *const fn (
    ctx: ?*anyopaque,
    source: []const u8,
    filename: [:0]const u8,
    allocator: std.mem.Allocator,
) anyerror![]u8;

pub const HASH_HEX_LEN: usize = 64; // sha256 hex

/// Storage-key prefix for compiled bytecode blobs — the trust boundary
/// for `JS_ReadObject`. quickjs's bytecode reader is not hardened
/// against adversarial input, so bytecode must be platform-compiled BY
/// CONSTRUCTION: `compileAndStage` is the only writer of `bc/{hash}`
/// keys, and every upload path (statics via blob.receive etc.) writes
/// natively-computed bare 64-hex content-hash keys — it CANNOT produce
/// a `bc/` key. Every bytecode fetch (deployment loader, deploy-thread
/// package staging) reads ONLY `bc/{hash}`, so a manifest that
/// references an uploaded blob's hash as `bytecode_hash` finds nothing
/// and fails loud instead of feeding attacker bytes to the reader.
/// (`bytecode_hash` in manifests stays the bare content hash — the
/// prefix is a storage-key namespace, not part of the identity.)
pub const BC_KEY_PREFIX = "bc/";
pub const BC_KEY_LEN: usize = BC_KEY_PREFIX.len + HASH_HEX_LEN;

/// Build the `bc/{hash}` storage key for a bytecode content hash.
pub fn bcKey(buf: *[BC_KEY_LEN]u8, hash_hex: *const [HASH_HEX_LEN]u8) []const u8 {
    @memcpy(buf[0..BC_KEY_PREFIX.len], BC_KEY_PREFIX);
    @memcpy(buf[BC_KEY_PREFIX.len..], hash_hex);
    return buf[0..];
}

/// Longest `virtual_dir` prefix `compileAndStage` accepts:
/// `/pkg/` + 64-hex pkg hash + `/`.
pub const MAX_VIRTUAL_DIR_LEN: usize = 5 + HASH_HEX_LEN + 1;

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

/// One manifest entry: a deployed path and the content-addressed blobs
/// backing it. The in-memory shape behind `manifest_json.encode` /
/// `decode` and `computeDeploymentId`.
pub const Entry = struct {
    path: []const u8,
    kind: Kind,
    content_type: []const u8,
    source_hex: [HASH_HEX_LEN]u8,
    /// All-zero when `kind != .handler`.
    bytecode_hex: [HASH_HEX_LEN]u8,
};

// ── Stateless deploy staging ───────────────────────────────────────────

/// One file's bytes + metadata for a stateless deploy. The caller (the
/// worker's `DeployThread`, driven by the `platform.*` deploy primitives,
/// or `starter.zig` for baked bundles) supplies the raw bytes; there is
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

/// One compiled handler's content-addressed hashes (the result of
/// `compileAndStage`). `path` borrows the caller's input slice.
pub const CompiledFile = struct {
    path: []const u8,
    source_hex: [HASH_HEX_LEN]u8,
    bytecode_hex: [HASH_HEX_LEN]u8,
    /// Bytes each blob occupies in the tenant's `file-blobs/`. Reported so the
    /// caller can meter what a deploy stored (`src/kv/usage.zig`) without
    /// re-reading the objects back out of the store.
    source_len: u64,
    bytecode_len: u64,
};

/// Content-address handler sources into `blob` WITHOUT compiling them —
/// the staging half of a deploy, split from the linking half.
///
/// Compilation resolves imports eagerly (quickjs runs `js_resolve_module`
/// even under `COMPILE_ONLY`), so a module can only be compiled once every
/// module it imports is present. A deploy that uploads files one at a time
/// never has that until the last one lands, which is why staging and
/// compiling are separate steps: stage each file as it arrives, then compile
/// the finished bundle, where every sibling is resolvable.
///
/// Returns one `source_hex` per input; `path` borrows the input slice.
pub fn stageSources(
    allocator: std.mem.Allocator,
    blob: BlobStore,
    inputs: []const DeployInput,
) Error![]StagedFile {
    if (inputs.len > 256) return Error.InvalidManifest;
    for (inputs, 0..) |in_a, i| {
        try validatePath(in_a.path);
        for (inputs[0..i]) |in_b| {
            if (std.mem.eql(u8, in_a.path, in_b.path)) return Error.InvalidManifest;
        }
    }

    const out = allocator.alloc(StagedFile, inputs.len) catch return Error.OutOfMemory;
    errdefer allocator.free(out);
    for (inputs, 0..) |in, i| {
        var src_hex: [HASH_HEX_LEN]u8 = undefined;
        hashHex(in.bytes, &src_hex);
        try putBlobIfMissingTo(blob, &src_hex, in.bytes);
        out[i] = .{ .path = in.path, .source_hex = src_hex, .source_len = in.bytes.len };
    }
    return out;
}

/// One staged source's content hash (the result of `stageSources`).
pub const StagedFile = struct {
    path: []const u8,
    source_hex: [HASH_HEX_LEN]u8,
    /// Bytes the staged source occupies in `file-blobs/` — see
    /// `CompiledFile.source_len`.
    source_len: u64,
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
///
/// `virtual_dir` is the compile-time filename prefix — empty for app
/// handlers (module name = the deploy path), `/pkg/<pkg_hash>/` for a
/// package compile (PM P1). The module's own name bakes into its
/// bytecode and is the base quickjs re-resolves its imports against at
/// every load, so a package MUST compile under its package-virtual name
/// (per-importer encapsulation + one-instance-per-version identity);
/// `path` itself stays relative (validated, and the manifest key).
/// `failed_path`, when given, receives the path of the input being compiled
/// if compilation fails. The compiler's own message names the missing module
/// or the syntax error; only the caller's loop knows which FILE was in hand,
/// and that is the half the author acts on.
pub fn compileAndStage(
    allocator: std.mem.Allocator,
    blob: BlobStore,
    compile: CompileFn,
    compile_ctx: ?*anyopaque,
    inputs: []const DeployInput,
    virtual_dir: []const u8,
    failed_path: ?*[]const u8,
) Error![]CompiledFile {
    if (inputs.len > 256) return Error.InvalidManifest;
    if (virtual_dir.len > MAX_VIRTUAL_DIR_LEN) return Error.InvalidPath;

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
        var fname_buf: [MAX_VIRTUAL_DIR_LEN + MAX_PATH_LEN + 1]u8 = undefined;
        @memcpy(fname_buf[0..virtual_dir.len], virtual_dir);
        @memcpy(fname_buf[virtual_dir.len..][0..in.path.len], in.path);
        const fname_len = virtual_dir.len + in.path.len;
        fname_buf[fname_len] = 0;
        const fname: [:0]const u8 = fname_buf[0..fname_len :0];

        const bytecode = compile(compile_ctx, in.bytes, fname, allocator) catch {
            if (failed_path) |report| report.* = in.path;
            return Error.CompileFailed;
        };
        defer allocator.free(bytecode);

        var bc_hex: [HASH_HEX_LEN]u8 = undefined;
        hashHex(bytecode, &bc_hex);
        var bc_key_buf: [BC_KEY_LEN]u8 = undefined;
        try putBlobIfMissingTo(blob, bcKey(&bc_key_buf, &bc_hex), bytecode);

        out[i] = .{
            .path = in.path,
            .source_hex = src_hex,
            .bytecode_hex = bc_hex,
            .source_len = in.bytes.len,
            .bytecode_len = bytecode.len,
        };
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
pub fn putBlobIfMissingTo(blob: BlobStore, key: []const u8, bytes: []const u8) Error!void {
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

/// Unconditional PUT with the same bounded backoff as
/// `putBlobIfMissingTo`, minus the exists() short-circuit. For keys that
/// are NOT a pure content address of the stored bytes — a deployment
/// manifest's key derives from the dep_id (a hash of the content list,
/// not the serialized JSON), so the bytes at the key can legitimately
/// change (schema version bump) while the key stays the same. Skipping
/// on exists would pin the old bytes there forever.
pub fn putBlobTo(blob: BlobStore, key: []const u8, bytes: []const u8) Error!void {
    var attempt: u8 = 0;
    while (attempt < 6) : (attempt += 1) {
        blob.put(key, bytes) catch {
            const delay_ms: u64 = @as(u64, 50) << @as(u6, @intCast(attempt));
            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
            continue;
        };
        return;
    }
    return Error.Blob;
}

/// Hex sha-256 of `bytes` — the content address every blob key uses.
pub fn hashHex(bytes: []const u8, out: *[HASH_HEX_LEN]u8) void {
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
/// hook in the tree (worker, dual-worker example) uses this to set
/// `qjs.EvalFlags.kind`.
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

/// Test-framework artifacts (`_tests/`, which holds its own `__snapshots__/`
/// and `__fixtures__/`) are dev-repo-only and must never be deployed. The
/// customer CLI strips them at classify time (`cli/common.zig`); this is the
/// server-side defensive reject the `/_system/deploy` handler applies so a
/// direct poster can't smuggle them in (`docs/architecture/replay-and-sim.md`).
/// Inputs here are already `validatePath`'d (lowercase `[a-z0-9-_./]`, no
/// traversal / `//`), so a root-prefix check is sufficient and unspoofable.
pub fn isTestArtifactPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "_tests/");
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
/// Different source yields different bytecode, identical source yields
/// identical bytecode.
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

test "isTestArtifactPath flags _tests/ deploy artifacts, not real files" {
    try testing.expect(isTestArtifactPath("_tests/orders.mjs"));
    try testing.expect(isTestArtifactPath("_tests/__snapshots__/orders.json"));
    try testing.expect(isTestArtifactPath("_tests/__fixtures__/world.json"));
    try testing.expect(!isTestArtifactPath("index.mjs"));
    try testing.expect(!isTestArtifactPath("_static/app.css"));
    try testing.expect(!isTestArtifactPath("lib/_helpers.mjs")); // not a _tests/ root
}

test {
    _ = manifest_json;
    _ = app_manifest;
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
    const out = try compileAndStage(a, blob.blobStore(), passthroughCompile, null, &inputs, "", null);
    defer a.free(out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("index.mjs", out[0].path);
    try testing.expectEqualStrings("api/index.mjs", out[1].path);
    // Both the source AND bytecode blobs landed for every handler —
    // source at its bare content hash, bytecode ONLY under `bc/` (the
    // JS_ReadObject trust boundary: uploads can't produce bc/ keys, so
    // everything there is compiler output by construction).
    for (out) |cf| {
        try testing.expect(try blob.blobStore().exists(&cf.source_hex));
        var bc_key_buf: [BC_KEY_LEN]u8 = undefined;
        try testing.expect(try blob.blobStore().exists(bcKey(&bc_key_buf, &cf.bytecode_hex)));
        try testing.expect(!(try blob.blobStore().exists(&cf.bytecode_hex)));
    }
    // Distinct sources → distinct source hashes (and distinct bytecode).
    try testing.expect(!std.mem.eql(u8, &out[0].source_hex, &out[1].source_hex));
    try testing.expect(!std.mem.eql(u8, &out[0].bytecode_hex, &out[1].bytecode_hex));
}

test "stageSources: content-addresses the source and compiles nothing" {
    const a = testing.allocator;
    var blob = MemBlobStore.init(a);
    defer blob.deinit();

    // A source that CANNOT compile on its own: it imports a sibling that is
    // not staged yet, which is exactly the state a per-file upload is in
    // partway through. Staging must not care.
    const inputs = [_]DeployInput{
        .{ .path = "index.mjs", .kind = .handler, .bytes = "import {x} from './lib.mjs'; export default () => x;" },
    };
    const out = try stageSources(a, blob.blobStore(), &inputs);
    defer a.free(out);

    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("index.mjs", out[0].path);
    try testing.expect(try blob.blobStore().exists(&out[0].source_hex));

    // The hash is the same one `compileAndStage` would derive, so a file
    // staged now and compiled later keeps one identity.
    var expect_hex: [HASH_HEX_LEN]u8 = undefined;
    hashHex(inputs[0].bytes, &expect_hex);
    try testing.expectEqualSlices(u8, &expect_hex, &out[0].source_hex);

    // No bytecode was written — nothing under the `bc/` namespace at all.
    var bc_key_buf: [BC_KEY_LEN]u8 = undefined;
    try testing.expect(!(try blob.blobStore().exists(bcKey(&bc_key_buf, &out[0].source_hex))));
}

test "stageSources: rejects duplicate and invalid paths like the compile path" {
    const a = testing.allocator;
    var blob = MemBlobStore.init(a);
    defer blob.deinit();

    const dupes = [_]DeployInput{
        .{ .path = "index.mjs", .kind = .handler, .bytes = "a" },
        .{ .path = "index.mjs", .kind = .handler, .bytes = "b" },
    };
    try testing.expectError(Error.InvalidManifest, stageSources(a, blob.blobStore(), &dupes));

    const escaping = [_]DeployInput{.{ .path = "../evil.mjs", .kind = .handler, .bytes = "a" }};
    try testing.expectError(Error.InvalidPath, stageSources(a, blob.blobStore(), &escaping));
}

test "compileAndStage: idempotent — identical inputs yield identical hashes" {
    const a = testing.allocator;
    var blob = MemBlobStore.init(a);
    defer blob.deinit();
    const inputs = [_]DeployInput{.{ .path = "index.mjs", .kind = .handler, .bytes = "x" }};

    const o1 = try compileAndStage(a, blob.blobStore(), passthroughCompile, null, &inputs, "", null);
    defer a.free(o1);
    const o2 = try compileAndStage(a, blob.blobStore(), passthroughCompile, null, &inputs, "", null);
    defer a.free(o2);
    try testing.expectEqualSlices(u8, &o1[0].source_hex, &o2[0].source_hex);
    try testing.expectEqualSlices(u8, &o1[0].bytecode_hex, &o2[0].bytecode_hex);
}

test "compileAndStage: compile failure surfaces as CompileFailed" {
    const a = testing.allocator;
    var blob = MemBlobStore.init(a);
    defer blob.deinit();
    const inputs = [_]DeployInput{.{ .path = "bad.mjs", .kind = .handler, .bytes = "syntax(" }};
    // The failing file's path comes back so the caller can say WHICH file —
    // a bundle compiles as a batch, and the compiler's own message names only
    // the problem.
    var failed: []const u8 = "";
    try testing.expectError(Error.CompileFailed, compileAndStage(a, blob.blobStore(), failingCompile, null, &inputs, "", &failed));
    try testing.expectEqualStrings(inputs[0].path, failed);
}

test "compileAndStage: rejects duplicate + traversal paths" {
    const a = testing.allocator;
    var blob = MemBlobStore.init(a);
    defer blob.deinit();
    const dup = [_]DeployInput{
        .{ .path = "index.mjs", .kind = .handler, .bytes = "a" },
        .{ .path = "index.mjs", .kind = .handler, .bytes = "b" },
    };
    try testing.expectError(Error.InvalidManifest, compileAndStage(a, blob.blobStore(), passthroughCompile, null, &dup, "", null));
    const bad = [_]DeployInput{.{ .path = "../x.mjs", .kind = .handler, .bytes = "a" }};
    try testing.expectError(Error.InvalidPath, compileAndStage(a, blob.blobStore(), passthroughCompile, null, &bad, "", null));
}
