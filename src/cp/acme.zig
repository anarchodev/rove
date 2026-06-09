//! Leader-elected ACME HTTP-01 issuer for the V2 control plane (gap #3 slice 3).
//!
//! A background thread on the CP. On the directory-group leader, every tick it
//! computes the work-list — mapped hosts (the domain index, gap #2) that lack a
//! `cert/{host}` (the cert axis, slice 1) — and runs the RFC 8555 client
//! (`rove-acme`) for each, writing the issued cert back to the cert axis via
//! `directory.setCert`. That replicates through the CP raft to every follower
//! CP, and the front door's `CertSync` (slice 2) pulls it into the SNI store.
//!
//! The HTTP-01 `:80` challenge is answered by the FRONT door's plaintext
//! listener (gap #6 phase 5), which fetches the key-authorization from the CP's
//! `GET /_cp/acme-challenge?token=` endpoint. So this issuer never binds `:80`:
//! it publishes the keyauth into an in-memory `acme.Responder` map (reused as a
//! pure store — `start()` is never called) that the CP endpoint reads via
//! `challengeFor`.
//!
//! Inert unless `REWIND_ACME_DIRECTORY` is set: zero behavior change otherwise.
//!
//! Threading: `Client.issue` blocks (it polls the CA with `Thread.sleep`), so it
//! MUST run off the CP's request loop — otherwise the loop couldn't serve the
//! `/_cp/acme-challenge` the CA's validation depends on (a self-deadlock). On
//! this dedicated thread the loop stays free; `setCert` proposes through the
//! mutex-guarded bridge, whose pump advances commit on its own thread, so the
//! blocking commit-wait is safe cross-thread.

const std = @import("std");
const acme = @import("rove-acme");
const blob = @import("rove-blob");
const directory_mod = @import("cp-directory");
const Directory = directory_mod.Directory;

pub const Config = struct {
    allocator: std.mem.Allocator,
    directory: *Directory,
    /// Where the long-lived ACME account key is persisted
    /// (`{data_dir}/acme/account.key`), generated on first use.
    data_dir: []const u8,
    /// ACME CA directory URL — Pebble in tests, Let's Encrypt in prod.
    directory_url: []const u8,
    contact_email: ?[]const u8 = null,
    /// Pebble's throwaway root → skip CA-API TLS verification. Never in prod.
    insecure_tls: bool = false,
    /// Hosts under the platform wildcard / system suffix are already covered by
    /// `REWIND_TLS_CERT` and must NOT be sent to ACME. Empty ⇒ every mapped host
    /// is eligible.
    public_suffix: []const u8 = "",
    system_suffix: []const u8 = "",
};

pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool),
    /// The reused `Responder` wants a stop pointer even though we never bind its
    /// socket; point it here so the field is valid.
    responder_stop: std.atomic.Value(bool),
    config: Config,
    /// In-memory `token → keyAuthorization` store (no `:80` socket). The ACME
    /// client `put`/`remove`s here; the CP endpoint reads via `challengeFor`.
    challenges: acme.Responder,

    pub fn signalStop(self: *Handle) void {
        self.stop_flag.store(true, .release);
    }

    pub fn join(self: *Handle) void {
        self.thread.join();
        // Frees the token map; the socket was never bound (listen_fd == -1).
        self.challenges.join();
        self.allocator.destroy(self);
    }

    /// The key-authorization for an in-flight challenge `token`, or null. Served
    /// by the CP's `/_cp/acme-challenge?token=` endpoint (the front door's `:80`
    /// listener forwards `/.well-known/acme-challenge/<token>` here). Owned copy.
    pub fn challengeFor(self: *Handle, a: std.mem.Allocator, token: []const u8) ?[]u8 {
        return self.challenges.getOwned(a, token);
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
        // port 0, never `start()`ed — used only as the in-memory challenge map.
        .challenges = acme.Responder.init(config.allocator, undefined, 0),
    };
    h.challenges.stop = &h.responder_stop; // can't take &h before it exists; fix up now
    h.thread = try std.Thread.spawn(.{}, threadMain, .{h});
    return h;
}

fn threadMain(h: *Handle) void {
    runLoop(h) catch |err|
        std.log.err("cp-acme: issuer thread exited: {s}", .{@errorName(err)});
}

fn runLoop(h: *Handle) !void {
    std.log.info("cp-acme: issuer started (dir={s})", .{h.config.directory_url});
    blob.curl.globalInit();
    while (!h.stop_flag.load(.acquire)) {
        tick(h) catch |err|
            std.log.warn("cp-acme: tick error: {s}", .{@errorName(err)});
        // Issuance is rare and renewal cadence is days; sleep ~15 s in 1 s steps
        // so SIGTERM joins promptly.
        var slept: u32 = 0;
        while (slept < 15 and !h.stop_flag.load(.acquire)) : (slept += 1)
            std.Thread.sleep(std.time.ns_per_s);
    }
    std.log.info("cp-acme: issuer stopped", .{});
}

