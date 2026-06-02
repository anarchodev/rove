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

/// Write the initial deployment for a freshly-created instance. Opens
/// its own short-lived kv + blob-store connections, pushes the two
/// starter files through FileStore (which compiles + blob-addresses
/// them), and commits a deployment row. Closes everything on the way
/// out — the main worker and files-server lazy-open their own
/// connections later, so we're not holding onto any state that would
/// conflict.
/// Drop the starter content into the freshly-created tenant's
/// working tree, encode the resulting manifest as JSON, write it to
/// the per-tenant `deployments/` BlobBackend, and stage a `_deploy/
/// current = 1` write into `release_ws` so the caller can propose
/// it through raft alongside the rest of the signup writeset.
/// Phase 5.5(e) F2-storage retired the per-tenant files writeset
/// (envelope 3); the runtime release pointer rides envelope 0 with
/// the rest of the customer kv writes.
pub fn deployStarterContent(
    allocator: std.mem.Allocator,
    inst_dir: []const u8,
    inst_id: []const u8,
    blob_cfg: blob_mod.BackendConfig,
    compile_fn: files_mod.CompileFn,
    compile_ctx: ?*anyopaque,
    release_ws: *kv_mod.WriteSet,
) !u64 {
    // Same scratch-only role as bootstrap.zig's
    // `.bootstrap-scratch.kv` — `files_mod.FileStore.init` demands
    // a KvStore but nothing persists here (the manifest goes to
    // S3). Use a per-call tmp kvexp file that gets deleted on
    // return.
    const files_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/.starter-scratch.kv",
        .{inst_dir},
        0,
    );
    defer {
        std.fs.cwd().deleteFile(files_db_path) catch {};
        allocator.free(files_db_path);
    }
    std.fs.cwd().deleteFile(files_db_path) catch {};

    const files_kv = try kv_mod.KvStore.open(allocator, files_db_path);
    defer files_kv.close();

    var blob_backend = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        inst_id,
        "file-blobs",
    );
    defer blob_backend.deinit();

    var store = files_mod.FileStore.init(
        allocator,
        files_kv,
        blob_backend.blobStore(),
        compile_fn,
        compile_ctx,
    );

    try store.putSource("index.mjs", STARTER_INDEX_MJS);
    try store.putStatic("_static/index.html", STARTER_STATIC_INDEX_HTML, "text/html; charset=utf-8");

    const entries = try store.assembleManifest();
    defer store.freeEntries(entries);

    // Content-addressed dep_id (truncated sha-256). The starter content
    // is byte-identical across every tenant, so every starter deploy
    // mints the same id — and the per-tenant S3 prefix scopes the
    // manifest so cross-tenant collisions don't matter at all (each
    // tenant has its own `{inst_id}/deployments/` namespace).
    const next_id = files_mod.manifest_json.computeDeploymentId(entries);

    const json_bytes = try files_mod.manifest_json.encode(allocator, next_id, entries);
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

    try store.setCurrentDeploymentId(next_id);

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
