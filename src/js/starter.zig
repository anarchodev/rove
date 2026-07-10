//! `starter.zig` — initial deployment content for freshly-created tenants.
//!
//! Extracted from `worker.zig`. Bakes the two starter files into the
//! binary (`@embedFile`) and writes them as the tenant's first
//! deployment so signup answers 200 on `/` immediately. Self-contained:
//! opens its own short-lived kv + blob connections and closes them on
//! the way out. Called once per tenant create from the worker's
//! `deployStarterTrampoline`.

const std = @import("std");
const kv_mod = @import("raft-kv");
const blob_mod = @import("rove-blob");
const files_mod = @import("rove-files");

// ── Starter content ────────────────────────────────────────────────
//
// Baked into the binary so a freshly-created tenant answers 200 on
// `/` the moment signup completes. Intentionally tiny — the point is
// to prove the deploy pipeline works end-to-end, not to ship a
// template. The customer replaces these as soon as they push their
// own code through the files API.
//
// Edited as plain files under `src/js/starter/` (registered in
// build.zig's `js_runtime_files`). Trailing newlines from the source
// files ride into the manifest — that is part of the content-addressed
// dep_id and is fine: starter content is byte-identical across every
// tenant, so the resulting dep_id is too.

const STARTER_INDEX_MJS = @embedFile("starter_index_mjs");
const STARTER_STATIC_INDEX_HTML = @embedFile("starter_static_index_html");
/// The genesis `__admin__` deploy app (rewind-cli-plan §4.1 (f)) — the
/// minimal handler that composes deploys from `platform.*`. Baked so a
/// virgin cluster self-bootstraps deploy capability; the full admin is then
/// published THROUGH it.
const GENESIS_ADMIN_MJS = @embedFile("genesis_admin_mjs");
/// The streamed static-upload module (routed at `/v1/upload`) — baked into the
/// genesis bundle as a second handler so the bootstrap can stream large statics
/// into the admin it publishes. Same source as web/admin's upload module.
const GENESIS_UPLOAD_MJS = @embedFile("upload_mjs");

/// One baked handler / static file for `deployBakedBundle`.
pub const BakedHandler = struct { path: []const u8, source: []const u8 };
pub const BakedStatic = struct { path: []const u8, content: []const u8, content_type: []const u8 };

/// Write the initial deployment for a freshly-created instance:
/// compile + content-address the starter files into the tenant's
/// `file-blobs` backend, encode the resulting manifest as JSON, write
/// it to the per-tenant `deployments/` BlobBackend, and stage a
/// `_deploy/current` write into `release_ws` so the caller can propose
/// it through raft alongside the rest of the signup writeset.
pub fn deployStarterContent(
    allocator: std.mem.Allocator,
    inst_id: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    compile_fn: files_mod.CompileFn,
    compile_ctx: ?*anyopaque,
    release_ws: *kv_mod.WriteSet,
) !u64 {
    return deployBakedBundle(
        allocator,
        inst_id,
        blob_cfg,
        compile_fn,
        compile_ctx,
        release_ws,
        &.{.{ .path = "index.mjs", .source = STARTER_INDEX_MJS }},
        &.{.{ .path = "_static/index.html", .content = STARTER_STATIC_INDEX_HTML, .content_type = "text/html; charset=utf-8" }},
    );
}

/// Deploy the genesis `__admin__` deploy app (rewind-cli-plan §4.1 (f)) — the
/// baked minimal handler that composes deploys from `platform.*`. One handler,
/// no statics. Same staging path as the starter; the caller proposes
/// `release_ws`'s `_deploy/current` through raft.
pub fn deployGenesisAdminContent(
    allocator: std.mem.Allocator,
    inst_id: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    compile_fn: files_mod.CompileFn,
    compile_ctx: ?*anyopaque,
    release_ws: *kv_mod.WriteSet,
) !u64 {
    return deployBakedBundle(
        allocator,
        inst_id,
        blob_cfg,
        compile_fn,
        compile_ctx,
        release_ws,
        &.{
            .{ .path = "index.mjs", .source = GENESIS_ADMIN_MJS },
            .{ .path = "v1/upload/index.mjs", .source = GENESIS_UPLOAD_MJS },
        },
        &.{},
    );
}

