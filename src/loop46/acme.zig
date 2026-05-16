//! Phase 2b orchestration: leader-gated ACME issuance + every-node
//! cert materialization (auth-domain-plan.md §3.2).
//!
//! One leader-pinned thread per node (the schedule-server shape):
//!
//!   - **Every node, every tick** — materialize: for each custom
//!     domain that has a replicated `cert/{host}` in `__root__.db`,
//!     write `{custom_cert_dir}/{host}/{cert,key}.pem` if missing or
//!     stale. The Phase-2c reload poll then serves it by SNI within
//!     ≤1 s. This is how *followers* end up serving a leader-issued
//!     cert with no shared FS / S3.
//!   - **Leader only** — issue: for each custom domain lacking a
//!     `cert/{host}`, run the ACME client, then write the cert into
//!     `__root__.db` locally **and** propose envelope-2 root_writeset
//!     so every follower converges (size ~few KB, rare — see §3.2,
//!     explicitly *not* the size-based blobs-in-raft case).
//!
//! Inert unless `--acme-directory` + `--custom-cert-dir` are both
//! set: zero behavior change for existing deploys.

const std = @import("std");
const kv_mod = @import("rove-kv");
const acme = @import("rove-acme");
const tenant_mod = @import("rove-tenant");
const blob = @import("rove-blob");
const rjs = @import("rove-js");

const CERT_PREFIX = "cert/";

pub const Config = struct {
    allocator: std.mem.Allocator,
    raft: *kv_mod.RaftNode,
    cluster: *kv_mod.Cluster,
    tenant: *tenant_mod.Tenant,
    data_dir: []const u8,
    custom_cert_dir: []const u8,
    public_suffix: []const u8,
    system_suffix: []const u8,
    directory_url: []const u8,
    contact_email: ?[]const u8,
    insecure_tls: bool,
    http_port: u16,
};

pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool),
    responder_stop: std.atomic.Value(bool),
    config: Config,
    responder: acme.Responder,

    pub fn signalStop(self: *Handle) void {
        self.stop_flag.store(true, .release);
        self.responder_stop.store(true, .release);
    }

    pub fn join(self: *Handle) void {
        self.thread.join();
        self.responder.join();
        self.allocator.destroy(self);
    }
};

pub fn spawn(config: Config) !*Handle {
    const h = try config.allocator.create(Handle);
    errdefer config.allocator.destroy(h);
    h.* = .{
        .allocator = config.allocator,
        .thread = undefined,
        .stop_flag = .init(false),
        .responder_stop = .init(false),
        .config = config,
        .responder = acme.Responder.init(config.allocator, undefined, config.http_port),
    };
    // Point the responder at our own stop flag (can't take &h before
    // it exists; fix it up now that it does).
    h.responder.stop = &h.responder_stop;
    try h.responder.start();
    errdefer {
        h.responder_stop.store(true, .release);
        h.responder.join();
    }
    h.thread = try std.Thread.spawn(.{}, threadMain, .{h});
    return h;
}

fn threadMain(h: *Handle) void {
    runLoop(h) catch |err|
        std.log.err("acme thread exited: {s}", .{@errorName(err)});
}

fn runLoop(h: *Handle) !void {
    std.log.info("acme: started (dir={s}, port={d})", .{
        h.config.directory_url, h.config.http_port,
    });
    blob.curl.globalInit();

    while (!h.stop_flag.load(.acquire)) {
        tick(h) catch |err|
            std.log.warn("acme: tick error: {s}", .{@errorName(err)});
        // Issuance is rare; renewal cadence is days. Sleep ~15 s in
        // 1 s steps so SIGTERM joins promptly.
        var slept: u32 = 0;
        while (slept < 15 and !h.stop_flag.load(.acquire)) : (slept += 1)
            std.Thread.sleep(std.time.ns_per_s);
    }
    std.log.info("acme: stopped", .{});
}

