//! `js-worker` — the production rove-js worker binary.
//!
//! Shared-nothing multi-worker model (promoted from the `dual-worker`
//! spike, 2026-04-14). A configurable number of worker threads each
//! own their own `Registry` / `Io` / `H2` / `Tenant` / `Dispatcher`,
//! all bound to the same HTTP/2 port via `SO_REUSEPORT`. The kernel
//! hashes incoming connections across workers. **Any worker handles
//! any tenant** — there is no tenant pinning.
//!
//! Shared between workers (all thread-safe):
//!   - the single `RaftNode` (proposes go through its MPSC queue;
//!     committedSeq/faultedSeq are atomics)
//!   - the single raft-owned `ApplyCtx` (only the raft thread touches
//!     its cached stores; workers never do)
//!   - the files-server + log-server subsystem threads
//!
//! Per-worker (thread-local):
//!   - rove `Registry`, rove-io `Io`, rove-h2 `H2`
//!   - per-worker `Tenant` with its own `__root__.db` sqlite connection
//!   - per-tenant `KvStore` + `LogStore` (every worker opens its own
//!     — NOMUTEX sqlite connections cannot be shared across threads)
//!   - qjs `Dispatcher` (its own arena + snapshot)
//!   - penalty box, proxy state, raft-pending collection
//!
//! ## Data layout
//!
//!   {data_dir}/
//!     __root__.db                  tenant metadata (domain → instance)
//!     raft.log.db                  shared raft log (node-scoped)
//!     acme/
//!       app.db                     acme's handler state
//!       files.db                    acme's code index (deployments)
//!       file-blobs/                acme's source + bytecode blobs
//!       log.db                     acme's request log index
//!       log-blobs/                 acme's request log blobs
//!     globex/
//!       ...
//!     penalty/
//!       ...
//!
//! acme is a hit counter; globex echoes the path; penalty is an
//! intentional `while(true) {}` that exercises the CPU-budget
//! interrupt + penalty box.
//!
//! ## Shutdown
//!
//! SIGINT/SIGTERM flip an atomic stop flag. Workers check it on every
//! poll loop iteration and exit cleanly. `io_uring_enter` returning
//! `error.SignalInterrupt` is tolerated — we just fall through to the
//! flag check. Main thread joins all worker threads before returning.

const std = @import("std");
const rove = @import("rove");
const rjs = @import("rove-js");
const kv = @import("rove-kv");
const blob_mod = @import("rove-blob");
const files_mod = @import("rove-files");
const files_server = @import("rove-files-server");
const log_server = @import("rove-log-server");
const qjs = @import("rove-qjs");
const tenant_mod = @import("rove-tenant");
const h2_mod = @import("rove-h2");

// ── Demo handler sources (all .mjs, named-export RPC contract) ────
//
// Every export is called via `?fn=<name>` (GET) or `POST {fn, args}`.
// Return value is the response body (strings emit as-is; objects are
// `JSON.stringify`'d). Status/headers/cookies live on the `response`
// global.
//
// Each handler here exports `handler()` as its default verb for
// backward-compatible smoke coverage; a few (acme) add extra exports.

const ACME_INDEX =
    \\export function handler() {
    \\    const count = parseInt(kv.get("hits") ?? "0", 10) + 1;
    \\    kv.set("hits", String(count));
    \\    return "acme hit count: " + count + " (path=" + request.path + ")\n";
    \\}
;

/// Second route under acme — proves the filesystem router picks a
/// non-default file based on URL path. `/api?fn=handler` → `api/index.mjs`.
const ACME_API_INDEX =
    \\export function handler() {
    \\    return "acme api: method=" + request.method + " path=" + request.path + "\n";
    \\}
;

/// Third route under acme — multiple exports under one module.
/// `/users?fn=greet&args=["Claude"]` calls `greet("Claude")`.
const ACME_USERS_MJS =
    \\export function greet(name) {
    \\    return "mjs greet: hello " + (name ?? "world") + " (path=" + request.path + ")\n";
    \\}
    \\export async function slow(delay_label) {
    \\    const v = await Promise.resolve("async " + (delay_label ?? request.path));
    \\    response.status = 202;
    \\    return v + "\n";
    \\}
;

const GLOBEX_HANDLER =
    \\export function handler() {
    \\    return "globex: you hit " + request.path + " at " + Date.now() + "\n";
    \\}
;

/// Intentionally runaway — used by scripts/penalty_smoke.sh to prove
/// the interrupt handler + penalty-box pair actually protects the
/// worker from a badly-behaved tenant. Every request hits the 10ms CPU
/// budget and returns 504; after `kill_threshold` (default 3) kills the
/// tenant gets dropped into the penalty box and subsequent requests
/// short-circuit to 503 without ever entering qjs.
const PENALTY_HANDLER =
    \\export function handler() { while (true) {} }
;

/// Read-only KV benchmark tenant. Reads a pre-seeded key on every
/// request and never writes, so requests never propose through raft
/// and never dirty any WAL. The tenant's `app.db` is primed at
/// bootstrap with `greeting = "hello"` so the read is a real hit, not
/// a miss.
const READONLY_HANDLER =
    \\export function handler() {
    \\    return "readonly: " + (kv.get("greeting") ?? "(unset)") + "\n";
    \\}
;

/// Write benchmark handler. Used by the `write0..write7` tenants to
/// measure how the writer-lock ceiling on a single `app.db` scales
/// when the same workload is sharded across independent tenants.
/// Matches HOT_BENCH_HANDLER exactly so cross-tenant sharded runs are
/// directly comparable to single-tenant `hot.test` runs.
const WRITE_BENCH_HANDLER =
    \\export function handler() {
    \\    kv.set("k", "0123456789abcdef0123456789abcdef");
    \\    return "wbench\n";
    \\}
;

/// Random-key write benchmark handler. Each request writes to a unique
/// key (crypto.randomUUID), so there is zero row contention in SQLite.
/// Compare against WRITE_BENCH_HANDLER (which always hits "hits") to
/// see whether B-tree page contention is a bottleneck.
const RANDWRITE_BENCH_HANDLER =
    \\export function handler() {
    \\    const key = crypto.randomUUID();
    \\    kv.set(key, "v");
    \\    return "randwrite: " + key + "\n";
    \\}