/// Stage a baked bundle (compile + content-address each file, write the
/// manifest to the tenant's `deployments/` backend) and stage
/// `_deploy/current = dep_id` into `release_ws`. Shared by the starter +
/// genesis-admin deploys. Opens its own short-lived blob connections and
/// closes them on the way out — the same stateless staging shape as the
/// worker's deploy thread (`compileAndStage`), just with baked inputs.
pub fn deployBakedBundle(
    allocator: std.mem.Allocator,
    inst_id: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    compile_fn: files_mod.CompileFn,
    compile_ctx: ?*anyopaque,
    release_ws: *kv_mod.WriteSet,
    handlers: []const BakedHandler,
    statics: []const BakedStatic,
) !u64 {
    var blob_backend = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        inst_id,
        "file-blobs",
    );
    defer blob_backend.deinit();

    const inputs = try allocator.alloc(files_mod.DeployInput, handlers.len);
    defer allocator.free(inputs);
    for (handlers, 0..) |h, i|
        inputs[i] = .{ .path = h.path, .kind = .handler, .bytes = h.source };

    const compiled = try files_mod.compileAndStage(
        allocator,
        blob_backend.blobStore(),
        compile_fn,
        compile_ctx,
        inputs,
        "",
    );
    defer allocator.free(compiled);

    const entries = try allocator.alloc(files_mod.Entry, handlers.len + statics.len);
    defer allocator.free(entries);
    for (compiled, 0..) |cf, i| entries[i] = .{
        .path = cf.path,
        .kind = .handler,
        .content_type = "",
        .source_hex = cf.source_hex,
        .bytecode_hex = cf.bytecode_hex,
    };
    for (statics, 0..) |s, i| {
        try files_mod.validatePath(s.path);
        var src_hex: [files_mod.HASH_HEX_LEN]u8 = undefined;
        files_mod.hashHex(s.content, &src_hex);
        try files_mod.putBlobIfMissingTo(blob_backend.blobStore(), &src_hex, s.content);
        entries[handlers.len + i] = .{
            .path = s.path,
            .kind = .static,
            .content_type = s.content_type,
            .source_hex = src_hex,
            .bytecode_hex = @splat(0),
        };
    }

    // Content-addressed dep_id (truncated sha-256). The starter content
    // is byte-identical across every tenant, so every starter deploy
    // mints the same id — and the per-tenant S3 prefix scopes the
    // manifest so cross-tenant collisions don't matter at all (each
    // tenant has its own `{inst_id}/deployments/` namespace).
    const next_id = files_mod.manifest_json.computeDeploymentId(entries, &.{}, &.{});

    const json_bytes = try files_mod.manifest_json.encode(allocator, next_id, entries, &.{}, &.{});
    defer allocator.free(json_bytes);

    var manifest_be = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        inst_id,
        "deployments",
    );
    defer manifest_be.deinit();

    var key_buf: [25]u8 = undefined;
    const key = files_mod.manifest_json.manifestKey(&key_buf, next_id);
    try manifest_be.blobStore().put(key, json_bytes);

    // Stage `_deploy/current = next_id` so the caller's raft propose
    // sees it. Followers' apply path commits it into their copies of
    // the tenant's app.db; the worker's TenantFiles eager-open then
    // reads it on first request and loads the manifest from
    // manifest_backend (shared via fs/s3 between leader + followers).
    var hex_buf: [16]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x:0>16}", .{next_id}) catch unreachable;
    try release_ws.addPut("_deploy/current", hex);
    return next_id;
}
