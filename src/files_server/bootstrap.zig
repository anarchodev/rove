//! Platform-deploy bootstrap — runs once at `files-server-standalone`
//! startup to ensure the cluster's `__admin__` and `__replay__`
//! tenants have a deployment in S3 + a `_deploy/current` pointer in
//! their app.db.
//!
//! ## Why this lives in files-server
//!
//! files-server is the cluster's deploy authority — it owns the
//! upload + compile + manifest pipeline that turns a working tree
//! into a numbered deployment in S3. The worker is the runtime
//! authority — it executes whatever deployment the operator has
//! marked current.
//!
//! Before this lived here, every worker on every node ran its own
//! `bootstrapHandler` at startup, which:
//!   1. raced peers on identical content-addressed S3 PUTs, and
//!   2. wrote `_deploy/current` to its local app.db bypassing raft.
//!
//! Moving it here lets the deploy be a single cluster-wide op:
//! files-server PUTs the blobs once (idempotent skip-if-exists for
//! re-runs), then POSTs `/_system/release` to a worker. The worker's
//! handler is the existing customer-facing release endpoint; the
//! `_deploy/current` write goes through raft envelope 0 and lands on
//! every node.
//!
//! ## Idempotence
//!
//! `bootstrapPlatformDeployments` is safe to call on every restart.
//! - `bootstrapTenant` skips the S3 PUT when the manifest at
//!   `deployments/00000000000000000001.json` already exists.
//! - `postRelease` is idempotent on the worker side (writing the
//!   same dep_id to `_deploy/current` is a no-op once raft applies).
//! - On warm S3 the whole thing is one HEAD per tenant + one POST
//!   per tenant.

const std = @import("std");
const blob_mod = @import("rove-blob");
const kv_mod = @import("rove-kv");
const files_mod = @import("rove-files");
const qjs = @import("rove-qjs");
const jwt = @import("rove-jwt");

pub const DeployFile = struct {
    path: []const u8,
    content: []const u8,
    /// null → handler source (compile to bytecode). Non-null → static
    /// file served verbatim with this content-type.
    content_type: ?[]const u8 = null,
};

// ── Admin + replay tenant bundles (read from disk at bootstrap) ───────
//
// The admin / replay UI source lives under <web_root>/{admin,replay}/.
// `loadPlatformDeployFiles` reads the listed paths into an owned
// slice of DeployFile at bootstrap time and we ship them as
// `__admin__` / `__replay__` deployments via the same files-server
// route customer tenants use. The bytes are NOT compiled into the
// binary — production images need to ship `web/` alongside the
// binary (or pass `--web-root <path>` pointing at wherever it lives).
//
// Trade-off vs the old `@embedFile` approach: the binary is smaller
// and dashboard / replay-UI edits ship without a rebuild (just
// restart files-server-standalone with the same data dir); cost is
// one extra path argument and one disk read per file at bootstrap.

/// Compile-time list of every file the admin + replay tenants ship.
/// `disk_subpath` is resolved against `web_root`; `tenant_path` is
/// where the file lands inside the tenant's deployment.
const PlatformFile = struct {
    tenant: enum { admin, replay },
    disk_subpath: []const u8,
    tenant_path: []const u8,
    content_type: ?[]const u8,
};