;

/// Fixed-payload, fixed-key contention benchmark. Writes a 32-byte
/// value to a single hot key. Pair with SPREAD_BENCH_HANDLER (same
/// payload, 1000-key keyspace) to isolate row-contention cost from
/// B-tree growth and crypto-RNG overhead.
const HOT_BENCH_HANDLER =
    \\export function handler() {
    \\    kv.set("k", "0123456789abcdef0123456789abcdef");
    \\    return "hot\n";
    \\}
;

/// Fair-comparison counterpart to HOT_BENCH_HANDLER. Each request picks
/// one of 1000 keys at random and writes the same 32-byte value. Small
/// bounded keyspace keeps the B-tree at a fixed size after a brief
/// warmup, so the only difference vs HOT is whether concurrent writes
/// land on the same row or different rows.
const SPREAD_BENCH_HANDLER =
    \\export function handler() {
    \\    const i = Math.floor(Math.random() * 1000);
    \\    kv.set("k" + i, "0123456789abcdef0123456789abcdef");
    \\    return "spread\n";
    \\}
;

/// Number of `writeN` benchmark tenants spun up at startup. Each has
/// its own `app.db` and therefore its own SQLite WAL writer lock —
/// concurrent writes to different tenants do NOT serialize against
/// each other. Benching against all of them in parallel shows the
/// system's aggregate write throughput under a realistic multi-tenant
/// shape.
const NUM_WRITE_TENANTS: usize = 8;

const TENANT_IDS = [_][]const u8{
    "__admin__",
    "acme",     "globex",   "penalty",  "readonly",
    "randwrite", "hot",     "spread",
    "write0",   "write1",   "write2",   "write3",
    "write4",   "write5",   "write6",   "write7",
};

/// JS source for the admin handler. Deployed to `__admin__` at
/// bootstrap. Each RPC function is a named export; the UI calls them
/// by name (`?fn=listInstance` or `POST {fn:"listInstance",args:[...]}`).
///
/// Tenant CRUD writes `__root__/instance/*` / `__root__/domain/*`
/// keys, which only make sense when the dispatcher bound `kv` to the
/// root store (i.e. the bare admin domain). The UI hits those RPCs
/// on that host.
///
/// The KV RPCs operate on whatever store the dispatcher selected —
/// root for the bare admin domain, the target tenant's app.db for
/// `{id}.api.loop46.com`. Same handler, rebound scope.
///
/// Status on error flows through the ambient `response` global;
/// non-200 return values use the `{ error }` shape as the body.
const ADMIN_HANDLER_SRC =
    \\function validId(id) {
    \\    return typeof id === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(id);
    \\}
    \\
    \\export function listInstance() {
    \\    const entries = kv.prefix("__root__/instance/", "", 1000);
    \\    return {
    \\        instances: entries.map((e) => ({
    \\            id: e.key.slice("__root__/instance/".length),
    \\        })),
    \\    };
    \\}
    \\
    \\export function getInstance(id) {
    \\    if (!validId(id)) { response.status = 400; return { error: "invalid id" }; }
    \\    const v = kv.get("__root__/instance/" + id);
    \\    if (v === null) { response.status = 404; return { error: "not found" }; }
    \\    return { id: id };
    \\}
    \\
    \\export function createInstance(id) {
    \\    if (!validId(id)) { response.status = 400; return { error: "invalid id" }; }
    \\    kv.set("__root__/instance/" + id, "");
    \\    response.status = 201;
    \\    return { id: id };
    \\}
    \\
    \\export function deleteInstance(id) {
    \\    if (!validId(id)) { response.status = 400; return { error: "invalid id" }; }
    \\    kv.delete("__root__/instance/" + id);
    \\    const doms = kv.prefix("__root__/domain/", "", 1000);
    \\    for (let i = 0; i < doms.length; i++) {
    \\        if (doms[i].value === id) kv.delete(doms[i].key);
    \\    }
    \\    response.status = 204;
    \\    return null;
    \\}
    \\
    \\export function listDomain() {
    \\    const entries = kv.prefix("__root__/domain/", "", 1000);
    \\    return {
    \\        domains: entries.map((e) => ({
    \\            host: e.key.slice("__root__/domain/".length),
    \\            instance_id: e.value,
    \\        })),
    \\    };
    \\}
    \\
    \\export function assignDomain(host, instance_id) {
    \\    if (!host || !instance_id) {
    \\        response.status = 400;
    \\        return { error: "host and instance_id required" };
    \\    }
    \\    const exists = kv.get("__root__/instance/" + instance_id);
    \\    if (exists === null) {
    \\        response.status = 404;
    \\        return { error: "instance not found" };
    \\    }
    \\    kv.set("__root__/domain/" + host, instance_id);
    \\    response.status = 201;
    \\    return { host: host, instance_id: instance_id };
    \\}
    \\
    \\export function listKv(prefix, cursor, limit) {
    \\    const p = prefix || "";
    \\    const c = cursor || "";
    \\    const l = Math.max(1, Math.min(parseInt(limit ?? 100, 10) || 100, 1000));
    \\    const entries = kv.prefix(p, c, l);
    \\    const body = {
    \\        entries: entries.map((e) => ({ key: e.key, value: e.value })),
    \\    };
    \\    if (entries.length === l && entries.length > 0) {
    \\        body.next_cursor = entries[entries.length - 1].key;
    \\    }
    \\    return body;
    \\}
    \\
    \\export function getKv(key) {
    \\    if (!key) {
    \\        response.status = 400;
    \\        return { error: "missing key" };
    \\    }
    \\    const v = kv.get(key);
    \\    if (v === null) {
    \\        response.status = 404;
    \\        return { error: "not found" };
    \\    }
    \\    return v;
    \\}
    \\
    \\export function setKv(key, value) {
    \\    if (!key) {
    \\        response.status = 400;
    \\        return { error: "missing key" };
    \\    }
    \\    if (typeof value !== "string") {
    \\        response.status = 400;
    \\        return { error: "value must be a string" };
    \\    }
    \\    kv.set(key, value);
    \\    return { key: key };
    \\}
    \\
    \\export function deleteKv(key) {
    \\    if (!key) {
    \\        response.status = 400;
    \\        return { error: "missing key" };
    \\    }
    \\    kv.delete(key);
    \\    response.status = 204;
    \\    return null;
    \\}