fn tick(h: *Handle) !void {
    const a = h.allocator;
    const cfg = h.config;

    // Only the directory leader issues (and only the leader can `setCert`, which
    // commits through the leader's proposer). Followers no-op until they win.
    if (!cfg.directory.isLeader()) return;

    const hosts = cfg.directory.collectUncertedHosts(a) catch return;
    defer {
        for (hosts) |host| a.free(host);
        a.free(hosts);
    }
    if (hosts.len == 0) return;

    // Build the account key + client lazily — only when there's real work.
    var account_key: ?acme.crypto.Key = null;
    defer if (account_key) |*k| k.deinit();
    var easy: ?*blob.curl.Easy = null;
    defer if (easy) |e| e.deinit();
    var client: ?acme.Client = null;
    defer if (client) |*cl| cl.deinit();

    for (hosts) |host| {
        if (!isEligible(host, cfg.public_suffix, cfg.system_suffix)) continue;
        // A concurrent issuance or a `/_control/cert` operator upload may have
        // landed since `collectUncertedHosts`; don't double-issue.
        if (cfg.directory.hasCert(host)) continue;

        if (client == null) {
            account_key = ensureAccountKey(a, cfg.data_dir) catch |err| {
                std.log.warn("cp-acme: account key: {s}", .{@errorName(err)});
                return;
            };
            easy = blob.curl.Easy.init(a) catch return;
            client = .{
                .allocator = a,
                .easy = easy.?,
                .account_key = &account_key.?,
                .responder = &h.challenges,
                .directory_url = cfg.directory_url,
                .contact_email = cfg.contact_email,
                .insecure_tls = cfg.insecure_tls,
            };
        }

        std.log.info("cp-acme: issuing for {s}", .{host});
        var issued = client.?.issue(host) catch |err| {
            std.log.warn("cp-acme: issue {s} failed: {s}", .{ host, @errorName(err) });
            continue;
        };
        defer issued.deinit(a);

        // Write the cert axis — replicates to follower CPs; the front door's
        // CertSync then pulls it into the SNI store.
        cfg.directory.setCert(host, issued.cert_pem, issued.key_pem) catch |err| {
            std.log.warn("cp-acme: setCert {s} failed: {s}", .{ host, @errorName(err) });
            continue;
        };
        std.log.info("cp-acme: issued + replicated {s}", .{host});
    }
}

/// A mapped host needs ACME only if it's a brought custom domain — not the
/// platform wildcard suffix (covered by `REWIND_TLS_CERT`) nor the system
/// suffix. Empty suffixes ⇒ every mapped host is eligible.
fn isEligible(host: []const u8, public_suffix: []const u8, system_suffix: []const u8) bool {
    if (suffixCovers(host, public_suffix)) return false;
    if (suffixCovers(host, system_suffix)) return false;
    return true;
}

/// True if `host` equals `suffix` or is a dotted subdomain of it.
fn suffixCovers(host: []const u8, suffix: []const u8) bool {
    if (suffix.len == 0) return false;
    if (std.mem.eql(u8, host, suffix)) return true;
    return host.len > suffix.len + 1 and
        host[host.len - suffix.len - 1] == '.' and
        std.mem.eql(u8, host[host.len - suffix.len ..], suffix);
}

/// Load the long-lived account key from `{data_dir}/acme/account.key`,
/// generating + persisting it (mode 0600) on first use. Leader-owned per
/// auth-domain-plan.md §3.2.
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
    try std.fs.cwd().writeFile(.{ .sub_path = kpath, .data = pem, .flags = .{ .mode = 0o600 } });
    return k;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "cp-acme: eligibility excludes platform + system suffixes" {
    // Empty suffixes → everything eligible.
    try testing.expect(isEligible("anything.test", "", ""));

    // Platform wildcard covers its subdomains + apex.
    try testing.expect(!isEligible("foo.rewind.app", "rewind.app", ""));
    try testing.expect(!isEligible("rewind.app", "rewind.app", ""));
    // A brought custom domain is eligible.
    try testing.expect(isEligible("acmecorp.test", "rewind.app", "sys.internal"));
    // System suffix excluded too.
    try testing.expect(!isEligible("node1.sys.internal", "rewind.app", "sys.internal"));
    // A look-alike that isn't actually a subdomain stays eligible.
    try testing.expect(isEligible("notrewind.app", "rewind.app", ""));
    try testing.expect(isEligible("rewind.app.evil.com", "rewind.app", ""));
}
