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
    // V2 (V2 cutover; docs/architecture/consensus-and-storage.md): the `raft-kv` module now roots
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
    // ── rove-reserve: cluster-unique ids from raft-reserved blocks ──
    //
    // A reissued id corrupts whatever it names, and the double-buffered
    // refill that avoids a consensus round trip per id is not
    // concurrency worth writing twice. Used by the keyring's slot
    // allocation, where a reissued slot would give two identities one
    // key — so shredding either would shred both. The body pool does NOT
    // use it: a pool object is named by its own content, which removes
    // the uniqueness problem instead of coordinating it. std-only leaf.
    const reserve_mod = b.addModule("rove-reserve", .{
        .root_source_file = b.path("src/reserve/root.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    // The pure `@scope/pkg` resolution logic (src/js/package_resolver.zig),
    // shared by the worker (via module_execution's relative import) and the
    // offline sim (which imports it here as a module) so the two can't drift.
    // A separate compilation for the sim is fine — it's pure (std + manifest
    // types), no shared state.
    const pkgres_mod = b.createModule(.{
        .root_source_file = b.path("src/js/package_resolver.zig"),
        .target = target,
        .optimize = optimize,
    });
    pkgres_mod.addImport("rove-files", files_mod);

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
    // Readset replication (docs/architecture/effects-and-handlers.md):
    // fetch-response bodies and inbound request bodies stream into a per-tenant
    // in-memory buffer that periodically flushes to S3 as one object
    // per batch. The raft entry's readset carries a `BodyRef` naming a
    // content-addressed pool object and an extent inside it; the bytes
    // never ride in the entry. Depends on rove-blob, which owns the pool
    // object format this re-exports.
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
    // import the ONE tier table without a cycle (docs/architecture/control-plane.md). Owns
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
    // The interaction digest as its own std-only module (same arrangement as
    // tape-decode below): rove-tape re-exports it, and the replay engine's kv
    // delegate imports it directly — the lean CLI must not link rove-tape
    // (rove-log + rove-blob + libcurl), and one file must belong to one
    // module.
    const idigest_mod = b.createModule(.{
        .root_source_file = b.path("src/tape/interaction_digest.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tape_mod = b.addModule("rove-tape", .{
        .root_source_file = b.path("src/tape/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tape_mod.addImport("rove-log", log_mod);
    tape_mod.addImport("rove-blob", blob_mod);
    // Readset's `fetch_responses` channel records `BodyRef` values
    // pointing into the per-tenant readset-blob store
    // (the readset-replication model; docs/architecture/effects-and-handlers.md).
    tape_mod.addImport("rove-bodies", bodies_mod);
    // rove-kv is only used in bundle.zig's tests (to open a fresh
    // LogStore). Production bundle code never touches kv directly.
    tape_mod.addImport("raft-kv", kv_mod);
    // The lean CLI's std-only decoder for this same per-Tape wire format
    // (`rewind replay` can't link rove-tape — it would drag rove-log +
    // rove-blob + libcurl into the CLI, see tape_decode.zig's header).
    // Imported HERE so root.zig can comptime-assert MAGIC/VERSION/Channel
    // equality and round-trip serialize→tape_decode in its tests — format
    // drift between the two files is a compile/test failure, not a
    // runtime tape rejection.
    const tape_decode_mod = b.createModule(.{
        .root_source_file = b.path("src/replay/tape_decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    tape_mod.addImport("tape-decode", tape_decode_mod);
    tape_mod.addImport("interaction-digest", idigest_mod);

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

    // ── native arenajs replay engine (Phase 2 §2a) ──
    //
    // The `arenajs` artifact above is the worker's engine (trace OFF, no host).
    // The replay/simulator CLI links arenajs's SECOND artifact `arenajs-replay`
    // (the core TUs + reactor + replay-bindings + trace, ARENA_TRACE_ENABLED=1 —
    // the same composition the browser `qjs_arena_wasm` target builds). The
    // trace/snapshot-sensitive cflags live in arenajs's build.zig, not here.
    const linkReplayEngine = struct {
        fn f(mod: *std.Build.Module, dep: *std.Build.Dependency) void {
            mod.link_libc = true;
            mod.linkSystemLibrary("m", .{});
            mod.linkSystemLibrary("pthread", .{});
            mod.addIncludePath(dep.path("."));
            mod.linkLibrary(dep.artifact("arenajs-replay"));
        }
    }.f;

    // The sim base prelude (`src/replay/sim_globals.zig`) embeds the compute
    // `globals/*.js` — which live outside the replay module's package — via
    // anonymous imports. Every module that compiles `src/replay/root.zig` needs
    // them registered (replay_mod, driver_smoke_mod).
    const addSimGlobalEmbeds = struct {
        fn f(bb: *std.Build, mod: *std.Build.Module) void {
            // schedule stays (installs the private `_system.sched` the sim
            // webhook shim captures); the 11 lifted customer globals are gone.
            const names = [_][]const u8{ "crypto", "http", "request", "base64", "urlsearchparams", "platform", "time", "schedule", "webhook", "after", "stream", "next", "blob" };
            inline for (names) |nm| {
                mod.addAnonymousImport("g_" ++ nm, .{ .root_source_file = bb.path("src/js/globals/" ++ nm ++ ".js") });
            }
            // The prod ip-mask rule (`request.ip`) — shared with the sim's
            // world build (root.zig derives the masked channel from an
            // authored ip) so the two surfaces can't drift.
            mod.addAnonymousImport("ip_mask", .{ .root_source_file = bb.path("src/js/ip_mask.zig") });
            // The prod header-filter predicates (reserved prefixes + the
            // IP-transport strip list) — shared with the sim's
            // authored-header hygiene (root.zig) so the filters can't drift.
            mod.addAnonymousImport("reserved_headers", .{ .root_source_file = bb.path("src/js/reserved_headers.zig") });
            // The interaction digest's JS mirror — the SAME file the browser
            // replay arena's prelude embeds (scripts/ops/gen_replay_prelude.py),
            // so the sim folds the identical hash rather than a third
            // implementation. `src/tape/testdata/digest_vectors.json` remains
            // the reference for both; neither JS copy is authoritative.
            mod.addAnonymousImport("js_interaction_digest", .{ .root_source_file = bb.path("src/tape/js_interaction_digest.js") });
        }
    }.f;

    // replay-spike: de-risk the native link + console/result extraction (§2a).
    const spike_mod = b.createModule(.{
        .root_source_file = b.path("src/replay/spike.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkReplayEngine(spike_mod, arenajs_dep);
    const spike_exe = b.addExecutable(.{ .name = "replay-spike", .root_module = spike_mod });
    const spike_step = b.step("replay-spike", "Native arenajs replay de-risk spike (Phase 2 §2a)");
    spike_step.dependOn(&b.addInstallArtifact(spike_exe, .{}).step);

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
    // Indexer + h2 query API, S3-backed. The production binary at
    // src/log_server/main.zig wraps these modules.
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
    // Seam interference (`seam.zig`) decodes candidate records' kv tapes
    // server-side — the whole point is filtering N foreign records down
    // to the interacting few without shipping N tapes to the client.
    log_server_mod.addImport("rove-tape", tape_mod);
    // Body resolution (`body_ref.zig`) turns a record's out-of-line
    // payload pointer back into bytes, so it needs the pool key template
    // and the `NO_BATCH` sentinel that discriminate the pointer shapes.
    log_server_mod.addImport("rove-bodies", bodies_mod);

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

    // ── rove-keyring: one tenant's key state, cluster-blind ─────────
    //
    // The keyring, the slot pool, completeness and the destroy queue,
    // owned in one place with one lifetime. Everything that reaches
    // other nodes — reserving a slot range through raft, pushing a shard
    // over HTTP, publishing the minted watermark — arrives as a callback
    // instead, so this module never learns the cluster exists and stays
    // testable without one.
    const keyring_mod = b.addModule("rove-keyring", .{
        .root_source_file = b.path("src/keyring/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── rove-crypt: the sealed-envelope primitive ───────────────────
    //
    // Crypto shredding's one cipher seam: erasure is key destruction,
    // so every ciphertext carries the algorithm, key generation, and a
    // ref naming the key that opens it — self-describing from the first
    // byte persisted (the crypto algorithm-agility gate,
    // docs/architecture/format-versioning.md). std-only leaf: AEAD and
    // HKDF come from std.crypto, matching `js/bindings/crypto.zig`, so
    // importing it adds no link requirement to any binary. The browser
    // replay arena deliberately does NOT import it — replay is decrypted
    // server-side and no key is ever distributed to a client.
    const crypt_mod = b.addModule("rove-crypt", .{
        .root_source_file = b.path("src/crypt/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The slot pool is `rove-reserve` with a provider that also mints and
    // replicates — the same block allocator the blob coordinator uses,
    // because a reissued slot would give two identities one key.
    crypt_mod.addImport("rove-reserve", reserve_mod);

    // ── rove-origin: node origin parsing ────────────────────────────
    //
    // The one definition of what the fleet can dial. Shared so the CP
    // (which accepts origins into the directory from REWIND_CLUSTERS)
    // and the front door (which dials them) cannot disagree — a CP that
    // accepts what a front rejects only fails at dial time, a hop away
    // from the operator who typed it. std-only leaf.
    const origin_mod = b.addModule("rove-origin", .{
        .root_source_file = b.path("src/origin/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── rove-acme: in-tree ACME (RFC 8555) HTTP-01 client + :80
    //    challenge responder (docs/architecture/auth-and-domains.md). Issues
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

    // ── metrics-server: dedicated operator-metrics HTTP/1.1 listener.
    //    A std-only loopback server that serves a pre-rendered Prometheus
    //    snapshot off a separate thread + socket, so `/metrics` stays
    //    scrapable while the main request path is wedged. Shared by BOTH
    //    rewind-worker (rove-js) and rewind-cp — each renders its own snapshot
    //    text and publish()es it; the server is content-agnostic.
    const metrics_server_mod = b.addModule("metrics-server", .{
        .root_source_file = b.path("src/metrics_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const metrics_server_tests = b.addTest(.{ .root_module = metrics_server_mod });
    const run_metrics_server_tests = b.addRunArtifact(metrics_server_tests);

    // ── rove-boot: shared process-boot scaffolding for the four serving
    //    binaries (signal→stop-flag wiring, URL-list env parsing, the
    //    operator-metrics listener bring-up + the disjoint default-port
    //    table, the 2s publish cadence gate). See src/boot/root.zig.
    const boot_mod = b.addModule("rove-boot", .{
        .root_source_file = b.path("src/boot/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    boot_mod.addImport("metrics-server", metrics_server_mod);
    const boot_tests = b.addTest(.{ .root_module = boot_mod });
    const run_boot_tests = b.addRunArtifact(boot_tests);

    // rove-files-server was dissolved into the worker's `DeployThread`
    // (docs/architecture/cli-and-deploy.md §4.2): the worker already links
    // rove-files + rove-qjs + rove-blob, so compile + content-address +
    // stamp-manifest now runs IN the worker (on the background
    // DeployThread). The separate binary + its trust domain are gone.

    // ── Tests ──
    const test_step = b.step("test", "THE gate: every unit test + a compile of every shipped binary");

    // metrics-server (shared by rewind-worker + rewind-cp)
    test_step.dependOn(&run_metrics_server_tests.step);
    // rove-boot (shared by all four serving binaries)
    test_step.dependOn(&run_boot_tests.step);

    // rove tests
    const rove_tests = b.addTest(.{ .root_module = rove_mod });
    test_step.dependOn(&b.addRunArtifact(rove_tests).step);
    // Isolated core-ECS test step — entity/row/collection/registry/fat
    // without the rest of the suite.
    const rove_test_step = b.step("rove-test", "Run the core rove (ECS) unit tests in isolation");
    rove_test_step.dependOn(&b.addRunArtifact(rove_tests).step);

    // fat-bench: core-ECS move-cost microbenchmark — Registry (archetype)
    // vs FatRegistry (fat-entity shadow model) on the same Collection
    // machinery. Its own module rooted in src/rove so the registry code
    // under measurement compiles at ReleaseFast (rove_mod compiles at the
    // session's optimize mode). The gate compiles it; only the step runs it.
    const fat_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/rove/fat_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const fat_bench = b.addExecutable(.{ .name = "fat-bench", .root_module = fat_bench_mod });
    test_step.dependOn(&fat_bench.step);
    const fat_bench_step = b.step("fat-bench", "Run the core-ECS move-cost microbenchmark (ReleaseFast)");
    fat_bench_step.dependOn(&b.addRunArtifact(fat_bench).step);

    // access-bench: dense-walk vs gather vs flag-scan — the memory-hierarchy
    // number behind collections-as-dense-arrays. Same ReleaseFast isolation
    // as fat-bench; the gate compiles it, only the step runs it.
    const access_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/rove/access_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const access_bench = b.addExecutable(.{ .name = "access-bench", .root_module = access_bench_mod });
    test_step.dependOn(&access_bench.step);
    const access_bench_step = b.step("access-bench", "Run the access-pattern microbenchmark (ReleaseFast)");
    access_bench_step.dependOn(&b.addRunArtifact(access_bench).step);

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

    // rove-acme tests. The module had no test target at all — it built and
    // linked fine, so nothing indicated that its tests (certificate expiry, the
    // CSR/JWS crypto, the challenge responder) were never compiled.
    const acme_tests = b.addTest(.{ .root_module = acme_mod });
    const acme_test_step = b.step("acme-test", "Run the rove-acme unit tests");
    acme_test_step.dependOn(&b.addRunArtifact(acme_tests).step);
    test_step.dependOn(&b.addRunArtifact(acme_tests).step);

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

    // rove-log-server tests. The shared module stays sqlite-free (sqlite is
    // linked at the binary level), so the test gets its OWN module that links
    // sqlite3 (index_db.zig needs it) — which is why `zig build test` needs
    // libsqlite3 present, same as the `rewind-logs` binary it also compiles.
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
    log_server_test_mod.addImport("rove-tape", tape_mod);
    log_server_test_mod.addImport("rove-bodies", bodies_mod);
    const log_server_tests = b.addTest(.{ .root_module = log_server_test_mod });
    const run_log_server_tests = b.addRunArtifact(log_server_tests);
    const log_server_test_step = b.step("log-server-test", "Run rove-log-server unit tests");
    log_server_test_step.dependOn(&run_log_server_tests.step);
    test_step.dependOn(&run_log_server_tests.step);

    // rove-jwt tests
    const jwt_tests = b.addTest(.{ .root_module = jwt_mod });
    test_step.dependOn(&b.addRunArtifact(jwt_tests).step);

    // rove-ssrf tests
    const ssrf_tests = b.addTest(.{ .root_module = ssrf_mod });
    test_step.dependOn(&b.addRunArtifact(ssrf_tests).step);

    // rove-crypt tests
    const crypt_tests = b.addTest(.{ .root_module = crypt_mod });
    test_step.dependOn(&b.addRunArtifact(crypt_tests).step);


    // rove-reserve tests
    const reserve_tests = b.addTest(.{ .root_module = reserve_mod });
    test_step.dependOn(&b.addRunArtifact(reserve_tests).step);

    // rove-origin tests
    const origin_tests = b.addTest(.{ .root_module = origin_mod });
    test_step.dependOn(&b.addRunArtifact(origin_tests).step);

    // rove-plan tests — also exposed as a dedicated `plan-test` step for
    // running the tier table in isolation.
    const plan_tests = b.addTest(.{ .root_module = plan_mod });
    const run_plan_tests = b.addRunArtifact(plan_tests);
    test_step.dependOn(&run_plan_tests.step);
    const plan_test_step = b.step("plan-test", "Run rove-plan (tier table) unit tests");
    plan_test_step.dependOn(&run_plan_tests.step);

    // The HTTP/1.1 codec (`src/h2/http1.zig`) and the RFC 6455 WebSocket codec
    // (`src/h2/ws.zig`, docs/architecture/websockets.md) had standalone test
    // modules + `h1-test`/`ws-test` steps. Both files are re-exported by
    // `src/h2/root.zig`, so `h2_tests` already runs their tests — the extra
    // artifacts only ran the same tests a second time.

    // ── rove-instance-id: the tenant-id spec ──
    //
    // A dependency-free leaf so the worker (which resolves `{id}.{suffix}`
    // locally) and the control plane (which validates at provisioning and
    // resolves the same wildcard for the front door) read ONE rule. A CP that
    // accepted an id the worker's wildcard cannot resolve would provision a
    // tenant that is placed but unreachable.
    const instance_id_mod = b.addModule("rove-instance-id", .{
        .root_source_file = b.path("src/instance_id/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const instance_id_tests = b.addTest(.{ .root_module = instance_id_mod });
    test_step.dependOn(&b.addRunArtifact(instance_id_tests).step);

    // ── rove-reserved: the platform-reserved KV prefixes ──
    //
    // A std-only leaf so the WORKER (which enforces the customer-write guard)
    // and the REPLAY/sim engine (which mirrors that guard offline, in JS) read
    // ONE list. They used to hold two hand-authored copies and had already
    // drifted — `_export/` reached the worker and never reached replay, so a
    // handler using the export verb was writable in prod and refused offline
    // (rove#499). The engines disagreeing about what a handler may do is the
    // exact failure the conformance suite exists to catch.
    const reserved_mod = b.addModule("rove-reserved", .{
        .root_source_file = b.path("src/reserved/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const reserved_tests = b.addTest(.{ .root_module = reserved_mod });
    test_step.dependOn(&b.addRunArtifact(reserved_tests).step);

    // rove-keyring's deps, wired here because they are declared above:
    // the crypto primitive, the kv facade for the replicated `_keys/*`
    // rows, the reserved-prefix contracts, and the block allocator.
    keyring_mod.addImport("rove-crypt", crypt_mod);
    keyring_mod.addImport("raft-kv", kv_mod);
    keyring_mod.addImport("rove-reserved", reserved_mod);
    keyring_mod.addImport("rove-reserve", reserve_mod);
    const keyring_tests = b.addTest(.{ .root_module = keyring_mod });
    test_step.dependOn(&b.addRunArtifact(keyring_tests).step);

    // ── rove-sizing: the sizing chain, one derivation ──
    //
    // `RECV_BUF_SIZE` → frame → message → entry → per-activation budgets →
    // the batch's admission reserve, plus the encoders' own byte arithmetic
    // so admission, attribution and propose measure the same quantity in the
    // same unit. Five layers used to hold four approximations of it and a
    // reserve larger than a whole entry went unseen (rove#671).
    //
    // Imports the CONTRACT numbers (the kv write budget) and derives the
    // replication ones from them — one direction, so `rove-reserved` stays
    // the std-only leaf the offline engines read.
    const sizing_mod = b.addModule("rove-sizing", .{
        .root_source_file = b.path("src/sizing/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    sizing_mod.addImport("rove-reserved", reserved_mod);
    const sizing_tests = b.addTest(.{ .root_module = sizing_mod });
    test_step.dependOn(&b.addRunArtifact(sizing_tests).step);

    // Every layer that measures bytes against the entry limit reads them
    // here: the transport that owns the receiver's buffer, the codecs whose
    // framing the arithmetic describes, the tape that trims a readset to the
    // room an entry has left, the guards that spend the write budget, and
    // the worker's admission walk.
    kv_mod.addImport("rove-sizing", sizing_mod);
    tape_mod.addImport("rove-sizing", sizing_mod);

    // The tier table resolves a tenant with no plan blob from its ID (the
    // reserved platform singletons default to the platform tier), so it needs
    // the one reserved-id list. Both are leaves, so this adds no cycle.
    plan_mod.addImport("rove-instance-id", instance_id_mod);

    // ── rove-guards: the handler-facing checks, one authority ──
    //
    // Every engine that runs a customer handler must answer "is this allowed"
    // identically. Three run natively and call the Zig here directly. The
    // offline pair cannot: their storage seam (`replay/host.zig`'s kv_set)
    // reports ok/not_found/exhausted/divergence and has no way to say
    // "refused", so a Zig verdict cannot become a thrown error in their QJS.
    // They evaluate the same rules as JS, emitted from this module.
    const guards_mod = b.addModule("rove-guards", .{
        .root_source_file = b.path("src/guards/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    guards_mod.addImport("rove-reserved", reserved_mod);
    // The write budget is denominated in WIRE bytes — an op costs its
    // framing too — so the one evaluator of the rule needs the one
    // arithmetic for it.
    guards_mod.addImport("rove-sizing", sizing_mod);

    const guards_tests = b.addTest(.{ .root_module = guards_mod });
    test_step.dependOn(&b.addRunArtifact(guards_tests).step);

    // interaction-digest's inline tests (the reference vectors) no longer run
    // under rove-tape's test binary now that the file is its own module.
    const idigest_tests = b.addTest(.{ .root_module = idigest_mod });
    test_step.dependOn(&b.addRunArtifact(idigest_tests).step);

    // ── rove-binding: the common JS↔Zig binding, one implementation ──
    //
    // rove-guards made the CHECKS one authority; this is the same move for
    // the whole binding — coercion, guard call, refusal throw, result shape —
    // with a comptime delegate per engine for storage/reads/effect recording
    // (the engine-parity direction, docs/architecture/effects-and-handlers.md).
    // Deliberately generic over each engine's own quickjs @cImport instance,
    // so it links nothing and carries no C import of its own; its behavioural
    // tests live in rove-js (`kv_binding_test.zig`), where a real QJS is
    // linked.
    const binding_mod = b.addModule("rove-binding", .{
        .root_source_file = b.path("src/binding/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    binding_mod.addImport("rove-guards", guards_mod);
    binding_mod.addImport("interaction-digest", idigest_mod);
    // Needed to root a test artifact here (std's C allocator). Safe on the
    // shared module: every in-build consumer (`js_mod`, `replay_mod`,
    // `driver_smoke_mod`) already links libc for arenajs, and the browser
    // wasm arena assembles its own module graph in
    // `scripts/ops/build_wasm_arena.sh` rather than using this one.
    binding_mod.link_libc = true;

    // The binding's own tests. Importing a module does NOT bring its tests
    // along — `js_mod`/`replay_mod` import this one for its declarations, and
    // its two offline-shred tests were compiling nowhere until
    // `test_reachability_lint.py` was finally run (it had never been wired
    // into a step, so nothing said so).
    const binding_tests = b.addTest(.{ .root_module = binding_mod });
    test_step.dependOn(&b.addRunArtifact(binding_tests).step);

    // ── wasm-arena: the browser replay arena, built IN-TREE ──
    //
    // rove's Zig (src/arena/root.zig — the common binding + guards + the
    // arena delegate) compiled to a wasm32-emscripten archive and linked
    // into arenajs's qjs_arena_wasm via its ROVE_ARENA seam, so the browser
    // engine runs the SAME compiled checks the worker and the sim run. An
    // explicit step, not part of `test`: it needs emsdk, and the shipped
    // artifact is committed in rewind-apps (the replay tenant) — rebuild
    // here, copy there, republish.
    const wasm_arena = b.addSystemCommand(&.{"bash"});
    wasm_arena.addFileArg(b.path("scripts/ops/build_wasm_arena.sh"));
    wasm_arena.addDirectoryArg(arenajs_dep.path("."));
    wasm_arena.addArg(b.pathJoin(&.{ b.install_path, "wasm-arena" }));
    wasm_arena.has_side_effects = true;
    b.step("wasm-arena", "Build the browser replay arena wasm (rove Zig + arenajs C via emscripten)")
        .dependOn(&wasm_arena.step);

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
    tenant_mod.addImport("rove-instance-id", instance_id_mod);
    // storage.zig: the per-tenant blob-backend constructor lives on the
    // TenantStorage handle, so the (id, incarnation) → prefix rule has
    // exactly one home.
    tenant_mod.addImport("rove-blob", blob_mod);

    const tenant_tests = b.addTest(.{ .root_module = tenant_mod });
    test_step.dependOn(&b.addRunArtifact(tenant_tests).step);

    // ── wire-headers: THE registry of platform-reserved header names.
    //    Pure std — no rove-blob, so no libcurl — because the binaries that
    //    link neither (`rewind-ops`, `rewind`) must still hold the one
    //    spelling. `scripts/ops/reserved_header_lint.py` keeps it the only
    //    place a name literal lives.
    const wire_headers_mod = b.addModule("wire-headers", .{
        .root_source_file = b.path("src/wire/headers.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── rove-wire: CP↔worker wire contracts (one encode/decode pair per
    //    envelope — docs/defect-patterns.md class 3). Shared by rewind-cp
    //    (senders) and rove-js (receivers); re-exports the names above.
    const wire_mod = b.addModule("rove-wire", .{
        .root_source_file = b.path("src/wire/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    wire_mod.addImport("rove-blob", blob_mod);
    wire_mod.addImport("wire-headers", wire_headers_mod);

    const wire_tests = b.addTest(.{ .root_module = wire_mod });
    test_step.dependOn(&b.addRunArtifact(wire_tests).step);

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
    js_mod.addImport("rove-wire", wire_mod);
    js_mod.addImport("rove-ssrf", ssrf_mod);
    js_mod.addImport("rove-plan", plan_mod);
    // Keyring shard transport: the worker installs peer-sent shards and
    // pushes its own to a quorum (`keyring_shard.zig`).
    js_mod.addImport("rove-crypt", crypt_mod);
    js_mod.addImport("rove-keyring", keyring_mod);
    js_mod.addImport("rove-reserved", reserved_mod);
    js_mod.addImport("rove-sizing", sizing_mod);
    js_mod.addImport("rove-guards", guards_mod);
    js_mod.addImport("rove-binding", binding_mod);
    js_mod.addImport("metrics-server", metrics_server_mod);
    // JS-side runtime polyfills evaluated into every dispatcher's QJS
    // context after the native CFunction bindings install.
    // retry.js provides a customer-side retry helper layered on
    // http.send (no system tenant, no cross-tenant privileges).
    // webhook.js wraps `http.send` (legacy webhook.send compatibility);
    // email.js wraps `webhook.send` (which now layers on http.send);
    // textcodec.js polyfills TextEncoder/Decoder.
    const js_runtime_files: []const struct { name: []const u8, path: []const u8 } = &.{
        // Public doc-carrying shims over `_system.*`
        // (docs/architecture/builtin-libs.md Phase A).
        .{ .name = "kv_js", .path = "src/js/globals/kv.js" },
        .{ .name = "console_js", .path = "src/js/globals/console.js" },
        .{ .name = "crypto_js", .path = "src/js/globals/crypto.js" },
        .{ .name = "http_js", .path = "src/js/globals/http.js" },
        .{ .name = "platform_js", .path = "src/js/globals/platform.js" },
        .{ .name = "base64_js", .path = "src/js/globals/base64.js" },
        .{ .name = "urlsearchparams_js", .path = "src/js/globals/urlsearchparams.js" },
        .{ .name = "time_js", .path = "src/js/globals/time.js" },
        // schedule.js stays embedded: it now installs the PRIVATE
        // `_system.sched` (webhook.js captures it), not a customer global.
        .{ .name = "schedule_js", .path = "src/js/globals/schedule.js" },
        .{ .name = "after_js", .path = "src/js/globals/after.js" },
        .{ .name = "stream_js", .path = "src/js/globals/stream.js" },
        .{ .name = "next_js", .path = "src/js/globals/next.js" },
        .{ .name = "webhook_js", .path = "src/js/globals/webhook.js" },
        .{ .name = "textcodec_js", .path = "src/js/globals/textcodec.js" },
        .{ .name = "handler_shape_md", .path = "docs/handler-shape.md" },
        .{ .name = "request_js", .path = "src/js/globals/request.js" },
        .{ .name = "blob_js", .path = "src/js/globals/blob.js" },

        // Built-in handler modules — compiled to bytecode at NodeState
        // init, resolved via the `__system/` module-path prefix
        // (the reified primitives; docs/architecture/effects-and-handlers.md). Not part
        // of any tenant's deployment files; shared across every
        // tenant's context. Add an entry here AND in
        // `src/js/builtin_modules.zig`'s `MODULES` table.
        .{ .name = "builtin_webhook_onresult_mjs", .path = "src/js/builtin_modules/webhook_onresult.mjs" },
        // webhook.send's wake-fired half (durable-wake; docs/architecture/effects-and-handlers.md).
        .{ .name = "builtin_webhook_fire_mjs", .path = "src/js/builtin_modules/webhook_fire.mjs" },
        .{ .name = "builtin_dispatch_fire_mjs", .path = "src/js/builtin_modules/dispatch_fire.mjs" },
        .{ .name = "builtin_dispatch_result_mjs", .path = "src/js/builtin_modules/dispatch_result.mjs" },
        .{ .name = "builtin_config_install_mjs", .path = "src/js/builtin_modules/config_install.mjs" },
        // §2.6 durable scheduled wake — the `scheduler_tick` baked
        // module (durable-wake P1; docs/architecture/effects-and-handlers.md). Add an entry here AND
        // in `src/js/builtin_modules.zig`'s `MODULES` table.
        .{ .name = "builtin_scheduler_tick_mjs", .path = "src/js/builtin_modules/scheduler_tick.mjs" },
        // Handler-surface Phase 5 — the `cron(...)` recurrence engine.
        .{ .name = "builtin_cron_tick_mjs", .path = "src/js/builtin_modules/cron_tick.mjs" },
        .{ .name = "builtin_export_run_mjs", .path = "src/js/builtin_modules/export_run.mjs" },
        // blob-storage P1 (docs/architecture/routing-and-ingress.md) — blob.put's marker-settling
        // result handler.
        .{ .name = "builtin_blob_onresult_mjs", .path = "src/js/builtin_modules/blob_onresult.mjs" },
        // blob-write-recipes.md §4 — the seal-time prompt compose + its flip.
        .{ .name = "builtin_blob_compose_mjs", .path = "src/js/builtin_modules/blob_compose.mjs" },
        .{ .name = "builtin_blob_compose_onresult_mjs", .path = "src/js/builtin_modules/blob_compose_onresult.mjs" },
        // blob-storage §6 (docs/architecture/routing-and-ingress.md) — segments.seal's swap half.
        .{ .name = "builtin_segments_onsealed_mjs", .path = "src/js/builtin_modules/segments_onsealed.mjs" },
        // Engine-fired deploy-static streamer ("onStatic") — cold/large static serve.
        .{ .name = "builtin_static_mjs", .path = "src/js/builtin_modules/static.mjs" },

        // Starter content baked into the freshly-created tenant's
        // first deployment — see `deployStarterContent` in
        // `src/js/worker.zig`. Edited as plain files under
        // `src/js/starter/` rather than as Zig multi-line literals
        // so JS / HTML keep syntax highlighting and aren't gated on
        // a Zig rebuild for trivial copy edits.
        .{ .name = "starter_index_mjs", .path = "src/js/starter/index.mjs" },
        .{ .name = "starter_static_index_html", .path = "src/js/starter/_static/index.html" },
        // The genesis __admin__ deploy app (docs/architecture/cli-and-deploy.md §4.1 (f)) — baked
        // so a virgin cluster self-bootstraps deploy capability with no
        // external push; the full admin is then published THROUGH it.
        .{ .name = "genesis_admin_mjs", .path = "src/js/starter/genesis_admin.mjs" },
        // The streamed static-upload module (routed at /v1/upload), baked into
        // genesis alongside index.mjs so the bootstrap can stream large statics
        // (codemirror) into the admin it publishes. The operator's admin app
        // (rewind-apps) carries its own copy of this module for its deploy bundle.
        .{ .name = "upload_mjs", .path = "src/js/starter/upload.mjs" },
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
    // libz for resident-HTML gzip (src/js/gzip.zig); Zig 0.15 flate is
    // incomplete, so we use libz directly (same as the log server).
    js_mod.linkSystemLibrary("z", .{});

    const js_tests = b.addTest(.{ .root_module = js_mod });
    test_step.dependOn(&b.addRunArtifact(js_tests).step);

    // V1→V2 cutover: `rove-snapshot` (src/loop46/snapshot.zig, willemt
    // RaftNode) and the `loop46` product binary (src/loop46/, V1 cluster +
    // sqlite raft) were RETIRED — the V2 worker is `rewind-worker`
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

    // files-server (V1 `files-server-standalone` and the cluster-free V2
    // `files-server-v2`) is RETIRED — dissolved into the worker's
    // `DeployThread` (docs/architecture/cli-and-deploy.md §4.2). Compile +
    // manifest + blob-write run IN the worker on that thread, driven by the
    // `__admin__` app's `/v1/deploy/*` routes; the `_deploy/current` flip stays
    // the worker's `/_system/release`. No separate deploy binary or trust
    // domain.

    // sse-server-standalone: RETIRED (task #10 Phase 3). The SSE
    // notification service now runs as a loop46-internal thread
    // (`sse_server.standalone.spawn`, sibling to the raft thread,
    // gated on `--sse-listen`; single-node only). Workers hand emits
    // via the in-process `Handle.enqueueEmit` queue — no cross-process
    // rendezvous, no `--sse-public-base`, no `SSE_INTERNAL_TOKEN`.
    // See `docs/architecture/routing-and-ingress.md` (SSE) +
    // `docs/architecture/websockets.md` (the connection actor).

    // rewind-logs: Phase 5.5 (a) step 2 — runs the new
    // S3-direct logs indexer + h2 query API as a standalone process.
    // Smoke driver populates the batch-store dir directly on disk
    // (no worker yet); step 3 wires the worker's flush path into S3.
    const ls_standalone_mod = b.addModule("rewind-logs", .{
        .root_source_file = b.path("src/log_server/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ls_standalone_mod.addImport("rove-boot", boot_mod);
    ls_standalone_mod.addImport("rove-log-server", log_server_mod);
    ls_standalone_mod.addImport("rove-jwt", jwt_mod);
    ls_standalone_mod.addImport("rove-blob", blob_mod);
    ls_standalone_mod.addImport("rove-h2", h2_mod);
    ls_standalone_mod.addImport("metrics-server", metrics_server_mod);
    // `rove-log-server` is deliberately sqlite-free (the C lib is linked at the
    // binary level, not the shared module — see `log_server_test_mod` below);
    // its `index_db.zig` needs sqlite3, so this binary links it. (Pre-cutover
    // this was masked by the default build failing on loop46 first.)
    ls_standalone_mod.link_libc = true;
    ls_standalone_mod.linkSystemLibrary("sqlite3", .{});
    const ls_standalone = b.addExecutable(.{
        .name = "rewind-logs",
        .root_module = ls_standalone_mod,
    });
    b.installArtifact(ls_standalone);
    // Named step so `zig build rewind-logs` works (scripts/deploy.sh builds
    // each shipped binary by name).
    const ls_step = b.step("rewind-logs", "Build the V2 log-server / tape indexer binary");
    ls_step.dependOn(&b.addInstallArtifact(ls_standalone, .{}).step);

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

    // echo server on the fat-entity registry model (port 8081)
    const echo_fat_mod = b.addModule("echo-server-fat", .{
        .root_source_file = b.path("examples/echo_server_fat.zig"),
        .target = target,
        .optimize = optimize,
    });
    echo_fat_mod.addImport("rove-io", io_mod);
    echo_fat_mod.addImport("rove", rove_mod);

    const echo_server_fat = b.addExecutable(.{
        .name = "echo-server-fat",
        .root_module = echo_fat_mod,
    });
    b.installArtifact(echo_server_fat);

    const run_echo_fat = b.addRunArtifact(echo_server_fat);
    const echo_fat_step = b.step("echo-server-fat", "Run the echo server example on the fat-entity registry");
    echo_fat_step.dependOn(&run_echo_fat.step);
    // The one artifact that instantiates Io under the fat registry model —
    // gate its compile or that whole comptime path rots invisibly.
    test_step.dependOn(&echo_server_fat.step);

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

    // h2 echo server on the fat-entity registry model (port 8445)
    const h2_echo_fat_mod = b.addModule("h2-echo-server-fat", .{
        .root_source_file = b.path("examples/h2_echo_server_fat.zig"),
        .target = target,
        .optimize = optimize,
    });
    h2_echo_fat_mod.addImport("rove-h2", h2_mod);
    h2_echo_fat_mod.addImport("rove", rove_mod);
    h2_echo_fat_mod.link_libc = true;
    h2_echo_fat_mod.linkSystemLibrary("nghttp2", .{});
    h2_echo_fat_mod.linkSystemLibrary("ssl", .{});
    h2_echo_fat_mod.linkSystemLibrary("crypto", .{});

    const h2_echo_server_fat = b.addExecutable(.{
        .name = "h2-echo-server-fat",
        .root_module = h2_echo_fat_mod,
    });
    b.installArtifact(h2_echo_server_fat);
    // The one artifact that instantiates H2 under the fat registry model —
    // gate its compile or that whole comptime path rots invisibly.
    test_step.dependOn(&h2_echo_server_fat.step);

    const run_h2_echo_fat = b.addRunArtifact(h2_echo_server_fat);
    const h2_echo_fat_step = b.step("h2-echo-server-fat", "Run the HTTP/2 echo server example on the fat-entity registry");
    h2_echo_fat_step.dependOn(&run_h2_echo_fat.step);

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

    // ws-echo: inbound WebSocket transport proof (docs/architecture/websockets.md).
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

    // Extended-CONNECT WS tunnel test (docs/architecture/websockets.md, front Extended CONNECT): in-process
    // client+server pair over RFC 8441. `zig build h2-ws-connect-test` runs it.
    const h2_ws_connect_mod = b.addModule("h2-ws-connect-test", .{
        .root_source_file = b.path("examples/h2_ws_connect_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    h2_ws_connect_mod.addImport("rove", rove_mod);
    h2_ws_connect_mod.addImport("rove-io", io_mod);
    h2_ws_connect_mod.addImport("rove-h2", h2_mod);
    h2_ws_connect_mod.link_libc = true;
    h2_ws_connect_mod.linkSystemLibrary("nghttp2", .{});
    h2_ws_connect_mod.linkSystemLibrary("ssl", .{});
    h2_ws_connect_mod.linkSystemLibrary("crypto", .{});

    const h2_ws_connect_test = b.addExecutable(.{
        .name = "h2-ws-connect-test",
        .root_module = h2_ws_connect_mod,
    });
    b.installArtifact(h2_ws_connect_test);
    const run_h2_ws_connect = b.addRunArtifact(h2_ws_connect_test);
    b.step("h2-ws-connect-test", "Run the Extended-CONNECT WS tunnel test").dependOn(&run_h2_ws_connect.step);

    // ── rust-ffi-smoke: V2 build-time cargo→link spike (docs/decisions.md,
    // deps are pinned-and-fetched at build time).
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

    // ── V2 raft substrate (v2-build-order Phase 0) ──────────────────────
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
    // RECV_BUF_SIZE is the head of the sizing chain, not a local knob: every
    // producer-side budget is derived from it (`rove-sizing`).
    raftnet_mod.addImport("rove-sizing", sizing_mod);

    const v2_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/consensus/v2_raft_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    v2_smoke_mod.addImport("raft_rs_zig", raft_dep.module("raft_rs_zig"));
    const v2_smoke_test = b.addTest(.{ .root_module = v2_smoke_mod });
    const run_v2_smoke_test = b.addRunArtifact(v2_smoke_test);
    // `v2-test` is a FOCUSED SUBSET, not a separate gate: every artifact below
    // is also on the aggregate `test`. The split dated from V2 being a branch
    // beside a live V1; V2 is main now, and the "keep cargo out of a
    // lightweight `test`" rationale expired when rove-js took a `bridge`
    // import — the aggregate already links raft-rs. Keeping the step is worth
    // it for iterating on the raft substrate alone (~4s vs the full suite);
    // keeping it EXCLUSIVE meant consensus and directory regressions did not
    // fail `zig build test`.
    const v2_test_step = b.step("v2-test", "V2 raft substrate tests, a subset of `test` (Phase-0 smoke + Phase-1 per-tenant pump)");
    v2_test_step.dependOn(&run_v2_smoke_test.step);
    test_step.dependOn(&run_v2_smoke_test.step);

    // The cross-node wire layer's own inline tests (loopback frame exchange,
    // mesh-count accounting). raft_net is a named module everywhere else, so
    // its tests aren't collected by the importers' test artifacts — root a
    // dedicated test at it so they actually run in the gate.
    const raftnet_test = b.addTest(.{ .root_module = raftnet_mod });
    const run_raftnet_test = b.addRunArtifact(raftnet_test);
    v2_test_step.dependOn(&run_raftnet_test.step);
    test_step.dependOn(&run_raftnet_test.step);

    // ── V2 Phase 1 — data-plane core: the per-tenant pump (single node)
    // (v2-build-order Phase 1). `src/consensus/node.zig` owns a
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
    v2_node_mod.addImport("rove-sizing", sizing_mod);
    const v2_node_test = b.addTest(.{ .root_module = v2_node_mod });

    // ── V2 Phase 6 — hibernation / active-set pump-cost microbench ─────
    // (hibernation; docs/architecture/consensus-and-storage.md). Measures node pump cycle time vs.
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
    // transport.zig pulls MicrosHistogram from the kvlimbs facade; needed once
    // a test instantiates the Transport struct (not just the wire codec).
    v2_transport_mod.addImport("kvlimbs", kv_mod);
    v2_transport_mod.addImport("rove-sizing", sizing_mod);
    const v2_transport_test = b.addTest(.{ .root_module = v2_transport_mod });
    const run_v2_transport_test = b.addRunArtifact(v2_transport_test);
    v2_test_step.dependOn(&run_v2_transport_test.step);
    test_step.dependOn(&run_v2_transport_test.step);
    const run_v2_node_test = b.addRunArtifact(v2_node_test);
    v2_test_step.dependOn(&run_v2_node_test.step);
    test_step.dependOn(&run_v2_node_test.step);

    // ── V2 Phase 2 — the worker-facing bridge over the per-tenant pump
    // (v2-build-order Phase 2). `src/consensus/bridge.zig` owns the
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
    v2_bridge_mod.addImport("rove-sizing", sizing_mod);
    const v2_bridge_test = b.addTest(.{ .root_module = v2_bridge_mod });
    const run_v2_bridge_test = b.addRunArtifact(v2_bridge_test);
    v2_test_step.dependOn(&run_v2_bridge_test.step);
    test_step.dependOn(&run_v2_bridge_test.step);

    // ── V2 Phase 3/7 — control plane: the tenant→cluster directory ─────
    // (directory replication; docs/architecture/control-plane.md).
    // `src/cp/directory.zig`
    // is the routing source of truth the front-door reads and a move flips.
    // Slice 1 makes it durable: it backs writes with the V2 `bridge`'s
    // directory raft group, so it now imports the bridge (and its test links
    // the raft artifact). Reads go through an in-memory projection, and a node
    // set is deep-copied out of it under the lock (rove#100).
    const v2_cp_dir_mod = b.createModule(.{
        .root_source_file = b.path("src/cp/directory.zig"),
        .target = target,
        .optimize = optimize,
    });
    v2_cp_dir_mod.addImport("bridge", v2_bridge_mod);
    // Origin parsing: the directory must not accept a node origin the front
    // door cannot dial, so both validate through the same parser.
    v2_cp_dir_mod.addImport("rove-origin", origin_mod);
    // Certificate expiry: the directory decides which hosts need issuance, and
    // "needs issuance" includes "expiring soon", so it has to be able to read a
    // certificate's notAfter.
    v2_cp_dir_mod.addImport("rove-acme", acme_mod);
    const v2_cp_dir_test = b.addTest(.{ .root_module = v2_cp_dir_mod });
    const run_v2_cp_dir_test = b.addRunArtifact(v2_cp_dir_test);
    v2_test_step.dependOn(&run_v2_cp_dir_test.step);
    test_step.dependOn(&run_v2_cp_dir_test.step);

    // rove-js imports the bridge as `@import("bridge")`. js_mod already
    // imports `kv_mod` as "raft-kv" (the facade), so the worker's
    // KvStore/TrackedTxn and the bridge's are the SAME type.
    //
    // A `js-v2` step used to compile rove-js against the facade + bridge to
    // drive the V1→V2 seam cut. It rooted a test at js_mod — the same module
    // `js_tests` roots at — so once this import landed it was `js_tests`
    // twice over. The aggregate covers it.
    js_mod.addImport("bridge", v2_bridge_mod);

    // ── rewind-worker: the V2 single-node worker binary (v2-build-order
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
    rewind_mod.addImport("rove-boot", boot_mod);
    rewind_mod.addImport("rove-jwt", jwt_mod);
    rewind_mod.addImport("rove-js", js_mod);
    rewind_mod.addImport("bridge", v2_bridge_mod);
    rewind_mod.addImport("raft-kv", kv_mod);
    rewind_mod.addImport("rove-h2", h2_mod);
    rewind_mod.addImport("rove-blob", blob_mod);
    // The request-id minter identity (RequestIdMinter.mintIdentity) is composed
    // at boot from REWIND_NODE_ID + the worker index.
    rewind_mod.addImport("rove-log", log_mod);
    rewind_mod.addImport("rove-tenant", tenant_mod);
    rewind_mod.addImport("rove-qjs", qjs_mod);
    rewind_mod.addImport("rove-log-server", log_server_mod);
    rewind_mod.addImport("rove-files", files_mod);
    rewind_mod.link_libc = true;
    rewind_mod.linkSystemLibrary("nghttp2", .{});
    rewind_mod.linkSystemLibrary("ssl", .{});
    rewind_mod.linkSystemLibrary("crypto", .{});
    const rewind_exe = b.addExecutable(.{ .name = "rewind-worker", .root_module = rewind_mod });

    // rewind-worker tests. Like rove-acme, this module had no test target: the
    // binary built, so nothing showed that `version.zig`'s tests never ran.
    const rewind_tests = b.addTest(.{ .root_module = rewind_mod });
    const rewind_test_step = b.step("rewind-worker-test", "Run the rewind-worker unit tests");
    rewind_test_step.dependOn(&b.addRunArtifact(rewind_tests).step);
    test_step.dependOn(&b.addRunArtifact(rewind_tests).step);
    const rewind_step = b.step("rewind-worker", "Build the V2 rewind worker binary (Phase 2d)");
    rewind_step.dependOn(&b.addInstallArtifact(rewind_exe, .{}).step);

    // ── rewind-front: the V2 front door (docs/architecture/routing-and-ingress.md).
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
    front_mod.addImport("rove-boot", boot_mod);
    front_mod.addImport("rove-h2", h2_mod);
    front_mod.addImport("rove-blob", blob_mod);
    front_mod.addImport("rove-wire", wire_mod);
    front_mod.addImport("metrics-server", metrics_server_mod);
    // Origin parsing, shared with the CP that hands these origins over.
    front_mod.addImport("rove-origin", origin_mod);
    // Certificate expiry parsing, for the gauge the front exports about the
    // certs it serves (`src/front/cert_expiry.zig`). rove-acme owns reading a
    // notAfter; rove-h2 stays free of it.
    front_mod.addImport("rove-acme", acme_mod);
    front_mod.link_libc = true;
    front_mod.linkSystemLibrary("nghttp2", .{});
    front_mod.linkSystemLibrary("ssl", .{});
    front_mod.linkSystemLibrary("crypto", .{});
    front_mod.linkSystemLibrary("curl", .{});
    const front_exe = b.addExecutable(.{ .name = "rewind-front", .root_module = front_mod });
    const front_step = b.step("rewind-front", "Build the V2 front-door binary (Phase 3b)");
    front_step.dependOn(&b.addInstallArtifact(front_exe, .{}).step);

    // Front-door inline tests (route cache + off-loop resolver).
    const front_tests = b.addTest(.{ .root_module = front_mod });
    const front_test_step = b.step("front-test", "Run the rewind-front unit tests");
    front_test_step.dependOn(&b.addRunArtifact(front_tests).step);
    test_step.dependOn(&b.addRunArtifact(front_tests).step);

    // ── rewind-cp: the V2 control plane (docs/architecture/control-plane.md).
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
    cp_mod.addImport("rove-boot", boot_mod);
    cp_mod.addImport("rove-h2", h2_mod);
    cp_mod.addImport("rove-blob", blob_mod);
    // Teardown's object sweep derives the tenant's S3 prefix through the same
    // `TenantStorage` handle every reader and writer uses (`storage_sweep.zig`).
    cp_mod.addImport("rove-tenant", tenant_mod);
    cp_mod.addImport("cp-directory", v2_cp_dir_mod);
    cp_mod.addImport("rove-instance-id", instance_id_mod);
    cp_mod.addImport("rove-wire", wire_mod);
    cp_mod.addImport("bridge", v2_bridge_mod);
    // Origin validation on the runtime `/_control/cluster` door, matching
    // the static seed's gate.
    cp_mod.addImport("rove-origin", origin_mod);
    cp_mod.addImport("rove-acme", acme_mod);
    cp_mod.addImport("metrics-server", metrics_server_mod);
    cp_mod.link_libc = true;
    cp_mod.linkSystemLibrary("nghttp2", .{});
    cp_mod.linkSystemLibrary("ssl", .{});
    cp_mod.linkSystemLibrary("crypto", .{});
    cp_mod.linkSystemLibrary("curl", .{});
    const cp_exe = b.addExecutable(.{ .name = "rewind-cp", .root_module = cp_mod });
    const cp_step = b.step("rewind-cp", "Build the V2 control-plane binary");
    cp_step.dependOn(&b.addInstallArtifact(cp_exe, .{}).step);

    // cp unit tests, on the aggregate `test` AND on their own step. Being on
    // the aggregate is what makes `cp/main.zig` compile there at all — the
    // module is otherwise reachable from no test root, so a type error in the
    // CP's main is invisible to `zig build test` and only the `rewind-cp`
    // binary build catches it.
    const cp_tests = b.addTest(.{ .root_module = cp_mod });
    const run_cp_tests = b.addRunArtifact(cp_tests);
    const cp_test_step = b.step("rewind-cp-test", "Run the rewind-cp unit tests");
    cp_test_step.dependOn(&run_cp_tests.step);
    test_step.dependOn(&run_cp_tests.step);

    // ── rewind-ops: the platform/operator CLI (docs/architecture/cli-and-deploy.md §2–§3,
    // §6). The privileged half of the split (root + move-secret + ops-secret);
    // the OIDC-scoped customer `rewind` binary lands later, sharing
    // src/cli/common.zig. std-only — operator env reader + curl/ssh transport +
    // bundle classifier — no rove modules, no system libs, no raft/cargo linkage.
    const ops_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/ops.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The first-party @rewind/* package sources the `seed-packages` verb POSTs
    // to the registry at genesis (leaves-first). Embedded so the seed is
    // self-contained (no rewind-apps checkout needed) and the exact bytes are
    // the frozen package identity. Same source files driver_smoke embeds.
    inline for (.{
        .{ "pkg_jwt", "src/js/packages/@rewind/jwt/index.mjs" },
        .{ "pkg_oauth", "src/js/packages/@rewind/oauth/index.mjs" },
        .{ "pkg_cron", "src/js/packages/@rewind/cron/index.mjs" },
        .{ "pkg_sessions", "src/js/packages/@rewind/sessions/index.mjs" },
        .{ "pkg_retry", "src/js/packages/@rewind/retry/index.mjs" },
        .{ "pkg_activitypub", "src/js/packages/@rewind/activitypub/index.mjs" },
        .{ "pkg_email", "src/js/packages/@rewind/email/index.mjs" },
        .{ "pkg_users", "src/js/packages/@rewind/users/index.mjs" },
        .{ "pkg_oidc", "src/js/packages/@rewind/oidc/index.mjs" },
        .{ "pkg_schedule", "src/js/packages/@rewind/schedule/index.mjs" },
        .{ "pkg_segments", "src/js/packages/@rewind/segments/index.mjs" },
        .{ "pkg_browser", "src/js/packages/@rewind/browser/index.mjs" },
        .{ "pkg_stripe", "src/js/packages/@rewind/stripe/index.mjs" },
        .{ "pkg_export", "src/js/packages/@rewind/export/index.mjs" },
    }) |e| ops_mod.addAnonymousImport(e[0], .{ .root_source_file = b.path(e[1]) });
    // `storage-namespace` signs S3 requests itself (the CLI links no libcurl).
    // Both files are pure-std halves of rove-blob, imported rather than
    // restated so the CLI and the platform cannot drift on the marker key,
    // the segment rules, or the signature.
    ops_mod.addImport("wire-headers", wire_headers_mod);
    ops_mod.addAnonymousImport("sigv4", .{ .root_source_file = b.path("src/blob/sigv4.zig") });
    ops_mod.addAnonymousImport("blob-namespace", .{ .root_source_file = b.path("src/blob/namespace.zig") });
    const ops_exe = b.addExecutable(.{ .name = "rewind-ops", .root_module = ops_mod });
    const ops_step = b.step("rewind-ops", "Build the rewind-ops operator CLI");
    ops_step.dependOn(&b.addInstallArtifact(ops_exe, .{}).step);

    const ops_tests = b.addTest(.{ .root_module = ops_mod });
    const ops_test_step = b.step("rewind-ops-test", "Run the rewind-ops CLI unit tests");
    ops_test_step.dependOn(&b.addRunArtifact(ops_tests).step);
    test_step.dependOn(&b.addRunArtifact(ops_tests).step);

    // ── rove-replay: the native replay driver (Phase 2 §2c). Decodes a pulled
    // fixture, drives arenajs's native replay engine over the recorded tape,
    // and emits the LLM-JSON artifact. Links `arenajs-replay` (so anything
    // importing it links the JS engine — see `rewind` below). Self-contained:
    // no rove modules, no Node/WASM/network at replay time.
    const replay_mod = b.createModule(.{
        .root_source_file = b.path("src/replay/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkReplayEngine(replay_mod, arenajs_dep);
    // The offline `_system.*` recorder layer, embedded into the JS module
    // so `globals.zig`'s record-version drift test can read the numbers the
    // sim and the browser arena declare. `@embedFile` cannot cross a package
    // boundary, hence the named import (same reason as the globals above).
    js_mod.addAnonymousImport("system_recorders", .{ .root_source_file = b.path("src/replay/js/system_recorders.js") });

    addSimGlobalEmbeds(b, replay_mod);
    replay_mod.addImport("package_resolver", pkgres_mod);
    // The prelude generates its reserved-prefix guard from this list (rove#499).
    replay_mod.addImport("rove-reserved", reserved_mod);
    replay_mod.addImport("rove-guards", guards_mod);
    replay_mod.addImport("rove-binding", binding_mod);
    replay_mod.addImport("interaction-digest", idigest_mod);
    replay_mod.addImport("rove-files", files_mod); // world.zig: manifest package types
    // The first-party @rewind/* package sources, so `rewind test` auto-resolves
    // an app's declared @rewind deps offline (src/replay/first_party.zig) without
    // per-scenario inlining. Same sources driver_smoke + rewind-ops embed.
    inline for (.{
        "jwt", "oauth", "cron", "sessions", "retry", "activitypub",
        "email", "users", "oidc", "schedule", "segments", "browser",
        "stripe", "export",
    }) |nm| replay_mod.addAnonymousImport("pkg_" ++ nm, .{
        .root_source_file = b.path("src/js/packages/@rewind/" ++ nm ++ "/index.mjs"),
    });

    const replay_tests = b.addTest(.{ .root_module = replay_mod });
    const replay_test_step = b.step("replay-test", "Run the native replay driver unit tests");
    replay_test_step.dependOn(&b.addRunArtifact(replay_tests).step);
    test_step.dependOn(&b.addRunArtifact(replay_tests).step);

    // replay-driver-smoke: full decode→host→epilogue→extract on the real
    // engine, in-memory fixture, no cluster (§2c verification).
    const driver_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/replay/driver_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkReplayEngine(driver_smoke_mod, arenajs_dep);
    addSimGlobalEmbeds(b, driver_smoke_mod);
    driver_smoke_mod.addImport("package_resolver", pkgres_mod);
    driver_smoke_mod.addImport("rove-binding", binding_mod);
    driver_smoke_mod.addImport("interaction-digest", idigest_mod);
    driver_smoke_mod.addImport("rove-files", files_mod); // world.zig: manifest package types
    // epilogue.zig generates `__CAPS` from rove-reserved's CAPABILITY_NAMES
    // (the one list every engine's activation object is built from), so the
    // driver smoke needs the module its own epilogue reads.
    driver_smoke_mod.addImport("rove-reserved", reserved_mod);
    // The lifted first-party @rewind/* package sources (P-Lift, rove#123),
    // embedded so the driver smoke can prove the real libs resolve + run
    // offline as packages — incl. the oauth→jwt intra-set dependency graph.
    driver_smoke_mod.addAnonymousImport("pkg_jwt", .{ .root_source_file = b.path("src/js/packages/@rewind/jwt/index.mjs") });
    driver_smoke_mod.addAnonymousImport("pkg_oauth", .{ .root_source_file = b.path("src/js/packages/@rewind/oauth/index.mjs") });
    driver_smoke_mod.addAnonymousImport("pkg_cron", .{ .root_source_file = b.path("src/js/packages/@rewind/cron/index.mjs") });
    driver_smoke_mod.addAnonymousImport("pkg_sessions", .{ .root_source_file = b.path("src/js/packages/@rewind/sessions/index.mjs") });
    driver_smoke_mod.addAnonymousImport("pkg_retry", .{ .root_source_file = b.path("src/js/packages/@rewind/retry/index.mjs") });
    driver_smoke_mod.addAnonymousImport("pkg_activitypub", .{ .root_source_file = b.path("src/js/packages/@rewind/activitypub/index.mjs") });
    driver_smoke_mod.addAnonymousImport("pkg_email", .{ .root_source_file = b.path("src/js/packages/@rewind/email/index.mjs") });
    driver_smoke_mod.addAnonymousImport("pkg_users", .{ .root_source_file = b.path("src/js/packages/@rewind/users/index.mjs") });
    driver_smoke_mod.addAnonymousImport("pkg_oidc", .{ .root_source_file = b.path("src/js/packages/@rewind/oidc/index.mjs") });
    driver_smoke_mod.addAnonymousImport("pkg_schedule", .{ .root_source_file = b.path("src/js/packages/@rewind/schedule/index.mjs") });
    driver_smoke_mod.addAnonymousImport("pkg_segments", .{ .root_source_file = b.path("src/js/packages/@rewind/segments/index.mjs") });
    driver_smoke_mod.addAnonymousImport("pkg_browser", .{ .root_source_file = b.path("src/js/packages/@rewind/browser/index.mjs") });
    driver_smoke_mod.addAnonymousImport("pkg_stripe", .{ .root_source_file = b.path("src/js/packages/@rewind/stripe/index.mjs") });
    driver_smoke_mod.addAnonymousImport("pkg_export", .{ .root_source_file = b.path("src/js/packages/@rewind/export/index.mjs") });
    const driver_smoke_exe = b.addExecutable(.{ .name = "replay-driver-smoke", .root_module = driver_smoke_mod });
    const driver_smoke_step = b.step("replay-driver-smoke", "Native replay driver end-to-end smoke (Phase 2 §2c)");
    driver_smoke_step.dependOn(&b.addRunArtifact(driver_smoke_exe).step);
    // A second process: the non-inbound (fetch_chunk) replay — ctx + flattened
    // fetch result from the trigger_payload + fetch_responses channels.
    const driver_smoke_fetch = b.addRunArtifact(driver_smoke_exe);
    driver_smoke_fetch.addArg("fetch");
    driver_smoke_step.dependOn(&driver_smoke_fetch.step);
    // `multi`: several worlds in ONE process — proves runWorld is multi-shot over
    // the resettable arena runtime (the `simulate()` primitive), with per-run
    // isolation (run 3 must not leak run 1's KV).
    const driver_smoke_multi = b.addRunArtifact(driver_smoke_exe);
    driver_smoke_multi.addArg("multi");
    driver_smoke_step.dependOn(&driver_smoke_multi.step);
    // `arena-gc`: the allocator-regime round-trip — a world stamped
    // arena_gc replays under GC (succeeds where bump OOMs), the
    // unstamped twin OOMs under bump, and a following bump world proves
    // the mode doesn't leak across runs.
    const driver_smoke_gc = b.addRunArtifact(driver_smoke_exe);
    driver_smoke_gc.addArg("arena-gc");
    driver_smoke_step.dependOn(&driver_smoke_gc.step);
    // `packages`: multi-version `@scope/pkg` encapsulation resolves offline
    // (the app sees jwt19, the encapsulated oidc sees its own jwt14) — #50.
    const driver_smoke_pkgs = b.addRunArtifact(driver_smoke_exe);
    driver_smoke_pkgs.addArg("packages");
    driver_smoke_step.dependOn(&driver_smoke_pkgs.step);
    // `oauthjwt`: the real lifted @rewind/oauth package imports the real lifted
    // @rewind/jwt package (a nested/private dep) and calls into it — proving
    // the first intra-set package dependency graph resolves + runs offline
    // (P-Lift, rove#123).
    const driver_smoke_oauth = b.addRunArtifact(driver_smoke_exe);
    driver_smoke_oauth.addArg("oauthjwt");
    driver_smoke_step.dependOn(&driver_smoke_oauth.step);
    // `cronpkg`: the lifted @rewind/cron package — an IIFE-wrapped ambient lib
    // lifted to a module (the IIFE wrapper drops, module scope takes over) —
    // resolves + runs offline, its static helpers composing over ambient `time`
    // (P-Lift, rove#123).
    const driver_smoke_cron = b.addRunArtifact(driver_smoke_exe);
    driver_smoke_cron.addArg("cronpkg");
    driver_smoke_step.dependOn(&driver_smoke_cron.step);
    // `leafpkgs`: the object-literal leaf libs (sessions/retry/activitypub)
    // lifted to packages resolve + load offline (P-Lift, rove#123).
    const driver_smoke_leaf = b.addRunArtifact(driver_smoke_exe);
    driver_smoke_leaf.addArg("leafpkgs");
    driver_smoke_step.dependOn(&driver_smoke_leaf.step);
    // `morepkgs`: the rest of the lifted libs — users (leaf), oidc (→ nested
    // @rewind/jwt), and the IIFE-wrapped schedule/segments/browser — all
    // resolve + load offline (P-Lift, rove#123).
    const driver_smoke_more = b.addRunArtifact(driver_smoke_exe);
    driver_smoke_more.addArg("morepkgs");
    driver_smoke_step.dependOn(&driver_smoke_more.step);
    // `poison`: an off-tape read on a captured world poisons the run —
    // survives try/catch, brakes via the uncatchable interrupt, reports
    // post-run (the divergence model of the engine-parity epic).
    const driver_smoke_poison = b.addRunArtifact(driver_smoke_exe);
    driver_smoke_poison.addArg("poison");
    driver_smoke_step.dependOn(&driver_smoke_poison.step);
    // `refusals`: outcome-replay — a captured world throws the tape's
    // recorded refusals and re-decides nothing (#516).
    const driver_smoke_refusals = b.addRunArtifact(driver_smoke_exe);
    driver_smoke_refusals.addArg("refusals");
    driver_smoke_step.dependOn(&driver_smoke_refusals.step);
    // `elided`: the kv budget's read side (rove#430 §3) — a record whose read
    // the budget dropped REFUSES the run instead of answering `not_found`.
    const driver_smoke_elided = b.addRunArtifact(driver_smoke_exe);
    driver_smoke_elided.addArg("elided");
    driver_smoke_step.dependOn(&driver_smoke_elided.step);
    // This ONE scenario hangs off the gate. The rest of `replay-driver-smoke`
    // cannot yet: its `cronpkg` scenario is red on main (`@rewind/schedule`
    // does not resolve in the fixture sources), which is itself the cost of a
    // test artifact no gate runs — rove#647 fixes that and wires the whole
    // step in. Wiring this one in now keeps the budget's refusal from rotting
    // the same way.
    test_step.dependOn(&driver_smoke_elided.step);

    // ── rewind: the OIDC customer CLI (docs/architecture/cli-and-deploy.md §6, Track 3).
    // The customer-shippable half of the split — carries an OIDC session
    // (device-grant login → /v1/cli/exchange), never a platform secret.
    // Shares src/cli/common.zig with rewind-ops; std-only transport (TLS curl +
    // cookie jar) for the deploy/log verbs. Phase 2 adds `logs`/`pull`/`replay`,
    // which link the native replay engine via `rove-replay` — so `rewind` now
    // links the JS engine (heavier than the std-only deploy build; acceptable
    // for one unified CLI, plan §2a). No system libs beyond the engine's own.
    const cli_version = b.option([]const u8, "version", "version string baked into `rewind --version` (CI passes the release tag; defaults to \"dev\")") orelse "dev";
    const cli_opts = b.addOptions();
    cli_opts.addOption([]const u8, "version", cli_version);
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/rewind.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("rove-replay", replay_mod);
    cli_mod.addImport("wire-headers", wire_headers_mod);
    cli_mod.addImport("build_options", cli_opts.createModule());
    linkReplayEngine(cli_mod, arenajs_dep);
    const cli_exe = b.addExecutable(.{ .name = "rewind", .root_module = cli_mod });

    // ── The shipped binaries COMPILE as part of `test` ──────────────────
    //
    // A test build never analyses `main`: Zig analyses function bodies
    // lazily, and nothing in a test references it. So a type error in any
    // `main.zig` passes both `zig build test` and that binary's own
    // `*-test` step, and only the binary build catches it — which is how a
    // broken `rewind-cp` reached a green test run.
    //
    // Depend on the COMPILE step, not the install artifact: this gates the
    // build without writing into zig-out.
    test_step.dependOn(&rewind_exe.step);
    test_step.dependOn(&front_exe.step);
    test_step.dependOn(&cp_exe.step);
    test_step.dependOn(&ls_standalone.step);
    test_step.dependOn(&ops_exe.step);
    test_step.dependOn(&cli_exe.step);

    // Bare `zig build` gets the same gate. The default install step builds
    // examples and benches (their unconditional `installArtifact`s) while —
    // without these lines — skipping every shipped binary, so it read as "the
    // build passes" while proving nothing about the product. The rule "only
    // `zig build test` is the gate" lived in heads, not the build graph
    // (docs/defect-patterns.md class 10). Compile steps only, same as above:
    // installing stays behind the named steps `scripts/ops/build.sh` drives.
    b.getInstallStep().dependOn(&rewind_exe.step);
    b.getInstallStep().dependOn(&front_exe.step);
    b.getInstallStep().dependOn(&cp_exe.step);
    b.getInstallStep().dependOn(&ls_standalone.step);
    b.getInstallStep().dependOn(&ops_exe.step);
    b.getInstallStep().dependOn(&cli_exe.step);
    const cli_step = b.step("rewind", "Build the rewind customer CLI");
    cli_step.dependOn(&b.addInstallArtifact(cli_exe, .{}).step);

    // CLI unit tests (`src/cli/*.zig` — e.g. the P-CLI package resolver in
    // packages.zig). Folded into the aggregate `test` step; also runnable in
    // isolation via `zig build cli-test`.
    const cli_tests = b.addTest(.{ .root_module = cli_mod });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_step.dependOn(&run_cli_tests.step);
    const cli_test_step = b.step("cli-test", "Run the rewind CLI unit tests");
    cli_test_step.dependOn(&run_cli_tests.step);

    // ── rewind-test-smoke: drive `rewind test` end-to-end (offline, no cluster)
    // over the checkout fixture (proves the two-reactor saga runner) PLUS the
    // smoke cross-checks — the SAME first-party handlers the `*_smoke_v2.py`
    // suites deploy, run offline and asserting the same results the smokes assert
    // through the real stack. Agreement proves each fold faithful against a real
    // handler (writing on_fetch's surfaced the streaming-fetch gap). A failing
    // assertion exits non-zero and fails the build.
    // ── the interaction digest's cross-language gate ──
    //
    // The digest has two implementations (interaction_digest.zig and its JS
    // mirror), and a silent disagreement between them would surface as an
    // unexplained "replay diverged" on a real record — the hardest kind of
    // bug to attribute. Neither side is the reference: both assert against
    // `src/replay/testdata/digest_vectors.json`, the Zig half in its own unit
    // tests and the JS half here. A change to one that the other does not
    // mirror fails the build.
    const digest_vectors = b.addSystemCommand(&.{"node"});
    digest_vectors.addFileArg(b.path("src/replay/js/digest_vectors_test.mjs"));
    // Declared inputs, so editing either the mirror or the vectors re-runs the
    // check. Without them the step is cached on its argv alone and a broken
    // mirror silently "passes" — which is how a gate rots into decoration.
    digest_vectors.addFileInput(b.path("src/tape/js_interaction_digest.js"));
    digest_vectors.addFileInput(b.path("src/tape/testdata/digest_vectors.json"));
    digest_vectors.expectExitCode(0);
    const digest_step = b.step("replay-digest-vectors", "Check the JS interaction-digest mirror against the shared vectors");
    digest_step.dependOn(&digest_vectors.step);
    test_step.dependOn(&digest_vectors.step);

    const smoke_step = b.step("rewind-test-smoke", "Run `rewind test` over the fixtures + smoke cross-checks (saga runner e2e)");
    const test_dirs = [_][]const u8{
        "src/replay/testdata/checkout", // the saga-runner fixture
        "examples/loop46-demo-tenants/acme", // ↔ on_fetch / on_kv / on_timer smokes
        "examples/loop46-demo-tenants/wsworker", // ↔ ws_worker_smoke_v2
        "examples/loop46-demo-tenants/wsfetch", // ↔ ws_fetch_smoke_v2 (WS+fetch)
        "examples/loop46-demo-tenants/wswake", // ↔ ws_wake_smoke_v2 (WS+wake)
        "src/replay/testdata/authsurface", // compute globals (crypto/base64url/jwt/oidc/sessions) in the sim base
        "src/replay/testdata/middleware", // real _middlewares/before + request.session injection
        "src/replay/testdata/middlewarejs", // a .js-spelled _middlewares is INERT — .mjs is the only deployable handler source
        "src/replay/testdata/platformsurface", // http/platform/browser globals (effect recorders)
        "src/replay/testdata/oidcverify", // RS256 crypto.verifyRsa + jwt.verify offline
        "src/replay/testdata/oidcsession", // @rewind/oidc's record reader: an UNSTAMPED `_rp/sess/` row reads as v1
        "src/replay/testdata/cpubudget", // a runaway while(true) handler → bounded 504 "handler exceeded cpu budget" (interrupt handler)
        "src/replay/testdata/oidcprovider", // OIDC provider mode: oidcGenerateKey + oidcSign (RS256) → id_token mint + verify round-trip offline
        "src/replay/testdata/ecdsaverify", // ES256 crypto.verifyEcdsa (P-256) + jwt.verify offline
        "src/replay/testdata/effects", // real webhook/schedule shims → primitive effect log
        "src/replay/testdata/email", // email.send → webhook _send/owed marker (Resend)
        "src/replay/testdata/blobrecipe", // blob put/write/seal/url — streaming sha256 offline
        "src/replay/testdata/utf8body", // multibyte UTF-8 request body round-trips (json/text/bytes)
        "src/replay/testdata/utf8encode", // TextEncoder/base64url/hash over non-ASCII ↔ utf8_encode_smoke_v2
        "src/replay/testdata/platformkv", // platform.scope(id)/root per-store kv isolation
        "src/replay/testdata/roottoken", // platform.auth.checkRootToken validates the configured token
        "src/replay/testdata/platformadmin", // platform.* admin-only gating (fail-closed)
        "src/replay/testdata/upload", // headers-first onHeaders + blob.receive → onStored continuation
        "src/replay/testdata/deploydoor", // result-in-ctx bound doors: platform.compile → onFileStaged / stampManifest → onCut
        "src/replay/testdata/concurrent", // whenConcurrent: cross-order fetch interleavings + invariant
        "src/replay/testdata/xmodule", // cross-module fetch continuation + scenario.fetchResult
        "src/replay/testdata/nexttarget", // cross-module next(target, ctx) parks the target: timer/kv/fetch/disconnect resumes re-enter it
        "src/replay/testdata/getreplay", // request.tenant/sagaId identity → browser.getReplay both branches
        "src/replay/testdata/bodyless", // authored bodyless inbound reads empty (not a divergence throw)
        "src/replay/testdata/responsevetting", // emit-side response vetting: header/cookie sanitize, status clamp, content-type rule, binary body, stream-prepend
        "src/replay/testdata/requestsurface", // pinned identity, ip channels, activation bag, tag validation, retired body/on.* gone
        "src/replay/testdata/headerhygiene", // authored headers lowercase + pseudo/IP/reserved dropped with a warn
        "src/replay/testdata/pathquery", // request.path excludes ?query; request.query carries it
        "src/replay/testdata/consolefmt", // console formatting: JSON-stringified non-strings + level-prefix lines, sim text ≡ prod line
        "src/replay/testdata/wsmessage", // a WS frame reads back as request.text/.bytes (browser.message)
        "src/replay/testdata/wsfetchloop", // continue a WS conversation past a fetch resume (agent-loop shape)
        "src/replay/testdata/fetchctx", // fetch-resume ctx override: fetch's own ctx if any, else the chain's next()
        "src/replay/testdata/errorsemantics", // throw→500+rollback, pending-promise→200 "{}", missing-export 404/no-op/fallback, bad middleware
        "src/replay/testdata/fetchrecorder", // fetch option bag + unique ftch_ ids + fetchId/fetchesPending threading + terminal-only status/ok + stream gating
        "src/replay/testdata/arenachurn", // >arena cumulative alloc / tiny peak completes under the GC arena
        "src/replay/testdata/kvguardrails", // kv.set/delete type + reserved-prefix + size guards, kv.prefix 100/1000 paging
        "src/replay/testdata/droppedeffects", // connection-scoped effects on terminal/connectionless activations tagged dropped + warned; durable verbs survive
        "src/replay/testdata/argvalidation", // prod's synchronous effect-argument throw table fires offline with the same error types/messages
        "src/replay/testdata/ssrfgate", // resolving a success outcome for a prod-blocked fetch URL (SSRF/plain-http/localhost) fails loud; status 0 stays authorable
        "src/replay/testdata/emailbudget", // scenario({emailBudget}) arms the outbound rate limiter offline — N+1-th send throws code:"rate_limited"; unset stays unmetered
        "src/replay/testdata/pkgimport", // scenario({packages, app_imports}) resolves a first-party @rewind/* package offline through the shared PackageResolver (P-Lift enabler)
        "src/replay/testdata/jwtpkg", // the lifted @rewind/jwt package (globalThis.jwt → ES exports) resolves + runs offline through a consumer (P-Lift lib #1)
        "src/replay/testdata/emailpkg", // the lifted @rewind/email package composes over the ambient webhook primitive offline (P-Lift lib #2)
        "src/replay/testdata/instancefold", // instances.create's exists marker folds across resumes — create-then-scope-in-continuation resolves
        "src/replay/testdata/timerwakes", // held wake-fold: multiple after.ms → last-armed slot wins + due-time gate, per-arm {on} routing, after.kv prefix containment
        "src/replay/testdata/concurrentctx", // whenConcurrent threads the evolving next({ctx}) between legs — a no-ctx leg reads the prior leg's re-held ctx
        "src/replay/testdata/wslifecycle", // WS lifecycle: terminal/errored frame closes the socket (no further frame), pre-frame close runs nothing
        "src/replay/testdata/timezone", // local-time Date methods run in UTC (TZ pinned), matching prod regardless of host TZ
        "src/replay/testdata/importclamp", // over-popped ../ imports clamp to the app root, not escape source_dir (prod resolveSpecifier)
        "src/replay/testdata/worldschema", // scenario() authors a binary inbound body (request.bytes) + an export override
        "src/replay/testdata/snapshots", // toMatchSnapshot: call-site auto-names + stale-sidecar prune(--update)/warn
        "src/replay/testdata/inboundchunks", // streaming inbound body: per-chunk onChunk folds, ctx threads chunk-to-chunk, request.done ends
        "src/replay/testdata/shamidstate", // streaming-sha256 midstate: decode+emit the worker s2: token (prod-compatible), still read legacy js2:
        "src/replay/testdata/subscription", // http.subscribe recorder bag + detached onSubscription (subscription_fire) activation
        "src/replay/testdata/kvtriggers", // _triggers/<prefix>/index before/after chains run offline: mutate value / reject as trigger_rejected
        "src/replay/testdata/manifestpkg", // `rewind test` auto-resolves an app's manifest.json @rewind/* deps offline (P4a enabler) — direct jwt/oidc + transitive oidc→jwt, no inline scenario packages
        "src/replay/testdata/retrypkg", // @rewind/retry wraps webhook.send (maxAttempts→1 + ctx._retry chain state) + shouldRetry/ctx result logic — the package-model replacement for the retired ambient-retry dispatcher tests
    };
    for (test_dirs) |dir| {
        const run = b.addRunArtifact(cli_exe);
        run.addArg("test");
        run.addDirectoryArg(b.path(dir));
        // The timezone fixture asserts handler time is UTC wherever the HOST
        // sits, so run it somewhere that isn't UTC — on a UTC machine (every
        // CI box) its assertions hold whether or not the pin exists, and a
        // regression ships green.
        if (std.mem.endsWith(u8, dir, "/timezone"))
            run.setEnvironmentVariable("TZ", "Asia/Tokyo");
        run.expectExitCode(0);
        smoke_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }

    // ── the behavior conformance suite — the CHEAP LANE ──
    //
    // One corpus of behavior cases, run on every engine that executes customer
    // handlers, failing when two of them disagree. The corpus is the spec: the
    // engines' agreement is the assertion, not a hand-copied expected value on
    // each side (the shape `src/replay/testdata/utf8encode` and
    // `scripts/smoke/utf8_encode_smoke_v2.py` are in today — one literal,
    // duplicated, keeping itself in sync by hand).
    //
    // This lane runs the engines that need no cluster: the offline sim, and the
    // WASM replay arena once its adapter exists. The cluster lane (a live
    // V2Cluster, S3 credentials, port slots) cannot hang off `test` and gets a
    // scheduled runner instead.
    //
    // The selftest runs FIRST and is not optional. Until a second adapter
    // lands the corpus compares one engine against itself — that is, nothing —
    // so the comparison, the allowlist, and the stale-entry rule would all be
    // unexercised. The selftest drives them with synthetic outcomes so the gate
    // is provably able to go red before the engine that would turn it red
    // exists.
    // The browser replay arena's prelude is GENERATED from the engine's own
    // shim sources into rewind-apps (`scripts/ops/gen_replay_prelude.py`).
    // Nothing downstream notices when a shim moves and the generated file
    // does not: the browser engine simply runs older shim code than the
    // worker, silently, which is the drift the shared prelude exists to
    // prevent. It has happened twice.
    //
    // The artifact lives in another repo, so this gate checks the half that
    // is local — that the shim sources still match the digest recorded
    // beside the generator. Changing a shim turns this red at the moment of
    // the change, naming the two commands that propagate it. rewind-apps'
    // own CI checks the other half (its committed prelude vs the rove commit
    // it pins).
    const prelude_fresh = b.addSystemCommand(&.{"python3"});
    prelude_fresh.addFileArg(b.path("scripts/ops/gen_replay_prelude.py"));
    prelude_fresh.addArg("--verify");
    // Always run. Declaring inputs would mean mirroring the generator's
    // source list here, and a shim added there but not here would leave the
    // gate cached-green on the very change it exists to catch. Hashing
    // ~170 KB is cheaper than that failure.
    prelude_fresh.has_side_effects = true;
    prelude_fresh.expectExitCode(0);

    // The docs site's contract pages (`handler-contract.html`,
    // `effect-algebra.html`) and API reference (`reference.html`) are
    // GENERATED into rewind-apps — the first two from `docs/handler-shape.md`
    // + `docs/effect-algebra.md`, the third from the shim JSDoc. The publish
    // driver runs the generators, so a stale mirror is INVISIBLE: the site
    // gets correct HTML from the publish run while the committed copy rots,
    // and the drift surfaces only as a customer reading a contract the engine
    // does not implement. It reached prod that way once — the mirrors were
    // missing the per-activation kv write budget and described retention as
    // deletion, which it is not.
    //
    // Same split as the prelude gate above: the artifact is cross-repo, so
    // this checks the half that is local — that the rove sources still match
    // the digest recorded beside each generator. Always run, for the reason
    // given above: declaring inputs would mirror each generator's source list
    // here, and a doc or shim added there but not here would leave the gate
    // cached-green on the very change it exists to catch.
    // The received-not-ambient ratchet (tracker #753,
    // docs/architecture/package-isolation.md). Counts customer-shaped JS
    // that still reaches a capability as an ambient global; the number may
    // only go DOWN. The migration is a dual-support window across two
    // repos and three engines, and its known failure mode is that the
    // window never closes — so the remaining tail is a number in the gate
    // rather than a vibe. Always run: the corpus it scans is data, not a
    // declared input, and a file added but not declared here would leave
    // this cached-green on the very change it exists to catch.
    const ambient_ratchet = b.addSystemCommand(&.{"python3"});
    ambient_ratchet.addFileArg(b.path("scripts/ops/ambient_use_lint.py"));
    ambient_ratchet.has_side_effects = true;
    ambient_ratchet.expectExitCode(0);

    // ── the standalone lints, on the gate ──
    //
    // These were "run by hand or pre-commit", which meant never: when they
    // were finally run, `globals_lint` had been red since the replay prelude
    // mirror landed (it scans `web/`, and the GENERATED mirror of the engine's
    // own shims lives there), and `test_reachability_lint` was reporting 3
    // tests that had never compiled. Both work; nothing was invoking them.
    //
    // A lint nobody runs is a rule nobody keeps — the same failure the lints
    // exist to prevent, one level up. Always run: each scans the tree as data
    // rather than as declared inputs, so declaring inputs here would leave
    // them cached-green on exactly the change they exist to catch.
    const standalone_lints = [_][]const u8{
        "scripts/ops/create_init_lint.py",
        "scripts/ops/doc_pointer_lint.py",
        "scripts/ops/globals_lint.py",
        "scripts/ops/reserved_header_lint.py",
        "scripts/ops/spdx_lint.py",
        "scripts/ops/tenant_prefix_lint.py",
        "scripts/ops/test_reachability_lint.py",
    };
    for (standalone_lints) |lint_path| {
        const run_lint = b.addSystemCommand(&.{"python3"});
        run_lint.addFileArg(b.path(lint_path));
        run_lint.has_side_effects = true;
        run_lint.expectExitCode(0);
        test_step.dependOn(&run_lint.step);
    }

    const docs_contract_fresh = b.addSystemCommand(&.{"python3"});
    docs_contract_fresh.addFileArg(b.path("scripts/ops/gen_docs_contract.py"));
    docs_contract_fresh.addArg("--verify");
    docs_contract_fresh.has_side_effects = true;
    docs_contract_fresh.expectExitCode(0);

    const docs_reference_fresh = b.addSystemCommand(&.{"python3"});
    docs_reference_fresh.addFileArg(b.path("scripts/ops/gen_docs_reference.py"));
    docs_reference_fresh.addArg("--verify");
    docs_reference_fresh.has_side_effects = true;
    docs_reference_fresh.expectExitCode(0);

    // The guard-parity lint is GONE, on purpose: every engine — the worker,
    // the sim/replay driver, and the browser arena (via the in-tree wasm) —
    // now executes the ONE compiled implementation of the handler-facing
    // rules (`rove-binding` + `rove-guards`), so there is no second surface
    // whose PRESENCE could lag. What remains checkable is behaviour, and
    // that is the conformance corpus' job.

    const conf_selftest = b.addSystemCommand(&.{"python3"});
    conf_selftest.addFileArg(b.path("scripts/conformance/selftest.py"));
    conf_selftest.addFileInput(b.path("scripts/conformance/outcome.py"));
    conf_selftest.addFileInput(b.path("scripts/conformance/allowlist.py"));
    conf_selftest.expectExitCode(0);

    const conf_run = b.addSystemCommand(&.{"python3"});
    conf_run.addFileArg(b.path("scripts/conformance/run.py"));
    conf_run.addArg("--engines");
    conf_run.addArg("sim,replay");
    // Hand the runner the CLI artifact this build just produced, rather than
    // letting it discover one on disk: a discovered binary can be stale, and a
    // gate quietly testing yesterday's engine is worse than no gate.
    conf_run.addArg("--rewind-bin");
    conf_run.addArtifactArg(cli_exe);
    conf_run.addFileInput(b.path("scripts/conformance/adapters.py"));
    conf_run.addFileInput(b.path("scripts/conformance/outcome.py"));
    conf_run.addFileInput(b.path("scripts/conformance/allowlist.py"));
    conf_run.addArg("--cases-dir");
    conf_run.addDirectoryArg(b.path("scripts/conformance/cases"));
    conf_run.expectExitCode(0);
    // Always re-run. A source `addDirectoryArg` is hashed by PATH, not by
    // contents, and the corpus reaches further still — a case names an app tree
    // under `src/replay/testdata/`, so a handler edit changes what the step
    // asserts without touching any declared input. Both were verified to leave
    // the step `cached` while the runner itself failed, which is the worst
    // possible state for a gate: green because it never ran. The corpus is
    // sub-second; correctness is worth more than the cache hit.
    conf_run.has_side_effects = true;
    conf_run.step.dependOn(&conf_selftest.step);

    const conf_step = b.step("conformance", "Behavior conformance suite — one corpus, every engine (cheap lane)");
    conf_step.dependOn(&conf_run.step);
    test_step.dependOn(&conf_run.step);
    test_step.dependOn(&prelude_fresh.step);
    test_step.dependOn(&docs_contract_fresh.step);
    test_step.dependOn(&ambient_ratchet.step);
    test_step.dependOn(&docs_reference_fresh.step);
}