;

comptime {
    // Keep TENANT_IDS and NUM_WRITE_TENANTS in lockstep so bootstrap
    // and workerMain iterate the same set. 8 = __admin__ + acme +
    // globex + penalty + readonly + randwrite + hot + spread.
    std.debug.assert(TENANT_IDS.len == 8 + NUM_WRITE_TENANTS);
}

const Cli = struct {
    node_id: u32 = 0,
    /// Comma-separated `host:port` list. Position determines node_id.
    peers: []const u8 = "127.0.0.1:40100",
    /// `host:port` this node listens on for raft RPCs. Must match the
    /// peers entry at index `node_id`.
    listen: []const u8 = "127.0.0.1:40100",
    /// HTTP/2 listen address (all workers share this via SO_REUSEPORT).
    http: []const u8 = "127.0.0.1:8082",
    /// Per-node data directory. Each node MUST have a unique dir.
    data_dir: []const u8 = "/tmp/rove-js-data",
    /// If true, wipe the data dir before starting (smoke-test mode).
    fresh: bool = false,
    /// Hex-encoded 256-bit root token. When set, the worker installs
    /// it into the tenant root store at startup; any subsequent
    /// `/_system/*` request must carry this token in an
    /// `Authorization: Bearer <hex>` header.
    bootstrap_root_token: ?[]const u8 = null,
    /// Platform-provided Resend API key. When set, the worker
    /// installs it at `__root__/resend_key` so `email.send` can read
    /// it when building its outbox envelope. Customer handlers never
    /// see the plaintext. Rotate by re-running with a new value.
    bootstrap_resend_key: ?[]const u8 = null,
    /// Number of worker threads. Each owns its own Registry/Io/H2/
    /// Tenant/Dispatcher and binds the same HTTP/2 port via
    /// SO_REUSEPORT. Defaults to the number of online CPUs.
    workers: u16 = 0,
    /// Origin allowed to call `/_system/*` with CORS. When set, the
    /// worker responds to preflight (OPTIONS) requests from this
    /// origin and adds `Access-Control-Allow-*` headers to all
    /// `/_system/*` responses. Required for the browser admin UI in
    /// dev (typically `http://localhost:5173`) and prod (e.g.
    /// `https://admin.example.com`). Unset = no CORS, and the admin
    /// UI must be served same-origin or go through a proxy.
    admin_origin: ?[]const u8 = null,
    /// Base domain for the per-tenant admin API. When set, any
    /// request whose Host matches `{id}.{admin_api_domain}` runs the
    /// `__admin__` tenant's handler with `kv` rebound to `{id}`'s
    /// store (or `__admin__`'s = root store when Host is exactly
    /// `admin_api_domain`). Requires a root bearer token.
    ///
    /// Example: `api.loop46.com`. Then `acme.api.loop46.com/kv` reads
    /// acme's KV; `api.loop46.com/tenant/instance` hits root.
    admin_api_domain: ?[]const u8 = null,
    /// Wildcard customer-app suffix. Enables `{id}.{public_suffix}` →
    /// instance `{id}` resolution without needing `assignDomain` per
    /// tenant. Explicit domain aliases still win. Must NOT overlap with
    /// `admin_api_domain` — admin check runs first, so
    /// `api.loop46.me` as admin and `loop46.me` as public suffix is
    /// fine; same-string collisions route to admin.
    /// Example: `loop46.me`. Then `acme.loop46.me` → instance `acme`.
    public_suffix: ?[]const u8 = null,
    /// TLS certificate path (PEM, full chain). When both this and
    /// `tls_key` are set, the `--http` listener speaks HTTPS (h2 over
    /// TLS) instead of plaintext h2c. Changes to either file on disk
    /// are picked up on a periodic mtime check, so cert renewal by a
    /// sidecar (e.g. scripts/rove-lego-renew.sh) reloads in-process
    /// without a restart.
    tls_cert: ?[]const u8 = null,
    /// TLS private key path (PEM). See `tls_cert`.
    tls_key: ?[]const u8 = null,
    /// Raft proposal linger budget, in microseconds. Hold pending
    /// proposals up to this long so the raft thread can pack more
    /// into a single `raft_log.db` commit + fsync. Under heavy write
    /// load at multi-worker scale, the raft thread's per-tick fsync
    /// is the single hard ceiling on write throughput — every
    /// writeset funnels through one raft log regardless of how many
    /// dispatch workers are running. Trading a few hundred µs of
    /// commit latency for a 3–5× write throughput lift is usually
    /// worth it. 0 disables linger (every tick commits whatever it
    /// has). Mapped directly to `RaftNodeConfig.propose_linger_ns`
    /// at init time.
    propose_linger_us: u64 = 500,
    /// How often each tenant's `deployment/current` is polled for
    /// changes. Low values make new deploys visible fast (good for
    /// tests); high values reduce per-tenant kv work. Mapped onto
    /// `WorkerConfig.refresh_interval_ns`. 0 means "every tick".
    refresh_interval_ms: u32 = 2000,
};