fn tick(h: *Handle) !void {
    const a = h.allocator;
    const cfg = h.config;
    const root = try cfg.cluster.openRoot();

    var domains = cfg.tenant.listDomains(std.math.maxInt(u32)) catch return;
    defer domains.deinit();

    const is_leader = cfg.raft.isLeader();
    var acme_client: ?acme.Client = null;
    var account_key: ?acme.crypto.Key = null;
    defer if (account_key) |*k| k.deinit();
    defer if (acme_client) |*cl| cl.deinit();
    var easy: ?*blob.curl.Easy = null;
    defer if (easy) |e| e.deinit();

    for (domains.entries) |d| {
        if (!isCustomHost(d.host, cfg.public_suffix, cfg.system_suffix)) continue;

        var key_buf: [CERT_PREFIX.len + 256]u8 = undefined;
        if (d.host.len > 256) continue;
        const ck = std.fmt.bufPrint(&key_buf, CERT_PREFIX ++ "{s}", .{d.host}) catch continue;

        const existing: ?[]u8 = root.get(ck) catch |err| switch (err) {
            error.NotFound => null,
            else => return err,
        };
        defer if (existing) |e| a.free(e);

        if (existing) |blob_bytes| {
            // Every node: make sure it's on local disk for the SNI store.
            materialize(a, cfg.custom_cert_dir, d.host, blob_bytes) catch |err|
                std.log.warn("acme: materialize {s}: {s}", .{ d.host, @errorName(err) });
            continue;
        }

        // Missing → only the leader issues.
        if (!is_leader) continue;

        if (account_key == null) {
            account_key = ensureAccountKey(a, cfg.data_dir) catch |err| {
                std.log.warn("acme: account key: {s}", .{@errorName(err)});
                return;
            };
            easy = blob.curl.Easy.init(a) catch return;
            acme_client = .{
                .allocator = a,
                .easy = easy.?,
                .account_key = &account_key.?,
                .responder = &h.responder,
                .directory_url = cfg.directory_url,
                .contact_email = cfg.contact_email,
                .insecure_tls = cfg.insecure_tls,
            };
        }

        std.log.info("acme: issuing for {s}", .{d.host});
        var issued = acme_client.?.issue(d.host) catch |err| {
            std.log.warn("acme: issue {s} failed: {s}", .{ d.host, @errorName(err) });
            continue;
        };
        defer issued.deinit(a);

        const packed_blob = try packCert(a, issued.cert_pem, issued.key_pem);
        defer a.free(packed_blob);

        // Leader writes locally (applyRootWriteSet is leader-skip),
        // then proposes so followers converge.
        root.put(ck, packed_blob) catch |err| {
            std.log.warn("acme: root.put {s}: {s}", .{ d.host, @errorName(err) });
            continue;
        };
        // Replicate via envelope-2 root_writeset (same encoder
        // signup/platform.root.* use; rove-js exports `apply`).
        propose: {
            var ws = kv_mod.WriteSet.init(a);
            defer ws.deinit();
            ws.addPut(ck, packed_blob) catch break :propose;
            const ws_bytes = ws.encode(a) catch break :propose;
            defer a.free(ws_bytes);
            const env = rjs.apply.encodeRootWriteSetEnvelope(a, ws_bytes) catch break :propose;
            defer a.free(env);
            const seq = cfg.raft.highWatermark() + 1;
            cfg.raft.propose(seq, env) catch |err|
                std.log.warn("acme: propose cert/{s}: {s}", .{ d.host, @errorName(err) });
        }

        // Materialize immediately on the leader too.
        materialize(a, cfg.custom_cert_dir, d.host, packed_blob) catch {};
        std.log.info("acme: issued + replicated {s}", .{d.host});
    }
}

/// A host is "custom" (ACME-eligible) when it is not under the
/// customer wildcard nor the system suffix — i.e. a brought domain
/// that has no operator-owned wildcard cert covering it.
fn isCustomHost(host: []const u8, public_suffix: []const u8, system_suffix: []const u8) bool {
    if (std.mem.eql(u8, host, public_suffix) or std.mem.eql(u8, host, system_suffix))
        return false;
    if (endsWithDotted(host, public_suffix) or endsWithDotted(host, system_suffix))
        return false;
    return true;
}

fn endsWithDotted(host: []const u8, suffix: []const u8) bool {
    if (host.len <= suffix.len + 1) return false;
    if (host[host.len - suffix.len - 1] != '.') return false;
    return std.mem.eql(u8, host[host.len - suffix.len ..], suffix);
}

/// `cert/{host}` value: [4B BE cert_len][cert_pem][key_pem].
fn packCert(a: std.mem.Allocator, cert: []const u8, key: []const u8) ![]u8 {
    const out = try a.alloc(u8, 4 + cert.len + key.len);
    std.mem.writeInt(u32, out[0..4], @intCast(cert.len), .big);
    @memcpy(out[4 .. 4 + cert.len], cert);
    @memcpy(out[4 + cert.len ..], key);
    return out;
}

const Unpacked = struct { cert: []const u8, key: []const u8 };
fn unpackCert(blob_bytes: []const u8) ?Unpacked {
    if (blob_bytes.len < 4) return null;
    const clen = std.mem.readInt(u32, blob_bytes[0..4], .big);
    if (4 + clen > blob_bytes.len) return null;
    return .{ .cert = blob_bytes[4 .. 4 + clen], .key = blob_bytes[4 + clen ..] };
}

/// Write `{dir}/{host}/{cert,key}.pem` iff missing or changed (avoid
/// rewriting every tick → no needless Phase-2c reload churn).
fn materialize(
    a: std.mem.Allocator,
    dir: []const u8,
    host: []const u8,
    blob_bytes: []const u8,
) !void {
    const u = unpackCert(blob_bytes) orelse return error.BadCertBlob;
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const hdir = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, host });
    std.fs.cwd().makePath(hdir) catch {};
    try writeIfChanged(a, hdir, "cert.pem", u.cert);
    try writeIfChanged(a, hdir, "key.pem", u.key);
}

fn writeIfChanged(a: std.mem.Allocator, hdir: []const u8, name: []const u8, content: []const u8) !void {
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ hdir, name });
    if (std.fs.cwd().readFileAlloc(a, path, 1 << 20)) |old| {
        defer a.free(old);
        if (std.mem.eql(u8, old, content)) return; // unchanged
    } else |_| {}
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
}

/// Load the long-lived account key from `{data_dir}/acme/account.key`,
/// generating + persisting it on first use (leader-owned per §3.2).
fn ensureAccountKey(a: std.mem.Allocator, data_dir: []const u8) !acme.crypto.Key {
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const adir = try std.fmt.bufPrint(&pb, "{s}/acme", .{data_dir});
    std.fs.cwd().makePath(adir) catch {};
    var pb2: [std.fs.max_path_bytes]u8 = undefined;
    const kpath = try std.fmt.bufPrint(&pb2, "{s}/account.key", .{adir});

    if (std.fs.cwd().readFileAlloc(a, kpath, 1 << 16)) |pem| {
        defer a.free(pem);
        return acme.crypto.Key.fromPem(pem);
    } else |_| {}

    var k = try acme.crypto.Key.generate();
    errdefer k.deinit();
    const pem = try k.privatePem(a);
    defer a.free(pem);
    try std.fs.cwd().writeFile(.{
        .sub_path = kpath,
        .data = pem,
        .flags = .{ .mode = 0o600 },
    });
    return k;
}
