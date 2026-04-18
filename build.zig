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

    // ── rove-kv: KV store + raft. Standalone leaf module — does NOT
    // depend on rove or rove-io. raft_net is a direct liburing wrapper;
    // raft itself is vendored willemt/raft. See
    // memory/feedback_raft_net_direct_liburing.md.
    const kv_mod = b.addModule("rove-kv", .{
        .root_source_file = b.path("src/kv/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    kv_mod.link_libc = true;
    kv_mod.linkSystemLibrary("sqlite3", .{});

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

    // ── rove-code: content-addressed module store + deploy index ──
    //
    // Library layer only in Phase 1b session 1. The `rove-code-server`
    // binary (HTTP/2 wrapper + raft group) lands in a follow-up session.
    const code_mod = b.addModule("rove-code", .{
        .root_source_file = b.path("src/code/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    code_mod.addImport("rove-kv", kv_mod);
    code_mod.addImport("rove-blob", blob_mod);

    // ── rove-log: per-tenant request log store ──
    //
    // Phase 3. Mirrors rove-code's "per-tenant SQLite index + rove-blob
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

    // ── rove-tape: deterministic replay capture ──
    //
    // Phase 4. Per-channel append-only tapes (kv, date, math_random,
    // crypto_random, module) that serialize to self-describing blobs.
    // The worker attaches tape references to each LogRecord; replay
    // reads them back via `parse` and feeds them to instrumented
    // globals. No deps beyond std.
    const tape_mod = b.addModule("rove-tape", .{
        .root_source_file = b.path("src/tape/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── rove-qjs: quickjs-ng wrapper + snapshot machinery ──
    //
    // Vendors quickjs-ng v0.13.0+ (commit 71a3c54) with shift-js's
    // stable-shape-hash patch already applied to vendor/quickjs-ng/
    // quickjs.c (see vendor/quickjs-ng/LICENSE, MIT licensed).
    //
    // The four C files below are the complete quickjs-ng core — no
    // libc module, no CLI. Definitions match shift-js's build:
    // -D_GNU_SOURCE and -DQUICKJS_NG_BUILD are both required.
    const qjs_mod = b.addModule("rove-qjs", .{
        .root_source_file = b.path("src/qjs/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    qjs_mod.link_libc = true;
    qjs_mod.linkSystemLibrary("m", .{});
    qjs_mod.linkSystemLibrary("pthread", .{});
    qjs_mod.addIncludePath(b.path("vendor/quickjs-ng"));
    qjs_mod.addCSourceFiles(.{
        .root = b.path("vendor/quickjs-ng"),
        .files = &.{
            "quickjs.c",
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

    // ── rove-log-server: per-instance log read operations (Phase 5) ──
    //
    // Mirror of rove-code-server for the observability side. Read-only
    // SQLite connections per call so the worker's h2 thread remains
    // the sole writer. Wrapped by a later thread subsystem + proxied
    // via `/_system/log/*` on the worker.
    const log_server_mod = b.addModule("rove-log-server", .{
        .root_source_file = b.path("src/log_server/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    log_server_mod.link_libc = true;
    log_server_mod.linkSystemLibrary("nghttp2", .{});
    log_server_mod.linkSystemLibrary("ssl", .{});
    log_server_mod.linkSystemLibrary("crypto", .{});
    log_server_mod.addImport("rove", rove_mod);
    log_server_mod.addImport("rove-io", io_mod);
    log_server_mod.addImport("rove-h2", h2_mod);
    log_server_mod.addImport("rove-kv", kv_mod);
    log_server_mod.addImport("rove-blob", blob_mod);
    log_server_mod.addImport("rove-log", log_mod);

    // ── rove-code-server: per-instance code operations (Phase 5) ──
    //
    // Compile + upload + deploy + source fetch, wrapping rove-code.
    // Each operation opens its own per-instance SQLite connection so
    // it's safe to call off the worker's h2 thread — later slices add
    // a thread pool and an h2 proxy endpoint for `/_system/code/*`.
    // Needs libc + nghttp2/ssl/crypto because it pulls in rove-qjs,
    // which transitively brings in the C runtime link requirements.
    const code_server_mod = b.addModule("rove-code-server", .{
        .root_source_file = b.path("src/code_server/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    code_server_mod.link_libc = true;
    code_server_mod.linkSystemLibrary("nghttp2", .{});
    code_server_mod.linkSystemLibrary("ssl", .{});
    code_server_mod.linkSystemLibrary("crypto", .{});
    code_server_mod.addImport("rove", rove_mod);
    code_server_mod.addImport("rove-io", io_mod);
    code_server_mod.addImport("rove-h2", h2_mod);
    code_server_mod.addImport("rove-kv", kv_mod);
    code_server_mod.addImport("rove-blob", blob_mod);
    code_server_mod.addImport("rove-code", code_mod);
    code_server_mod.addImport("rove-qjs", qjs_mod);

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

    // rove-code tests
    const code_tests = b.addTest(.{ .root_module = code_mod });
    test_step.dependOn(&b.addRunArtifact(code_tests).step);

    // rove-log tests
    const log_tests = b.addTest(.{ .root_module = log_mod });
    test_step.dependOn(&b.addRunArtifact(log_tests).step);

    // rove-tape tests
    const tape_tests = b.addTest(.{ .root_module = tape_mod });
    test_step.dependOn(&b.addRunArtifact(tape_tests).step);

    // rove-code-server tests
    const code_server_tests = b.addTest(.{ .root_module = code_server_mod });
    test_step.dependOn(&b.addRunArtifact(code_server_tests).step);

    // rove-log-server tests
    const log_server_tests = b.addTest(.{ .root_module = log_server_mod });
    test_step.dependOn(&b.addRunArtifact(log_server_tests).step);

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
    js_mod.addImport("rove-code", code_mod);
    js_mod.addImport("rove-log", log_mod);
    js_mod.addImport("rove-tape", tape_mod);
    js_mod.addImport("rove-tenant", tenant_mod);
    js_mod.link_libc = true;
    js_mod.linkSystemLibrary("nghttp2", .{});
    js_mod.linkSystemLibrary("ssl", .{});
    js_mod.linkSystemLibrary("crypto", .{});

    const js_tests = b.addTest(.{ .root_module = js_mod });
    test_step.dependOn(&b.addRunArtifact(js_tests).step);

    // js-worker: smoke-test binary for the rove-js end-to-end path.
    const js_worker_mod = b.addModule("js-worker", .{
        .root_source_file = b.path("examples/js_worker.zig"),
        .target = target,
        .optimize = optimize,
    });
    js_worker_mod.addImport("rove", rove_mod);
    js_worker_mod.addImport("rove-js", js_mod);
    js_worker_mod.addImport("rove-kv", kv_mod);
    js_worker_mod.addImport("rove-blob", blob_mod);
    js_worker_mod.addImport("rove-code", code_mod);
    js_worker_mod.addImport("rove-code-server", code_server_mod);
    js_worker_mod.addImport("rove-log-server", log_server_mod);
    js_worker_mod.addImport("rove-qjs", qjs_mod);
    js_worker_mod.addImport("rove-tenant", tenant_mod);
    js_worker_mod.addImport("rove-h2", h2_mod);
    js_worker_mod.link_libc = true;
    js_worker_mod.linkSystemLibrary("nghttp2", .{});
    js_worker_mod.linkSystemLibrary("ssl", .{});
    js_worker_mod.linkSystemLibrary("crypto", .{});

    const js_worker_exe = b.addExecutable(.{
        .name = "js-worker",
        .root_module = js_worker_mod,
    });
    b.installArtifact(js_worker_exe);

    const run_js_worker = b.addRunArtifact(js_worker_exe);
    const js_worker_step = b.step("js-worker", "Run the rove-js worker smoke server");
    js_worker_step.dependOn(&run_js_worker.step);

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

    // code-cli: local driver for rove-code. Wires rove-qjs in as the
    // compile hook and runs against a local KvStore + fs BlobStore.
    // Also houses the rove-code × rove-qjs integration tests.
    const code_cli_mod = b.addModule("rove-code-cli", .{
        .root_source_file = b.path("examples/code_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    code_cli_mod.addImport("rove-qjs", qjs_mod);
    code_cli_mod.addImport("rove-code", code_mod);
    code_cli_mod.addImport("rove-kv", kv_mod);
    code_cli_mod.addImport("rove-blob", blob_mod);

    const code_cli = b.addExecutable(.{
        .name = "rove-code-cli",
        .root_module = code_cli_mod,
    });
    b.installArtifact(code_cli);

    const code_cli_tests = b.addTest(.{ .root_module = code_cli_mod });
    test_step.dependOn(&b.addRunArtifact(code_cli_tests).step);

    // log-cli: read-only query tool for the per-tenant log store.
    const log_cli_mod = b.addModule("rove-log-cli", .{
        .root_source_file = b.path("examples/log_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    log_cli_mod.addImport("rove-kv", kv_mod);
    log_cli_mod.addImport("rove-blob", blob_mod);
    log_cli_mod.addImport("rove-log", log_mod);
    log_cli_mod.addImport("rove-code", code_mod);
    log_cli_mod.addImport("rove-tape", tape_mod);

    const log_cli = b.addExecutable(.{
        .name = "rove-log-cli",
        .root_module = log_cli_mod,
    });
    b.installArtifact(log_cli);

    // code-server-standalone: spawns the rove-code-server thread and
    // idles. Exists so the smoke test can drive it from curl.
    const cs_standalone_mod = b.addModule("code-server-standalone", .{
        .root_source_file = b.path("examples/code_server_standalone.zig"),
        .target = target,
        .optimize = optimize,
    });
    cs_standalone_mod.addImport("rove-code-server", code_server_mod);
    const cs_standalone = b.addExecutable(.{
        .name = "code-server-standalone",
        .root_module = cs_standalone_mod,
    });
    b.installArtifact(cs_standalone);

    // dual-worker: shift-js shared-nothing spike. Two full rove-js
    // worker instances in one process, both bound to the same port
    // via SO_REUSEPORT, sharing one raft node + one apply ctx.
    const dual_worker_mod = b.addModule("dual-worker", .{
        .root_source_file = b.path("examples/dual_worker.zig"),
        .target = target,
        .optimize = optimize,
    });
    dual_worker_mod.addImport("rove", rove_mod);
    dual_worker_mod.addImport("rove-io", io_mod);
    dual_worker_mod.addImport("rove-js", js_mod);
    dual_worker_mod.addImport("rove-kv", kv_mod);
    dual_worker_mod.addImport("rove-blob", blob_mod);
    dual_worker_mod.addImport("rove-code", code_mod);
    dual_worker_mod.addImport("rove-code-server", code_server_mod);
    dual_worker_mod.addImport("rove-log-server", log_server_mod);
    dual_worker_mod.addImport("rove-qjs", qjs_mod);
    dual_worker_mod.addImport("rove-tenant", tenant_mod);
    dual_worker_mod.link_libc = true;
    dual_worker_mod.linkSystemLibrary("nghttp2", .{});
    dual_worker_mod.linkSystemLibrary("ssl", .{});
    dual_worker_mod.linkSystemLibrary("crypto", .{});
    const dual_worker_exe = b.addExecutable(.{
        .name = "dual-worker",
        .root_module = dual_worker_mod,
    });
    b.installArtifact(dual_worker_exe);

    // rove-js-ctl: admin CLI over the worker's /_system/* surface.
    const js_ctl_mod = b.addModule("rove-js-ctl", .{
        .root_source_file = b.path("examples/rove_js_ctl.zig"),
        .target = target,
        .optimize = optimize,
    });
    js_ctl_mod.addImport("rove", rove_mod);
    js_ctl_mod.addImport("rove-io", io_mod);
    js_ctl_mod.addImport("rove-h2", h2_mod);
    js_ctl_mod.link_libc = true;
    js_ctl_mod.linkSystemLibrary("nghttp2", .{});
    js_ctl_mod.linkSystemLibrary("ssl", .{});
    js_ctl_mod.linkSystemLibrary("crypto", .{});
    const js_ctl = b.addExecutable(.{
        .name = "rove-js-ctl",
        .root_module = js_ctl_mod,
    });
    b.installArtifact(js_ctl);

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
}