fn parseCli(argv: [][:0]u8) !Cli {
    var out: Cli = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--node-id")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.node_id = try std.fmt.parseInt(u32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--peers")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.peers = argv[i];
        } else if (std.mem.eql(u8, a, "--listen")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.listen = argv[i];
        } else if (std.mem.eql(u8, a, "--http")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.http = argv[i];
        } else if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.data_dir = argv[i];
        } else if (std.mem.eql(u8, a, "--fresh")) {
            out.fresh = true;
        } else if (std.mem.eql(u8, a, "--bootstrap-root-token")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.bootstrap_root_token = argv[i];
        } else if (std.mem.eql(u8, a, "--bootstrap-resend-key")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.bootstrap_resend_key = argv[i];
        } else if (std.mem.eql(u8, a, "--workers")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.workers = try std.fmt.parseInt(u16, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--admin-origin")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.admin_origin = argv[i];
        } else if (std.mem.eql(u8, a, "--admin-api-domain")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.admin_api_domain = argv[i];
        } else if (std.mem.eql(u8, a, "--public-suffix")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.public_suffix = argv[i];
        } else if (std.mem.eql(u8, a, "--tls-cert")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.tls_cert = argv[i];
        } else if (std.mem.eql(u8, a, "--tls-key")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.tls_key = argv[i];
        } else if (std.mem.eql(u8, a, "--propose-linger-us")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.propose_linger_us = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--refresh-interval-ms")) {
            i += 1;
            if (i >= argv.len) return error.Usage;
            out.refresh_interval_ms = try std.fmt.parseInt(u32, argv[i], 10);
        } else {
            return error.Usage;
        }
    }
    return out;
}

fn parseHostPort(allocator: std.mem.Allocator, hp: []const u8) !std.net.Address {
    const colon = std.mem.lastIndexOfScalar(u8, hp, ':') orelse return error.MalformedHostPort;
    const host = hp[0..colon];
    const port = try std.fmt.parseInt(u16, hp[colon + 1 ..], 10);
    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);
    return try std.net.Address.parseIp(host_z, port);
}

fn parsePeerList(allocator: std.mem.Allocator, peers_str: []const u8) ![]kv.RaftPeerAddr {
    var count: usize = 1;
    for (peers_str) |b| {
        if (b == ',') count += 1;
    }

    const out = try allocator.alloc(kv.RaftPeerAddr, count);
    errdefer allocator.free(out);

    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, peers_str, ',');
    while (it.next()) |entry| : (idx += 1) {
        const colon = std.mem.lastIndexOfScalar(u8, entry, ':') orelse return error.MalformedPeer;
        const host = try allocator.dupe(u8, entry[0..colon]);
        errdefer allocator.free(host);
        const port = try std.fmt.parseInt(u16, entry[colon + 1 ..], 10);
        out[idx] = .{ .host = host, .port = port };
    }
    return out;
}

// ── Signal-driven shutdown ────────────────────────────────────────────
//
// sigaction handler has to be signal-safe; it only stores into an
// atomic. The main thread polls it and the worker threads check it
// on every poll-loop iteration.

var stop_flag: std.atomic.Value(bool) = .init(false);

fn handleSignal(_: c_int) callconv(.c) void {
    stop_flag.store(true, .release);
}

fn installSignalHandlers() !void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

// ── Worker thread ─────────────────────────────────────────────────────

const Worker = rjs.Worker(.{});

/// Per-worker state assembled on the worker thread itself. Everything
/// in here is thread-local: allocating on the worker thread keeps the
/// rove registry's allocations co-located for cache locality.
const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    worker_idx: u16,
    data_dir: []const u8,
    http_addr: std.net.Address,
    raft: *kv.RaftNode,
    code_addr: std.net.Address,
    log_addr: std.net.Address,
    admin_origin: ?[]const u8,
    admin_api_domain: ?[]const u8,
    public_suffix: ?[]const u8,
    refresh_interval_ms: u32,
    /// Shared TlsConfig (or null for plaintext h2c). When present,
    /// all workers hand it to their h2 session on accept. Lives in
    /// the main thread; workers borrow.
    tls_config: ?*h2_mod.TlsConfig,
    /// Shared across all workers — every per-tenant `app.db` `KvStore`
    /// opens with a counter from this registry so seq allocation
    /// stays globally monotonic.
    seq_counters: *kv.SeqCounterRegistry,
    /// Main thread blocks on these until every worker has bound its
    /// h2 listener — this is what `SO_REUSEPORT` needs before requests
    /// can hit any of them.
    ready: *std.Thread.ResetEvent,
};

