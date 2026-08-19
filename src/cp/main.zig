// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! rewind-cp — the V2 control plane (docs/architecture/control-plane.md).
//!
//! The CP is the authoritative, replicated directory: it owns placement
//! (tenant → cluster), the host→tenant index, and orchestrates moves. It
//! runs as its OWN small raft cluster (3–5 voters) and is **never on the
//! request hot path** — the stateless `rewind-front` proxy learns placement
//! from this binary's `/_cp/route` endpoint and caches it.
//!
//! The directory raft lives only here, never on the front door — so
//! front-door replica count is decoupled from CP voter count and front
//! doors scale horizontally as stateless read-replicas.
//!
//! Surface served (control only — NO customer traffic):
//!   - `POST /_control/move` / `/_control/move-live` — move orchestration
//!     (the directory flip is the atomic commit point; a directory WRITE,
//!     so leader-gated with follower→leader forwarding for CP HA).
//!   - `GET  /_cp/route?host=H` — authoritative owner lookup (front-door
//!     routing + DP serve-or-forward consult this).
//!   - `GET  /_cp/leader` — directory-group leader probe (CP HA discovery).
//!
//! Storage + HA config mirror the worker's: `REWIND_CP_DATA_DIR` (durable
//! directory store), `REWIND_CP_NODE_ID`/`VOTERS`/`PEERS` (multi-node raft),
//! `REWIND_CP_PEER_URLS` (peer HTTP origins for write forwarding).

const std = @import("std");
const rove = @import("rove");
const boot = @import("rove-boot");
const h2 = @import("rove-h2");
const blob = @import("rove-blob");
const cert_mirror = @import("cert_mirror.zig");

const curl = blob.curl;
const bc = @import("backend_client.zig");
const move = @import("move.zig");
const storage_sweep = @import("storage_sweep.zig");
const tenant_mod = @import("rove-tenant");
const reconciler = @import("reconciler.zig");
const BackendResp = bc.BackendResp;
const MOVE_SECRET_HEADER = bc.MOVE_SECRET_HEADER;
const directory_mod = @import("cp-directory");
/// The tenant-id spec — shared with the worker so provisioning refuses any id
/// the worker's wildcard could not resolve, and `/_cp/route` splits a
/// `{id}.{suffix}` host exactly the way the worker does.
const id_spec = @import("rove-instance-id");
const origin_mod = @import("rove-origin");
const Directory = directory_mod.Directory;
const bridge_mod = @import("bridge");
const Bridge = bridge_mod.Bridge;
const acme_issuer = @import("acme.zig");
const MetricsServer = @import("metrics-server").MetricsServer;

const CpH2 = h2.H2(.{});

/// Constant-time byte-slice equality for secret comparison: the
/// compare time depends only on the (non-secret) length, never on how
/// many leading bytes matched — so a timing signal can't be used to
/// brute-force the secret one byte at a time. Mirrors the root-token
/// check in `rove-tenant`'s `authenticate`.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

// ── Signal-driven shutdown ────────────────────────────────────────────
var stop_flag: std.atomic.Value(bool) = .init(false);

// SIGINT/SIGTERM → stop_flag wiring lives in rove-boot (shared by all four binaries).

// ── Multi-node CP (HA) config ─────────────────────────────────────────

/// Parsed multi-node CP bridge config — the shared
/// `consensus/cluster_config.zig` parser under the CP's `REWIND_CP_` env
/// prefix (`REWIND_CP_NODE_ID` / `REWIND_CP_VOTERS` / `REWIND_CP_PEERS`;
/// the directory raft group spans these nodes, and the raft ports are
/// distinct from the HTTP listen port, argv[1]). `null` = single-node CP.
const CpMultiNode = bridge_mod.cluster_config.MultiNode;

fn parseCpMultiNode(a: std.mem.Allocator) !?CpMultiNode {
    return bridge_mod.cluster_config.fromEnv(a, "REWIND_CP_");
}

// The domain index (host → tenant) lives in the replicated `__directory__`
// group (`directory.zig` `hosts` projection + `host/{host}` keys), so it
// survives a CP restart, spans the HA nodes, and accepts runtime custom-domain
// provisioning via the `/_control/host` control write. The static `REWIND_HOSTS`
// env is seeded INTO the directory (see `main`).

// ── Header lookup over h2 ReqHeaders ──────────────────────────────────
fn headerValue(rh: h2.ReqHeaders, name: []const u8) ?[]const u8 {
    const fields = rh.fields orelse return null;
    var i: u32 = 0;
    while (i < rh.count) : (i += 1) {
        const f = fields[i];
        const fname = f.name[0..f.name_len];
        if (std.ascii.eqlIgnoreCase(fname, name)) {
            return f.value[0..f.value_len];
        }
    }
    return null;
}

fn methodFrom(s: []const u8) ?curl.Method {
    if (std.mem.eql(u8, s, "GET")) return .GET;
    if (std.mem.eql(u8, s, "PUT")) return .PUT;
    if (std.mem.eql(u8, s, "POST")) return .POST;
    if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
    if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
    return null;
}

/// Carries a tenant's opaque plan blob on `v2-attach` (delivery rides the move
/// handshake) and `v2-plan` (live push). See the CP operational-state model
/// (docs/architecture/control-plane.md).

