const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── rove: core entity/collection library ──
    const rove_mod = b.addModule("rove", .{
        .root_source_file = b.path("src/rove/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const rove_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "rove",
        .root_module = rove_mod,
    });
    b.installArtifact(rove_lib);

    // ── rove-io: io_uring wrapper using rove entities ──
    const io_mod = b.addModule("rove-io", .{
        .root_source_file = b.path("src/io/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    io_mod.addImport("rove", rove_mod);
    io_mod.link_libc = true;

    // ── rove-h2: HTTP/2 protocol on rove-io + nghttp2 ──
    const h2_mod = b.addModule("rove-h2", .{
        .root_source_file = b.path("src/h2/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    h2_mod.addImport("rove", rove_mod);
    h2_mod.addImport("rove-io", io_mod);
    h2_mod.link_libc = true;
    h2_mod.linkSystemLibrary("nghttp2", .{});
    h2_mod.linkSystemLibrary("ssl", .{});
    h2_mod.linkSystemLibrary("crypto", .{});

    // ── kvexp: embedded multi-tenant KV (anarchodev/kvexp), fetched as
    // a Zig package (pinned in build.zig.zon). LMDB-backed durable
    // B-tree fronted by an in-memory per-store memtable (overlay); the
    // per-tenant state engine. The fetched `kvexp` module already links
    // system liblmdb + libc (see kvexp's build.zig).
    const kvexp_dep = b.dependency("kvexp", .{ .target = target, .optimize = optimize });
    const kvexp_mod = kvexp_dep.module("kvexp");

    // ── rove-kv: KV store + raft. Standalone leaf module — does NOT
    // depend on rove or rove-io. raft_net is a direct liburing wrapper;
    // raft itself is vendored willemt/raft. See
    // memory/feedback_raft_net_direct_liburing.md.
    //
    // State engine is kvexp (vendored). raft_log persistence is still
    // sqlite for now (raft log is its own concern, separate from the
    // KV state path); follow-up cutover will migrate it.
    // V2 (docs/v2-build-order.md §Phase 2): the `raft-kv` module now roots
    // at the spine-free FACADE (`kvlimbs.zig`) — the kvexp-backed limbs +
    // metrics + envelope codec, NONE of the willemt-raft / io_uring spine.
    // Every importer (`rove-js`, files-server, files, log, tenant) gets the
    // facade at once; the consensus engine is the V2 bridge. The old V1
    // spine (`root.zig`, `cluster.zig`, `raft_node.zig`, …) is now dead on
    // this branch — V1 preservation dropped (it's deleted at cutover) — so
    // the willemt C sources + sqlite3 it needed are gone from this module.
    const kv_mod = b.addModule("raft-kv", .{
        .root_source_file = b.path("src/kv/kvlimbs.zig"),
        .target = target,
        .optimize = optimize,
    });
    kv_mod.link_libc = true;
    kv_mod.addImport("kvexp", kvexp_mod);

    // ── rove-blob: pluggable blob storage (fs + s3 backends) ──
    //
    // Leaf module — stdlib only. The fs backend lives in src/blob/fs.zig
    // and ships in Phase 1a. The s3 backend lands in Phase 6.
    const blob_mod = b.addModule("rove-blob", .{
        .root_source_file = b.path("src/blob/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    blob_mod.link_libc = true;
    // libcurl backs the S3 outbound path. Replaces std.http.Client,
    // which has a string of bugs in 0.15.x (HEAD stalls / segfaults,
    // no application-level timeouts → 15-minute kernel TCP retry
    // hangs, incomplete flate Compress, etc.) that we kept patching
    // around. libcurl handles HTTPS keep-alive, timeouts, and HEAD
    // correctly out of the box.
    blob_mod.linkSystemLibrary("curl", .{});

    // ── rove-files: content-addressed module store + deploy index ──
    //
    // Library layer only in Phase 1b session 1. The `rove-files-server`
    // binary (HTTP/2 wrapper + raft group) lands in a follow-up session.
    const files_mod = b.addModule("rove-files", .{
        .root_source_file = b.path("src/files/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    files_mod.addImport("raft-kv", kv_mod);
    files_mod.addImport("rove-blob", blob_mod);

    // ── rove-log: per-tenant request log store ──
    //
    // Phase 3. Mirrors rove-files's "per-tenant SQLite index + rove-blob
    // bulk storage" shape. Records are batched in memory and shipped
    // through the worker's raft group as opaque-bytes envelopes; the
    // worker's apply callback decodes and persists per-node.
    const log_mod = b.addModule("rove-log", .{
        .root_source_file = b.path("src/log/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    log_mod.addImport("raft-kv", kv_mod);
    log_mod.addImport("rove-blob", blob_mod);

    // ── rove-bodies: transport-layer body streaming buffer ──
    //
    // Per `docs/readset-replication-plan.md` Phase 2: fetch-response
    // bodies and inbound request bodies stream into a per-tenant
    // in-memory buffer that periodically flushes to S3 as one object
    // per batch. The raft entry's readset carries a `BodyRef =
    // (batch_id, offset, len)` pointer; the bytes never ride in the
    // entry. Leaf module — depends only on rove-blob for the
    // BlobStore interface.
    const bodies_mod = b.addModule("rove-bodies", .{
        .root_source_file = b.path("src/bodies/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    bodies_mod.addImport("rove-blob", blob_mod);

    // ── rove-plan: per-tenant plan tiers + effective limits ──────────
    //
    // A LEAF (std only) so both the worker (`rove-js`: rate + body caps)
    // and the log-query surface (`rove-log-server`: retention window) can
    // import the ONE tier table without a cycle (docs/plan-tiers.md). Owns
    // `RateLimitCaps`, which the limiter re-exports.
    const plan_mod = b.addModule("rove-plan", .{
        .root_source_file = b.path("src/plan/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── rove-tape: deterministic replay capture + replay bundle ──
    //
    // Phase 4. Per-channel append-only tapes (kv, date, math_random,
    // crypto_random, module) that serialize to self-describing blobs.
    // The worker attaches tape references to each LogRecord; replay
    // reads them back via `parse` and feeds them to instrumented
    // globals.
    //
    // `bundle.zig` (PLAN §10.12) renders a single request_id's log
    // record + captured tapes as the JSON document the browser-side
    // replay harness consumes. That brings rove-log + rove-blob in as
    // deps — bundle reads the LogRecord and fetches tape blobs.
    const tape_mod = b.addModule("rove-tape", .{
        .root_source_file = b.path("src/tape/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tape_mod.addImport("rove-log", log_mod);
    tape_mod.addImport("rove-blob", blob_mod);
    // Readset's `fetch_responses` channel records `BodyRef` values
    // pointing into the per-tenant readset-blob store
    // (`docs/readset-replication-plan.md` Phase 2c-2).
    tape_mod.addImport("rove-bodies", bodies_mod);
    // rove-kv is only used in bundle.zig's tests (to open a fresh
    // LogStore). Production bundle code never touches kv directly.
    tape_mod.addImport("raft-kv", kv_mod);

    // ── rove-qjs: arenajs (quickjs-ng fork) wrapper ──
    //
    // arenajs (anarchodev/arenajs) is a quickjs-ng fork that replaces
    // malloc + GC with a dual bump arena (base + per-request) and
    // collapses per-request restore to a single cursor write. It is
    // fetched as a Zig package (pinned in build.zig.zon) and exposes a
    // static library `arenajs`; the quickjs/arena C sources + flags live
    // in arenajs's own build.zig. The Zig wrapper stays here in rove.
    const qjs_mod = b.addModule("rove-qjs", .{
        .root_source_file = b.path("src/qjs/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    qjs_mod.link_libc = true;
    qjs_mod.linkSystemLibrary("m", .{});
    qjs_mod.linkSystemLibrary("pthread", .{});
    const arenajs_dep = b.dependency("arenajs", .{ .target = target, .optimize = optimize });
    qjs_mod.addIncludePath(arenajs_dep.path(".")); // quickjs.h, qjs-arena.h
    qjs_mod.linkLibrary(arenajs_dep.artifact("arenajs"));

    // ── rove-jwt: shared HS256 mint + verify for the standalone
    //    services' Authorization gate (log-server, files-server).
    //    Pure stdlib, no external library — see src/jwt/root.zig.
    const jwt_mod = b.addModule("rove-jwt", .{
        .root_source_file = b.path("src/jwt/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── rove-log-server: standalone log-server (Phase 5.5 a) ─────────
    //
    // Indexer + h2 query API, S3-backed. Runs in the loop46 process
    // for the in-process spawn path; the standalone binary at
    // examples/log_server_standalone.zig wraps the same modules.
    const log_server_mod = b.addModule("rove-log-server", .{
        .root_source_file = b.path("src/log_server/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    log_server_mod.link_libc = true;
    log_server_mod.linkSystemLibrary("nghttp2", .{});
    log_server_mod.linkSystemLibrary("ssl", .{});
    log_server_mod.linkSystemLibrary("crypto", .{});
    // Per-record raw-deflate compression on log batch payloads.
    // Zig 0.15.x stdlib's `flate.Compress.drain` is incomplete
    // (panics on payloads larger than ~32 KB lookahead), so we use
    // libz directly. Already a transitive dep via nghttp2.
    log_server_mod.linkSystemLibrary("z", .{});
    log_server_mod.addImport("rove", rove_mod);
    log_server_mod.addImport("rove-io", io_mod);
    log_server_mod.addImport("rove-h2", h2_mod);
    log_server_mod.addImport("raft-kv", kv_mod);
    log_server_mod.addImport("rove-blob", blob_mod);
    log_server_mod.addImport("rove-log", log_mod);
    log_server_mod.addImport("rove-jwt", jwt_mod);
    log_server_mod.addImport("rove-plan", plan_mod);

    // ── rove-ssrf: SSRF blocklist + dev-only test overrides ─────────
    //
    // What's left after the http.send N-way re-platform + the
    // 2026-05-24 durability-as-JS-shim flip: the libcurl engine
    // (`js/fetch_engine.zig`) and webhook.send (JS shim) consult this
    // module to refuse outbound HTTP to RFC1918 / loopback /
    // cloud-metadata addresses. No raft, no SQLite, no scheduler
    // thread — just IP-range checks + two test-only escape flags.
    const ssrf_mod = b.addModule("rove-ssrf", .{
        .root_source_file = b.path("src/ssrf/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── rove-acme: in-tree ACME (RFC 8555) HTTP-01 client + :80
    //    challenge responder (auth-domain-plan.md §3.2). Issues
    //    per-host certs into the Phase-2c custom-cert dir. OpenSSL
    //    for EC keygen / ES256 / CSR (same libs as rove-h2); libcurl
    //    (rove-blob) for the CA HTTP calls.
    const acme_mod = b.addModule("rove-acme", .{
        .root_source_file = b.path("src/acme/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    acme_mod.link_libc = true;
    acme_mod.linkSystemLibrary("ssl", .{});
    acme_mod.linkSystemLibrary("crypto", .{});
    acme_mod.addImport("rove-blob", blob_mod);

    // ── rove-files-server: per-instance code operations (Phase 5) ──
    //
    // Compile + upload + deploy + source fetch, wrapping rove-files.
    // Each operation opens its own per-instance SQLite connection so
    // it's safe to call off the worker's h2 thread — later slices add
    // a thread pool and an h2 proxy endpoint for `/_system/files/*`.
    // Needs libc + nghttp2/ssl/crypto because it pulls in rove-qjs,
    // which transitively brings in the C runtime link requirements.
    const files_server_mod = b.addModule("rove-files-server", .{
        .root_source_file = b.path("src/files_server/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    files_server_mod.link_libc = true;
    files_server_mod.linkSystemLibrary("nghttp2", .{});
    files_server_mod.linkSystemLibrary("ssl", .{});
    files_server_mod.linkSystemLibrary("crypto", .{});
    files_server_mod.addImport("rove", rove_mod);
    files_server_mod.addImport("rove-io", io_mod);
    files_server_mod.addImport("rove-h2", h2_mod);
    files_server_mod.addImport("raft-kv", kv_mod);
    files_server_mod.addImport("rove-blob", blob_mod);
    files_server_mod.addImport("rove-files", files_mod);
    files_server_mod.addImport("rove-qjs", qjs_mod);
    files_server_mod.addImport("rove-jwt", jwt_mod);
    // Admin + replay tenant bundles are NOT embedded — they're read
    // from disk at bootstrap by files-server-standalone via its
    // `--web-root <path>` flag (see src/files_server/bootstrap.zig
    // and examples/files_server_standalone.zig). Production deploys
    // ship `web/` alongside the binary; dev iteration is "restart
    // files-server-standalone, no rebuild required."

    // ── Tests ──
    const test_step = b.step("test", "Run all unit tests");

    // rove tests
    const rove_tests = b.addTest(.{ .root_module = rove_mod });
    test_step.dependOn(&b.addRunArtifact(rove_tests).step);

    // rove-io tests
    const io_tests = b.addTest(.{ .root_module = io_mod });
    test_step.dependOn(&b.addRunArtifact(io_tests).step);

    // rove-h2 tests
    const h2_tests = b.addTest(.{ .root_module = h2_mod });
    test_step.dependOn(&b.addRunArtifact(h2_tests).step);
    // Isolated rove-h2 test step — runs just the h2 inline tests (and so
    // compile-checks the WS transport in root.zig) without the rest of the suite.
    const h2_test_step = b.step("h2-test", "Run the rove-h2 unit tests (compile-checks root.zig)");
    h2_test_step.dependOn(&b.addRunArtifact(h2_tests).step);

    // rove-kv tests
    const kv_tests = b.addTest(.{ .root_module = kv_mod });
    test_step.dependOn(&b.addRunArtifact(kv_tests).step);
    // Isolated kv-only test step — a fast, sqlite-free `raft-kv` runner that
    // exercises the KV limbs (incl. the Phase-4 tenant-bundle dump/load) alone.
    const kv_test_step = b.step("kv-test", "Run rove-kv (raft-kv facade) unit tests in isolation");
    kv_test_step.dependOn(&b.addRunArtifact(kv_tests).step);

    // rove-blob tests
    const blob_tests = b.addTest(.{ .root_module = blob_mod });
    test_step.dependOn(&b.addRunArtifact(blob_tests).step);

    // rove-qjs tests
    const qjs_tests = b.addTest(.{ .root_module = qjs_mod });
    test_step.dependOn(&b.addRunArtifact(qjs_tests).step);

    // rove-files tests
    const files_tests = b.addTest(.{ .root_module = files_mod });
    test_step.dependOn(&b.addRunArtifact(files_tests).step);

    // rove-log tests
    const log_tests = b.addTest(.{ .root_module = log_mod });
    test_step.dependOn(&b.addRunArtifact(log_tests).step);

    // rove-tape tests
    const tape_tests = b.addTest(.{ .root_module = tape_mod });
    test_step.dependOn(&b.addRunArtifact(tape_tests).step);

    // rove-bodies tests
    const bodies_tests = b.addTest(.{ .root_module = bodies_mod });
    test_step.dependOn(&b.addRunArtifact(bodies_tests).step);

    // rove-files-server tests
    const files_server_tests = b.addTest(.{ .root_module = files_server_mod });
    test_step.dependOn(&b.addRunArtifact(files_server_tests).step);

    // rove-log-server tests — a dedicated `log-server-test` step, kept OUT of
    // the aggregate `test`: the shared module stays sqlite-free (sqlite is
    // linked at the binary level), so the test gets its OWN module that links
    // sqlite3 (index_db.zig needs it).
    const log_server_test_mod = b.createModule(.{
        .root_source_file = b.path("src/log_server/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    log_server_test_mod.link_libc = true;
    log_server_test_mod.linkSystemLibrary("nghttp2", .{});
    log_server_test_mod.linkSystemLibrary("ssl", .{});
    log_server_test_mod.linkSystemLibrary("crypto", .{});
    log_server_test_mod.linkSystemLibrary("z", .{});
    log_server_test_mod.linkSystemLibrary("sqlite3", .{});
    log_server_test_mod.addImport("rove", rove_mod);
    log_server_test_mod.addImport("rove-io", io_mod);
    log_server_test_mod.addImport("rove-h2", h2_mod);
    log_server_test_mod.addImport("raft-kv", kv_mod);
    log_server_test_mod.addImport("rove-blob", blob_mod);
    log_server_test_mod.addImport("rove-log", log_mod);
    log_server_test_mod.addImport("rove-jwt", jwt_mod);
    log_server_test_mod.addImport("rove-plan", plan_mod);
    const log_server_tests = b.addTest(.{ .root_module = log_server_test_mod });
    const run_log_server_tests = b.addRunArtifact(log_server_tests);
    const log_server_test_step = b.step("log-server-test", "Run rove-log-server unit tests");
    log_server_test_step.dependOn(&run_log_server_tests.step);

    // rove-jwt tests
    const jwt_tests = b.addTest(.{ .root_module = jwt_mod });
    test_step.dependOn(&b.addRunArtifact(jwt_tests).step);

    // rove-ssrf tests
    const ssrf_tests = b.addTest(.{ .root_module = ssrf_mod });
    test_step.dependOn(&b.addRunArtifact(ssrf_tests).step);

    // rove-plan tests — also exposed as a dedicated `plan-test` step for
    // running the tier table in isolation.
    const plan_tests = b.addTest(.{ .root_module = plan_mod });
    const run_plan_tests = b.addRunArtifact(plan_tests);
    test_step.dependOn(&run_plan_tests.step);
    const plan_test_step = b.step("plan-test", "Run rove-plan (tier table) unit tests");
    plan_test_step.dependOn(&run_plan_tests.step);

    // rove-h2 HTTP/1.1 codec (gap #6) — pure std, so a standalone test module.
    const h1_test_mod = b.createModule(.{
        .root_source_file = b.path("src/h2/http1.zig"),
        .target = target,
        .optimize = optimize,
    });
    const h1_tests = b.addTest(.{ .root_module = h1_test_mod });
    const h1_test_step = b.step("h1-test", "Run the HTTP/1.1 codec unit tests");
    h1_test_step.dependOn(&b.addRunArtifact(h1_tests).step);

    // rove-h2 RFC 6455 WebSocket codec (websocket-plan §4.6 piece B) — pure std.
    const ws_test_mod = b.createModule(.{
        .root_source_file = b.path("src/h2/ws.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ws_tests = b.addTest(.{ .root_module = ws_test_mod });
    const ws_test_step = b.step("ws-test", "Run the WebSocket frame codec unit tests");
    ws_test_step.dependOn(&b.addRunArtifact(ws_tests).step);

    // ── rove-tenant: account/user/instance/domain metadata ──
    //
    // M1 slice: just `Instance` + `Domain` with an in-memory cache and
    // coarse flush-on-write invalidation. Auth and the root-instance
    // check arrive in Phase 5.
    const tenant_mod = b.addModule("rove-tenant", .{
        .root_source_file = b.path("src/tenant/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tenant_mod.addImport("raft-kv", kv_mod);

    const tenant_tests = b.addTest(.{ .root_module = tenant_mod });
    test_step.dependOn(&b.addRunArtifact(tenant_tests).step);

    // ── rove-js: worker-side JS dispatcher ──
    //
    // Phase 2 session 1 scope: library only, in-process dispatcher.
    // HTTP/2 accept + router arrives in session 2, raft wiring in
    // session 3. Declared here (not earlier) because it needs qjs_mod
    // and kv_mod to already exist.
    const js_mod = b.addModule("rove-js", .{
        .root_source_file = b.path("src/js/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    js_mod.addImport("rove", rove_mod);
    js_mod.addImport("rove-io", io_mod);
    js_mod.addImport("rove-h2", h2_mod);
    js_mod.addImport("rove-qjs", qjs_mod);
    js_mod.addImport("raft-kv", kv_mod);
    js_mod.addImport("rove-blob", blob_mod);
    js_mod.addImport("rove-files", files_mod);
    js_mod.addImport("rove-log", log_mod);
    js_mod.addImport("rove-log-server", log_server_mod);
    js_mod.addImport("rove-jwt", jwt_mod);
    js_mod.addImport("rove-tape", tape_mod);
    js_mod.addImport("rove-bodies", bodies_mod);
    js_mod.addImport("rove-tenant", tenant_mod);
    js_mod.addImport("rove-ssrf", ssrf_mod);
    js_mod.addImport("rove-plan", plan_mod);
    // Worker reads the per-deployment manifest at release time so the
    // _config/ → kv mirror (config_mirror.zig) can stage config rows
    // alongside the _deploy/current flip.
    js_mod.addImport("rove-files-server", files_server_mod);
    // JS-side runtime polyfills evaluated into every dispatcher's QJS
    // context after the native CFunction bindings install.
    // retry.js provides a customer-side retry helper layered on
    // http.send (no system tenant, no cross-tenant privileges).
    // webhook.js wraps `http.send` (legacy webhook.send compatibility);
    // email.js wraps `webhook.send` (which now layers on http.send);
    // textcodec.js polyfills TextEncoder/Decoder.
    const js_runtime_files: []const struct { name: []const u8, path: []const u8 } = &.{
        // Public doc-carrying shims over `_system.*`
        // (docs/builtin-libs-docs-plan.md Phase A).
        .{ .name = "kv_js", .path = "src/js/globals/kv.js" },
        .{ .name = "console_js", .path = "src/js/globals/console.js" },
        .{ .name = "crypto_js", .path = "src/js/globals/crypto.js" },
        .{ .name = "http_js", .path = "src/js/globals/http.js" },
        .{ .name = "platform_js", .path = "src/js/globals/platform.js" },
        .{ .name = "base64_js", .path = "src/js/globals/base64.js" },
        .{ .name = "urlsearchparams_js", .path = "src/js/globals/urlsearchparams.js" },
        .{ .name = "jwt_js", .path = "src/js/globals/jwt.js" },
        .{ .name = "oauth_js", .path = "src/js/globals/oauth.js" },
        .{ .name = "oidc_js", .path = "src/js/globals/oidc.js" },
        .{ .name = "sessions_js", .path = "src/js/globals/sessions.js" },
        .{ .name = "cron_js", .path = "src/js/globals/cron.js" },
        .{ .name = "retry_js", .path = "src/js/globals/retry.js" },
        .{ .name = "scheduler_js", .path = "src/js/globals/scheduler.js" },
        .{ .name = "schedule_js", .path = "src/js/globals/schedule.js" },
        .{ .name = "on_js", .path = "src/js/globals/on.js" },
        .{ .name = "stream_js", .path = "src/js/globals/stream.js" },
        .{ .name = "next_js", .path = "src/js/globals/next.js" },
        .{ .name = "webhook_js", .path = "src/js/globals/webhook.js" },
        .{ .name = "email_js", .path = "src/js/globals/email.js" },
        .{ .name = "textcodec_js", .path = "src/js/globals/textcodec.js" },
        .{ .name = "users_js", .path = "src/js/globals/users.js" },
        .{ .name = "activitypub_js", .path = "src/js/globals/activitypub.js" },
        .{ .name = "blob_js", .path = "src/js/globals/blob.js" },

        // Built-in handler modules — compiled to bytecode at NodeState
        // init, resolved via the `__system/` module-path prefix
        // (`docs/effect-reification-plan.md` Phase 5 PR-2). Not part
        // of any tenant's deployment files; shared across every
        // tenant's context. Add an entry here AND in
        // `src/js/builtin_modules.zig`'s `MODULES` table.
        .{ .name = "builtin_webhook_onresult_mjs", .path = "src/js/builtin_modules/webhook_onresult.mjs" },
        // §2.6 durable scheduled wake — the `scheduler_tick` baked
        // module (docs/durable-wake-plan.md P1). Add an entry here AND
        // in `src/js/builtin_modules.zig`'s `MODULES` table.
        .{ .name = "builtin_scheduler_tick_mjs", .path = "src/js/builtin_modules/scheduler_tick.mjs" },
        // Handler-surface Phase 5 — the `cron(...)` recurrence engine.
        .{ .name = "builtin_cron_tick_mjs", .path = "src/js/builtin_modules/cron_tick.mjs" },
        // `docs/blob-storage-plan.md` P1 — blob.put's marker-settling
        // result handler.
        .{ .name = "builtin_blob_onresult_mjs", .path = "src/js/builtin_modules/blob_onresult.mjs" },

        // Starter content baked into the freshly-created tenant's
        // first deployment — see `deployStarterContent` in
        // `src/js/worker.zig`. Edited as plain files under
        // `src/js/starter/` rather than as Zig multi-line literals
        // so JS / HTML keep syntax highlighting and aren't gated on
        // a Zig rebuild for trivial copy edits.
        .{ .name = "starter_index_mjs", .path = "src/js/starter/index.mjs" },
        .{ .name = "starter_static_index_html", .path = "src/js/starter/_static/index.html" },
    };
    for (js_runtime_files) |f| {
        js_mod.addAnonymousImport(f.name, .{
            .root_source_file = b.path(f.path),
        });
    }
    js_mod.link_libc = true;
    js_mod.linkSystemLibrary("nghttp2", .{});
    js_mod.linkSystemLibrary("ssl", .{});
    js_mod.linkSystemLibrary("crypto", .{});

    const js_tests = b.addTest(.{ .root_module = js_mod });
    test_step.dependOn(&b.addRunArtifact(js_tests).step);

    // V1→V2 cutover: `rove-snapshot` (src/loop46/snapshot.zig, willemt
    // RaftNode) and the `loop46` product binary (src/loop46/, V1 cluster +
    // sqlite raft) were RETIRED — the V2 worker is `rewind`
    // (src/rewind/main.zig). Both broke the aggregate `test` step and the
    // default install on the v2 branch. Their per-tenant raft is the `Bridge`
    // (src/consensus/bridge.zig) + raft-rs.

    // qjs-hello: minimal demo that runs a JS snippet via rove-qjs.
    // Will grow into a snapshot-restoring executable in the next Phase 0
    // session; for now it's a one-shot eval so we can smoke-test the
    // module outside of `zig build test`.
    const qjs_hello_mod = b.addModule("qjs-hello", .{
        .root_source_file = b.path("examples/qjs_hello.zig"),
        .target = target,
        .optimize = optimize,
    });
    qjs_hello_mod.addImport("rove-qjs", qjs_mod);

    const qjs_hello = b.addExecutable(.{
        .name = "qjs-hello",
        .root_module = qjs_hello_mod,
    });
    b.installArtifact(qjs_hello);

    // qjs-bench: measures JS_NewRuntime vs Snapshot.restore per-iter cost.
    const qjs_bench_mod = b.addModule("qjs-bench", .{
        .root_source_file = b.path("examples/qjs_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    qjs_bench_mod.addImport("rove-qjs", qjs_mod);
    const qjs_bench = b.addExecutable(.{
        .name = "qjs-bench",
        .root_module = qjs_bench_mod,
    });
    b.installArtifact(qjs_bench);

    // Phase 5 PR-3: owed-recovery-scan-bench retired alongside the
    // SendDispatch kernel (the bench measured the boot-scan
    // SendDispatch.recover() drove). The JS-shim
    // `sweepOwedRetriesOnPromotion` covers the same shape; see
    // `scripts/webhook_recovery_smoke.py` for end-to-end coverage.

    // V1→V2 cutover: `files-server-standalone` (examples/files_server_standalone.zig,
    // its own willemt-raft `Cluster`) was RETIRED — replaced by `files-server-v2`
    // below (cluster-free; the flip is the worker's `/_system/release`).

    // files-server-v2: the cluster-free V2 deploy artifact (branch `v2`).
    // The V1 `files-server-standalone` brings up its own willemt-raft cluster
    // (dead on V2); this one is a pure compile + manifest + blob-write service
    // that shares the rewind worker's BlobBackend and delegates the
    // `_deploy/current` flip to the worker's `/_system/release`. Behind its own
    // named step (not the default install) so it builds on the V2 branch where
    // the V1 binaries don't.
    const fs_v2_mod = b.addModule("files-server-v2", .{
        .root_source_file = b.path("examples/files_server_v2.zig"),
        .target = target,
        .optimize = optimize,
    });
    fs_v2_mod.addImport("rove-files-server", files_server_mod);
    fs_v2_mod.addImport("rove-blob", blob_mod);
    fs_v2_mod.addImport("rove-h2", h2_mod);
    fs_v2_mod.addImport("raft-kv", kv_mod);
    const fs_v2_exe = b.addExecutable(.{
        .name = "files-server-v2",
        .root_module = fs_v2_mod,
    });
    const fs_v2_step = b.step("files-server-v2", "Build the cluster-free V2 files-server (deploy publisher)");
    fs_v2_step.dependOn(&b.addInstallArtifact(fs_v2_exe, .{}).step);

    // sse-server-standalone: RETIRED (task #10 Phase 3). The SSE
    // notification service now runs as a loop46-internal thread
    // (`sse_server.standalone.spawn`, sibling to the raft thread,
    // gated on `--sse-listen`; single-node only). Workers hand emits
    // via the in-process `Handle.enqueueEmit` queue — no cross-process
    // rendezvous, no `--sse-public-base`, no `SSE_INTERNAL_TOKEN`.
    // See `docs/sse-plan.md` + `docs/connection-actor-plan.md` §6.2.

    // log-server-standalone: Phase 5.5 (a) step 2 — runs the new
    // S3-direct logs indexer + h2 query API as a standalone process.
    // Smoke driver populates the batch-store dir directly on disk
    // (no worker yet); step 3 wires the worker's flush path into S3.
    const ls_standalone_mod = b.addModule("log-server-standalone", .{
        .root_source_file = b.path("examples/log_server_standalone.zig"),
        .target = target,
        .optimize = optimize,
    });
    ls_standalone_mod.addImport("rove-log-server", log_server_mod);
    ls_standalone_mod.addImport("rove-blob", blob_mod);
    ls_standalone_mod.addImport("rove-h2", h2_mod);
    // `rove-log-server` is deliberately sqlite-free (the C lib is linked at the
    // binary level, not the shared module — see `log_server_test_mod` below);
    // its `index_db.zig` needs sqlite3, so this binary links it. (Pre-cutover
    // this was masked by the default build failing on loop46 first.)
    ls_standalone_mod.link_libc = true;
    ls_standalone_mod.linkSystemLibrary("sqlite3", .{});
    const ls_standalone = b.addExecutable(.{
        .name = "log-server-standalone",
        .root_module = ls_standalone_mod,
    });
    b.installArtifact(ls_standalone);


    // V1→V2 cutover: `kv-maelstrom` (examples/kv_maelstrom.zig) drove
    // Maelstrom linearizability against the V1 willemt `RaftNode` — RETIRED.
    // V2 consensus (raft-rs) is exercised by the `v2-test` + cluster smokes.

    // ── Examples ──
    const echo_mod = b.addModule("echo-server", .{
        .root_source_file = b.path("examples/echo_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    echo_mod.addImport("rove", rove_mod);
    echo_mod.addImport("rove-io", io_mod);

    const echo_server = b.addExecutable(.{
        .name = "echo-server",
        .root_module = echo_mod,
    });
    b.installArtifact(echo_server);

    const run_echo = b.addRunArtifact(echo_server);
    const echo_step = b.step("echo-server", "Run the echo server example");
    echo_step.dependOn(&run_echo.step);

    // h2 echo server
    const h2_echo_mod = b.addModule("h2-echo-server", .{
        .root_source_file = b.path("examples/h2_echo_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    h2_echo_mod.addImport("rove", rove_mod);
    h2_echo_mod.addImport("rove-io", io_mod);
    h2_echo_mod.addImport("rove-h2", h2_mod);
    h2_echo_mod.link_libc = true;
    h2_echo_mod.linkSystemLibrary("nghttp2", .{});
    h2_echo_mod.linkSystemLibrary("ssl", .{});
    h2_echo_mod.linkSystemLibrary("crypto", .{});

    const h2_echo_server = b.addExecutable(.{
        .name = "h2-echo-server",
        .root_module = h2_echo_mod,
    });
    b.installArtifact(h2_echo_server);

    const run_h2_echo = b.addRunArtifact(h2_echo_server);
    const h2_echo_step = b.step("h2-echo-server", "Run the HTTP/2 echo server example");
    h2_echo_step.dependOn(&run_h2_echo.step);

    // h2 limit test
    const h2_limit_mod = b.addModule("h2-limit-test", .{
        .root_source_file = b.path("examples/h2_limit_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    h2_limit_mod.addImport("rove", rove_mod);
    h2_limit_mod.addImport("rove-io", io_mod);
    h2_limit_mod.addImport("rove-h2", h2_mod);
    h2_limit_mod.link_libc = true;
    h2_limit_mod.linkSystemLibrary("nghttp2", .{});
    h2_limit_mod.linkSystemLibrary("ssl", .{});
    h2_limit_mod.linkSystemLibrary("crypto", .{});

    // h2 streaming test
    const h2_stream_mod = b.addModule("h2-stream-test", .{
        .root_source_file = b.path("examples/h2_stream_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    h2_stream_mod.addImport("rove", rove_mod);
    h2_stream_mod.addImport("rove-io", io_mod);
    h2_stream_mod.addImport("rove-h2", h2_mod);
    h2_stream_mod.link_libc = true;
    h2_stream_mod.linkSystemLibrary("nghttp2", .{});
    h2_stream_mod.linkSystemLibrary("ssl", .{});
    h2_stream_mod.linkSystemLibrary("crypto", .{});

    const h2_stream_test = b.addExecutable(.{
        .name = "h2-stream-test",
        .root_module = h2_stream_mod,
    });
    b.installArtifact(h2_stream_test);
    const h2_stream_run = b.addRunArtifact(h2_stream_test);
    const h2_stream_step = b.step("h2-stream-test", "Run the streaming echo server example (h2 + h1 chunked)");
    h2_stream_step.dependOn(&h2_stream_run.step);

    // ws-echo: inbound WebSocket transport proof (websocket-plan §4.6 A/C/E-h2).
    const ws_echo_mod = b.addModule("ws-echo", .{
        .root_source_file = b.path("examples/ws_echo_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ws_echo_mod.addImport("rove", rove_mod);
    ws_echo_mod.addImport("rove-io", io_mod);
    ws_echo_mod.addImport("rove-h2", h2_mod);
    ws_echo_mod.link_libc = true;
    ws_echo_mod.linkSystemLibrary("nghttp2", .{});
    ws_echo_mod.linkSystemLibrary("ssl", .{});
    ws_echo_mod.linkSystemLibrary("crypto", .{});

    const ws_echo_exe = b.addExecutable(.{
        .name = "ws-echo",
        .root_module = ws_echo_mod,
    });
    b.installArtifact(ws_echo_exe);
    const ws_echo_run = b.addRunArtifact(ws_echo_exe);
    const ws_echo_step = b.step("ws-echo", "Run the inbound WebSocket echo server example");
    ws_echo_step.dependOn(&ws_echo_run.step);

    // s3-blob-smoke: exercise rove-blob's S3BlobStore against any
    // S3-compatible endpoint (default-tested against OVH). Pure
    // round-trip — no rove server, no raft, no h2 stack.
    const s3_blob_smoke_mod = b.addModule("s3-blob-smoke", .{
        .root_source_file = b.path("examples/s3_blob_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    s3_blob_smoke_mod.addImport("rove-blob", blob_mod);
    s3_blob_smoke_mod.link_libc = true;
    s3_blob_smoke_mod.linkSystemLibrary("ssl", .{});
    s3_blob_smoke_mod.linkSystemLibrary("crypto", .{});

    const s3_blob_smoke = b.addExecutable(.{
        .name = "s3-blob-smoke",
        .root_module = s3_blob_smoke_mod,
    });
    b.installArtifact(s3_blob_smoke);

    // s3-throughput-bench: K concurrent threads each looping PUTs to
    // S3 to find the concurrency × size knee where bandwidth stops
    // scaling. No rove server, no raft, no h2 stack — isolates the
    // S3 link from everything else.
    const s3_throughput_bench_mod = b.addModule("s3-throughput-bench", .{
        .root_source_file = b.path("examples/s3_throughput_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    s3_throughput_bench_mod.addImport("rove-blob", blob_mod);
    s3_throughput_bench_mod.link_libc = true;
    s3_throughput_bench_mod.linkSystemLibrary("ssl", .{});
    s3_throughput_bench_mod.linkSystemLibrary("crypto", .{});

    const s3_throughput_bench = b.addExecutable(.{
        .name = "s3-throughput-bench",
        .root_module = s3_throughput_bench_mod,
    });
    b.installArtifact(s3_throughput_bench);

    // h2 TLS test
    const h2_tls_mod = b.addModule("h2-tls-test", .{
        .root_source_file = b.path("examples/h2_tls_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    h2_tls_mod.addImport("rove", rove_mod);
    h2_tls_mod.addImport("rove-io", io_mod);
    h2_tls_mod.addImport("rove-h2", h2_mod);
    h2_tls_mod.link_libc = true;
    h2_tls_mod.linkSystemLibrary("nghttp2", .{});
    h2_tls_mod.linkSystemLibrary("ssl", .{});
    h2_tls_mod.linkSystemLibrary("crypto", .{});

    const h2_tls_test = b.addExecutable(.{
        .name = "h2-tls-test",
        .root_module = h2_tls_mod,
    });
    b.installArtifact(h2_tls_test);
    const h2_tls_run = b.addRunArtifact(h2_tls_test);
    const h2_tls_step = b.step("h2-tls-test", "Run the TLS echo server example (h2 + http/1.1 via ALPN)");
    h2_tls_step.dependOn(&h2_tls_run.step);

    // h2 client test
    const h2_client_mod = b.addModule("h2-client-test", .{
        .root_source_file = b.path("examples/h2_client_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    h2_client_mod.addImport("rove", rove_mod);
    h2_client_mod.addImport("rove-io", io_mod);
    h2_client_mod.addImport("rove-h2", h2_mod);
    h2_client_mod.link_libc = true;
    h2_client_mod.linkSystemLibrary("nghttp2", .{});
    h2_client_mod.linkSystemLibrary("ssl", .{});
    h2_client_mod.linkSystemLibrary("crypto", .{});

    const h2_client_test = b.addExecutable(.{
        .name = "h2-client-test",
        .root_module = h2_client_mod,
    });
    b.installArtifact(h2_client_test);

    // h2 client streaming test
    const h2_client_stream_mod = b.addModule("h2-client-stream-test", .{
        .root_source_file = b.path("examples/h2_client_stream_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    h2_client_stream_mod.addImport("rove", rove_mod);
    h2_client_stream_mod.addImport("rove-io", io_mod);
    h2_client_stream_mod.addImport("rove-h2", h2_mod);
    h2_client_stream_mod.link_libc = true;
    h2_client_stream_mod.linkSystemLibrary("nghttp2", .{});
    h2_client_stream_mod.linkSystemLibrary("ssl", .{});
    h2_client_stream_mod.linkSystemLibrary("crypto", .{});

    const h2_client_stream_test = b.addExecutable(.{
        .name = "h2-client-stream-test",
        .root_module = h2_client_stream_mod,
    });
    b.installArtifact(h2_client_stream_test);

    const h2_limit_test = b.addExecutable(.{
        .name = "h2-limit-test",
        .root_module = h2_limit_mod,
    });
    b.installArtifact(h2_limit_test);

    // ── rust-ffi-smoke: V2 vendoring spike (docs/v2-vendoring-spike.md).
    // Step 1 — prove `cargo build → linkSystemLibrary` works end-to-end
    // before vendoring raft-rs's full dep tree. The Rust staticlib at
    // examples/rust_ffi_smoke/ exports three C ABI fns (arithmetic,
    // static C string, Rust-fires-Zig-callback) mirroring the shape of
    // the eventual raft-rs FFI.
    const cargo_smoke = b.addSystemCommand(&.{ "cargo", "build", "--release", "--manifest-path" });
    cargo_smoke.addFileArg(b.path("examples/rust_ffi_smoke/Cargo.toml"));

    const rust_ffi_smoke_mod = b.addModule("rust-ffi-smoke", .{
        .root_source_file = b.path("examples/rust_ffi_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    rust_ffi_smoke_mod.link_libc = true;
    rust_ffi_smoke_mod.addIncludePath(b.path("examples/rust_ffi_smoke/include"));
    rust_ffi_smoke_mod.addLibraryPath(b.path("examples/rust_ffi_smoke/target/release"));
    rust_ffi_smoke_mod.linkSystemLibrary("rust_ffi_smoke", .{});
    // Native libs required by Rust's std even when the crate is
    // compiled with `panic = "abort"` (eh_personality + backtrace
    // machinery still get pulled in). Order matches the output of
    // `cargo rustc --release --lib -- --print native-static-libs`.
    rust_ffi_smoke_mod.linkSystemLibrary("gcc_s", .{});
    rust_ffi_smoke_mod.linkSystemLibrary("util", .{});
    rust_ffi_smoke_mod.linkSystemLibrary("rt", .{});
    rust_ffi_smoke_mod.linkSystemLibrary("pthread", .{});
    rust_ffi_smoke_mod.linkSystemLibrary("m", .{});
    rust_ffi_smoke_mod.linkSystemLibrary("dl", .{});

    const rust_ffi_smoke_exe = b.addExecutable(.{
        .name = "rust-ffi-smoke",
        .root_module = rust_ffi_smoke_mod,
    });
    rust_ffi_smoke_exe.step.dependOn(&cargo_smoke.step);
    // Deliberately NOT `b.installArtifact`: keeps cargo out of the
    // default `zig build` so V1 contributors don't need a Rust
    // toolchain. Reach the spike via `zig build rust-ffi-smoke`.

    const run_rust_ffi_smoke = b.addRunArtifact(rust_ffi_smoke_exe);
    run_rust_ffi_smoke.step.dependOn(&cargo_smoke.step);
    const rust_ffi_smoke_step = b.step("rust-ffi-smoke", "Run the Rust-FFI hello-world smoke (V2 spike)");
    rust_ffi_smoke_step.dependOn(&run_rust_ffi_smoke.step);

    // ── V2 raft substrate (docs/v2-build-order.md Phase 0) ──────────────
    // raft-rs-zig (anarchodev/raft-rs-zig) is the V2 multi-raft engine:
    // TiKV raft-rs, one group per tenant, behind a Zig wrapper. Fetched as
    // a Zig package (pinned in build.zig.zon); its own build.zig runs
    // `cargo build` → libraft_sys.a and exposes module("raft_rs_zig") +
    // artifact("raft_rs_zig"). Linking the artifact triggers that cargo
    // build. Kept behind the v2-only `v2-test` step so the default
    // `zig build` / `zig build test` never invoke cargo and V1
    // contributors need no Rust toolchain.
    const raft_dep = b.dependency("raft_rs_zig", .{ .target = target, .optimize = optimize });

    // ── V2 Phase 5 — raft peer transport (cross-node wire layer) ───────
    // Reuse the V1 liburing transport (`src/kv/raft_net.zig` + its frame
    // codec `raft_rpc.zig`, both std-only) as the V2 cross-node wire layer.
    // The V2 coalescing adapter (`src/consensus/transport.zig`) moves opaque
    // per-recipient envelopes over it; the V1 raft message types in
    // `raft_rpc` are unused by the transport core. Module-rooted at
    // raft_net.zig so its relative `@import("raft_rpc.zig")` resolves.
    const raftnet_mod = b.createModule(.{
        .root_source_file = b.path("src/kv/raft_net.zig"),
        .target = target,
        .optimize = optimize,
    });
    raftnet_mod.link_libc = true;

    const v2_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/consensus/v2_raft_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    v2_smoke_mod.addImport("raft_rs_zig", raft_dep.module("raft_rs_zig"));
    const v2_smoke_test = b.addTest(.{ .root_module = v2_smoke_mod });
    const run_v2_smoke_test = b.addRunArtifact(v2_smoke_test);
    const v2_test_step = b.step("v2-test", "V2 raft substrate tests (Phase-0 smoke + Phase-1 per-tenant pump)");
    v2_test_step.dependOn(&run_v2_smoke_test.step);

    // ── V2 Phase 1 — data-plane core: the per-tenant pump (single node)
    // (docs/v2-build-order.md §Phase 1). `src/consensus/node.zig` owns a
    // Manager + SharedWal and pumps per-tenant raft groups, applying
    // committed writeset envelopes to each tenant's kvexp store. It
    // reuses the V1 limbs as plain files — `src/kv/kvstore.zig` +
    // `src/kv/writeset.zig` (which only import `kvexp`, not the willemt
    // raft / io_uring spine) — so the node module needs `kvexp` in its
    // import table (those files' `@import("kvexp")` resolves through it)
    // plus the raft artifact. kvexp already links liblmdb + libc.
    const v2_node_mod = b.createModule(.{
        .root_source_file = b.path("src/consensus/node.zig"),
        .target = target,
        .optimize = optimize,
    });
    v2_node_mod.link_libc = true;
    v2_node_mod.addImport("raft_rs_zig", raft_dep.module("raft_rs_zig"));
    // kvlimbs == the `raft-kv` facade module (`kv_mod`, now rooted at
    // kvlimbs.zig). Sharing the SAME instance here and as rove-js's
    // `raft-kv` import is what makes `KvStore` / `WriteSet` a single type
    // across the worker and the bridge — the Zig per-module type identity
    // requirement for the Phase-2 seam.
    v2_node_mod.addImport("kvlimbs", kv_mod);
    v2_node_mod.addImport("raft-net", raftnet_mod);
    const v2_node_test = b.addTest(.{ .root_module = v2_node_mod });

    // ── V2 Phase 6 — hibernation / active-set pump-cost microbench ─────
    // (docs/v2-phase6-hibernation.md). Measures node pump cycle time vs.
    // active-set size: K idle tenants drain out so a cycle ticks ~nothing.
    // Build with -Doptimize=ReleaseFast; run `v2-hibernation-bench [K] [cycles]`.
    const v2_hib_bench_mod = b.createModule(.{
        .root_source_file = b.path("examples/v2_hibernation_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    v2_hib_bench_mod.link_libc = true;
    v2_hib_bench_mod.addImport("raft_rs_zig", raft_dep.module("raft_rs_zig"));
    v2_hib_bench_mod.addImport("node", v2_node_mod);
    const v2_hib_bench = b.addExecutable(.{ .name = "v2-hibernation-bench", .root_module = v2_hib_bench_mod });
    const v2_hib_bench_step = b.step("v2-hibernation-bench", "Build the V2 Phase-6 hibernation pump-cost microbench");
    v2_hib_bench_step.dependOn(&b.addInstallArtifact(v2_hib_bench, .{}).step);

    // ── V2 Phase 7 — empty-bundle race reproduction (kvstore/kvexp level)
    const v2_bundle_repro_mod = b.createModule(.{
        .root_source_file = b.path("examples/v2_bundle_repro.zig"),
        .target = target,
        .optimize = optimize,
    });
    v2_bundle_repro_mod.link_libc = true;
    v2_bundle_repro_mod.addImport("raft-kv", kv_mod);
    v2_bundle_repro_mod.addImport("kvexp", kvexp_mod);
    const v2_bundle_repro = b.addExecutable(.{ .name = "v2-bundle-repro", .root_module = v2_bundle_repro_mod });
    const v2_bundle_repro_step = b.step("v2-bundle-repro", "Reproduce the empty-bundle race at the kvstore/kvexp level");
    v2_bundle_repro_step.dependOn(&b.addInstallArtifact(v2_bundle_repro, .{}).step);

    // ── V2 Phase 5 — the cross-node transport adapter (coalesced) ──────
    // `src/consensus/transport.zig` wraps `raft_net` with per-recipient
    // coalescing; the Node drives it from its pump. Tested on its own
    // (wire-format) here + end-to-end by the 3-node node test.
    const v2_transport_mod = b.createModule(.{
        .root_source_file = b.path("src/consensus/transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    v2_transport_mod.link_libc = true;
    v2_transport_mod.addImport("raft_rs_zig", raft_dep.module("raft_rs_zig"));
    v2_transport_mod.addImport("raft-net", raftnet_mod);
    const v2_transport_test = b.addTest(.{ .root_module = v2_transport_mod });
    v2_test_step.dependOn(&b.addRunArtifact(v2_transport_test).step);
    const run_v2_node_test = b.addRunArtifact(v2_node_test);
    v2_test_step.dependOn(&run_v2_node_test.step);

    // ── V2 Phase 2 — the worker-facing bridge over the per-tenant pump
    // (docs/v2-build-order.md §Phase 2). `src/consensus/bridge.zig` owns the
    // Phase-1 `Node`, runs its pump on a dedicated thread, and presents
    // the per-tenant propose + watermark surface the reused rove-js worker
    // talks to in place of V1's global `kv.RaftNode`. Same import table as
    // the node module (it imports node.zig + envelope.zig relatively).
    const v2_bridge_mod = b.createModule(.{
        .root_source_file = b.path("src/consensus/bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    v2_bridge_mod.link_libc = true;
    v2_bridge_mod.addImport("raft_rs_zig", raft_dep.module("raft_rs_zig"));
    v2_bridge_mod.addImport("kvlimbs", kv_mod);
    v2_bridge_mod.addImport("raft-net", raftnet_mod);
    const v2_bridge_test = b.addTest(.{ .root_module = v2_bridge_mod });
    const run_v2_bridge_test = b.addRunArtifact(v2_bridge_test);
    v2_test_step.dependOn(&run_v2_bridge_test.step);

    // ── V2 Phase 3/7 — control plane: the tenant→cluster directory ─────
    // (docs/v2-build-order.md §Phase 3, docs/v2-phase3-directory-routing.md,
    // docs/v2-cp-directory-replication.md Slice 1). `src/cp/directory.zig`
    // is the routing source of truth the front-door reads and a move flips.
    // Slice 1 makes it durable: it backs writes with the V2 `bridge`'s
    // directory raft group, so it now imports the bridge (and its test links
    // the raft artifact). Reads stay on a pointer-stable in-memory projection.
    const v2_cp_dir_mod = b.createModule(.{
        .root_source_file = b.path("src/cp/directory.zig"),
        .target = target,
        .optimize = optimize,
    });
    v2_cp_dir_mod.addImport("bridge", v2_bridge_mod);
    const v2_cp_dir_test = b.addTest(.{ .root_module = v2_cp_dir_mod });
    const run_v2_cp_dir_test = b.addRunArtifact(v2_cp_dir_test);
    v2_test_step.dependOn(&run_v2_cp_dir_test.step);

    // ── V2 Phase 2c — attach the rove-js worker to the bridge ──────────
    // rove-js imports the bridge as `@import("bridge")`. js_mod already
    // imports `kv_mod` as "raft-kv" (the facade), so the worker's
    // KvStore/TrackedTxn and the bridge's are the SAME type. A dedicated
    // `js-v2` step compiles rove-js against the facade + bridge (V1's
    // loop46 is dead on this branch) to drive the seam cut.
    js_mod.addImport("bridge", v2_bridge_mod);
    const js_v2_test = b.addTest(.{ .root_module = js_mod });
    const js_v2_step = b.step("js-v2", "Compile rove-js against the V2 facade + bridge (Phase 2c)");
    js_v2_step.dependOn(&b.addRunArtifact(js_v2_test).step);

    // ── rewind: the V2 single-node worker binary (docs/v2-build-order.md
    // §Phase 2d). The V2 counterpart of `loop46` — the reused rove-js
    // worker stack on the per-tenant bridge instead of the willemt cluster.
    // Building this is also the FORCING FUNCTION for the Phase-2c generic
    // worker-body conversions (Zig only analyzes `worker: anytype` fns when
    // a concrete `Worker` is instantiated, which `rewind`'s workerMain does).
    // Not in the default `install` step (V1's loop46 is dead on this branch).
    const rewind_mod = b.createModule(.{
        .root_source_file = b.path("src/rewind/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    rewind_mod.addImport("rove", rove_mod);
    rewind_mod.addImport("rove-js", js_mod);
    rewind_mod.addImport("bridge", v2_bridge_mod);
    rewind_mod.addImport("raft-kv", kv_mod);
    rewind_mod.addImport("rove-h2", h2_mod);
    rewind_mod.addImport("rove-blob", blob_mod);
    rewind_mod.addImport("rove-tenant", tenant_mod);
    rewind_mod.addImport("rove-qjs", qjs_mod);
    rewind_mod.addImport("rove-log-server", log_server_mod);
    rewind_mod.addImport("rove-files", files_mod);
    rewind_mod.link_libc = true;
    rewind_mod.linkSystemLibrary("nghttp2", .{});
    rewind_mod.linkSystemLibrary("ssl", .{});
    rewind_mod.linkSystemLibrary("crypto", .{});
    const rewind_exe = b.addExecutable(.{ .name = "rewind", .root_module = rewind_mod });
    const rewind_step = b.step("rewind", "Build the V2 rewind worker binary (Phase 2d)");
    rewind_step.dependOn(&b.addInstallArtifact(rewind_exe, .{}).step);

    // ── rewind-front: the V2 front door (docs/v2-front-door-architecture.md).
    // A STATELESS HTTP/2 reverse proxy: resolves Host→cluster via the CP's
    // `/_cp/route` (cached) and reverse-proxies to the owning cluster's nodes
    // (leader-aware). Holds NO directory/raft state — that lives in `rewind-cp`
    // — so it links neither `bridge` nor `cp-directory`; just rove + h2 + curl.
    const front_mod = b.createModule(.{
        .root_source_file = b.path("src/front/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    front_mod.addImport("rove", rove_mod);
    front_mod.addImport("rove-h2", h2_mod);
    front_mod.addImport("rove-blob", blob_mod);
    front_mod.link_libc = true;
    front_mod.linkSystemLibrary("nghttp2", .{});
    front_mod.linkSystemLibrary("ssl", .{});
    front_mod.linkSystemLibrary("crypto", .{});
    front_mod.linkSystemLibrary("curl", .{});
    const front_exe = b.addExecutable(.{ .name = "rewind-front", .root_module = front_mod });
    const front_step = b.step("rewind-front", "Build the V2 front-door binary (Phase 3b)");
    front_step.dependOn(&b.addInstallArtifact(front_exe, .{}).step);

    // ── rewind-cp: the V2 control plane (docs/v2-front-door-architecture.md).
    // The authoritative, replicated directory: owns placement + the host→tenant
    // index, hosts the directory raft group (its OWN small cluster), and
    // orchestrates moves (`/_control/move`) + serves `/_cp/route` + `/_cp/leader`.
    // This is where `bridge` + `cp-directory` now live (lifted out of the front
    // door), fixing the inverted scaling where every front-door was a CP voter.
    const cp_mod = b.createModule(.{
        .root_source_file = b.path("src/cp/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cp_mod.addImport("rove", rove_mod);
    cp_mod.addImport("rove-h2", h2_mod);
    cp_mod.addImport("rove-blob", blob_mod);
    cp_mod.addImport("cp-directory", v2_cp_dir_mod);
    cp_mod.addImport("bridge", v2_bridge_mod);
    cp_mod.addImport("rove-acme", acme_mod);
    cp_mod.link_libc = true;
    cp_mod.linkSystemLibrary("nghttp2", .{});
    cp_mod.linkSystemLibrary("ssl", .{});
    cp_mod.linkSystemLibrary("crypto", .{});
    cp_mod.linkSystemLibrary("curl", .{});
    const cp_exe = b.addExecutable(.{ .name = "rewind-cp", .root_module = cp_mod });
    const cp_step = b.step("rewind-cp", "Build the V2 control-plane binary");
    cp_step.dependOn(&b.addInstallArtifact(cp_exe, .{}).step);
}