fn workerMain(args: *WorkerCtx) !void {
    const allocator = args.allocator;

    // Per-worker rove registry. Every entity, every collection, every
    // deferred-op queue is owned by this registry and only touched by
    // this thread.
    var reg = try rove.Registry.init(allocator, .{
        .max_entities = 65536,
        .deferred_queue_capacity = 4096,
    });
    defer reg.deinit();

    // Per-worker tenant. Opens its OWN connection to __root__.db.
    // Multiple connections to the same sqlite file are fine in WAL
    // mode, and each worker's connection respects the NOMUTEX
    // "one thread per connection" rule because it's created here.
    const root_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/__root__.db",
        .{args.data_dir},
        0,
    );
    defer allocator.free(root_path);
    const root_kv = try kv.KvStore.open(allocator, root_path);
    defer root_kv.close();

    var tenant = try tenant_mod.Tenant.initWithCounters(
        allocator,
        root_kv,
        args.data_dir,
        args.seq_counters,
    );
    defer tenant.deinit();
    try tenant.setPublicSuffix(args.public_suffix);

    // The main thread already created the instances + assigned domains
    // in the shared __root__.db before spawning us. We just need to
    // promote them into THIS worker's in-memory cache so `Worker.create`
    // can open their per-tenant stores eagerly.
    //
    // For the per-tenant `app.db` stores we also set `busy_timeout=0`
    // so BEGIN IMMEDIATE returns SQLITE_BUSY immediately instead of
    // blocking up to 5s. The batched dispatcher handles that: it
    // records the tenant as blocked for this tick and moves on to
    // pick a different anchor. The WAL-transition race startup
    // happens via the main thread's `prewarmTenantDbs`, so worker
    // opens never need the original 5s wait anymore.
    for (TENANT_IDS) |id| {
        try tenant.createInstance(id);
        // Skip the busy_timeout=0 hack on __admin__ — its kv ALIASES
        // to the root store, and root.db needs normal busy handling
        // so concurrent bootstrap writes across workers (marker +
        // domain updates) serialize instead of racing to SQLITE_BUSY.
        if (std.mem.eql(u8, id, tenant_mod.ADMIN_INSTANCE_ID)) continue;
        if (tenant.instances.get(id)) |inst| inst.kv.setBusyTimeout(0);
    }

    const worker = try Worker.create(allocator, &reg, .{
        .tenant = &tenant,
        .raft = args.raft,
        .addr = args.http_addr,
        .io_opts = .{
            .max_connections = 4096,
            .buf_count = 1024,
            .buf_size = 16384,
            .listen_backlog = 4096,
            .reuseport = true,
        },
        .h2_opts = .{
            .max_concurrent_streams = 512,
            .initial_window_size = 1024 * 1024,
            .max_frame_size = 16384,
            .tls_config = args.tls_config,
        },
        .code_addr = args.code_addr,
        .log_addr = args.log_addr,
        .admin_origin = args.admin_origin,
        .admin_api_domain = args.admin_api_domain,
        .log_worker_id = args.worker_idx,
        .refresh_interval_ns = @as(i64, args.refresh_interval_ms) * std.time.ns_per_ms,
    });
    defer worker.destroy();

    std.log.info("worker {d}: ready, listening on same port via SO_REUSEPORT", .{args.worker_idx});
    args.ready.set();

    // Scratch list of tenants that returned SQLITE_BUSY on BEGIN
    // IMMEDIATE during THIS tick. Cleared at the top of each tick so
    // a tenant temporarily held by another worker gets a fresh
    // chance next tick. Bounded at 32 — well above the realistic
    // handful-of-tenants-per-tick workloads we've measured.
    var blocked_tenants: rjs.BlockedTenants = .{};

    while (!stop_flag.load(.acquire)) {
        // Bounded-wait poll. The worker has multiple pieces of
        // background state that need periodic attention regardless of
        // incoming I/O:
        //   - parked raft entries (drainRaftPending)
        //   - deployment refresh deadlines (refreshDeployments)
        //   - buffered log records waiting on a flush threshold (flushLogs)
        // The cheapest correct shape is: every poll has a deadline,
        // the loop body runs at least that often, idle CPU stays
        // negligible because each tick is microseconds.
        //
        // `error.SignalInterrupt` is not fatal — it just means SIGINT
        // or SIGTERM arrived during `io_uring_enter`. Fall through to
        // the stop-flag check at the top of the loop.
        worker.pollWithTimeout(1 * std.time.ns_per_ms) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };

        // Code-server proxy: maintain the upstream session, forward
        // any parked /_system/files/* requests, map upstream responses
        // back onto their server-side peers. Order matters — ingest
        // before flush (so a connection that just came up is usable
        // in the same tick), and drain after flush (so responses
        // that came back in the same tick flow onward).
        try rjs.connectProxies(worker);
        try rjs.ingestProxyConnects(worker);
        try reg.flush();
        try rjs.flushProxyPending(worker);
        try reg.flush();
        try rjs.drainProxyResponses(worker);
        try reg.flush();

        // Drain request_out one tenant-batch at a time. Each call
        // processes at most one tenant's requests; the flush between
        // calls is what lets the next call see a smaller request_out
        // and pick a fresh anchor tenant. A BUSY anchor this tick is
        // remembered in `blocked_tenants` so subsequent calls skip it
        // and try different tenants.
        blocked_tenants.clear();
        while (true) {
            const processed = try rjs.dispatchOnce(worker, &blocked_tenants);
            try reg.flush();
            if (processed == 0) break;
        }
        try rjs.drainRaftPending(worker);
        try reg.flush();
        try rjs.cleanupResponses(worker);
        try reg.flush();
        try rjs.refreshDeployments(worker);
        // Best-effort log batch flush: drains each tenant's in-memory
        // buffer if any threshold (count/bytes/time) has been crossed
        // and proposes through raft (leader) or writes locally
        // (follower).
        try rjs.flushLogs(worker);
    }

    std.log.info("worker {d}: shutting down", .{args.worker_idx});
}

fn workerThreadEntry(args: *WorkerCtx) void {
    workerMain(args) catch |err| {
        std.log.err("worker {d}: exited with error: {s}", .{ args.worker_idx, @errorName(err) });
        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        // Release the main thread if we died before reaching the
        // `ready.set()` line — otherwise main would block forever.
        args.ready.set();
        // Flip stop_flag so the surviving workers don't keep running
        // on their own while main thinks everything is fine.
        stop_flag.store(true, .release);
    };
}

fn raftThreadMain(node: *kv.RaftNode) void {
    node.run(null) catch |err| {
        std.log.err("raft thread exited: {s}", .{@errorName(err)});
    };
}

// ── main ──────────────────────────────────────────────────────────────