const Router = struct {
    allocator: std.mem.Allocator,
    directory: *Directory,
    /// Shared secret presented to backends' `/_system/v2-*` move surface,
    /// and required (via `X-Rewind-Move-Secret`) on `/_control/move`.
    /// Null disables the move control surface (503).
    move_secret: ?[]const u8,
    /// HTTP origins of the CP nodes (HA), for forwarding a directory WRITE
    /// (`/_control/*`) when this node is not the directory group leader.
    /// Empty for a single-node CP (this node always leads). `REWIND_CP_PEER_URLS`,
    /// indexed by CP node id − 1 (same convention as `REWIND_CP_PEERS`).
    /// Borrowed; owned by `main`.
    cp_peer_urls: []const []const u8 = &.{},
    /// This node's own index into `cp_peer_urls` (= CP node id − 1), so the
    /// leader probe NEVER calls its own `/_cp/leader`: that is a synchronous
    /// self-call from the poll loop (which is busy making the call), so it
    /// can't be served and hangs until the request timeout. Null for a
    /// single-node CP (no forwarding).
    self_cp_idx: ?usize = null,
    /// The leader-elected ACME issuer, or null when
    /// `REWIND_ACME_DIRECTORY` is unset. Serves `/_cp/acme-challenge?token=`
    /// from its in-memory challenge store.
    acme: ?*acme_issuer.Handle = null,
    /// S3 connection params on the RAW `S3_KEY_PREFIX_BASE`, i.e. OUTSIDE the
    /// storage-namespace generation. That is deliberate and belongs to the
    /// certificate mirror only: certs must survive a cold re-genesis, which
    /// is precisely a generation bump. Null when the CP has no S3 configured.
    ///
    /// NOT for the teardown sweep — tenant objects live INSIDE the
    /// generation, so sweeping this prefix deletes nothing (rove#606). Use
    /// `sweep_cfg`.
    blob_cfg: ?blob.BackendConfig = null,

    /// S3 connection params scoped to the object store's resolved storage
    /// generation — the key space workers and the log-server actually write
    /// tenant objects into. THE config the deprovision sweep must use.
    ///
    /// Null when the CP could not resolve the generation (no S3 configured,
    /// marker missing, store unreachable). A null here never degrades into
    /// sweeping `blob_cfg` instead: a sweep of the wrong prefix deletes
    /// nothing while reporting a clean teardown, which is strictly worse
    /// than refusing, because it also drops the incarnation that was the
    /// only way to name the orphans afterwards (rove#606).
    sweep_cfg: ?blob.BackendConfig = null,

    /// Opt-in: run the additive membership reconciler each reconcile tick
    /// (`REWIND_CP_RECONCILE_MEMBERSHIP=1`). OFF by default — a continuous
    /// unattended actor on prod must be deliberately enabled.
    reconcile_membership: bool = false,

    /// The platform zone customer tenants auto-route under
    /// (`REWIND_PUBLIC_SUFFIX`, e.g. `rewindjs.app`): `/_cp/route` resolves
    /// `{tenant}.{public_suffix}` to that tenant with no stored alias, and
    /// provisioning reports the resulting URL. Empty disables the wildcard —
    /// every host then needs an explicit `/_control/host` mapping. MUST match
    /// the workers' `REWIND_PUBLIC_SUFFIX`: the front door resolves the host
    /// here and the worker resolves it again locally, so a mismatch routes a
    /// request to a cluster whose worker then 404s it.
    public_suffix: []const u8 = "",

    /// RC-6 demote hysteresis. A reconciler demote-to-learner of a voter judged
    /// `!recent_active` must require SUSTAINED inactivity, never a single reading:
    /// a rolling deploy makes a HEALTHY voter transiently unreachable for the
    /// length of its restart, and a one-shot demote would tear that voter out of
    /// the config — shrinking the voter set and enabling sub-majority commit
    /// (RC-1's trigger by another route). A demote candidate's FIRST
    /// `!recent_active` observation starts a timer (keyed `tenant|node_id`); the
    /// demote fires only after it has stayed inactive for `demote_grace_ns`. Any
    /// other observed state (responsive again, or no longer a hosted voter) clears
    /// the timer, so a long-ago transient never carries into a later window.
    /// Tunable via `REWIND_CP_DEMOTE_GRACE_MS` (default 60s — comfortably longer
    /// than a worker restart + group recover).
    demote_grace_ns: i128 = 60 * std.time.ns_per_s,
    demote_inactive_since: std.StringHashMapUnmanaged(i128) = .empty,

    /// CP action counters for `/metrics`. The reconciler (which writes these)
    /// and the metrics render (which reads them) both run on the CP main loop,
    /// so plain fields suffice — no atomics; the MetricsServer listener thread
    /// only ever serves the already-rendered byte snapshot. `confchange_failed`
    /// is the reconciler-wedge signal: a conf-change the leader can't commit
    /// (the `__admin__`-stuck-at-{1,2} grow) is re-proposed every pass, so a
    /// climbing failed-count with membership not advancing is the incident.
    reconcile_passes: u64 = 0,
    confchange_total: u64 = 0,
    confchange_failed: u64 = 0,

    /// Creation-velocity guard over `/_control/provision` (the rate half of
    /// the signup-velocity control — ten tenants over a year and ten in a
    /// minute are different events even at the same total). One coarse
    /// token bucket for the whole door: per-identity totals belong to the
    /// dashboard's plan-derived allowances, but a bulk-creation flood —
    /// each tenant costing a raft group ×3 nodes, an LMDB env, a placement,
    /// and an S3 prefix — is bounded HERE, behind whatever identity the
    /// caller presents. Leader-gated door ⇒ the leader's bucket is
    /// authoritative. Plain fields (main-loop only, like the counters).
    provision_tokens: f64 = PROVISION_BURST,
    provision_last_refill_ns: i64 = 0,
    provision_limited: u64 = 0,

    /// Burst: enough for a demo/test session's worth of creates in quick
    /// succession.
    const PROVISION_BURST: f64 = 10.0;
    /// Sustained: one create per 30s (~2.9k/day) — far above any organic
    /// signup curve the funnel could produce at launch, far below a flood.
    const PROVISION_REFILL_PER_SEC: f64 = 1.0 / 30.0;

    /// Take one provision token (refilling first). Main-loop only.
    fn provisionTokenTake(self: *Router) bool {
        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        if (self.provision_last_refill_ns != 0) {
            const elapsed_s = @as(f64, @floatFromInt(now_ns - self.provision_last_refill_ns)) /
                @as(f64, std.time.ns_per_s);
            self.provision_tokens = @min(PROVISION_BURST, self.provision_tokens + elapsed_s * PROVISION_REFILL_PER_SEC);
        }
        self.provision_last_refill_ns = now_ns;
        if (self.provision_tokens >= 1.0) {
            self.provision_tokens -= 1.0;
            return true;
        }
        return false;
    }

    /// Reply helper: set an immediate status (no body) on the request
    /// entity and move it to response_in.
    fn replyStatus(server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, code: u16) !void {
        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = code });
        try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
        try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = null, .len = 0 });
        try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
        try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
        try server.reg.set(ent, &server.request_out, h2.Session, sess);
        try server.reg.move(ent, &server.request_out, &server.response_in);
    }

    /// Reply with a status + owned text body (`msg` is freed by the
    /// registry via `RespBody.deinit`).
    fn replyText(server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, code: u16, msg: []u8) !void {
        try server.reg.set(ent, &server.request_out, h2.Status, .{ .code = code });
        try server.reg.set(ent, &server.request_out, h2.RespHeaders, .{ .fields = null, .count = 0 });
        try server.reg.set(ent, &server.request_out, h2.RespBody, .{ .data = msg.ptr, .len = @intCast(msg.len) });
        try server.reg.set(ent, &server.request_out, h2.H2IoResult, .{ .err = 0 });
        try server.reg.set(ent, &server.request_out, h2.StreamId, sid);
        try server.reg.set(ent, &server.request_out, h2.Session, sess);
        try server.reg.move(ent, &server.request_out, &server.response_in);
    }

    /// The CP serves ONLY its control surface — `/_control/*` (move
    /// orchestration) and `/_cp/*` (route lookup + leader probe). Customer
    /// traffic never reaches here (it goes to `rewind-front` → DP); any other
    /// path 404s.
    fn processRequests(self: *Router, server: *CpH2) !void {
        const entities = server.request_out.entitySlice();
        const sids = server.request_out.column(h2.StreamId);
        const sessions = server.request_out.column(h2.Session);
        const req_hdrs = server.request_out.column(h2.ReqHeaders);
        const req_bodies = server.request_out.column(h2.ReqBody);

        for (entities, sids, sessions, req_hdrs, req_bodies) |ent, sid, sess, rh, rb| {
            const req_path = headerValue(rh, ":path") orelse "/";

            // `/_control/move` is handled by the CP itself (the move
            // orchestrator), not proxied: it owns the directory, so the
            // move's directory flip is its atomic commit point.
            if (std.mem.startsWith(u8, req_path, "/_control/")) {
                try self.handleControl(server, ent, sid, sess, rh, rb, req_path);
                continue;
            }

            // `/_cp/route?host=H` — the authoritative owner lookup the
            // front door (routing) and DP clusters (serve-or-forward)
            // consult; `/_cp/leader` — directory-group leader probe.
            if (std.mem.startsWith(u8, req_path, "/_cp/")) {
                try self.handleCp(server, ent, sid, sess, req_path);
                continue;
            }

            try replyStatus(server, ent, sid, sess, 404);
        }
    }

    // ── Control plane: owner lookup (routing + serve-or-forward) ──────

    /// `GET /_cp/route?host=H` — return the cluster that currently owns the
    /// tenant for `H`, as JSON `{cluster, tenant, nodes:[…]}`, or 404
    /// if the host maps to no tenant / the tenant is unplaced. The front door
    /// caches this for routing; a DP cluster that can't serve a request
    /// locally consults it and forwards to the owner (serve-or-forward) — so a
    /// stale route costs an extra hop, never a failure. No auth: it leaks only
    /// placement (host→cluster), which the public proxy config already
    /// encodes.
    fn handleCp(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, path: []const u8) !void {
        // `/_cp/leader` — 200 iff THIS CP node leads the directory raft group
        // (so directory WRITES can commit here), else 503. A follower CP node
        // uses this to discover the leader to forward a `/_control/*` write to;
        // a single-node CP always answers 200.
        if (std.mem.startsWith(u8, path, "/_cp/leader")) {
            try replyStatus(server, ent, sid, sess, if (self.directory.isLeader()) 200 else 503);
            return;
        }
        if (std.mem.startsWith(u8, path, "/_cp/plan")) {
            try self.handleCpPlan(server, ent, sid, sess, path);
            return;
        }
        if (std.mem.startsWith(u8, path, "/_cp/acme-challenge")) {
            try self.handleCpAcmeChallenge(server, ent, sid, sess, path);
            return;
        }
        if (std.mem.startsWith(u8, path, "/_cp/certs")) {
            try self.handleCpCerts(server, ent, sid, sess);
            return;
        }
        if (std.mem.startsWith(u8, path, "/_cp/cert")) {
            try self.handleCpCert(server, ent, sid, sess, path);
            return;
        }
        if (!std.mem.startsWith(u8, path, "/_cp/route")) {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        }
        const host = queryParam(path, "host") orelse {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        const a = self.allocator;
        // Domain index: host → tenant from the replicated directory.
        // Owned copy (a host's tenant can be replaced by a concurrent apply,
        // and `resolve` re-takes the directory mutex), freed after we resolve.
        const mapped = self.directory.hostTenantForOwned(a, host) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        // No stored alias → the wildcard: `{tenant}.{public_suffix}` belongs to
        // the tenant of that name. The worker applies the same rule to the
        // proxied Host (`rove-instance-id`'s `wildcardLabel`), so the two hops
        // agree by construction; deriving it here means a self-serve tenant is
        // routable the moment it is placed, with no per-tenant host row to
        // write, retry, or leave dangling. An explicit alias still wins — it is
        // consulted first.
        const tenant = mapped orelse blk: {
            const label = id_spec.wildcardLabel(host, self.public_suffix) orelse {
                try replyStatus(server, ent, sid, sess, 404);
                return;
            };
            // A label that could never BE a tenant (uppercase, too long, a
            // reserved platform label) is a 404 here rather than a directory
            // lookup for a name provisioning would have refused.
            if (!id_spec.isValid(label)) {
                try replyStatus(server, ent, sid, sess, 404);
                return;
            }
            break :blk a.dupe(u8, label) catch {
                try replyStatus(server, ent, sid, sess, 500);
                return;
            };
        };
        defer a.free(tenant);
        var resolution = (self.directory.resolve(a, tenant) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        }) orelse {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        };
        defer resolution.deinit(a);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(a);
        const w = buf.writer(a);
        try w.print("{{\"cluster\":\"{s}\",\"tenant\":\"{s}\",\"nodes\":[", .{ resolution.id, tenant });
        for (resolution.nodes, 0..) |n, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("\"{s}\"", .{n});
        }
        try w.writeAll("]");
        // A suspended tenant still RESOLVES (placement is untouched — that's
        // what makes suspension reversible), but the front door must answer
        // 403 instead of proxying. Carried on the route rather than a
        // separate lookup so the front's route cache holds the whole answer.
        if (self.directory.isSuspended(tenant)) try w.writeAll(",\"suspended\":true");
        try w.writeAll("}");
        const owned = try buf.toOwnedSlice(a);
        try replyText(server, ent, sid, sess, 200, owned);
    }

    /// `GET /_cp/plan?tenant=T` — the tenant's opaque plan/limits blob (200 +
    /// the raw value), or 404 if unset (the DP treats absent as the free tier).
    /// The DP reads this to resolve effective limits; placement-independent, so
    /// it's keyed on the tenant, not the host. No auth (same trust as
    /// `/_cp/route` — an internal CP read over the private network).
    fn handleCpPlan(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, path: []const u8) !void {
        const tenant = queryParam(path, "tenant") orelse {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        const a = self.allocator;
        const plan = (self.directory.planForOwned(a, tenant) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        }) orelse {
            try replyStatus(server, ent, sid, sess, 404); // unset → free tier
            return;
        };
        // `plan` is owned; replyText hands it to the registry (RespBody.deinit).
        try replyText(server, ent, sid, sess, 200, plan);
    }

    /// `GET /_cp/cert?host=H` — the host's packed TLS cert+key frame
    /// (`[1B version][4B cert_len][cert][key]`, application/octet-stream;
    /// served verbatim — the front door unpacks), or 404 if no
    /// cert is stored (the front door then SNI-falls-back to the platform
    /// wildcard / refuses). The stateless front-door pool pulls this for SNI
    /// termination. No auth: it serves only over the private CP
    /// network, same trust as `/_cp/route`. (The PRIVATE key crosses this hop —
    /// it must stay on the private network; production fronts the CP with the
    /// same network boundary as `/_cp/route`.)
    fn handleCpCert(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, path: []const u8) !void {
        const host = queryParam(path, "host") orelse {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        const a = self.allocator;
        const packed_bytes = (self.directory.certForOwned(a, host) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        }) orelse {
            try replyStatus(server, ent, sid, sess, 404); // no cert for this host
            return;
        };
        // `replyText` serves arbitrary owned bytes (data/len) — the packed
        // frame is binary, but the front door reads it by length, not type.
        try replyText(server, ent, sid, sess, 200, packed_bytes);
    }

    /// `GET /_cp/acme-challenge?token=T` — the HTTP-01 key-authorization for an
    /// in-flight challenge token, served from the issuer's in-memory store. The
    /// front door's `:80` listener forwards
    /// `/.well-known/acme-challenge/<token>` here so the ACME CA's validation
    /// reaches the leader that published the token. 404 when no issuer is
    /// running or the token isn't published (the correct "no challenge" answer).
    fn handleCpAcmeChallenge(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, path: []const u8) !void {
        const token = queryParam(path, "token") orelse {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        const issuer = self.acme orelse {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        };
        const keyauth = issuer.challengeFor(self.allocator, token) orelse {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        };
        try replyText(server, ent, sid, sess, 200, keyauth);
    }

    /// `GET /_cp/certs` — newline-separated list of hosts that have a stored
    /// cert. The front door polls this, then pulls each host's frame via
    /// `/_cp/cert?host=` into its SNI store (the SNI handshake callback can't
    /// block on a fetch, so certs are synced proactively, not lazily).
    fn handleCpCerts(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session) !void {
        const a = self.allocator;
        const hosts = self.directory.certHostsOwned(a) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        defer {
            for (hosts) |h| a.free(h);
            a.free(hosts);
        }
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(a);
        for (hosts) |h| {
            buf.appendSlice(a, h) catch {
                try replyStatus(server, ent, sid, sess, 500);
                return;
            };
            buf.append(a, '\n') catch {};
        }
        const owned = buf.toOwnedSlice(a) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        try replyText(server, ent, sid, sess, 200, owned);
    }

    // ── Control plane: tenant-move orchestration ─────────────────────

    /// Route + auth a `/_control/*` request. `POST /_control/move` (brief
    /// pause) and `POST /_control/move-live` (zero-downtime) exist; both
    /// require the move secret (`X-Rewind-Move-Secret`).
    fn handleControl(
        self: *Router,
        server: *CpH2,
        ent: rove.Entity,
        sid: h2.StreamId,
        sess: h2.Session,
        rh: h2.ReqHeaders,
        rb: h2.ReqBody,
        path: []const u8,
    ) !void {
        const method_s = headerValue(rh, ":method") orelse "GET";
        const is_move = std.mem.eql(u8, path, "/_control/move");
        const is_move_live = std.mem.eql(u8, path, "/_control/move-live");
        const is_provision = std.mem.eql(u8, path, "/_control/provision");
        const is_plan = std.mem.eql(u8, path, "/_control/plan");
        const is_host = std.mem.eql(u8, path, "/_control/host");
        const is_cert = std.mem.eql(u8, path, "/_control/cert");
        const is_cluster = std.mem.eql(u8, path, "/_control/cluster");
        const is_node_addr = std.mem.eql(u8, path, "/_control/node-address");
        const is_delete = std.mem.eql(u8, path, "/_control/delete");
        const is_suspend = std.mem.eql(u8, path, "/_control/suspend");
        const is_unsuspend = std.mem.eql(u8, path, "/_control/unsuspend");
        if (!(is_move or is_move_live or is_provision or is_plan or is_host or is_cert or is_cluster or is_node_addr or is_delete or is_suspend or is_unsuspend) or !std.mem.eql(u8, method_s, "POST")) {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        }
        const secret = self.move_secret orelse {
            try replyStatus(server, ent, sid, sess, 503); // move surface disabled
            return;
        };
        const presented = headerValue(rh, MOVE_SECRET_HEADER) orelse "";
        if (!constantTimeEql(presented, secret)) {
            try replyStatus(server, ent, sid, sess, 401);
            return;
        }

        // Multi-node CP (HA): the move flips the directory, which only commits
        // on the directory-group LEADER. If this CP node is a follower, forward
        // the whole control request to the CP leader and relay its response —
        // so an operator can target any CP node. (Single-node CP always leads;
        // `cp_peer_urls` is empty → handle locally.)
        if (self.cp_peer_urls.len > 0 and !self.directory.isLeader()) {
            try self.forwardControlToLeader(server, ent, sid, sess, rh, rb, path);
            return;
        }

        const body: []const u8 = if (rb.data) |d| d[0..rb.len] else &.{};
        if (is_plan)
            try self.handlePlan(server, ent, sid, sess, body)
        else if (is_host)
            try self.handleHost(server, ent, sid, sess, body)
        else if (is_cert)
            try self.handleCert(server, ent, sid, sess, body)
        else if (is_cluster)
            try self.handleCluster(server, ent, sid, sess, body)
        else if (is_node_addr)
            try self.handleNodeAddress(server, ent, sid, sess, body)
        else if (is_provision)
            try self.handleProvision(server, ent, sid, sess, body)
        else if (is_delete)
            try self.handleDelete(server, ent, sid, sess, body)
        else if (is_suspend)
            try self.handleSuspend(server, ent, sid, sess, body)
        else if (is_unsuspend)
            try self.handleUnsuspend(server, ent, sid, sess, body)
        else
            // `move` and `move-live` name the SAME (zero-downtime) move; both
            // route names are accepted so callers can use either.
            try self.handleMoveLive(server, ent, sid, sess, body);
    }

    /// `POST /_control/cluster {id, nodes:[url,…]}` — define/update a cluster's
    /// node set (the runtime "grow" primitive: add a node to a cluster so the
    /// membership reconciler backfills the placed tenants onto it). A directory
    /// WRITE: leader-gated (a follower already forwarded above), replicated via
    /// `addCluster`. Idempotent — re-defining with the same nodes is a no-op
    /// apply. NOTE: node identity is currently positional (`nodes[i]` ↔ raft id
    /// i+1), matching `REWIND_VOTERS`; the explicit-id model is the SSOT cleanup.
    fn handleCluster(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            id: []const u8,
            nodes: []const []const u8,
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        if (parsed.value.id.len == 0 or parsed.value.nodes.len == 0) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }
        // Same gate the static seed applies: an origin the front door cannot
        // dial must not enter the directory, whichever door it arrives
        // through. Rejecting here costs a 400; accepting it costs a cluster
        // that resolves but never serves.
        for (parsed.value.nodes) |node| {
            _ = origin_mod.parse(node) catch |e| {
                std.log.err(
                    "rewind-cp: /_control/cluster {s}: origin `{s}` is not dialable ({s}) — " ++
                        "node origins must be `ip:port` IP literals",
                    .{ parsed.value.id, node, @errorName(e) },
                );
                try replyStatus(server, ent, sid, sess, 400);
                return;
            };
        }
        self.directory.addCluster(parsed.value.id, parsed.value.nodes) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        std.log.info("rewind-cp: cluster {s} set to {d} node(s)", .{ parsed.value.id, parsed.value.nodes.len });
        try replyStatus(server, ent, sid, sess, 204);
    }

    /// `POST /_control/node-address {cluster, id, raft_addr, cp_raft_addr?,
    /// http_url?}` — register a node's transport addresses in the directory
    /// node-address registry (docs/architecture/consensus-and-storage.md "Cluster genesis &
    /// membership", node-address registry). The explicit
    /// raft id → address binding that replaces the static positional
    /// `REWIND_PEERS`; the peer resolver reads it so a node configured with only
    /// its own identity can dial its peers. A directory WRITE: leader-gated (a
    /// follower already forwarded above), replicated via `setNodeAddr`.
    /// Idempotent on (cluster, id) — a repeat re-registers (re-IP).
    fn handleNodeAddress(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            cluster: []const u8,
            id: u64,
            raft_addr: []const u8,
            cp_raft_addr: []const u8 = "",
            http_url: []const u8 = "",
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        const v = parsed.value;
        self.directory.setNodeAddr(v.cluster, v.id, v.raft_addr, v.cp_raft_addr, v.http_url) catch |err| {
            // BadConfig (empty cluster/raft_addr, id 0, bad chars) → 400;
            // replication/other → 500.
            const code: u16 = if (err == error.BadConfig) 400 else 500;
            try replyStatus(server, ent, sid, sess, code);
            return;
        };
        std.log.info("rewind-cp: node-address {s}/{d} → {s}", .{ v.cluster, v.id, v.raft_addr });
        try replyStatus(server, ent, sid, sess, 204);
    }

    /// `POST /_control/provision {tenant, cluster?, host?}` — stand up a
    /// brand-new tenant: form its raft group on EVERY node of
    /// `cluster` via an empty-attach (no bundle — the multi-node formation path
    /// that needs no move), await the group's election, then write the
    /// placement (the commit point that makes it routable), and optionally map
    /// `host`→tenant. Create-only: 409 if the tenant is already placed (use
    /// `/_control/move` to relocate); 400 for an unknown cluster or an id the
    /// spec refuses. On a formation failure the freshly-formed groups are
    /// evicted, so a failed provision is a no-op.
    ///
    /// This is the chokepoint EVERY provisioner goes through — the operator
    /// CLI, the dashboard's self-serve signup, and any future API — so the id
    /// spec is enforced here rather than in each caller. It is the only place
    /// that can see the whole rule: an id must be a legal DNS label because it
    /// becomes `{id}.{public_suffix}`, and must not claim a platform label.
    ///
    /// `cluster` is optional when exactly one is configured — a customer has no
    /// basis to choose one, and inventing a default when there IS a choice
    /// would be a placement policy decided by omission.
    ///
    /// 200 with `{tenant, cluster, host}` on success — `host` is where the
    /// tenant now answers, so a caller that does not carry the platform's zone
    /// in its own config (the dashboard) learns the URL from the party that
    /// decided it, rather than re-deriving it from state it would have to be
    /// told separately and could get wrong.
    ///
    /// A refusal carries `{"error": reason}`: this endpoint is the only place
    /// that knows WHICH rule an id broke, and the dashboard puts that sentence
    /// in front of the customer.
    fn handleProvision(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            tenant: []const u8,
            cluster: []const u8 = "",
            host: ?[]const u8 = null,
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try self.replyProvisionError(server, ent, sid, sess, 400, "malformed request body");
            return;
        };
        defer parsed.deinit();
        const tenant = parsed.value.tenant;
        // The id spec, in the customer's words — a bare 400 leaves the
        // dashboard guessing which of five rules the name broke.
        if (id_spec.check(tenant)) |reject| {
            try self.replyProvisionError(server, ent, sid, sess, 400, reject.message());
            return;
        }

        // Create-only — provisioning an already-placed tenant is a 409 (its
        // group already exists; relocate via `/_control/move`).
        if (self.directory.isPlaced(tenant)) {
            try self.replyProvisionError(server, ent, sid, sess, 409, "that name is taken");
            return;
        }

        // Creation-velocity guard (see `provisionTokenTake`). After the
        // cheap validation/409 reads — only a request that would actually
        // create a group consumes a token — and before any expensive work.
        if (!self.provisionTokenTake()) {
            self.provision_limited += 1;
            std.log.warn("rewind-cp: provision velocity guard tripped (requested: {s})", .{tenant});
            try self.replyProvisionError(server, ent, sid, sess, 429, "tenant creation is rate limited — retry in a minute");
            return;
        }
        // OWNED (rove#100): `nodes` is held across attachToAll → awaitDestLeader
        // → evictAll → pushDomainToNodes, every one of them a blocking HTTP
        // fan-out. A projection-aliased slice would be freed under us by a
        // concurrent `/_control/cluster` re-address on the pump thread.
        var cluster_ref: directory_mod.Directory.OwnedCluster = blk: {
            if (parsed.value.cluster.len > 0) {
                break :blk (self.directory.clusterById(a, parsed.value.cluster) catch {
                    try replyStatus(server, ent, sid, sess, 500);
                    return;
                }) orelse {
                    try self.replyProvisionError(server, ent, sid, sess, 400, "unknown cluster");
                    return;
                };
            }
            break :blk (self.directory.soleCluster(a) catch {
                try replyStatus(server, ent, sid, sess, 500);
                return;
            }) orelse {
                try self.replyProvisionError(server, ent, sid, sess, 400, "cluster is required (more than one is configured)");
                return;
            };
        };
        defer cluster_ref.deinit(a);
        const cluster = cluster_ref.id;
        const nodes = cluster_ref.nodes;

        // A failed provision ENDS this tenant lifetime, so the rollback
        // shreds too. Leaving the keyring behind would be worse than
        // untidy: the name is free again, and a later tenant taking it
        // would find a keyring from the previous lifetime on some nodes
        // and not others.
        const tbody = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\",\"shred\":true}}", .{tenant}) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        defer a.free(tbody);

        // 1. Form the group. TWO births, by whether a membership reconciler is
        //    present to GROW a single-voter group:
        //
        //    - Genesis §2d (born-{self}+grow, when `reconcile_membership`): birth
        //      the group as the SOLE voter `{1}` on the FIRST node ONLY. A
        //      born-`{self}` group auto-leads immediately (no election race —
        //      sidesteps the cold-multi-election bug that took prod down,
        //      `project_prod_genesis_gap`), and the RC-6 reconciler grows it to
        //      the full node set learner-first over the next passes. This is the
        //      path the genesis smoke validates.
        //    - No reconciler: birth the full node set on EVERY node
        //      (`1,2,…,nodes.len`) — the cold-multi formation for
        //      static-config clusters that have no reconciler to finish a grow.
        //
        //    Either way a new tenant has no plan yet → free tier until
        //    `/_control/plan`. Raft ids are positional (node i ↔ id i+1).
        const grow = self.reconcile_membership;
        const birth_nodes: []const []const u8 = if (grow) nodes[0..1] else nodes;
        const birth_voters = (if (grow) a.dupe(u64, &.{1}) else move.clusterVoterIds(a, nodes.len)) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        defer a.free(birth_voters);
        // Mint this tenant LIFETIME's storage incarnation (#357). Random, not a
        // counter: a counter would have to survive the very deletion that
        // destroys the tenant, and losing it would silently re-issue a live
        // storage path. Minted HERE, once, and delivered to every node — a
        // per-node value would key the same tenant's storage differently on
        // each, which is a correctness fault, not just a leak.
        var inc_buf: [16]u8 = undefined;
        var rnd: [8]u8 = undefined;
        std.crypto.random.bytes(&rnd);
        const incarnation = std.fmt.bufPrint(&inc_buf, "{x:0>16}", .{std.mem.readInt(u64, &rnd, .big)}) catch
            return replyStatus(server, ent, sid, sess, 500);

        // Mint this tenant's keyring ROOT SECRET — the HKDF root whose
        // destruction is the C1 shred. Same reasoning as the incarnation
        // above, and one more besides: it is minted here rather than
        // derived from anything, because a DERIVED key cannot be shredded
        // (while its parent exists the child is re-derivable), so there
        // would be nothing whose destruction constitutes erasure.
        //
        // It is never recorded. The directory is a raft group, and a key
        // written to a log stays legible after it is "destroyed" — the
        // exact recursion crypto-shredding exists to avoid. So this is the
        // only moment the CP holds it: minted, delivered to the birth
        // nodes, forgotten. A later joiner gets it from a peer as sealed
        // ciphertext, never from here.
        var secret_raw: [32]u8 = undefined;
        std.crypto.random.bytes(&secret_raw);
        var secret_hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&secret_hex, "{x}", .{&secret_raw}) catch
            return replyStatus(server, ent, sid, sess, 500);
        defer std.crypto.secureZero(u8, &secret_raw);
        defer std.crypto.secureZero(u8, &secret_hex);

        if (!move.attachToAll(self, birth_nodes, tenant, null, birth_voters, incarnation, &secret_hex)) {
            move.evictAll(self, tenant, birth_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 502);
            return;
        }
        // 2. Await the formed group's leader so the first request finds one. A
        //    born-`{self}` group auto-leads, so this returns at once; a born-multi
        //    group waits out its election.
        if (!move.awaitDestLeader(self, birth_nodes, tenant)) {
            move.evictAll(self, tenant, birth_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 504);
            return;
        }
        // 2b. RECORD the incarnation before the placement commits. Every later
        //     attach — a move, a membership backfill, a node rejoining — must
        //     carry it, and the CP is the only party positioned to know it. A
        //     node that attaches without it opens a legacy-keyed store while
        //     the rest of the cluster uses the incarnation-keyed one, and the
        //     tenant's data silently diverges (#357).
        self.directory.setIncarnation(tenant, incarnation) catch |err| {
            std.log.warn("rewind-cp: provision {s}: setIncarnation failed: {s}", .{ tenant, @errorName(err) });
            move.evictAll(self, tenant, birth_nodes, tbody);
            try self.replyProvisionError(server, ent, sid, sess, 500, "could not record the storage incarnation");
            return;
        };

        // 3. Write the placement — the commit point that makes it routable.
        self.directory.assign(tenant, cluster) catch {
            move.evictAll(self, tenant, nodes, tbody);
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        // 4. Optional EXTRA host→tenant mapping. The tenant is already
        //    reachable at `{tenant}.{public_suffix}` via the wildcard the
        //    moment step 3 committed — this is for a custom domain, and only
        //    an operator passes one. It is already provisioned (placed), so a
        //    host write failure is non-fatal; retry via `/_control/host`.
        if (parsed.value.host) |host| {
            if (host.len > 0 and self.hostClaimViolation(host, tenant) == null) {
                self.directory.setHost(host, tenant) catch |err|
                    std.log.warn("rewind-cp: provision {s}: setHost({s}) failed: {s}", .{ tenant, host, @errorName(err) });
                // Also push the worker-side `__root__/domain/{host}` alias to the
                // serving cluster. WITHOUT this the CP resolves host→cluster (front
                // /_cp/route 200) but the WORKER can't map Host→tenant and 404s the
                // request — provision --host left every PRIMARY host unreachable
                // until a manual `host add` (the worker-alias gap). Mirrors
                // `/_control/host`'s push; kept best-effort here (the tenant is
                // already placed — the 204 commit point — so a transient push
                // failure just warns and `/_control/host` re-runs it).
                // Push to `nodes` directly (NOT pushDomainToServingCluster, which
                // re-resolves): the placement was just `assign`ed above and isn't
                // in the local projection yet, so a resolve would return null and
                // the alias would silently never land.
                //
                // Retry briefly: the alias is a leader-gated `__root__` write, and
                // `__root__` on the serving node can be hibernated/leaderless at
                // this instant (its first write since the worker came up) — the
                // worker 421s AND wakes it, so the next attempt lands. Without the
                // retry a cold `__root__` leaves the host unreachable until a
                // manual `host add` (which only worked on prod because `__root__`
                // was already warm). Bounded so a genuinely-down cluster still
                // returns (best-effort: the tenant is placed = the 204 commit).
                var dom_try: u32 = 0;
                const domain_pushed = while (dom_try < 15) : (dom_try += 1) {
                    if (self.pushDomainToNodes(nodes, tenant, host)) break true;
                    std.Thread.sleep(200 * std.time.ns_per_ms);
                } else false;
                if (!domain_pushed)
                    std.log.warn("rewind-cp: provision {s}: v2-domain push for host {s} did not land — retry via `host add {s} {s}`", .{ tenant, host, host, tenant });
            }
        }
        std.log.info("rewind-cp: provisioned {s} on {s} ({d} node(s))", .{ tenant, cluster, nodes.len });

        // Where the tenant answers: the explicitly-mapped custom domain if one
        // was requested, else the wildcard host placement just made live.
        // Empty when neither exists (no `host`, no configured suffix) — the
        // tenant is placed but nothing routes to it, and saying so beats
        // reporting a URL that 404s.
        const primary_host: []const u8 = blk: {
            if (parsed.value.host) |h| {
                if (h.len > 0) break :blk h;
            }
            if (self.public_suffix.len == 0) break :blk "";
            break :blk std.fmt.allocPrint(a, "{s}.{s}", .{ tenant, self.public_suffix }) catch "";
        };
        const msg = std.fmt.allocPrint(
            a,
            "{{\"tenant\":\"{s}\",\"cluster\":\"{s}\",\"host\":\"{s}\"}}",
            .{ tenant, cluster, primary_host },
        ) catch {
            // The provision COMMITTED and only the report failed. 204 also
            // means placed, so the caller must not read this as a failure and
            // retry — it just doesn't learn the URL.
            try replyStatus(server, ent, sid, sess, 204);
            return;
        };
        try replyText(server, ent, sid, sess, 200, msg);
    }

    /// `POST /_control/delete {tenant}` — deprovision: make the tenant
    /// unroutable, withdraw its directory rows, and tear its raft group down on
    /// every node that held it. The inverse of `/_control/provision`.
    ///
    /// ## Order: the directory goes first, and that is load-bearing
    ///
    /// Removing `placement/` is the COMMIT POINT — from that moment the front
    /// door 404s the tenant and its name is free. Eviction follows.
    ///
    /// The opposite order is the trap (#293): evicting first leaves a window
    /// where `placement/` still names a cluster whose nodes no longer hold the
    /// tenant, so the front door routes live traffic at a group that is gone;
    /// and if the directory write then fails, the tenant is left permanently
    /// routable-to-nothing. Placement-first fails the other way — an orphaned
    /// group that nothing routes to, invisible to users and cleared by running
    /// the delete again.
    ///
    /// So every step is idempotent and the whole thing is safe to retry: the
    /// directory removals no-op when already gone, and `v2-evict` no-ops on a
    /// node that no longer has the group.
    ///
    /// 204 on success (including a tenant that was already gone — the caller
    /// asked for it to not exist, and it doesn't). 502 if the directory rows
    /// came out but some node's eviction did not, so the caller knows to retry;
    /// the tenant is already unroutable at that point.
    ///
    /// Step 4 sweeps the tenant's stored objects (`app-blobs/`, `file-blobs/`,
    /// `log-blobs/`, `deployments/`) — nothing else ever removes them, so
    /// without it a deleted tenant bills forever and an account-closure
    /// erasure promise has no code behind it. It runs after eviction (nothing
    /// is still writing) and before the incarnation row is withdrawn (that row
    /// names the prefix). See `storage_sweep.zig`.
    fn handleDelete(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            tenant: []const u8,
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try self.replyProvisionError(server, ent, sid, sess, 400, "malformed request body");
            return;
        };
        defer parsed.deinit();
        const tenant = parsed.value.tenant;
        if (tenant.len == 0) {
            try self.replyProvisionError(server, ent, sid, sess, 400, "tenant is required");
            return;
        }
        // The platform's own singletons are not deprovisionable: deleting
        // `__admin__` would remove the surface that serves this request.
        for (id_spec.RESERVED_INSTANCE_IDS) |r| {
            if (std.mem.eql(u8, tenant, r)) {
                try self.replyProvisionError(server, ent, sid, sess, 403, "that tenant is part of the platform");
                return;
            }
        }

        // Capture the node set BEFORE withdrawing the placement — it is the
        // only record of which nodes hold the group, and step 2 destroys it.
        // An unplaced tenant may still have a group on nodes from a previous
        // partial delete, so fall back to every configured cluster's nodes
        // rather than skipping eviction (that is what makes a retry converge).
        var nodes_owned: ?directory_mod.Directory.OwnedCluster = null;
        defer if (nodes_owned) |*r| r.deinit(a);
        nodes_owned = (self.directory.resolve(a, tenant) catch null) orelse null;

        // The storage incarnation names the tenant's object prefix (#357), and
        // the sweep in step 4 needs it. Read it here alongside the other
        // captures; empty means a legacy, name-keyed layout.
        const inc_owned = self.directory.incarnationForOwned(a, tenant) catch a.dupe(u8, "") catch "";
        defer if (inc_owned.len != 0) a.free(inc_owned);
        const incarnation: ?[]const u8 = if (inc_owned.len == 0) null else inc_owned;

        // Host rows must be collected before removal too — the host index has
        // no reverse direction.
        const hosts = self.directory.hostsForOwned(a, tenant) catch &[_][]u8{};
        defer {
            for (hosts) |h| a.free(h);
            if (hosts.len != 0) a.free(hosts);
        }

        // 1. Withdraw the placement — the commit point. Unroutable from here.
        self.directory.unassign(tenant) catch {
            try self.replyProvisionError(server, ent, sid, sess, 500, "could not withdraw the placement");
            return;
        };
        // 2. The remaining directory rows. Each is idempotent; a failure here
        //    leaves the tenant already-unroutable and the delete retryable.
        for (hosts) |h| {
            self.directory.removeHost(h) catch |err|
                std.log.warn("rewind-cp: delete {s}: removeHost({s}) failed: {s}", .{ tenant, h, @errorName(err) });
            self.directory.removeCert(h) catch |err|
                std.log.warn("rewind-cp: delete {s}: removeCert({s}) failed: {s}", .{ tenant, h, @errorName(err) });
        }
        self.directory.removePlan(tenant) catch |err|
            std.log.warn("rewind-cp: delete {s}: removePlan failed: {s}", .{ tenant, @errorName(err) });
        // A deleted tenant's suspension row must not outlive it — a future
        // tenant reborn under this name starts unsuspended.
        self.directory.removeSuspend(tenant) catch |err|
            std.log.warn("rewind-cp: delete {s}: removeSuspend failed: {s}", .{ tenant, @errorName(err) });
        // The incarnation row is withdrawn LAST, after the object sweep below:
        // it is the handle to the tenant's storage prefix, so dropping it
        // first would strand the objects under a prefix nothing can name
        // again. See `storage_sweep.zig`.

        // 3. Tear the group down on every node that could hold it. `v2-evict`
        //    destroys the raft group AND the instance (its store, its
        //    `instance/{id}` root marker — which is what frees the name — and
        //    its domain aliases).
        // `shred` marks this as the END of the tenant's lifetime, not a
        // change of address: the node destroys its keyring, so every byte
        // it ever sealed goes permanently unreadable. A move's source
        // eviction sends the same request WITHOUT it, because the tenant
        // carries on serving the same data elsewhere.
        //
        // It rides here rather than being inferred at the node, because
        // only the caller knows which of the two this is — and guessing
        // wrong in one direction destroys a live tenant's keys.
        const tbody = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\",\"shred\":true}}", .{tenant}) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        defer a.free(tbody);
        const nodes: []const []const u8 = if (nodes_owned) |r| r.nodes else &.{};
        const all_evicted = move.evictAllChecked(self, tenant, nodes, tbody);

        if (!all_evicted) {
            std.log.warn("rewind-cp: delete {s}: directory rows withdrawn but eviction incomplete — retry the delete", .{tenant});
            try self.replyProvisionError(server, ent, sid, sess, 502, "tenant is unroutable, but its group was not fully torn down — retry");
            return;
        }

        // 4. Delete the tenant's stored objects. AFTER eviction, so no node is
        //    still serving (or writing) the bytes being removed, and BEFORE
        //    the incarnation row goes — that row names the prefix, so a failed
        //    sweep must leave it in place for the retry to find.
        var swept: u64 = 0;
        if (self.sweep_cfg) |cfg| {
            const storage = tenant_mod.TenantStorage{
                .id = tenant,
                .incarnation = if (incarnation) |i| .{ .token = i } else .legacy,
            };
            swept = storage_sweep.deleteTenantObjects(a, cfg, storage) catch {
                try self.replyProvisionError(server, ent, sid, sess, 502, "tenant is torn down, but its stored objects were not fully deleted — retry");
                return;
            };
        } else if (self.blob_cfg != null) {
            // S3 IS configured but the generation never resolved, so we know
            // objects exist and cannot name them. Refusing is the only honest
            // answer: sweeping the un-namespaced prefix would delete nothing
            // and report a clean teardown, and step 5 would then drop the
            // incarnation — the only handle on the orphans (rove#606).
            std.log.warn(
                "rewind-cp: delete {s}: storage generation unresolved — REFUSING to sweep " ++
                    "(a sweep off the raw prefix removes nothing and claims success); " ++
                    "the tenant is torn down but its objects remain — fix the object store and retry",
                .{tenant},
            );
            try self.replyProvisionError(server, ent, sid, sess, 502, "tenant is torn down, but its stored objects were not deleted (storage generation unresolved) — retry");
            return;
        } else {
            // No object store at all (dev / a CP deliberately run without S3):
            // there is nothing to delete, so proceeding is honest. Still said
            // out loud, because a MISconfigured S3 looks identical from here.
            std.log.warn("rewind-cp: delete {s}: no S3 config — stored objects NOT deleted", .{tenant});
        }

        // 5. The incarnation is per-LIFETIME: the next tenant to take this
        //    name must mint a fresh one, never inherit this one. Safe to drop
        //    now — the objects it named are gone, which every path reaching
        //    here has established: swept, or there was no object store. A
        //    path that could NOT sweep returns above rather than falling
        //    through, because this row is the only thing that names the
        //    prefix and dropping it strands the bytes unfindable (rove#606).
        self.directory.removeIncarnation(tenant) catch |err|
            std.log.warn("rewind-cp: delete {s}: removeIncarnation failed: {s}", .{ tenant, @errorName(err) });

        std.log.info(
            "rewind-cp: deleted {s} ({d} node(s), {d} host row(s), {d} object(s))",
            .{ tenant, nodes.len, hosts.len, swept },
        );
        try replyStatus(server, ent, sid, sess, 204);
    }

    /// A `/_control/provision` failure, as `{"error": reason}` — the dashboard
    /// puts the reason straight in front of the customer, so the status alone
    /// is not enough. Falls back to a bare status if the body can't be built.
    fn replyProvisionError(
        self: *Router,
        server: *CpH2,
        ent: rove.Entity,
        sid: h2.StreamId,
        sess: h2.Session,
        code: u16,
        reason: []const u8,
    ) !void {
        const msg = std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{reason}) catch {
            try replyStatus(server, ent, sid, sess, code);
            return;
        };
        try replyText(server, ent, sid, sess, code, msg);
    }

    /// Set a tenant's plan/limits blob: `POST /_control/plan {tenant, plan}`.
    /// `plan` is an opaque string the CP stores verbatim at `plan/{tenant}`
    /// (the DP parses it into effective limits — `docs/architecture/control-plane.md`). A directory
    /// WRITE: leader-gated, so a follower has already forwarded to the leader
    /// by the time we get here.
    fn handlePlan(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            tenant: []const u8,
            plan: []const u8,
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        const tenant = parsed.value.tenant;
        if (tenant.len == 0) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }
        self.directory.setPlan(tenant, parsed.value.plan) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        // Live single-target push: the CP knows the tenant's current placement,
        // so it delivers the new plan to the ONE serving cluster's nodes (which
        // bump their slot's plan generation). Best-effort — the CP is now the
        // durable source of truth; a failed push just means the change rides
        // the tenant's next move/attach. Unplaced tenant → nothing to push.
        self.pushPlanToServingCluster(tenant, parsed.value.plan);
        const msg = std.fmt.allocPrint(a, "plan set for {s}\n", .{tenant}) catch {
            try replyStatus(server, ent, sid, sess, 200);
            return;
        };
        try replyText(server, ent, sid, sess, 200, msg);
    }

    /// Suspend a tenant: `POST /_control/suspend {tenant, reason?}` — the
    /// reversible kill switch behind the AUP (the suspension axis,
    /// docs/architecture/control-plane.md). Writes the replicated
    /// `suspend/{tenant}` record ({reason, at_ms} — who/why/when survives in
    /// the raft log) and live-pushes the state to the serving cluster so
    /// enforcement lands without waiting for a re-attach. Non-destructive by
    /// construction: placement, plan, hosts, and every stored byte are
    /// untouched — `/_control/unsuspend` restores serving exactly.
    /// Deliberately NOT a plan write, so a billing push can never
    /// un-suspend an abuse response. The platform singletons refuse (a
    /// suspended `__admin__` would take down the door that un-suspends).
    fn handleSuspend(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            tenant: []const u8,
            reason: []const u8 = "",
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        const tenant = parsed.value.tenant;
        if (tenant.len == 0) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }
        for (id_spec.RESERVED_INSTANCE_IDS) |r| {
            if (std.mem.eql(u8, tenant, r)) {
                try self.replyProvisionError(server, ent, sid, sess, 403, "that tenant is part of the platform");
                return;
            }
        }
        const record = std.json.Stringify.valueAlloc(a, .{
            .reason = parsed.value.reason,
            .at_ms = std.time.milliTimestamp(),
        }, .{}) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        defer a.free(record);
        self.directory.setSuspend(tenant, record) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        std.log.warn("rewind-cp: SUSPENDED {s} ({s})", .{ tenant, parsed.value.reason });
        // Best-effort live push (mirror of the plan push): the directory row
        // is the durable truth; a failed push means the DP learns on the
        // reconciler's next re-push pass instead.
        self.pushSuspendToServingCluster(tenant, true);
        const msg = std.fmt.allocPrint(a, "suspended {s}\n", .{tenant}) catch {
            try replyStatus(server, ent, sid, sess, 200);
            return;
        };
        try replyText(server, ent, sid, sess, 200, msg);
    }

    /// Reverse a suspension: `POST /_control/unsuspend {tenant}` — delete the
    /// `suspend/{tenant}` row and live-push the cleared state. Idempotent.
    fn handleUnsuspend(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            tenant: []const u8,
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        const tenant = parsed.value.tenant;
        if (tenant.len == 0) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }
        self.directory.removeSuspend(tenant) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        std.log.info("rewind-cp: unsuspended {s}", .{tenant});
        self.pushSuspendToServingCluster(tenant, false);
        const msg = std.fmt.allocPrint(a, "unsuspended {s}\n", .{tenant}) catch {
            try replyStatus(server, ent, sid, sess, 200);
            return;
        };
        try replyText(server, ent, sid, sess, 200, msg);
    }

    /// Reconcile-tick pass: re-push every suspended tenant's state to its
    /// serving cluster (see the call site for why). Leader-only, like every
    /// pass that writes to serving clusters on the directory's authority.
    pub fn repushSuspensions(self: *Router) void {
        if (!self.directory.isLeader()) return;
        const a = self.allocator;
        const ids = self.directory.suspendedTenantsOwned(a) catch return;
        defer {
            for (ids) |id| a.free(id);
            a.free(ids);
        }
        for (ids) |tenant| self.pushSuspendToServingCluster(tenant, true);
    }

    /// Push a tenant's suspension state to its serving cluster's nodes
    /// (`POST /_system/v2-suspend {tenant, suspended}`). Mirror of
    /// `pushPlanToServingCluster`: best-effort, the directory row stays the
    /// durable truth, and the reconciler re-pushes suspended tenants each
    /// pass so a worker restart (which loses the in-memory flag) re-learns
    /// the state within one reconcile interval.
    fn pushSuspendToServingCluster(self: *Router, tenant: []const u8, suspended: bool) void {
        const a = self.allocator;
        var res = (self.directory.resolve(a, tenant) catch return) orelse return; // unplaced
        defer res.deinit(a);
        const payload = std.json.Stringify.valueAlloc(a, .{ .tenant = tenant, .suspended = suspended }, .{}) catch return;
        defer a.free(payload);
        for (res.nodes) |base| {
            if (bc.call(self, base, "/_system/v2-suspend", .POST, payload, &.{})) |resp| {
                var r = resp;
                defer r.deinit(a);
                if (r.status != 204)
                    std.log.warn("rewind-cp: v2-suspend push for {s} on {s} → {d}", .{ tenant, base, r.status });
            } else |err| {
                std.log.warn("rewind-cp: v2-suspend push for {s} on {s} failed: {s}", .{ tenant, base, @errorName(err) });
            }
        }
    }

    /// Map a host to a tenant: `POST /_control/host {host, tenant}` (writes
    /// the replicated domain index). A directory WRITE: leader-gated, so a
    /// follower has already forwarded to the leader by the time we get here.
    /// Routing is a pure CP read (`/_cp/route`), so unlike a plan change there
    /// is nothing to push to a DP — the front door picks up the new mapping on
    /// its next CP route query (subject to its route-cache TTL).
    const HostClaimViolation = struct { code: u16, msg: []const u8 };

    /// The host-claim rules, shared by every door that writes a host row
    /// (`/_control/host` and provision's optional custom host) so
    /// `Directory.setHost` stays the dumb last-write-wins primitive while
    /// the POLICY has one enforcement point:
    ///
    /// 1. First-claim-wins across tenants. A host already mapped to a
    ///    DIFFERENT tenant refuses (409) — a later claim must never take a
    ///    hostname another tenant is serving. Releasing a claim is the
    ///    delete path (or an operator `force` resolving a dispute);
    ///    same-tenant re-claims are idempotent.
    /// 2. The platform zone is identity-bound. `{label}.{public_suffix}`
    ///    belongs to the tenant named `label` by the wildcard route; an
    ///    explicit row aiming it at any other tenant would let one tenant
    ///    impersonate another (or a platform surface — `login.`-shaped
    ///    labels are already unclaimable as tenant ids) on our own zone.
    ///    403; operator `force` is the only escape hatch (platform
    ///    surfaces on the zone).
    ///
    /// Returns the refusal to send, or null when the claim is allowed.
    fn hostClaimViolation(self: *Router, host: []const u8, tenant: []const u8) ?HostClaimViolation {
        if (id_spec.wildcardLabel(host, self.public_suffix)) |label| {
            // The zone rule protects against CUSTOMER impersonation on our
            // own zone. The platform singletons (`__admin__`, `__auth__`, …)
            // ARE the platform — their serving hosts (`app.`, `auth.`, …)
            // are deliberately not their tenant ids, and a customer can
            // never provision a reserved id, so exempting them opens no
            // spoof. First-claim-wins below still applies to them.
            const is_reserved = blk: {
                for (id_spec.RESERVED_INSTANCE_IDS) |r| {
                    if (std.mem.eql(u8, tenant, r)) break :blk true;
                }
                break :blk false;
            };
            if (!is_reserved and !std.mem.eql(u8, label, tenant)) {
                std.log.warn("rewind-cp: host claim refused — {s} is on the platform zone and not tenant {s}'s own label", .{ host, tenant });
                return .{ .code = 403, .msg = "hosts on the platform domain are fixed to the tenant of the same name" };
            }
        }
        const existing = self.directory.hostTenantForOwned(self.allocator, host) catch null;
        if (existing) |owner| {
            defer self.allocator.free(owner);
            if (!std.mem.eql(u8, owner, tenant)) {
                std.log.warn("rewind-cp: host claim refused — {s} is already claimed by {s} (requested by {s})", .{ host, owner, tenant });
                return .{ .code = 409, .msg = "that host is already claimed by another tenant" };
            }
        }
        return null;
    }

    fn handleHost(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            host: []const u8,
            tenant: []const u8,
            /// Operator override for the claim rules below. The customer
            /// door (#291's dashboard path) must never send it.
            force: bool = false,
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        if (parsed.value.host.len == 0 or parsed.value.tenant.len == 0) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }
        if (!parsed.value.force) {
            if (self.hostClaimViolation(parsed.value.host, parsed.value.tenant)) |v| {
                try self.replyProvisionError(server, ent, sid, sess, v.code, v.msg);
                return;
            }
        }
        self.directory.setHost(parsed.value.host, parsed.value.tenant) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        // Propagate the worker-side `__root__/domain/{host}` alias to the
        // tenant's serving cluster (docs/architecture/auth-consolidation.md B3). The CP owns
        // host→tenant, so it pushes the alias the workers need for local
        // custom-host resolution (`resolveDomain`) — no operator-held worker
        // secret is needed. If it didn't land (tenant
        // unplaced, or no reachable leader), the directory mapping still
        // stands; report 503 so the operator re-runs once the tenant is placed.
        if (!self.pushDomainToServingCluster(parsed.value.tenant, parsed.value.host)) {
            try replyStatus(server, ent, sid, sess, 503);
            return;
        }
        const msg = std.fmt.allocPrint(a, "host {s} -> {s}\n", .{ parsed.value.host, parsed.value.tenant }) catch {
            try replyStatus(server, ent, sid, sess, 200);
            return;
        };
        try replyText(server, ent, sid, sess, 200, msg);
    }

    /// Store a host's TLS cert: `POST /_control/cert {host, cert, key}` (PEM
    /// strings) — the operator-brings-their-own-cert path (and, until DNS-01
    /// lands, how the platform wildcard is supplied). The leader-elected ACME
    /// issuer writes the same axis directly via `directory.setCert` (no HTTP
    /// hop). A directory WRITE: leader-gated, so a follower has already
    /// forwarded to the leader by the time we get here.
    fn handleCert(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct {
            host: []const u8,
            cert: []const u8,
            key: []const u8,
        }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        if (parsed.value.host.len == 0 or parsed.value.cert.len == 0 or parsed.value.key.len == 0) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }
        self.directory.setCert(parsed.value.host, parsed.value.cert, parsed.value.key) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        const msg = std.fmt.allocPrint(a, "cert stored for {s}\n", .{parsed.value.host}) catch {
            try replyStatus(server, ent, sid, sess, 200);
            return;
        };
        try replyText(server, ent, sid, sess, 200, msg);
    }

    /// Deliver a tenant's plan blob to its CURRENT serving cluster — a live
    /// `POST /_system/v2-plan {tenant, plan}` to every node of the cluster the
    /// directory resolves the tenant to (the plan cache is per-node slot state,
    /// so fan out like attach). Best-effort: logs per-node failures, never
    /// blocks the control reply on delivery. No-op if the tenant is unplaced
    /// (the plan rides its first attach instead).
    fn pushPlanToServingCluster(self: *Router, tenant: []const u8, plan: []const u8) void {
        const a = self.allocator;
        var res = (self.directory.resolve(a, tenant) catch return) orelse return; // unplaced
        defer res.deinit(a);
        const payload = std.json.Stringify.valueAlloc(a, .{ .tenant = tenant, .plan = plan }, .{}) catch return;
        defer a.free(payload);
        for (res.nodes) |base| {
            if (bc.call(self, base, "/_system/v2-plan", .POST, payload, &.{})) |resp| {
                var r = resp;
                defer r.deinit(a);
                if (r.status != 204)
                    std.log.warn("rewind-cp: v2-plan push for {s} on {s} → {d}", .{ tenant, base, r.status });
            } else |err| {
                std.log.warn("rewind-cp: v2-plan push for {s} on {s} failed: {s}", .{ tenant, base, @errorName(err) });
            }
        }
    }

    /// Push a `host → tenant` worker alias to the tenant's serving cluster: a
    /// `POST /_system/v2-domain {host, tenant}` to the cluster's nodes. The
    /// alias is a leader-gated `__root__` write, so only the group leader
    /// accepts (204) and the rest answer 421 — fan out, succeed on the first
    /// 204. Returns false if the tenant is unplaced or no node took it (the
    /// caller surfaces that). Mirror of `pushPlanToServingCluster`, but GATED
    /// (a half-mapped host must not report success — docs/architecture/auth-consolidation.md B3).
    fn pushDomainToServingCluster(self: *Router, tenant: []const u8, host: []const u8) bool {
        const a = self.allocator;
        var res = (self.directory.resolve(a, tenant) catch return false) orelse return false; // unplaced
        defer res.deinit(a);
        return self.pushDomainToNodes(res.nodes, tenant, host);
    }

    /// Push the `host → tenant` worker alias to an EXPLICIT node set (the
    /// `/_system/v2-domain` POST), leader-gated: first 204 wins, rest 421.
    /// Split out of `pushDomainToServingCluster` so a caller that ALREADY holds
    /// the cluster's nodes can skip the `directory.resolve` lookup. That matters
    /// in `handleProvision`: the placement is `assign`ed and pushed within the
    /// same handler, but `resolve` reads the LOCAL projection which the just-
    /// proposed `assign` hasn't applied yet — so resolve returns null and the
    /// alias silently never lands (the worker then 404s the host until a manual
    /// `host add`). Provision passes its own `nodes` here to dodge that race.
    fn pushDomainToNodes(self: *Router, nodes: []const []const u8, tenant: []const u8, host: []const u8) bool {
        const a = self.allocator;
        const payload = std.json.Stringify.valueAlloc(a, .{ .host = host, .tenant = tenant }, .{}) catch return false;
        defer a.free(payload);
        for (nodes) |base| {
            if (bc.call(self, base, "/_system/v2-domain", .POST, payload, &.{})) |resp| {
                var r = resp;
                defer r.deinit(a);
                if (r.status == 204) return true; // the leader took it
                if (r.status != 421)
                    std.log.warn("rewind-cp: v2-domain push for {s}={s} on {s} → {d}", .{ host, tenant, base, r.status });
            } else |err| {
                std.log.warn("rewind-cp: v2-domain push for {s}={s} on {s} failed: {s}", .{ host, tenant, base, @errorName(err) });
            }
        }
        return false;
    }

    /// Forward a `/_control/*` request to the CP node that currently leads the
    /// directory group (discovered via `/_cp/leader`), relaying its response.
    /// Used when this CP node is a follower (directory writes can't commit
    /// here). 503 if no CP leader is reachable (the client retries).
    fn forwardControlToLeader(
        self: *Router,
        server: *CpH2,
        ent: rove.Entity,
        sid: h2.StreamId,
        sess: h2.Session,
        rh: h2.ReqHeaders,
        rb: h2.ReqBody,
        path: []const u8,
    ) !void {
        const a = self.allocator;
        const leader = self.findCpLeaderUrl() orelse {
            try replyStatus(server, ent, sid, sess, 503); // no CP leader right now
            return;
        };
        defer a.free(leader);
        const method = methodFrom(headerValue(rh, ":method") orelse "POST") orelse .POST;
        const body: []const u8 = if (rb.data) |d| d[0..rb.len] else &.{};
        const resp = bc.call(self, leader, path, method, body, &.{}) catch |err| {
            std.log.warn("rewind-cp: forward control to CP leader {s} failed: {s}", .{ leader, @errorName(err) });
            try replyStatus(server, ent, sid, sess, 502);
            return;
        };
        var r = resp;
        defer r.deinit(a);
        if (r.body.len == 0) {
            try replyStatus(server, ent, sid, sess, @intCast(r.status));
            return;
        }
        const owned = a.dupe(u8, r.body) catch {
            try replyStatus(server, ent, sid, sess, @intCast(r.status));
            return;
        };
        try replyText(server, ent, sid, sess, @intCast(r.status), owned);
    }

    /// Find the CP node currently leading the directory group: try each CP
    /// peer's `/_cp/leader` until one answers 200, returning its URL (owned).
    /// Null if none leads (mid-election / all unreachable).
    fn findCpLeaderUrl(self: *Router) ?[]u8 {
        const a = self.allocator;
        for (self.cp_peer_urls, 0..) |base, i| {
            // Never probe self — a blocking call to our own /_cp/leader from
            // inside the poll loop self-deadlocks (we are the loop, busy here).
            // We are forwarding precisely because we are NOT the leader.
            if (self.self_cp_idx) |self_i| {
                if (i == self_i) continue;
            }
            const resp = bc.call(self, base, "/_cp/leader", .GET, "", &.{}) catch continue;
            const ok = resp.status == 200;
            var r = resp;
            r.deinit(a);
            if (ok) return a.dupe(u8, base) catch null;
        }
        return null;
    }


    // ── Zero-downtime move ───────────────────────────────────────────

    /// Orchestrate a ZERO-DOWNTIME tenant move — the source keeps serving the
    /// whole time; no quiesce, no `moving` hold. Built on slice (b)'s
    /// SYNCHRONOUS forwarding (a source write is acked only after the dest
    /// applies it), so the dest always has every acked write and the snapshot
    /// loads insert-if-absent without clobbering a forwarded (newer) key:
    ///
    ///   1. empty-attach the dest (form group + instance, NO data) on all
    ///      destination nodes — ready to receive forwards.
    ///   2. await the dest group's leader (its URL is the forward target).
    ///   3. forward-begin on the source leader → it dual-writes every commit
    ///      to the dest leader (synchronous).
    ///   4-5. stream the source leader's non-quiescing snapshot peer→peer into
    ///      every dest node in merge mode (insert-if-absent, out-of-band from
    ///      raft) — the CP never buffers the bundle.
    ///   6. flip the directory — the atomic commit point.
    ///   7. evict the source — drops its instance + group + forward marker,
    ///      so it stops serving + forwarding; serve-or-forward routes any
    ///      straggler to the dest.
    ///
    /// A pre-flip failure forward-ends the source (stops dual-writing) +
    /// evicts the half-attached dest, leaving the tenant serving on the
    /// source untouched. The forward target is the full dest node list (leader first) —
    /// the source re-aims past 421s, so a dest-leader change mid-overlap
    /// degrades to a retry hop, not a failed acked write.
    fn handleMoveLive(self: *Router, server: *CpH2, ent: rove.Entity, sid: h2.StreamId, sess: h2.Session, body: []const u8) !void {
        const a = self.allocator;
        var parsed = std.json.parseFromSlice(struct { tenant: []const u8, dest: []const u8 }, a, body, .{ .ignore_unknown_fields = true }) catch {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer parsed.deinit();
        const tenant = parsed.value.tenant;
        const dest = parsed.value.dest;
        if (tenant.len == 0 or dest.len == 0) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }
        // OWNED (rove#100): both node sets are held across the whole
        // attach → await → forward → flip → evict sequence, all blocking HTTP.
        var src = (self.directory.resolve(a, tenant) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        }) orelse {
            try replyStatus(server, ent, sid, sess, 404);
            return;
        };
        defer src.deinit(a);
        if (std.mem.eql(u8, src.id, dest)) {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        }
        var dest_ref = (self.directory.clusterById(a, dest) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        }) orelse {
            try replyStatus(server, ent, sid, sess, 400);
            return;
        };
        defer dest_ref.deinit(a);
        const src_nodes = src.nodes;
        const dest_nodes = dest_ref.nodes;
        const tbody = std.fmt.allocPrint(a, "{{\"tenant\":\"{s}\"}}", .{tenant}) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        defer a.free(tbody);

        // 1. Empty-attach the dest (no bundle → just the group + instance).
        //    The plan blob (if any) rides attach so the dest enforces limits
        //    from the first forwarded write onward.
        const plan_blob = self.directory.planForOwned(a, tenant) catch null;
        defer if (plan_blob) |p| a.free(p);
        // The tenant's recorded incarnation rides the move, so the destination
        // opens the SAME store the source used (#357). An unreadable record
        // fails the move loudly — guessing "legacy" would re-key the tenant.
        const move_inc = self.directory.incarnationForOwned(a, tenant) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        defer a.free(move_inc);
        // No secret: a move re-homes an EXISTING tenant, whose keyring
        // reaches the destination as KEK-sealed ciphertext from a peer.
        // Minting a fresh one here would strand every byte the old key
        // sealed, which is data loss wearing the shape of a provisioning
        // step.
        if (!move.attachToAll(self, dest_nodes, tenant, plan_blob, null, move_inc, null)) {
            move.evictAll(self, tenant, dest_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 502);
            return;
        }
        // 2. Await the dest leader; the source's forward target is the FULL
        //    dest node list, leader first — the source tries it in order and
        //    re-aims past 421s, so a dest leader change mid-overlap costs a
        //    retry hop instead of failing acked source writes.
        const dest_leader = move.findDestLeaderUrl(self, dest_nodes, tenant) orelse {
            move.evictAll(self, tenant, dest_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 504);
            return;
        };
        defer a.free(dest_leader);
        const fwd_targets = move.csvLeaderFirst(a, dest_leader, dest_nodes) orelse {
            move.evictAll(self, tenant, dest_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };
        defer a.free(fwd_targets);

        // 3. forward-begin on the source leader (dual-write to the dest).
        if (!move.forwardBeginOnLeader(self, src_nodes, tenant, fwd_targets)) {
            move.evictAll(self, tenant, dest_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 502);
            return;
        }

        // 4+5. Stream the source leader's non-quiescing snapshot directly to
        //      every dest node in merge mode (insert-if-absent). The source
        //      pushes peer→peer; the CP never buffers the bundle, so a
        //      multi-GB tenant moves with bounded memory on all three parties.
        if (!move.streamMergeToAll(self, src_nodes, dest_nodes, tenant)) {
            move.forwardEndOnLeader(self, src_nodes, tenant);
            move.evictAll(self, tenant, dest_nodes, tbody);
            try replyStatus(server, ent, sid, sess, 502);
            return;
        }

        // 6. Flip the directory — the atomic commit point.
        self.directory.move(tenant, dest) catch {
            try replyStatus(server, ent, sid, sess, 500);
            return;
        };

        // 7. Evict the source (drops instance + group + forward marker → it
        //    stops serving + forwarding; serve-or-forward routes stragglers
        //    to the dest). Evict subsumes forward-end on the happy path.
        move.evictAll(self, tenant, src_nodes, tbody);

        const msg = std.fmt.allocPrint(a, "moved-live {s}: {s} -> {s}\n", .{ tenant, src.id, dest }) catch {
            try replyStatus(server, ent, sid, sess, 200);
            return;
        };
        try replyText(server, ent, sid, sess, 200, msg);
    }

};