const PLATFORM_FILES = [_]PlatformFile{
    // __admin__ tenant
    .{ .tenant = .admin, .disk_subpath = "admin/handler.mjs",            .tenant_path = "index.mjs",                  .content_type = null },
    .{ .tenant = .admin, .disk_subpath = "admin/middleware.mjs",         .tenant_path = "_middlewares/index.mjs",     .content_type = null },
    .{ .tenant = .admin, .disk_subpath = "admin/index.html",             .tenant_path = "_static/index.html",         .content_type = "text/html; charset=utf-8" },
    .{ .tenant = .admin, .disk_subpath = "admin/app.js",                 .tenant_path = "_static/app.js",             .content_type = "application/javascript" },
    .{ .tenant = .admin, .disk_subpath = "admin/api.js",                 .tenant_path = "_static/api.js",             .content_type = "application/javascript" },
    .{ .tenant = .admin, .disk_subpath = "admin/app.css",                .tenant_path = "_static/app.css",            .content_type = "text/css" },
    .{ .tenant = .admin, .disk_subpath = "admin/pages/login.js",         .tenant_path = "_static/pages/login.js",     .content_type = "application/javascript" },
    .{ .tenant = .admin, .disk_subpath = "admin/pages/instances.js",     .tenant_path = "_static/pages/instances.js", .content_type = "application/javascript" },
    .{ .tenant = .admin, .disk_subpath = "admin/pages/instance.js",      .tenant_path = "_static/pages/instance.js",  .content_type = "application/javascript" },
    .{ .tenant = .admin, .disk_subpath = "admin/codemirror.mjs",         .tenant_path = "_static/codemirror.mjs",     .content_type = "application/javascript" },
    // __replay__ tenant (iframe + WASM shells)
    .{ .tenant = .replay, .disk_subpath = "replay/index.html",           .tenant_path = "_static/index.html",         .content_type = "text/html; charset=utf-8" },
    .{ .tenant = .replay, .disk_subpath = "replay/app.js",               .tenant_path = "_static/app.js",             .content_type = "application/javascript" },
    .{ .tenant = .replay, .disk_subpath = "replay/wasm.html",            .tenant_path = "_static/wasm.html",          .content_type = "text/html; charset=utf-8" },
    .{ .tenant = .replay, .disk_subpath = "replay/wasm-app.mjs",         .tenant_path = "_static/wasm-app.mjs",       .content_type = "application/javascript" },
    .{ .tenant = .replay, .disk_subpath = "replay/rtap.mjs",             .tenant_path = "_static/rtap.mjs",           .content_type = "application/javascript" },
    .{ .tenant = .replay, .disk_subpath = "replay/qjs_arena_wasm.js",    .tenant_path = "_static/qjs_arena_wasm.js",  .content_type = "application/javascript" },
    .{ .tenant = .replay, .disk_subpath = "replay/qjs_arena_wasm.wasm",  .tenant_path = "_static/qjs_arena_wasm.wasm", .content_type = "application/wasm" },
};

/// Read every file the admin + replay deployments need from disk.
/// Returns `{ admin, replay }` — each a freshly-allocated slice of
/// `DeployFile` whose `content` bytes are owned by `allocator`. Caller
/// frees via `freePlatformDeployFiles`.
pub const LoadedPlatformFiles = struct {
    admin: []DeployFile,
    replay: []DeployFile,
};

pub fn loadPlatformDeployFiles(
    allocator: std.mem.Allocator,
    web_root: []const u8,
) !LoadedPlatformFiles {
    var admin: std.ArrayList(DeployFile) = .empty;
    errdefer {
        for (admin.items) |f| allocator.free(f.content);
        admin.deinit(allocator);
    }
    var replay: std.ArrayList(DeployFile) = .empty;
    errdefer {
        for (replay.items) |f| allocator.free(f.content);
        replay.deinit(allocator);
    }

    // Generous per-file cap — the largest current asset is
    // qjs_arena_wasm.wasm at ~1 MiB; 8 MiB leaves room for codemirror
    // and a moderately bloated UI before this needs revisiting.
    const MAX_FILE: usize = 8 * 1024 * 1024;

    for (PLATFORM_FILES) |pf| {
        const full_path = try std.fs.path.join(allocator, &.{ web_root, pf.disk_subpath });
        defer allocator.free(full_path);

        const bytes = std.fs.cwd().readFileAlloc(allocator, full_path, MAX_FILE) catch |err| {
            std.log.err("bootstrap: read {s} failed: {s}", .{ full_path, @errorName(err) });
            return err;
        };
        errdefer allocator.free(bytes);

        const df: DeployFile = .{
            .path = pf.tenant_path,
            .content = bytes,
            .content_type = pf.content_type,
        };
        switch (pf.tenant) {
            .admin => try admin.append(allocator, df),
            .replay => try replay.append(allocator, df),
        }
    }

    return .{
        .admin = try admin.toOwnedSlice(allocator),
        .replay = try replay.toOwnedSlice(allocator),
    };
}