pub fn main() !void {
    // c_allocator (glibc malloc) — NOT DebugAllocator. The latter
    // spends ~20% of CPU in stack-trace capture per alloc even in
    // ReleaseFast. See memory `feedback_zig_*` / session-9 notes.
    const allocator = std.heap.c_allocator;

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const cli = parseCli(argv) catch {
        var stderr_buf: [1024]u8 = undefined;
        var sw = std.fs.File.stderr().writer(&stderr_buf);
        try sw.interface.writeAll(
            \\usage: js-worker [opts]
            \\  --node-id <n>               index into --peers (default 0)
            \\  --peers <h:p,h:p,...>       raft peer list (default 127.0.0.1:40100)
            \\  --listen <host:port>        raft RPC listen (default 127.0.0.1:40100)
            \\  --http <host:port>          HTTP/2 listen (default 127.0.0.1:8082)
            \\  --data-dir <path>           per-node data dir (default /tmp/rove-js-data)
            \\  --fresh                     wipe data dir before start
            \\  --bootstrap-root-token HEX  seed the root auth token at startup
            \\  --workers <n>               number of worker threads (default 0 = nCPU - 1)
            \\  --propose-linger-us <n>     raft proposal linger budget in µs (default 500)
            \\
        );
        try sw.interface.flush();
        std.process.exit(2);
    };

    // Resolve workers=0 → online CPU count (minus one for the raft thread).
    const num_workers: u16 = if (cli.workers == 0) blk: {
        const cpus = std.Thread.getCpuCount() catch 4;
        break :blk @intCast(@max(1, cpus -| 1));
    } else cli.workers;

    if (cli.fresh) {
        std.fs.cwd().deleteTree(cli.data_dir) catch {};
    }
    try std.fs.cwd().makePath(cli.data_dir);

    try installSignalHandlers();

    // ── One-time bootstrap: __root__ + instances + handler ────────────
    //
    // Done on the main thread so the workers only have to discover
    // pre-existing state on startup. Each worker will open its OWN
    // connections to these files when it spins up.
    {
        const root_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/__root__.db",
            .{cli.data_dir},
            0,
        );
        defer allocator.free(root_path);
        const root_kv = try kv.KvStore.open(allocator, root_path);
        defer root_kv.close();

        var tenant = try tenant_mod.Tenant.init(allocator, root_kv, cli.data_dir);
        defer tenant.deinit();

        if (cli.bootstrap_root_token) |t| {
            tenant.installRootToken(t) catch |err| {
                std.debug.print("bootstrap: installRootToken failed: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            };
            std.debug.print("bootstrap: root token installed\n", .{});
        }

        if (cli.bootstrap_resend_key) |k| {
            tenant.installResendKey(k) catch |err| {
                std.debug.print("bootstrap: installResendKey failed: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            };
            std.debug.print("bootstrap: resend key installed (platform default)\n", .{});
        }

        // __admin__ must be created before any other tenant because
        // its `app.db` aliases to the root store — that aliasing is
        // the whole reason admin handler JS can do plain `kv.set` on
        // `__root__/*` keys. See `src/tenant/root.zig`.
        try tenant.createInstance("__admin__");
        try tenant.createInstance("acme");
        try tenant.createInstance("globex");
        try tenant.createInstance("penalty");
        try tenant.createInstance("readonly");
        try tenant.createInstance("randwrite");
        try tenant.createInstance("hot");
        try tenant.createInstance("spread");
        try tenant.assignDomain("acme.test", "acme");
        try tenant.assignDomain("globex.test", "globex");
        try tenant.assignDomain("penalty.test", "penalty");
        try tenant.assignDomain("readonly.test", "readonly");
        try tenant.assignDomain("randwrite.test", "randwrite");
        try tenant.assignDomain("hot.test", "hot");
        try tenant.assignDomain("spread.test", "spread");

        // Write benchmark tenants — each one gets its own app.db and
        // therefore its own WAL writer lock, so parallel load across
        // them bypasses the per-tenant write ceiling.
        var wi: usize = 0;
        while (wi < NUM_WRITE_TENANTS) : (wi += 1) {
            var id_buf: [16]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buf, "write{d}", .{wi});
            var dom_buf: [32]u8 = undefined;
            const dom = try std.fmt.bufPrint(&dom_buf, "write{d}.test", .{wi});
            try tenant.createInstance(id);
            try tenant.assignDomain(dom, id);
        }

        // Bootstrap handler code on EVERY node. The bytecode is
        // content-addressed and the deploy is local-deterministic, so
        // all nodes independently end up with the same hashes — no
        // replication needed for code in M1.
        try bootstrapHandler(allocator, cli.data_dir, "__admin__", &ADMIN_DEPLOY_FILES);
        try bootstrapHandler(allocator, cli.data_dir, "acme", &.{
            .{ .path = "index.mjs", .content = ACME_INDEX },
            .{ .path = "api/index.mjs", .content = ACME_API_INDEX },
            .{ .path = "users/index.mjs", .content = ACME_USERS_MJS },
        });
        try bootstrapHandler(allocator, cli.data_dir, "globex", &.{
            .{ .path = "index.mjs", .content = GLOBEX_HANDLER },
        });
        try bootstrapHandler(allocator, cli.data_dir, "penalty", &.{
            .{ .path = "index.mjs", .content = PENALTY_HANDLER },
        });
        try bootstrapHandler(allocator, cli.data_dir, "readonly", &.{
            .{ .path = "index.mjs", .content = READONLY_HANDLER },
        });
        try bootstrapHandler(allocator, cli.data_dir, "randwrite", &.{
            .{ .path = "index.mjs", .content = RANDWRITE_BENCH_HANDLER },
        });
        try bootstrapHandler(allocator, cli.data_dir, "hot", &.{
            .{ .path = "index.mjs", .content = HOT_BENCH_HANDLER },
        });
        try bootstrapHandler(allocator, cli.data_dir, "spread", &.{
            .{ .path = "index.mjs", .content = SPREAD_BENCH_HANDLER },
        });
        wi = 0;
        while (wi < NUM_WRITE_TENANTS) : (wi += 1) {
            var id_buf: [16]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buf, "write{d}", .{wi});
            try bootstrapHandler(allocator, cli.data_dir, id, &.{
                .{ .path = "index.mjs", .content = WRITE_BENCH_HANDLER },
            });
        }

        // Seed the readonly tenant's app.db with a value the handler
        // can read. Opens a throwaway kv connection directly to the
        // per-tenant app.db file; the workers will open their own
        // connections at startup and see this row via WAL.
        try seedReadonlyTenant(allocator, cli.data_dir);

        // Prewarm every tenant's app.db + log.db on the main thread
        // so the WAL-mode transition is committed before workers race
        // to open them. Without this, `--workers 8` occasionally kills
        // a worker with `error: JournalMode` because two openers try
        // to upgrade journal_mode=WAL at the same time.
        try prewarmTenantDbs(allocator, cli.data_dir);
    }

    // ── Subsystem threads (shared across workers) ──────────────────────
    //
    // Spawn BEFORE the workers so the workers can open client
    // connections to them during startup. Each owns its own rove
    // context (registry + io_uring + h2 server) and binds to a
    // loopback TCP ephemeral port.
    // Sized from the worker count: each worker holds one persistent
    // h2 client to each subsystem, plus a small slack so a reconnect
    // during churn doesn't collide with the old connection still in
    // the fd table.
    const subsystem_max_connections: u32 = @as(u32, num_workers) + 4;

    const cs_handle = try files_server.thread.spawn(allocator, cli.data_dir, subsystem_max_connections);
    defer cs_handle.shutdown();
    const code_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, cs_handle.port);

    const ls_handle = try log_server.thread.spawn(allocator, cli.data_dir, subsystem_max_connections);
    defer ls_handle.shutdown();
    const log_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, ls_handle.port);

    // ── Raft setup ─────────────────────────────────────────────────────
    //
    // ApplyCtx is raft-thread-local: it owns its own per-tenant sqlite
    // connections, opened lazily on follower applies. These are
    // DISTINCT from any worker's connections, so the raft thread and
    // the worker threads never share a NOMUTEX sqlite connection.
    var apply_ctx: rjs.apply.ApplyCtx = undefined;

    const peers = try parsePeerList(allocator, cli.peers);
    defer {
        for (peers) |p| allocator.free(p.host);
        allocator.free(peers);
    }
    const listen_addr = try parseHostPort(allocator, cli.listen);

    const raft_log_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/raft.log.db",
        .{cli.data_dir},
        0,
    );
    defer allocator.free(raft_log_path);

    const raft_node = try kv.RaftNode.init(allocator, .{
        .node_id = cli.node_id,
        .peers = peers,
        .listen_addr = listen_addr,
        .apply = .{
            .opaque_bytes = .{
                .apply_fn = rjs.apply.applyOne,
                .ctx = &apply_ctx,
            },
        },
        .raft_log_path = raft_log_path,
        .worker_count = 0,
        .propose_linger_ns = cli.propose_linger_us * std.time.ns_per_us,
    });
    defer raft_node.deinit();

    apply_ctx = rjs.apply.ApplyCtx.init(allocator, cli.data_dir, raft_node);
    defer apply_ctx.deinit();

    var raft_thread = try std.Thread.spawn(.{}, raftThreadMain, .{raft_node});
    raft_thread.detach();

    // ── Spawn worker threads ───────────────────────────────────────────
    const http_addr = try parseHostPort(allocator, cli.http);

    const ctxs = try allocator.alloc(WorkerCtx, num_workers);
    defer allocator.free(ctxs);
    const threads = try allocator.alloc(std.Thread, num_workers);
    defer allocator.free(threads);
    const ready_events = try allocator.alloc(std.Thread.ResetEvent, num_workers);
    defer allocator.free(ready_events);
    for (ready_events) |*ev| ev.* = .{};

    // Shared seq-counter registry. Every per-tenant `app.db` KvStore
    // opened by any worker draws from this, so concurrent worker
    // threads allocating new seqs for the same tenant never collide.
    var seq_counters = kv.SeqCounterRegistry.init(allocator);
    defer seq_counters.deinit();

    // Optional TLS. Both flags must be set; either alone is a usage
    // error (silent fall-through to plaintext would mask a config
    // mistake in prod).
    const tls_config: ?*h2_mod.TlsConfig = blk: {
        const has_cert = cli.tls_cert != null;
        const has_key = cli.tls_key != null;
        if (!has_cert and !has_key) break :blk null;
        if (has_cert != has_key) {
            std.debug.print("error: --tls-cert and --tls-key must be set together\n", .{});
            std.process.exit(2);
        }
        const cfg = h2_mod.TlsConfig.createFromFiles(
            allocator,
            cli.tls_cert.?,
            cli.tls_key.?,
        ) catch |err| {
            std.debug.print("error: tls: {s} (cert={s}, key={s})\n", .{
                @errorName(err), cli.tls_cert.?, cli.tls_key.?,
            });
            std.process.exit(2);
        };
        std.log.info("tls: loaded {s} + {s}", .{ cli.tls_cert.?, cli.tls_key.? });
        break :blk cfg;
    };

    var i: u16 = 0;
    while (i < num_workers) : (i += 1) {
        ctxs[i] = .{
            .allocator = allocator,
            .worker_idx = i,
            .data_dir = cli.data_dir,
            .http_addr = http_addr,
            .raft = raft_node,
            .code_addr = code_addr,
            .log_addr = log_addr,
            .admin_origin = cli.admin_origin,
            .admin_api_domain = cli.admin_api_domain,
            .public_suffix = cli.public_suffix,
            .refresh_interval_ms = cli.refresh_interval_ms,
            .tls_config = tls_config,
            .seq_counters = &seq_counters,
            .ready = &ready_events[i],
        };
        threads[i] = try std.Thread.spawn(.{}, workerThreadEntry, .{&ctxs[i]});
    }
    for (ready_events) |*ev| ev.wait();

    std.debug.print(
        "rove-js worker node {d} listening on http://{s} (h2c)\n" ++
            "  workers:    {d} (SO_REUSEPORT)\n" ++
            "  data dir:   {s}\n" ++
            "  raft:       node {d} of {d} @ {s}\n" ++
            "  peers:      {s}\n" ++
            "  instances:  acme (counter), globex (echo), penalty (while(true))\n" ++
            "  domains:    acme.test, globex.test, penalty.test\n",
        .{ cli.node_id, cli.http, num_workers, cli.data_dir, cli.node_id, peers.len, cli.listen, cli.peers },
    );

    // Block until SIGINT/SIGTERM flips stop_flag, then join workers.
    // 50ms poll granularity is invisible to shutdown perception and
    // costs nothing. If TLS is on, the main thread also stat()s the
    // PEM files once per second — the sidecar (scripts/rove-lego-
    // renew.sh) rewrites these whenever lego renews, and workers pick
    // up the new cert on the next TLS accept.
    const reload_interval_ticks: u64 = 20; // 20 × 50ms = 1s
    var tick: u64 = 0;
    while (!stop_flag.load(.acquire)) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
        tick += 1;
        if (tls_config) |cfg| {
            if (tick % reload_interval_ticks == 0) {
                const changed = cfg.reloadIfChanged() catch |err| blk: {
                    std.log.warn("tls: reloadIfChanged failed: {s}", .{@errorName(err)});
                    break :blk false;
                };
                if (changed) std.log.info("tls: cert/key reloaded", .{});
            }
        }
    }
    std.log.info("js-worker: shutdown requested, joining {d} worker(s)", .{num_workers});
    for (threads) |t| t.join();
    std.log.info("js-worker: bye", .{});

    // Skip the teardown chain. The raft thread is detached and still
    // inside `node.run()`; running `raft_node.deinit()` out from under
    // it would segfault. Subsystem threads (files-server, log-server)
    // would also need a join story before it's safe to free their
    // handles. The pragmatic answer is `_exit(0)` — same as nginx,
    // envoy, etc.: the kernel reclaims memory + fds + sockets in one
    // shot and we avoid re-implementing a clean teardown graph for
    // every subsystem.
    std.process.exit(0);
}