/// Read a single query-string value (`/p?a=b&c=d`) by key. Values taken
/// verbatim (no percent-decoding — the CP route lookup uses bare hostnames).
fn queryParam(path: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, path, '?') orelse return null;
    var it = std.mem.tokenizeScalar(u8, path[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn cleanupResponses(server: *CpH2) !void {
    const entities = server.response_out.entitySlice();
    for (entities) |ent| try server.reg.destroy(ent);
}

fn getEnvCfg(name: []const u8) []const u8 {
    return std.posix.getenv(name) orelse "";
}

/// Which static-config env var to seed from. Pairing the var name with its
/// seed function here keeps the two from drifting at the six call sites.
const SeedKind = enum {
    clusters,
    placements,
    hosts,

    fn envVar(self: SeedKind) []const u8 {
        return switch (self) {
            .clusters => "REWIND_CLUSTERS",
            .placements => "REWIND_PLACEMENT",
            .hosts => "REWIND_HOSTS",
        };
    }
};

/// Seed one static-config var, reporting a parse failure in the operator's
/// vocabulary before propagating it.
///
/// The parser stays silent and returns a distinct error per condition
/// (`Directory.ConfigError`); this is the boundary that owns the env-var
/// names, so the message belongs here. Replication faults pass through
/// untouched — the caller retries those.
fn seedOrReport(directory: *Directory, kind: SeedKind) !void {
    const cfg = getEnvCfg(kind.envVar());
    const result = switch (kind) {
        .clusters => directory.seedClusters(cfg),
        .placements => directory.seedPlacements(cfg),
        .hosts => directory.seedHosts(cfg),
    };
    result catch |e| {
        if (asConfigError(e)) |ce| reportSeedError(kind.envVar(), directory.seed_bad_entry, ce);
        return e;
    };
}

/// Narrow `anyerror` to a `ConfigError` member, or null. Reflection over the
/// error set rather than a hand-written list, so it cannot fall behind.
fn asConfigError(e: anyerror) ?directory_mod.ConfigError {
    inline for (@typeInfo(directory_mod.ConfigError).error_set.?) |f| {
        if (e == @field(directory_mod.ConfigError, f.name)) {
            return @field(directory_mod.ConfigError, f.name);
        }
    }
    return null;
}

/// The operator message for each parse failure, naming the env var and the
/// entry that broke.
///
/// Exhaustive with NO `else`: adding a condition to `ConfigError` is a
/// compile error until it gets a message, so a new way to misconfigure the
/// CP cannot ship reporting nothing.
fn reportSeedError(var_name: []const u8, entry: []const u8, e: directory_mod.ConfigError) void {
    switch (e) {
        error.SeedEntryMissingEquals => std.log.err(
            "rewind-cp: {s} entry `{s}` has no `=` — entries are `key=value`, separated by `;`",
            .{ var_name, entry },
        ),
        error.SeedClusterIdEmpty => std.log.err(
            "rewind-cp: {s} entry `{s}` has an empty cluster id — `id=origin,origin`",
            .{ var_name, entry },
        ),
        error.SeedClusterNodesEmpty => std.log.err(
            "rewind-cp: {s} entry `{s}` lists no node origins — `id=origin,origin`",
            .{ var_name, entry },
        ),
        error.SeedClusterTooManyNodes => std.log.err(
            "rewind-cp: {s} entry `{s}` lists more than {d} node origins",
            .{ var_name, entry, directory_mod.MAX_CLUSTER_NODES },
        ),
        error.SeedOriginNotIpLiteral => std.log.err(
            "rewind-cp: {s} origin `{s}` is not an IP literal — hostnames are unsupported " ++
                "(the front door would have to resolve them on its :443 poll loop, which must " ++
                "never block); use the node's vRack IP",
            .{ var_name, entry },
        ),
        error.SeedOriginBadPort => std.log.err(
            "rewind-cp: {s} origin `{s}` has a malformed port — expected `ip:port`",
            .{ var_name, entry },
        ),
        error.SeedOriginEmpty => std.log.err(
            "rewind-cp: {s} origin `{s}` has no host",
            .{ var_name, entry },
        ),
        error.SeedPlacementTenantEmpty => std.log.err(
            "rewind-cp: {s} entry `{s}` has an empty tenant id — `tenant=cluster`",
            .{ var_name, entry },
        ),
        error.SeedPlacementClusterEmpty => std.log.err(
            "rewind-cp: {s} entry `{s}` names no cluster — `tenant=cluster`",
            .{ var_name, entry },
        ),
        error.SeedHostEmpty => std.log.err(
            "rewind-cp: {s} entry `{s}` has an empty host — `host=tenant`",
            .{ var_name, entry },
        ),
        error.SeedHostTenantEmpty => std.log.err(
            "rewind-cp: {s} entry `{s}` names no tenant — `host=tenant`",
            .{ var_name, entry },
        ),
    }
}

/// Parse a `;`/`,`-separated list of origins into an owned, owned-element
/// slice. Empty input → empty slice. Whitespace trimmed; blanks skipped.
const parseUrlList = boot.parseUrlList;
const freeUrlList = boot.freeUrlList;

/// Render the CP operator metrics in Prometheus text (caller frees). Two
/// halves, both node-wide with no per-tenant labels (the docs/architecture/observability.md
/// active-series rule):
///
///   1. The directory raft group's health — leadership + the dial-mesh — via
///      the SAME `Bridge` gauges the worker exposes. The CP runs one raft group
///      (the replicated directory), so `raft_groups_no_leader` is the directory
///      wedge signal and `raftnet_peers_unreachable` is the cross-host
///      CP-genesis wedge the June incident lacked any view of.
///   2. The reconciler's action counters — liveness (`cp_reconcile_passes`) and
///      the stuck-conf-change signal (`cp_reconcile_confchange_failed`).
///
/// Rendered on the CP main loop (which also writes the counters); the
/// MetricsServer listener thread only serves the returned bytes. The bridge
/// gauges read pump-published atomics, so they are safe off the pump thread.
fn buildCpMetricsText(allocator: std.mem.Allocator, router: *Router, bridge: *Bridge, server: *CpH2) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
    const w = &aw.writer;

    // Shared rove-h2 connection/io-ring metrics + the http_requests_total RED
    // signal for the CP's control surface (/_cp, /_control). Same poll-loop
    // thread renders + serves, so it's safe to read the server's counters here.
    try server.writeConnMetrics(w);

    const gc = bridge.groupCounts();
    try w.print(
        \\# HELP raft_is_leader 1 if this CP leads its directory raft group, 0 otherwise.
        \\# TYPE raft_is_leader gauge
        \\raft_is_leader {d}
        \\# HELP raft_groups raft groups on this node (the CP hosts the replicated directory group).
        \\# TYPE raft_groups gauge
        \\raft_groups {d}
        \\# HELP raft_groups_led groups this node currently leads.
        \\# TYPE raft_groups_led gauge
        \\raft_groups_led {d}
        \\# HELP raft_groups_no_leader groups this node neither leads nor knows a leader for (leader_id=0) — the directory wedge signal; sustained > 0 = a failed CP election / lost quorum.
        \\# TYPE raft_groups_no_leader gauge
        \\raft_groups_no_leader {d}
        \\
    , .{ @intFromBool(bridge.leadsAnyGroup()), gc.total, gc.led, gc.no_leader });

    const mesh = bridge.meshSnapshot();
    const mesh_configured: u32 = if (mesh) |m| m.configured else 0;
    const mesh_connected: u32 = if (mesh) |m| m.connected else 0;
    try w.print(
        \\# HELP raftnet_peers_configured non-self CP peers this node must be able to send to (the outbound directory mesh it should hold).
        \\# TYPE raftnet_peers_configured gauge
        \\raftnet_peers_configured {d}
        \\# HELP raftnet_peers_connected configured peers with an established outbound connection (raft can send to them).
        \\# TYPE raftnet_peers_connected gauge
        \\raftnet_peers_connected {d}
        \\# HELP raftnet_peers_unreachable configured peers with NO outbound connection (configured − connected) — the dial-mesh wedge signal; sustained > 0 = a CP node raft can't reach (zombie-connect / partition).
        \\# TYPE raftnet_peers_unreachable gauge
        \\raftnet_peers_unreachable {d}
        \\
    , .{ mesh_configured, mesh_connected, mesh_configured - mesh_connected });

    try w.print(
        \\# HELP cp_reconcile_passes_total membership-reconciler passes executed as the directory leader (liveness: a flat count on a node that should lead = the reconciler isn't running).
        \\# TYPE cp_reconcile_passes_total counter
        \\cp_reconcile_passes_total {d}
        \\# HELP cp_reconcile_confchange_total membership conf-changes proposed by the reconciler (add/promote/demote/remove).
        \\# TYPE cp_reconcile_confchange_total counter
        \\cp_reconcile_confchange_total {d}
        \\# HELP cp_reconcile_confchange_failed_total conf-change proposals that did not commit (non-204) — the stuck-grow signal; climbing while membership doesn't advance = a conf-change the leader can't commit (the __admin__-stuck-at-{{1,2}} wedge).
        \\# TYPE cp_reconcile_confchange_failed_total counter
        \\cp_reconcile_confchange_failed_total {d}
        \\# HELP cp_provision_limited_total provisions refused by the creation-velocity guard (bulk tenant-creation flood signal).
        \\# TYPE cp_provision_limited_total counter
        \\cp_provision_limited_total {d}
        \\
    , .{ router.reconcile_passes, router.confchange_total, router.confchange_failed, router.provision_limited });

    buf = aw.toArrayList();
    return try buf.toOwnedSlice(allocator);
}

pub fn main() !void {
    curl.globalInit();
    const allocator = std.heap.c_allocator;
    boot.installSignalHandlers(&stop_flag);
    // Logging must never block the poll loop: a backpressured log sink
    // (journald) would otherwise freeze the CP on a synchronous std.log
    // write. O_NONBLOCK drops the line instead. See `rove.logNonBlocking`.
    rove.logNonBlocking();

    var arg_it = std.process.args();
    _ = arg_it.next();
    const port_str = arg_it.next() orelse "9090";
    const port = try std.fmt.parseInt(u16, port_str, 10);

    // Control-plane directory — durable, backed by the CP `bridge` (one
    // "directory" raft group; directory replication,
    // docs/architecture/control-plane.md).
    // The store at `REWIND_CP_DATA_DIR` persists placement across restarts;
    // `initReplicated` replays it before the pump thread starts. Required: a
    // CP without durable storage loses every committed move on restart, which
    // is a misconfiguration — fail loud rather than default to an ephemeral
    // path that silently re-seeds static config.
    const cp_data_dir = std.posix.getenv("REWIND_CP_DATA_DIR") orelse {
        std.log.err("rewind-cp: REWIND_CP_DATA_DIR is required (the durable directory store path)", .{});
        return error.MissingCpDataDir;
    };
    // Single-node CP by default; a multi-node (HA) CP is configured by env
    // (this CP node's raft id, the voter set, the consensus transport
    // addresses). The directory raft group spans the voter set.
    var cp_self_idx: ?usize = null;
    const cp_bridge = if (try parseCpMultiNode(allocator)) |mn| blk: {
        defer mn.deinit(allocator);
        cp_self_idx = mn.node_id - 1; // index into REWIND_CP_PEER_URLS
        std.log.info("rewind-cp: multi-node CP id={d} voters={d} listen={s}", .{ mn.node_id, mn.voters.len, mn.listen_str });
        break :blk try Bridge.initMultiNode(allocator, cp_data_dir, mn.node_id, mn.voters, mn.listen_addr, mn.peers);
    } else try Bridge.initSingleNode(allocator, cp_data_dir);
    // Raft logical-tick cadence (ms). Keep the CP directory group's election
    // timing in lockstep with the workers' tenant groups — same hardware, same
    // number — so election timeout ≈ election_tick × this is uniform across the
    // node (docs/architecture/raft-best-practices.md "how to size election/heartbeat"). The
    // default preserves the historical ~1ms cadence. Set BEFORE startPump.
    if (std.posix.getenv("REWIND_RAFT_TICK_MS")) |v| {
        if (std.fmt.parseInt(i64, v, 10)) |ms| {
            if (ms > 0) {
                cp_bridge.node.setTickInterval(ms * std.time.ns_per_ms);
                std.log.info("rewind-cp: raft tick interval = {d}ms (election timeout ≈ election_tick × {d}ms)", .{ ms, ms });
            }
        } else |_| {}
    }
    const directory = try Directory.initReplicated(allocator, cp_bridge);

    // The durable certificate copy. Certificates live in the directory raft
    // group, which a cold bring-up wipes, and re-issuing spends CA rate-limit
    // quota — so every cert written here is mirrored to object storage outside
    // the storage-namespace generation, and the issuer restores from there
    // before calling a CA. Optional: a CP without S3 configured still serves,
    // it just leaves certificates raft-only (loudly).
    var blob_owned: ?blob.BlobBackendOwned = blob.env.loadFromEnv(allocator) catch |err| blk: {
        std.log.warn(
            "rewind-cp: no S3 config ({s}) — certificates will NOT be mirrored, so a cold " ++
                "bring-up destroys them and the re-issue spends CA quota (rove#269)",
            .{@errorName(err)},
        );
        break :blk null;
    };
    defer if (blob_owned) |*b| b.deinit(allocator);

    // The teardown sweep's key space (rove#606). Tenant objects live INSIDE
    // the storage-namespace generation — `prod/1/{tenant}/…`, not `prod/…` —
    // because the worker and the log-server both scope their stores with
    // `applyNamespace` at startup. The CP did not, so every deprovision swept
    // a prefix nothing had ever been written to, deleted nothing, and logged
    // that as success.
    //
    // Resolved into its OWN config rather than by scoping `blob_owned` in
    // place: the certificate mirror deliberately sits outside the generation
    // so certs survive a cold re-genesis, and moving it inside would destroy
    // exactly the property it exists for.
    //
    // DEGRADE, never refuse to start: the worker exits when the marker is
    // missing, but a CP that will not boot over an object-store hiccup takes
    // provisioning and moves down for the whole cluster. So an unresolved
    // generation leaves `sweep_cfg` null, and `handleDelete` refuses that one
    // operation loudly instead of the CP refusing every operation.
    var sweep_cfg: ?blob.BackendConfig = null;
    var sweep_prefix_owned: ?[]u8 = null;
    defer if (sweep_prefix_owned) |p| allocator.free(p);
    if (blob_owned) |b| {
        if (blob.namespace_store.resolve(allocator, b.cfg)) |segment| {
            defer allocator.free(segment);
            const scoped = try blob.namespace.apply(allocator, b.cfg.key_prefix_base, segment);
            sweep_prefix_owned = scoped;
            var c2 = b.cfg;
            c2.key_prefix_base = scoped;
            sweep_cfg = c2;
            std.log.info("rewind-cp: teardown sweep scoped to generation '{s}' ({s})", .{ segment, scoped });
        } else |err| {
            std.log.warn(
                "rewind-cp: storage generation unresolved ({s}) — deprovision will REFUSE to " ++
                    "sweep rather than delete nothing and report success (rove#606). " ++
                    "Serving normally otherwise.",
                .{@errorName(err)},
            );
        }
    }

    var cert_mirror_store: ?cert_mirror.CertMirror = if (blob_owned) |b|
        cert_mirror.CertMirror.init(allocator, b.cfg) catch |err| blk: {
            std.log.warn("rewind-cp: certificate mirror unavailable: {s}", .{@errorName(err)});
            break :blk null;
        }
    else
        null;
    defer if (cert_mirror_store) |*m| m.deinit();
    if (cert_mirror_store) |*m| {
        directory.cert_mirror = m.hook();
        std.log.info("rewind-cp: certificate mirror at {s}{s}", .{ blob_owned.?.cfg.key_prefix_base, cert_mirror.SUBDIR });
    }
    // Teardown order matters: the pump fires the directory's apply observer,
    // so the pump must STOP (`cp_bridge.deinit` → `stopPump`) before the
    // directory is freed. Defers run LIFO, so declare `directory.destroy`
    // first (runs last) and `cp_bridge.deinit` second (runs first).
    defer directory.destroy();
    defer cp_bridge.deinit();
    // WAL sync mode: async (default — the flusher thread keeps the fsync
    // out of the pump cycle) or `inline` (the operator rollback lever;
    // re-serializes heartbeats behind the fsync).
    if (std.posix.getenv("REWIND_WAL_SYNC_MODE")) |v| {
        if (std.mem.eql(u8, v, "inline")) {
            cp_bridge.inline_fsync = true;
            std.log.info("rewind-cp: WAL sync mode = inline (async flusher disabled)", .{});
        }
    }
    try cp_bridge.startPump();

    // Static config seeds ONLY a fresh (empty) directory — a restart over a
    // populated store keeps its committed placements (incl. completed moves)
    // rather than re-seeding back to the static config.
    //
    // Single-node CP: this node is always the leader, so seed immediately.
    // Multi-node CP: a directory write only commits on the LEADER, so only the
    // leader seeds (once); every follower boots empty and fills its projection
    // from the leader's replicated seed (the apply observer). Wait briefly for
    // election / replication to settle before deciding.
    if (cp_bridge.node.isSingleNode()) {
        if (directory.isEmpty()) {
            try seedOrReport(directory, .clusters);
            try seedOrReport(directory, .placements);
            try seedOrReport(directory, .hosts);
            std.log.info("rewind-cp: seeded directory from static config", .{});
        } else {
            std.log.info("rewind-cp: directory replayed from {s} (skipping static seed)", .{cp_data_dir});
        }
    } else {
        const deadline: i128 = std.time.nanoTimestamp() + 10 * std.time.ns_per_s;
        while (std.time.nanoTimestamp() < deadline and !directory.isLeader() and directory.isEmpty()) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        if (directory.isLeader() and directory.isEmpty()) {
            // Seed as the leader, RETRYING transient replication faults:
            // leadership can still be settling right after election, so a
            // propose may fault even though we just read isLeader()==true.
            // Seeds are idempotent (addCluster/assign upsert), so re-running
            // after a partial seed is safe. Stop if we lose leadership (a peer
            // will seed) or the store fills (replicated from elsewhere).
            var seeded = false;
            var attempt: u32 = 0;
            while (attempt < 100) : (attempt += 1) {
                if (!directory.isLeader() or !directory.isEmpty()) break;
                seedOrReport(directory, .clusters) catch |e| switch (e) {
                    error.Replication => {
                        std.Thread.sleep(100 * std.time.ns_per_ms);
                        continue;
                    },
                    else => return e, // malformed config / OOM → fail loud
                };
                seedOrReport(directory, .placements) catch |e| switch (e) {
                    error.Replication => {
                        std.Thread.sleep(100 * std.time.ns_per_ms);
                        continue;
                    },
                    else => return e,
                };
                seedOrReport(directory, .hosts) catch |e| switch (e) {
                    error.Replication => {
                        std.Thread.sleep(100 * std.time.ns_per_ms);
                        continue;
                    },
                    else => return e,
                };
                seeded = true;
                break;
            }
            if (seeded) {
                std.log.info("rewind-cp: directory leader seeded from static config", .{});
            } else if (directory.isEmpty()) {
                std.log.warn("rewind-cp: leader could not seed (replication unstable); will rely on replication / a peer", .{});
            } else {
                std.log.info("rewind-cp: directory replayed/replicated (skipping static seed)", .{});
            }
        } else if (directory.isEmpty()) {
            std.log.info("rewind-cp: CP follower — awaiting directory replication from the leader", .{});
        } else {
            std.log.info("rewind-cp: directory replayed/replicated (skipping static seed)", .{});
        }
    }

    // CP peer HTTP origins (HA) — the OTHER CP nodes' control URLs, so a
    // follower can forward a `/_control/*` write to the directory leader.
    // `REWIND_CP_PEER_URLS=http://a:9090;http://b:9090;http://c:9090`. Empty
    // for a single-node CP (this node always leads → no forward).
    const cp_peer_urls = try parseUrlList(allocator, getEnvCfg("REWIND_CP_PEER_URLS"));
    defer freeUrlList(allocator, cp_peer_urls);

    // Shared secret for the cluster-internal move surface. The CP
    // presents it to backends' `/_system/v2-*` endpoints and requires it on
    // `/_control/move`. Unset → move control disabled.
    const move_secret: ?[]const u8 = std.posix.getenv("REWIND_MOVE_SECRET");

    var reg = try rove.Registry.init(allocator, .{
        .max_entities = 8192,
        .deferred_queue_capacity = 2048,
    });
    defer reg.deinit();

    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    const server = try CpH2.create(&reg, allocator, addr, .{
        .max_connections = 1024,
        .buf_count = 1024,
        .buf_size = 16384,
        .listen_backlog = 1024,
        .reuseport = true,
    }, .{ .tls_config = null });
    defer server.destroy();

    // Leader-elected ACME HTTP-01 issuer. Inert unless
    // `REWIND_ACME_DIRECTORY` is set — then it issues certs for mapped custom
    // domains lacking a `cert/{host}` and serves the challenge via
    // `/_cp/acme-challenge` (the front door's :80 listener forwards to it).
    const acme_handle: ?*acme_issuer.Handle = blk: {
        const dir_url = std.posix.getenv("REWIND_ACME_DIRECTORY") orelse break :blk null;
        const h = acme_issuer.spawn(.{
            .allocator = allocator,
            .directory = directory,
            .data_dir = cp_data_dir,
            .directory_url = dir_url,
            .contact_email = std.posix.getenv("REWIND_ACME_CONTACT"),
            .insecure_tls = std.posix.getenv("REWIND_ACME_INSECURE_TLS") != null,
            .public_suffix = getEnvCfg("REWIND_PUBLIC_SUFFIX"),
            .system_suffix = getEnvCfg("REWIND_SYSTEM_SUFFIX"),
            .mirror = if (cert_mirror_store) |*m| m else null,
        }) catch |err| {
            std.log.warn("rewind-cp: ACME issuer spawn failed: {s}", .{@errorName(err)});
            break :blk null;
        };
        std.log.info("rewind-cp: ACME issuer enabled (dir={s})", .{dir_url});
        break :blk h;
    };
    defer if (acme_handle) |h| {
        h.signalStop();
        h.join();
    };

    const reconcile_membership = blk: {
        const v = std.posix.getenv("REWIND_CP_RECONCILE_MEMBERSHIP") orelse break :blk false;
        break :blk std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    };
    // The reconciler drives every DP membership call through backendCall, which
    // presents the move secret. Enabling it without REWIND_MOVE_SECRET would
    // panic on the first tick (move_secret.?). Refuse at boot instead.
    if (reconcile_membership and move_secret == null) {
        std.log.err("rewind-cp: REWIND_CP_RECONCILE_MEMBERSHIP=1 requires REWIND_MOVE_SECRET", .{});
        return error.MissingMoveSecret;
    }
    // RC-6 demote hysteresis grace (default 60s); tunable for tests/operators.
    const demote_grace_ns: i128 = blk: {
        const v = std.posix.getenv("REWIND_CP_DEMOTE_GRACE_MS") orelse break :blk 60 * std.time.ns_per_s;
        const ms = std.fmt.parseInt(i64, std.mem.trim(u8, v, " \t"), 10) catch break :blk 60 * std.time.ns_per_s;
        break :blk @as(i128, ms) * std.time.ns_per_ms;
    };
    var router = Router{ .allocator = allocator, .directory = directory, .move_secret = move_secret, .cp_peer_urls = cp_peer_urls, .self_cp_idx = cp_self_idx, .acme = acme_handle, .reconcile_membership = reconcile_membership, .demote_grace_ns = demote_grace_ns, .public_suffix = getEnvCfg("REWIND_PUBLIC_SUFFIX"), .blob_cfg = if (blob_owned) |b| b.cfg else null, .sweep_cfg = sweep_cfg };

    // Periodic membership reconciliation on the directory leader (between
    // request batches). last=0 → the first iteration reconciles, so a CP
    // restart / failover converges membership within one tick. Period from
    // `REWIND_CP_RECONCILE_SECS` (default 5); 0 disables reconciliation.
    const reconcile_secs: i128 = blk: {
        const s = std.posix.getenv("REWIND_CP_RECONCILE_SECS") orelse break :blk 5;
        break :blk std.fmt.parseInt(i128, std.mem.trim(u8, s, " \t"), 10) catch 5;
    };
    const reconcile_period_ns: i128 = reconcile_secs * std.time.ns_per_s;
    var last_reconcile_ns: i128 = 0;

    // Dedicated operator-metrics HTTP/1.1 listener (mirrors the worker's): a
    // loopback /metrics on REWIND_CP_METRICS_PORT (default 9111 — distinct from
    // the worker's 9110 so both coexist on one host; 0 disables). Independent
    // thread + socket, so /metrics stays scrapable while the CP loop is wedged
    // — exactly the directory-election incident this surfaces. A bind failure
    // logs and runs without it (metrics are optional).
    const cp_metrics_srv: ?*MetricsServer =
        boot.metricsFromEnv(allocator, "REWIND_CP_METRICS_PORT", boot.METRICS_PORT_CP, "rewind-cp");
    defer if (cp_metrics_srv) |ms| ms.deinit();
    var metrics_cadence: boot.Cadence = .{};

    // Say whether wildcard tenant routing is live. Unset, every self-serve
    // tenant provisions successfully and is then unroutable — a silent config
    // gap whose only symptom is a 404 at the front door, one hop away from
    // here. Worth a boot line rather than a discovery.
    if (router.public_suffix.len > 0) {
        std.log.info("rewind-cp: wildcard tenant routing on *.{s} (must match the workers' REWIND_PUBLIC_SUFFIX)", .{router.public_suffix});
    } else {
        std.log.warn("rewind-cp: REWIND_PUBLIC_SUFFIX unset — no wildcard routing; every tenant needs an explicit host mapping", .{});
    }
    std.log.info("rewind-cp: listening on 0.0.0.0:{d} (move control {s}, reconcile {s})", .{
        port,
        if (move_secret != null) "enabled" else "disabled",
        if (reconcile_secs > 0) "on" else "off",
    });
    while (!stop_flag.load(.acquire)) {
        server.pollWithTimeout(10 * std.time.ns_per_ms) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
        try router.processRequests(server);
        try reg.flush();
        try cleanupResponses(server);
        try reg.flush();

        if (reconcile_secs > 0) {
            const now_ns = std.time.nanoTimestamp();
            if (now_ns - last_reconcile_ns > reconcile_period_ns) {
                last_reconcile_ns = now_ns;
                reconciler.reconcileMembership(&router);
                // Re-push suspension state to serving clusters. A worker
                // restart loses the in-memory suspended flag; the directory
                // row is the durable truth, so this pass re-delivers it
                // within one reconcile interval. Suspended tenants are few —
                // the pass is O(suspended), not O(tenants).
                router.repushSuspensions();
                // Re-install certificates this cluster already owns but whose
                // raft copy is gone — the state after a cold bring-up. Leader
                // only (the write goes through the leader's proposer), and
                // independent of ACME: a deployment serving operator-uploaded
                // certificates has to get them back too.
                if (cert_mirror_store) |*m| {
                    if (directory.isLeader()) {
                        const n = m.restorePass(allocator, directory, std.time.timestamp(), acme_issuer.RENEW_WINDOW_S);
                        if (n > 0) std.log.info("rewind-cp: restored {d} certificate(s) from the mirror", .{n});
                    }
                }
            }
        }

        // Re-render + publish the metrics snapshot ~every 2s (the CP loop is the
        // only thread that may read the counters; the listener serves bytes).
        if (cp_metrics_srv) |ms| {
            if (metrics_cadence.due(std.time.nanoTimestamp())) {
                if (buildCpMetricsText(allocator, &router, cp_bridge, server)) |txt| {
                    defer allocator.free(txt);
                    ms.publish(txt);
                } else |_| {}
            }
        }
    }
    std.log.info("rewind-cp: shut down", .{});
}

test {
    // Test discovery: Zig compiles tests only from files a test build
    // reaches, and importing a file for its declarations does not reach it.
    // `scripts/ops/test_reachability_lint.py` fails when one is missing here.
    _ = @import("acme.zig");
    _ = @import("reconciler.zig");
}