pub fn freePlatformDeployFiles(allocator: std.mem.Allocator, loaded: LoadedPlatformFiles) void {
    for (loaded.admin) |f| allocator.free(f.content);
    allocator.free(loaded.admin);
    for (loaded.replay) |f| allocator.free(f.content);
    allocator.free(loaded.replay);
}

/// Tenant ids that this module bootstraps. Kept here so the names
/// are colocated with the deploy file lists; consumers wanting the
/// full tenant model use `rove-tenant` directly.
pub const ADMIN_TENANT_ID: []const u8 = "__admin__";
pub const REPLAY_TENANT_ID: []const u8 = "__replay__";

// ── QuickJS compiler used during bootstrap ────────────────────────────
//
// The deploy path needs a JS compiler to turn `.mjs` source into
// bytecode (the customer dispatcher executes from the compiled
// bytecode, not from source). The compiler is single-runtime + no
// module loader; admin's cross-module imports (`_middlewares/index.mjs`
// imported by `index.mjs`) resolve at execution time on the worker,
// not at compile time here.

const QjsCompiler = struct {
    runtime: qjs.Runtime,
    context: qjs.Context,

    fn init() !QjsCompiler {
        var rt = try qjs.Runtime.init();
        errdefer rt.deinit();
        const ctx = try rt.newContext();
        return .{ .runtime = rt, .context = ctx };
    }

    fn deinit(self: *QjsCompiler) void {
        self.context.deinit();
        self.runtime.deinit();
    }

    fn compile(
        ctx_opaque: ?*anyopaque,
        source: []const u8,
        filename: [:0]const u8,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *QjsCompiler = @ptrCast(@alignCast(ctx_opaque.?));
        const kind: qjs.EvalFlags = if (files_mod.isJsModule(filename))
            .{ .kind = .module }
        else
            .{};
        return self.context.compileToBytecode(source, filename, allocator, kind);
    }
};

// ── Per-tenant bootstrap step ─────────────────────────────────────────

pub const Error = error{
    BootstrapFailed,
    ReleasePostFailed,
    OutOfMemory,
};