/// Compile `source` (or pass-through for static) for an instance and
/// publish it as the current deployment through that tenant's file
/// store. Mirrors what `rove-files-cli upload + deploy` would do
/// externally; kept inline so the smoke test is a single binary.
const DeployFile = struct {
    path: []const u8,
    content: []const u8,
    /// null → handler source (compile to bytecode). Non-null → static
    /// file served verbatim with this content-type.
    content_type: ?[]const u8 = null,
};

fn bootstrapHandler(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance_id: []const u8,
    files: []const DeployFile,
) !void {
    const inst_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, instance_id });
    defer allocator.free(inst_dir);
    try std.fs.cwd().makePath(inst_dir);

    const files_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/files.db", .{inst_dir}, 0);
    defer allocator.free(files_db_path);

    const files_blob_dir = try std.fmt.allocPrint(allocator, "{s}/file-blobs", .{inst_dir});
    defer allocator.free(files_blob_dir);

    const files_kv = try kv.KvStore.open(allocator, files_db_path);
    defer files_kv.close();
    var fs_store = try blob_mod.FilesystemBlobStore.open(allocator, files_blob_dir);
    defer fs_store.deinit();

    // Real qjs compile so the stored bytecode is real.
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
    _ = try store.deploy();
}

// The admin UI bundle is embedded into the binary so a fresh start
// ships with a functioning login page at app.loop46.me. Each file
// becomes a `_static/<path>` entry in __admin__'s initial deployment.
const ADMIN_UI_INDEX_HTML = @embedFile("admin_ui_index_html");
const ADMIN_UI_APP_JS = @embedFile("admin_ui_app_js");
const ADMIN_UI_API_JS = @embedFile("admin_ui_api_js");
const ADMIN_UI_APP_CSS = @embedFile("admin_ui_app_css");
const ADMIN_UI_PAGE_LOGIN = @embedFile("admin_ui_page_login");
const ADMIN_UI_PAGE_INSTANCES = @embedFile("admin_ui_page_instances");
const ADMIN_UI_PAGE_INSTANCE = @embedFile("admin_ui_page_instance");

