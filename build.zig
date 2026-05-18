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

    // ── kvexp: vendored embedded multi-tenant KV (anarchodev/kvexp).
    // LMDB-backed durable B-tree fronted by an in-memory per-store
    // memtable (overlay). Links against system liblmdb. Replaces
    // SQLite as the per-tenant state engine. See
    // vendor/kvexp/README.md.
    const kvexp_mod = b.addModule("kvexp", .{
        .root_source_file = b.path("vendor/kvexp/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    kvexp_mod.link_libc = true;
    kvexp_mod.linkSystemLibrary("lmdb", .{});

    // ── rove-kv: KV store + raft. Standalone leaf module — does NOT
    // depend on rove or rove-io. raft_net is a direct liburing wrapper;
    // raft itself is vendored willemt/raft. See
    // memory/feedback_raft_net_direct_liburing.md.
    //
    // State engine is kvexp (vendored). raft_log persistence is still
    // sqlite for now (raft log is its own concern, separate from the
    // KV state path); follow-up cutover will migrate it.
    const kv_mod = b.addModule("rove-kv", .{
        .root_source_file = b.path("src/kv/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    kv_mod.link_libc = true;
    kv_mod.linkSystemLibrary("sqlite3", .{});
    kv_mod.addImport("kvexp", kvexp_mod);

    // Vendored willemt/raft (BSD-licensed, see vendor/raft/LICENSE).
    kv_mod.addIncludePath(b.path("vendor/raft/include"));
    kv_mod.addCSourceFiles(.{
        .root = b.path("vendor/raft/src"),
        .files = &.{
            "raft_server.c",
            "raft_server_properties.c",
            "raft_node.c",
            "raft_log.c",
        },
        .flags = &.{
            "-std=c99",
            "-Wno-pointer-sign",
            "-Wno-unused-parameter",
        },
    });

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
    files_mod.addImport("rove-kv", kv_mod);
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
    log_mod.addImport("rove-kv", kv_mod);
    log_mod.addImport("rove-blob", blob_mod);

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
    // rove-kv is only used in bundle.zig's tests (to open a fresh
    // LogStore). Production bundle code never touches kv directly.
    tape_mod.addImport("rove-kv", kv_mod);

    // ── rove-qjs: arenajs (quickjs-ng fork) wrapper ──
    //
    // Vendors anarchodev/arenajs at vendor/arenajs/ — a quickjs-ng
    // fork that replaces malloc + GC with a dual bump arena (base
    // + per-request) and collapses per-request restore to a single
    // cursor write. See vendor/arenajs/README.md for the snapshot
    // commit and the constraints inherited from the fork.
    const qjs_mod = b.addModule("rove-qjs", .{
        .root_source_file = b.path("src/qjs/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    qjs_mod.link_libc = true;
    qjs_mod.linkSystemLibrary("m", .{});
    qjs_mod.linkSystemLibrary("pthread", .{});
    qjs_mod.addIncludePath(b.path("vendor/arenajs"));
    qjs_mod.addCSourceFiles(.{
        .root = b.path("vendor/arenajs"),
        .files = &.{
            "quickjs.c",
            "qjs-arena.c",
            "libregexp.c",
            "libunicode.c",
            "dtoa.c",
        },
        .flags = &.{
            "-std=c11",
            "-D_GNU_SOURCE",
            "-DQUICKJS_NG_BUILD",
            "-Wno-implicit-fallthrough",
            "-Wno-sign-compare",
            "-Wno-array-bounds",
            "-Wno-unused-parameter",
            "-Wno-unused-but-set-variable",
            "-Wno-unused-variable",
            "-Wno-unused-function",
            "-fno-sanitize=undefined",
        },
    });

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
    log_server_mod.addImport("rove-kv", kv_mod);
    log_server_mod.addImport("rove-blob", blob_mod);
    log_server_mod.addImport("rove-log", log_mod);
    log_server_mod.addImport("rove-jwt", jwt_mod);

    // ── rove-sse-server: centralized SSE notification service ───────
    //
    // Replaces the in-worker `_events/{sid}/...` storage + pump model
    // (sse-plan §1). Standalone process; receives `POST /v1/emit` from
    // workers and serves long-lived `text/event-stream` connections to
    // browsers. Per-(tenant, sid) ring cache + per-tenant connection
    // table live in-memory; failover is "load balancer fails over,
    // clients reconnect, hit sentinel, refetch."
    const sse_server_mod = b.addModule("rove-sse-server", .{
        .root_source_file = b.path("src/sse_server/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    sse_server_mod.link_libc = true;
    sse_server_mod.linkSystemLibrary("nghttp2", .{});
    sse_server_mod.linkSystemLibrary("ssl", .{});
    sse_server_mod.linkSystemLibrary("crypto", .{});
    sse_server_mod.addImport("rove", rove_mod);
    sse_server_mod.addImport("rove-io", io_mod);
    sse_server_mod.addImport("rove-h2", h2_mod);
    sse_server_mod.addImport("rove-jwt", jwt_mod);

    // ── rove-schedule-server: outbound HTTP via http.send ────────────
    //
    // Storage + wire format + leader-pinned scheduler thread for the
    // platform's outbound HTTP primitive (docs/http-send-plan.md).
    // Replaced rove-webhook-server entirely; webhook.send is now a
    // JS polyfill on top of http.send (src/js/globals/webhook.js).
    const schedule_server_mod = b.addModule("rove-schedule-server", .{
        .root_source_file = b.path("src/schedule_server/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    schedule_server_mod.link_libc = true;
    schedule_server_mod.linkSystemLibrary("sqlite3", .{});
    schedule_server_mod.addImport("rove-kv", kv_mod);
    // The scheduler thread fires schedules over libcurl
    // (rove-blob's `curl.Easy`).
    schedule_server_mod.addImport("rove-blob", blob_mod);

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
    files_server_mod.addImport("rove-kv", kv_mod);
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

    // rove-kv tests
    const kv_tests = b.addTest(.{ .root_module = kv_mod });
    test_step.dependOn(&b.addRunArtifact(kv_tests).step);

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

    // rove-files-server tests
    const files_server_tests = b.addTest(.{ .root_module = files_server_mod });
    test_step.dependOn(&b.addRunArtifact(files_server_tests).step);

    // rove-log-server tests
    const log_server_tests = b.addTest(.{ .root_module = log_server_mod });
    test_step.dependOn(&b.addRunArtifact(log_server_tests).step);

    // rove-jwt tests
    const jwt_tests = b.addTest(.{ .root_module = jwt_mod });
    test_step.dependOn(&b.addRunArtifact(jwt_tests).step);

    // rove-sse-server tests
    const sse_server_tests = b.addTest(.{ .root_module = sse_server_mod });
    test_step.dependOn(&b.addRunArtifact(sse_server_tests).step);

    // rove-schedule-server tests
    const schedule_server_tests = b.addTest(.{ .root_module = schedule_server_mod });
    test_step.dependOn(&b.addRunArtifact(schedule_server_tests).step);

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
    tenant_mod.addImport("rove-kv", kv_mod);

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
    js_mod.addImport("rove-kv", kv_mod);
    js_mod.addImport("rove-blob", blob_mod);
    js_mod.addImport("rove-files", files_mod);
    js_mod.addImport("rove-log", log_mod);
    js_mod.addImport("rove-log-server", log_server_mod);
    js_mod.addImport("rove-jwt", jwt_mod);
    js_mod.addImport("rove-tape", tape_mod);
    js_mod.addImport("rove-tenant", tenant_mod);
    js_mod.addImport("rove-schedule-server", schedule_server_mod);
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
        .{ .name = "events_js", .path = "src/js/globals/events.js" },
        .{ .name = "platform_js", .path = "src/js/globals/platform.js" },
        .{ .name = "base64_js", .path = "src/js/globals/base64.js" },
        .{ .name = "urlsearchparams_js", .path = "src/js/globals/urlsearchparams.js" },
        .{ .name = "jwt_js", .path = "src/js/globals/jwt.js" },
        .{ .name = "oauth_js", .path = "src/js/globals/oauth.js" },
        .{ .name = "oidc_js", .path = "src/js/globals/oidc.js" },
        .{ .name = "sessions_js", .path = "src/js/globals/sessions.js" },
        .{ .name = "cron_js", .path = "src/js/globals/cron.js" },
        .{ .name = "retry_js", .path = "src/js/globals/retry.js" },
        .{ .name = "webhook_js", .path = "src/js/globals/webhook.js" },
        .{ .name = "email_js", .path = "src/js/globals/email.js" },
        .{ .name = "textcodec_js", .path = "src/js/globals/textcodec.js" },
        .{ .name = "users_js", .path = "src/js/globals/users.js" },
        .{ .name = "activitypub_js", .path = "src/js/globals/activitypub.js" },
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

    // Phase 5.5(c) snapshot capture orchestrator. Lives under
    // src/loop46/ since it composes apply-side state with a
    // BatchStore output, but it's testable in isolation against
    // a FsBatchStore + a stub RaftNode + a real ApplyCtx.
    const snapshot_mod = b.addModule("rove-snapshot", .{
        .root_source_file = b.path("src/loop46/snapshot.zig"),
        .target = target,
        .optimize = optimize,
    });
    snapshot_mod.addImport("rove-kv", kv_mod);
    snapshot_mod.addImport("rove-js", js_mod);
    snapshot_mod.addImport("rove-log-server", log_server_mod);
    snapshot_mod.link_libc = true;
    snapshot_mod.linkSystemLibrary("nghttp2", .{});
    snapshot_mod.linkSystemLibrary("ssl", .{});
    snapshot_mod.linkSystemLibrary("crypto", .{});
    const snapshot_tests = b.addTest(.{ .root_module = snapshot_mod });
    test_step.dependOn(&b.addRunArtifact(snapshot_tests).step);

    // loop46: the Loop46 product binary. Subcommand-dispatched entry
    // point (`loop46 dev`, `loop46 worker`, …) that composes the rove
    // engine modules with the embedded admin UI bundle.
    const loop46_mod = b.addModule("loop46", .{
        .root_source_file = b.path("src/loop46/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    loop46_mod.addImport("rove", rove_mod);
    loop46_mod.addImport("rove-js", js_mod);
    loop46_mod.addImport("rove-kv", kv_mod);
    loop46_mod.addImport("rove-blob", blob_mod);
    loop46_mod.addImport("rove-jwt", jwt_mod);
    loop46_mod.addImport("rove-files", files_mod);
    loop46_mod.addImport("rove-files-server", files_server_mod);
    loop46_mod.addImport("rove-log-server", log_server_mod);
    loop46_mod.addImport("rove-qjs", qjs_mod);
    loop46_mod.addImport("rove-tenant", tenant_mod);
    loop46_mod.addImport("rove-h2", h2_mod);
    loop46_mod.addImport("rove-schedule-server", schedule_server_mod);
    loop46_mod.addImport("rove-acme", acme_mod);
    // The admin + replay tenant bundles + UI files used to be
    // embedded into the loop46 binary so the worker could
    // bootstrap-deploy them at startup. Phase 5.5(e) step 3 moved
    // that responsibility to files-server-standalone, so the embeds
    // moved with it (see the platform_bundle_files block on
    // files_server_mod above).
    loop46_mod.link_libc = true;
    loop46_mod.linkSystemLibrary("nghttp2", .{});
    loop46_mod.linkSystemLibrary("ssl", .{});
    loop46_mod.linkSystemLibrary("crypto", .{});

    const loop46_exe = b.addExecutable(.{
        .name = "loop46",
        .root_module = loop46_mod,
    });
    b.installArtifact(loop46_exe);

    const run_loop46 = b.addRunArtifact(loop46_exe);
    const loop46_step = b.step("loop46", "Run the loop46 product binary");
    loop46_step.dependOn(&run_loop46.step);

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

    // files-server-standalone: spawns the rove-files-server thread and
    // idles. Exists so the smoke test can drive it from curl.
    const cs_standalone_mod = b.addModule("files-server-standalone", .{
        .root_source_file = b.path("examples/files_server_standalone.zig"),
        .target = target,
        .optimize = optimize,
    });
    cs_standalone_mod.addImport("rove-files-server", files_server_mod);
    cs_standalone_mod.addImport("rove-blob", blob_mod);
    cs_standalone_mod.addImport("rove-h2", h2_mod);
    cs_standalone_mod.addImport("rove-kv", kv_mod);
    const cs_standalone = b.addExecutable(.{
        .name = "files-server-standalone",
        .root_module = cs_standalone_mod,
    });
    b.installArtifact(cs_standalone);

    // sse-server-standalone: runs the centralized SSE notification
    // service as a separate process. See `docs/sse-plan.md`. v1
    // ships with the worker still owning the legacy `/_events`
    // route; this binary stands up alongside (sse-plan §7 step 1).
    const sse_standalone_mod = b.addModule("sse-server-standalone", .{
        .root_source_file = b.path("examples/sse_server_standalone.zig"),
        .target = target,
        .optimize = optimize,
    });
    sse_standalone_mod.addImport("rove-sse-server", sse_server_mod);
    sse_standalone_mod.addImport("rove-h2", h2_mod);
    const sse_standalone = b.addExecutable(.{
        .name = "sse-server-standalone",
        .root_module = sse_standalone_mod,
    });
    b.installArtifact(sse_standalone);

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
    const ls_standalone = b.addExecutable(.{
        .name = "log-server-standalone",
        .root_module = ls_standalone_mod,
    });
    b.installArtifact(ls_standalone);


    // kv-maelstrom: adapter binary that lets Maelstrom drive lin-kv
    // linearizability workloads against rove-kv over stdin/stdout.
    const kv_maelstrom_mod = b.addModule("kv-maelstrom", .{
        .root_source_file = b.path("examples/kv_maelstrom.zig"),
        .target = target,
        .optimize = optimize,
    });
    kv_maelstrom_mod.addImport("rove-kv", kv_mod);
    kv_maelstrom_mod.link_libc = true;

    const kv_maelstrom = b.addExecutable(.{
        .name = "kv-maelstrom",
        .root_module = kv_maelstrom_mod,
    });
    b.installArtifact(kv_maelstrom);

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
}