/// Compile + upload a single tenant's deploy bundle. Does NOT write
/// `_deploy/current` — that's the worker's job; the caller follows
/// up with `postRelease` to put the pointer through raft.
///
/// Returns the deployment id (always 1 today; future revisions could
/// rev the bundle). `data_dir` is files-server's local working dir
/// for the per-node files.db that holds the deploy index.
///
/// `cluster` (production.md #1.4): when set, the manifest JSON is
/// ALSO written into the per-tenant Cluster store under
/// `deployment/{N:020d}/manifest` + `deployment/current = {N}` via
/// `proposeAndWait`. Followers' apply path replicates the same
/// rows. Today this is a dual-write (S3 PUT stays, until worker
/// reads migrate to fetch from files-server's HTTP API instead of
/// S3 directly). Pre-launch the duplicated bytes are acceptable;
/// subsequent commits drop the S3 PUT once read-side migration
/// lands. Pass null for the offline `loop46 seed` path (no
/// running cluster).
pub fn bootstrapTenant(
    allocator: std.mem.Allocator,
    blob_cfg: blob_mod.BackendConfig,
    data_dir: []const u8,
    instance_id: []const u8,
    files: []const DeployFile,
    cluster: ?*kv_mod.Cluster,
) !u64 {
    var manifest_be = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        instance_id,
        "deployments",
    );
    defer manifest_be.deinit();

    // Idempotency for the cluster path: if `deployment/current` is
    // already set, this tenant has been bootstrapped + released.
    // Skip the rebuild and return the recorded id.
    if (cluster) |c| {
        if (try clusterCurrentDeployId(c, instance_id)) |cur_id| {
            return cur_id;
        }
    }

    const inst_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, instance_id });
    defer allocator.free(inst_dir);
    try std.fs.cwd().makePath(inst_dir);

    // Bootstrap's files-index work is scratch only — the durable
    // state is the manifest JSON we upload to S3 below.
    // `files_mod.FileStore.init` requires a KvStore handle, so use
    // a per-call tmp kvexp file that gets deleted on return.
    const scratch_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/.bootstrap-scratch.kv",
        .{inst_dir},
        0,
    );
    defer {
        std.fs.cwd().deleteFile(scratch_path) catch {};
        allocator.free(scratch_path);
    }
    std.fs.cwd().deleteFile(scratch_path) catch {};

    const files_kv = try kv_mod.KvStore.open(allocator, scratch_path);
    defer files_kv.close();

    var fs_store = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        instance_id,
        "file-blobs",
    );
    defer fs_store.deinit();

    var compiler = try QjsCompiler.init();
    defer compiler.deinit();

    var store = files_mod.FileStore.init(
        allocator,
        files_kv,
        fs_store.blobStore(),
        QjsCompiler.compile,
        &compiler,
    );

    for (files) |f| {
        if (f.content_type) |ct| {
            try store.putStatic(f.path, f.content, ct);
        } else {
            try store.putSource(f.path, f.content);
        }
    }

    const entries = try store.assembleManifest();
    defer store.freeEntries(entries);

    // Content-addressed dep_id (truncated sha-256). Same content →
    // same id; same-content re-bootstraps PUT to the same key with
    // identical bytes (no-op at the storage level).
    const next_id = files_mod.manifest_json.computeDeploymentId(entries);

    const json_bytes = try files_mod.manifest_json.encode(allocator, next_id, entries);
    defer allocator.free(json_bytes);

    var key_buf2: [25]u8 = undefined;
    const key2 = files_mod.manifest_json.manifestKey(&key_buf2, next_id);

    // Manifest durability splits on whether a running cluster is
    // supplied:
    //   - cluster != null: write through the raft cluster (production
    //     path post-#1.4). The cluster store is the source of truth;
    //     loop46 workers read via `--files-internal-base`. No S3 PUT.
    //   - cluster == null: offline `loop46 seed` path. No cluster to
    //     talk to, so the manifest goes to S3 and the (eventual)
    //     worker boot trusts the S3-warm fast path above to migrate
    //     it into the cluster store on first contact.
    //
    // Dropping the S3 PUT on the cluster-supplied path closes
    // production.md #1.3 ("stop writing per-tenant S3 manifests at
    // bootstrap"): one durable write per deploy, no
    // 10k-S3-PUTs-per-mass-provisioning waste.
    if (cluster) |c| {
        try writeManifestThroughCluster(allocator, c, instance_id, next_id, json_bytes);
    } else {
        if (!(manifest_be.blobStore().exists(key2) catch false)) {
            manifest_be.blobStore().put(key2, json_bytes) catch {
                if (!(manifest_be.blobStore().exists(key2) catch false)) return Error.BootstrapFailed;
            };
        }
    }
    try store.setCurrentDeploymentId(next_id);

    return next_id;
}

/// Per-tenant Cluster store key for a numbered manifest. Mirrors
/// `manifest_json.manifestKey`'s `00000000000000000001.json` shape
/// (zero-padded u64 hex) but without the `.json` suffix — kv values
/// are bytes, not S3 objects, so the file extension doesn't add
/// anything.
fn clusterManifestKey(buf: *[CLUSTER_MANIFEST_KEY_LEN]u8, dep_id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "deployment/{x:0>20}/manifest", .{dep_id}) catch unreachable;
}

/// "deployment/" (11) + 20 hex nibbles + "/manifest" (9).
pub const CLUSTER_MANIFEST_KEY_LEN: usize = 40;

/// Read `deployment/current` from the per-tenant cluster store.
/// Returns the parsed deployment id when present, null when the
/// key is absent (fresh tenant on this cluster).
///
/// Used by `bootstrapTenant` as the post-migration idempotency
/// check: a non-null result means the cluster has already
/// replicated the manifest, so a re-run on files-server restart
/// should skip the full bootstrap.
fn clusterCurrentDeployId(cluster: *kv_mod.Cluster, instance_id: []const u8) !?u64 {
    const store = cluster.openStore(instance_id) catch |err| switch (err) {
        // A truly fresh tenant store opens just fine; an open
        // failure here is the SQLite layer complaining, which we
        // surface so the caller can decide.
        else => return err,
    };
    const value = store.get("deployment/current") catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    defer cluster.allocator.free(value);
    if (value.len == 0) return null;
    return std.fmt.parseInt(u64, value, 10) catch null;
}