const ADMIN_DEPLOY_FILES = [_]DeployFile{
    .{ .path = "index.mjs", .content = ADMIN_HANDLER_SRC },
    .{ .path = "_static/index.html", .content = ADMIN_UI_INDEX_HTML, .content_type = "text/html; charset=utf-8" },
    .{ .path = "_static/app.js", .content = ADMIN_UI_APP_JS, .content_type = "application/javascript" },
    .{ .path = "_static/api.js", .content = ADMIN_UI_API_JS, .content_type = "application/javascript" },
    .{ .path = "_static/app.css", .content = ADMIN_UI_APP_CSS, .content_type = "text/css" },
    .{ .path = "_static/pages/login.js", .content = ADMIN_UI_PAGE_LOGIN, .content_type = "application/javascript" },
    .{ .path = "_static/pages/instances.js", .content = ADMIN_UI_PAGE_INSTANCES, .content_type = "application/javascript" },
    .{ .path = "_static/pages/instance.js", .content = ADMIN_UI_PAGE_INSTANCE, .content_type = "application/javascript" },
};

/// Pre-seed the readonly tenant's per-tenant `app.db` with a row the
/// benchmark handler reads. Opens a throwaway direct kv connection,
/// writes one row, closes it. The workers open their own connections
/// later and see this row via SQLite WAL.
fn seedReadonlyTenant(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
) !void {
    const inst_dir = try std.fmt.allocPrint(allocator, "{s}/readonly", .{data_dir});
    defer allocator.free(inst_dir);
    try std.fs.cwd().makePath(inst_dir);

    const app_db_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/app.db",
        .{inst_dir},
        0,
    );
    defer allocator.free(app_db_path);

    const app_kv = try kv.KvStore.open(allocator, app_db_path);
    defer app_kv.close();
    try app_kv.put("greeting", "hello");
}

/// Open + close each tenant's `app.db` and `log.db` once from the
/// main thread so the `PRAGMA journal_mode=WAL` transition is
/// committed to disk BEFORE any workers race to open them. Concurrent
/// WAL-mode transitions from multiple openers can fail with a
/// `JournalMode` error under load (the brief exclusive lock SQLite
/// needs can't be re-entered while another opener holds it), which
/// we observed at `--workers 8`. Prewarming fixes it once and for
/// all: subsequent openers see the existing WAL mode and skip the
/// transition.
fn prewarmTenantDbs(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
) !void {
    for (TENANT_IDS) |id| {
        const inst_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, id });
        defer allocator.free(inst_dir);
        try std.fs.cwd().makePath(inst_dir);

        const app_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/app.db", .{inst_dir}, 0);
        defer allocator.free(app_db_path);
        const app_kv = try kv.KvStore.open(allocator, app_db_path);
        app_kv.close();

        const log_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/log.db", .{inst_dir}, 0);
        defer allocator.free(log_db_path);
        const log_kv = try kv.KvStore.open(allocator, log_db_path);
        log_kv.close();
    }
}

/// Inline qjs compile hook — identical to the one in files_cli.zig.
/// Duplicating it here keeps the smoke test self-contained; the
/// production path reuses files_cli's helper.
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
        // Treat `.mjs` files as ES modules; everything else compiles
        // as a plain script. Extension is the source of truth — the
        // rove-files-cli rewrite will apply the same rule.
        const kind: qjs.EvalFlags = if (std.mem.endsWith(u8, filename, ".mjs"))
            .{ .kind = .module }
        else
            .{};
        return self.context.compileToBytecode(source, filename, allocator, kind);
    }
};
