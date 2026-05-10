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

// ── Embedded admin + replay tenant bundles ────────────────────────────
//
// The admin UI bundle ships in the binary so a fresh cluster has a
// working dashboard at `app.{public_suffix}/` after the first
// files-server boot. Each file lands as a `_static/<path>` (or the
// JS `index.mjs` / `_middlewares/index.mjs`) entry in __admin__'s
// initial deployment.

const ADMIN_HANDLER_SRC = @embedFile("admin_handler_mjs");
const ADMIN_MIDDLEWARE_SRC = @embedFile("admin_middleware_mjs");
const ADMIN_UI_INDEX_HTML = @embedFile("admin_ui_index_html");
const ADMIN_UI_APP_JS = @embedFile("admin_ui_app_js");
const ADMIN_UI_API_JS = @embedFile("admin_ui_api_js");
const ADMIN_UI_APP_CSS = @embedFile("admin_ui_app_css");
const ADMIN_UI_PAGE_LOGIN = @embedFile("admin_ui_page_login");
const ADMIN_UI_PAGE_INSTANCES = @embedFile("admin_ui_page_instances");
const ADMIN_UI_PAGE_INSTANCE = @embedFile("admin_ui_page_instance");
const ADMIN_UI_CODEMIRROR = @embedFile("admin_ui_codemirror");

pub const ADMIN_DEPLOY_FILES = [_]DeployFile{
    .{ .path = "index.mjs", .content = ADMIN_HANDLER_SRC },
    .{ .path = "_middlewares/index.mjs", .content = ADMIN_MIDDLEWARE_SRC },
    .{ .path = "_static/index.html", .content = ADMIN_UI_INDEX_HTML, .content_type = "text/html; charset=utf-8" },
    .{ .path = "_static/app.js", .content = ADMIN_UI_APP_JS, .content_type = "application/javascript" },
    .{ .path = "_static/api.js", .content = ADMIN_UI_API_JS, .content_type = "application/javascript" },
    .{ .path = "_static/app.css", .content = ADMIN_UI_APP_CSS, .content_type = "text/css" },
    .{ .path = "_static/pages/login.js", .content = ADMIN_UI_PAGE_LOGIN, .content_type = "application/javascript" },
    .{ .path = "_static/pages/instances.js", .content = ADMIN_UI_PAGE_INSTANCES, .content_type = "application/javascript" },
    .{ .path = "_static/pages/instance.js", .content = ADMIN_UI_PAGE_INSTANCE, .content_type = "application/javascript" },
    .{ .path = "_static/codemirror.mjs", .content = ADMIN_UI_CODEMIRROR, .content_type = "application/javascript" },
};

const REPLAY_INDEX_HTML = @embedFile("replay_index_html");
const REPLAY_APP_JS = @embedFile("replay_app_js");

pub const REPLAY_DEPLOY_FILES = [_]DeployFile{
    .{ .path = "_static/index.html", .content = REPLAY_INDEX_HTML, .content_type = "text/html; charset=utf-8" },
    .{ .path = "_static/app.js", .content = REPLAY_APP_JS, .content_type = "application/javascript" },
};

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
    // Fast path: if manifest 1 already exists in S3, the cluster has
    // already bootstrapped this tenant. Skip every other step.
    // (Idempotency check stays S3-side until the manifest fully
    // moves to the cluster store — keeps the offline `loop46 seed`
    // path working without a running cluster.)
    var manifest_be = try blob_mod.BlobBackend.openPerTenant(
        allocator,
        blob_cfg,
        instance_id,
        "deployments",
    );
    defer manifest_be.deinit();
    var key_buf: [25]u8 = undefined;
    const key = files_mod.manifest_json.manifestKey(&key_buf, 1);
    if (manifest_be.blobStore().exists(key) catch false) {
        // S3-side idempotent — but if a cluster is supplied AND the
        // cluster store is missing the entry (operator wiped local
        // data_dir, brand-new cluster against warm S3), still write
        // through the cluster so followers / restarts see consistent
        // state.
        if (cluster) |c| try writeManifestThroughCluster(allocator, c, instance_id, 1, "");
        return 1;
    }

    const inst_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, instance_id });
    defer allocator.free(inst_dir);
    try std.fs.cwd().makePath(inst_dir);

    const files_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/files.db", .{inst_dir}, 0);
    defer allocator.free(files_db_path);

    const files_kv = try kv_mod.KvStore.open(allocator, files_db_path);
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

    const cur = try store.currentDeploymentId();
    const next_id = cur + 1;

    const entries = try store.assembleManifest();
    defer store.freeEntries(entries);

    const json_bytes = try files_mod.manifest_json.encode(allocator, next_id, entries);
    defer allocator.free(json_bytes);

    var key_buf2: [25]u8 = undefined;
    const key2 = files_mod.manifest_json.manifestKey(&key_buf2, next_id);
    if (!(manifest_be.blobStore().exists(key2) catch false)) {
        manifest_be.blobStore().put(key2, json_bytes) catch {
            if (!(manifest_be.blobStore().exists(key2) catch false)) return Error.BootstrapFailed;
        };
    }
    try store.setCurrentDeploymentId(next_id);

    // Dual-write through the raft cluster (#1.4 step 2). The
    // cluster store ends up with the same manifest JSON the S3
    // PUT above just wrote, plus a `deployment/current` pointer.
    // After read-side migration lands the S3 PUT goes away.
    if (cluster) |c| try writeManifestThroughCluster(
        allocator,
        c,
        instance_id,
        next_id,
        json_bytes,
    );

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
) !void {
    const admin_dep_id = try bootstrapTenant(
        allocator,
        blob_cfg,
        data_dir,
        ADMIN_TENANT_ID,
        &ADMIN_DEPLOY_FILES,
        cluster,
    );
    try postRelease(allocator, leader_url, jwt_secret, ADMIN_TENANT_ID, admin_dep_id);
    std.log.info(
        "files-server bootstrap: __admin__ deploy {d} released",
        .{admin_dep_id},
    );

    const replay_dep_id = try bootstrapTenant(
        allocator,
        blob_cfg,
        data_dir,
        REPLAY_TENANT_ID,
        &REPLAY_DEPLOY_FILES,
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