/// Write the manifest + current pointer for a tenant through the
/// cluster's raft consensus. One writeset envelope, two kv ops:
/// `deployment/{N}/manifest = <json>` + `deployment/current =
/// <ascii decimal>`. Returns the raft seq the proposal committed
/// at on success.
///
/// `manifest_json_bytes` may be empty when the caller is just
/// re-asserting the current pointer (S3-warm idempotent case);
/// the manifest write is skipped in that case so we don't
/// overwrite the real bytes with empty.
fn writeManifestThroughCluster(
    allocator: std.mem.Allocator,
    cluster: *kv_mod.Cluster,
    instance_id: []const u8,
    dep_id: u64,
    manifest_json_bytes: []const u8,
) !void {
    if (!cluster.raft.isLeader()) {
        // Followers / a non-leader at startup just skip the
        // through-raft write. The leader-side bootstrap path will
        // populate the cluster store; followers replicate.
        // Idempotent re-runs are fine — the apply path filters
        // by `_apply_state.last_applied_raft_idx`.
        return;
    }

    var ws = kv_mod.WriteSet.init(allocator);
    defer ws.deinit();

    if (manifest_json_bytes.len > 0) {
        var mk_buf: [CLUSTER_MANIFEST_KEY_LEN]u8 = undefined;
        const manifest_key = clusterManifestKey(&mk_buf, dep_id);
        try ws.addPut(manifest_key, manifest_json_bytes);
    }

    var dec_buf: [32]u8 = undefined;
    const dec = std.fmt.bufPrint(&dec_buf, "{d}", .{dep_id}) catch unreachable;
    try ws.addPut("deployment/current", dec);

    const ws_bytes = try ws.encode(allocator);
    defer allocator.free(ws_bytes);

    // Envelope type 2 = files-server's manifest writeset (registered
    // at standalone startup with leader_skip = false). See
    // ENVELOPE_FILES_WRITESET in src/files_server/thread.zig.
    const env = try kv_mod.encodeEnvelope(allocator, 2, instance_id, ws_bytes);
    defer allocator.free(env);

    _ = cluster.proposeAndWait(env, 10 * std.time.ns_per_s) catch |err| switch (err) {
        // Lost leadership mid-flight. Logged but not fatal — the
        // S3 PUT above is the load-bearing write today; cluster
        // store is supplementary until reads migrate.
        error.NotLeader, error.ProposalTimedOut, error.QueueFull, error.ShuttingDown => {
            std.log.warn(
                "files-server bootstrap: through-cluster manifest write for {s} dep={d} failed: {s}",
                .{ instance_id, dep_id, @errorName(err) },
            );
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

// ── Release POST + JWT mint ───────────────────────────────────────────

/// Mint a 5-minute services-JWT carrying `cap`. Caller frees.
pub fn mintCapToken(allocator: std.mem.Allocator, jwt_secret: []const u8, cap: []const u8) ![]u8 {
    const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
    const exp_ms: i64 = now_ms + 5 * 60 * 1000;
    return jwt.mint(allocator, jwt_secret, .{
        .exp_ms = exp_ms,
        .caps = &.{cap},
    });
}

/// POST `/_system/release` to the cluster leader so the worker writes
/// `_deploy/current = dep_id` for `tenant_id` via raft envelope 0.
/// `leader_url` should be the admin-host URL (e.g.
/// `https://app.loop46.localhost:8197`); files-server typically
/// receives it as an operator-supplied flag.
///
/// Idempotent: re-posting the same dep_id re-stamps the kv row,
/// which raft replicates as a redundant write — harmless.
///
/// Implementation: shells out to `curl` because Zig 0.15's
/// `std.http.Client` is HTTP/1.1-only and the worker speaks h2
/// exclusively (rejects HTTP/1.1 with `426 Upgrade Required`).
/// rove-h2 has a client surface (used inside the worker for
/// dispatcher-internal proxy traffic), but wrapping it for a single
/// one-shot POST is a lot of code; `curl` is already a smoke + ops
/// dependency and gives us a real h2 client for free. A future
/// revision can swap this for rove-h2's client surface.
/// Internal: shell out to curl for a POST with a Bearer-token JSON
/// body. Expects 204. Reads optional `LOOP46_LEADER_CACERT` +
/// `LOOP46_LEADER_RESOLVE` env vars so the smoke can pass dev-cert
/// + DNS overrides through without putting them in the binary's
/// flag surface.
fn curlPostJson(
    allocator: std.mem.Allocator,
    url: []const u8,
    bearer_token: []const u8,
    body: []const u8,
) !void {
    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{bearer_token});
    defer allocator.free(auth_header);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "curl",        "--silent",
        "--show-error", "--max-time",
        "30",          "--write-out",
        "%{http_code}", "--output",
        "/dev/null",   "-X",
        "POST",        "-H",
        auth_header,   "-H",
        "Content-Type: application/json",
        "-d",          body,
    });
    // Hoist env-var slices to function scope so their lifetime
    // outlives the spawn() call. (An inner-block `defer
    // allocator.free` would fire before child.spawn reads argv,
    // leaving curl with garbage strings.)
    const cacert_opt: ?[]u8 = std.process.getEnvVarOwned(allocator, "LOOP46_LEADER_CACERT") catch null;
    defer if (cacert_opt) |s| allocator.free(s);
    if (cacert_opt) |s| try argv.appendSlice(allocator, &.{ "--cacert", s });

    const resolve_opt: ?[]u8 = std.process.getEnvVarOwned(allocator, "LOOP46_LEADER_RESOLVE") catch null;
    defer if (resolve_opt) |s| allocator.free(s);
    if (resolve_opt) |s| try argv.appendSlice(allocator, &.{ "--resolve", s });

    try argv.append(allocator, url);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var stdout_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    child.spawn() catch |err| {
        std.log.err("files-server bootstrap: spawn curl: {s}", .{@errorName(err)});
        return Error.ReleasePostFailed;
    };
    child.collectOutput(allocator, &stdout_buf, &stderr_buf, 4096) catch |err| {
        std.log.err("files-server bootstrap: collectOutput: {s}", .{@errorName(err)});
        _ = child.kill() catch {};
        return Error.ReleasePostFailed;
    };
    const term = child.wait() catch |err| {
        std.log.err("files-server bootstrap: curl wait: {s}", .{@errorName(err)});
        return Error.ReleasePostFailed;
    };

    const exited = term == .Exited and term.Exited == 0;
    const http_code_str = std.mem.trim(u8, stdout_buf.items, " \t\r\n");
    const http_code = std.fmt.parseInt(u16, http_code_str, 10) catch 0;
    if (!exited or http_code != 204) {
        const stderr_s = std.mem.trim(u8, stderr_buf.items, " \t\r\n");
        std.log.err(
            "files-server bootstrap: POST {s} returned http={d} curl_term={any} stderr={s}",
            .{ url, http_code, term, stderr_s },
        );
        return Error.ReleasePostFailed;
    }
}

pub fn postRelease(
    allocator: std.mem.Allocator,
    leader_url: []const u8,
    jwt_secret: []const u8,
    tenant_id: []const u8,
    dep_id: u64,
) !void {
    const token = try mintCapToken(allocator, jwt_secret, jwt.Cap.RELEASE);
    defer allocator.free(token);

    const url = try std.fmt.allocPrint(allocator, "{s}/_system/release", .{leader_url});
    defer allocator.free(url);

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"tenant_id\":\"{s}\",\"dep_id\":{d}}}",
        .{ tenant_id, dep_id },
    );
    defer allocator.free(body);

    try curlPostJson(allocator, url, token, body);
}

/// POST `/_system/admin-kv` with a list of `key=value` pairs (parsed
/// from `--bootstrap-kv key=value` flags). The worker writes each
/// pair into `__admin__/app.db` via raft so every node sees the same
/// admin config.
///
/// `pairs` is a slice of `"key=value"` strings (the flag's raw form).
/// Empty list → no-op (no POST). Mints a JWT with `cap=admin-kv`.
pub fn postAdminKv(
    allocator: std.mem.Allocator,
    leader_url: []const u8,
    jwt_secret: []const u8,
    pairs: []const []const u8,
) !void {
    if (pairs.len == 0) return;

    const token = try mintCapToken(allocator, jwt_secret, jwt.Cap.ADMIN_KV);
    defer allocator.free(token);

    const url = try std.fmt.allocPrint(allocator, "{s}/_system/admin-kv", .{leader_url});
    defer allocator.free(url);

    // Build `{"pairs":[{"key":"k","value":"v"},...]}`. Hand-coded
    // because the keys/values are small + deterministic and we want
    // to avoid pulling std.json's encoder for ~50 lines of glue.
    // Validates pair shape (`key=value`, key non-empty, no
    // double-quotes, no NUL).
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"pairs\":[");
    for (pairs, 0..) |pair, i| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return Error.ReleasePostFailed;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (key.len == 0) return Error.ReleasePostFailed;
        if (i > 0) try json.append(allocator, ',');
        try json.appendSlice(allocator, "{\"key\":");
        try jsonEncodeString(&json, allocator, key);
        try json.appendSlice(allocator, ",\"value\":");
        try jsonEncodeString(&json, allocator, value);
        try json.append(allocator, '}');
    }
    try json.appendSlice(allocator, "]}");

    try curlPostJson(allocator, url, token, json.items);
}

/// Append `s` to `out` as a JSON string literal. Escapes the
/// characters JSON requires escaping for and rejects control bytes
/// + NUL — our admin-kv values come from `--bootstrap-kv` flags so
/// shouldn't contain anything weird, but we belt-and-suspender it.
fn jsonEncodeString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |b| {
        switch (b) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => return Error.ReleasePostFailed,
            else => try out.append(allocator, b),
        }
    }
    try out.append(allocator, '"');
}

// ── Public entry point ────────────────────────────────────────────────

/// Bootstrap admin + replay deploys + push admin-kv pairs.
/// Idempotent — safe to run on every files-server boot. On warm S3
/// + a healthy cluster this is roughly: 2 HEADs (one per manifest),
/// 2 release POSTs that raft applies as no-ops, and 1 admin-kv POST
/// that re-stamps the same kv rows.
///
/// `leader_url` must point at a cluster node that can route
/// `/_system/*`. The smoke / operator points it at the elected
/// leader's admin host (e.g. `https://app.loop46.localhost:8197`).
/// Followers reject these POSTs with 503 — the caller polls
/// `discover_leader`-style if needed before invoking this.
///
/// `bootstrap_kv` is a slice of `"key=value"` strings parsed from
/// `--bootstrap-kv` flags. Empty slice = no admin-kv POST.
pub fn bootstrapPlatformDeployments(
    allocator: std.mem.Allocator,
    blob_cfg: blob_mod.BackendConfig,
    data_dir: []const u8,
    leader_url: []const u8,
    jwt_secret: []const u8,
    bootstrap_kv: []const []const u8,
    cluster: ?*kv_mod.Cluster,
    web_root: []const u8,
) !void {
    const loaded = try loadPlatformDeployFiles(allocator, web_root);
    defer freePlatformDeployFiles(allocator, loaded);

    const admin_dep_id = try bootstrapTenant(
        allocator,
        blob_cfg,
        data_dir,
        ADMIN_TENANT_ID,
        loaded.admin,
        cluster,
    );
    try postRelease(allocator, leader_url, jwt_secret, ADMIN_TENANT_ID, admin_dep_id);
    std.log.info(
        "files-server bootstrap: __admin__ deploy {d} released (web_root={s})",
        .{ admin_dep_id, web_root },
    );

    const replay_dep_id = try bootstrapTenant(
        allocator,
        blob_cfg,
        data_dir,
        REPLAY_TENANT_ID,
        loaded.replay,
        cluster,
    );
    try postRelease(allocator, leader_url, jwt_secret, REPLAY_TENANT_ID, replay_dep_id);
    std.log.info(
        "files-server bootstrap: __replay__ deploy {d} released",
        .{replay_dep_id},
    );

    if (bootstrap_kv.len > 0) {
        try postAdminKv(allocator, leader_url, jwt_secret, bootstrap_kv);
        std.log.info(
            "files-server bootstrap: pushed {d} admin-kv pair(s)",
            .{bootstrap_kv.len},
        );
    }
}
