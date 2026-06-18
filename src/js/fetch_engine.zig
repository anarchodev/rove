//! `http.fetch` engine — Phase 2 of `docs/curl-multi-plan.md`.
//!
//! Replaces `fetch_pool.zig` (8 worker threads each blocking on one
//! `curl_easy_perform`) with a single thread driving a `curl_multi`
//! handle that holds many concurrent transfers. Lifts the
//! `FETCH_POOL_SIZE = 8` ceiling structurally — the engine runs as
//! many simultaneous fetches as libcurl + the OS allow.
//!
//! ## Architecture
//!
//! One `FetchEngine` per node. Workers (any thread) call `submit(pf)`
//! to enqueue a `PendingFetch`; the engine thread drains the queue,
//! builds a `curl_multi.Transfer` per fetch, and adds it to the multi
//! handle. libcurl drives all transfers concurrently. Per-writeback
//! `on_chunk` callbacks (fired on the engine thread inside
//! `curl_multi_poll`) re-chunk the response and route
//! `UpstreamFetchEvent`s to the destination worker via
//! `NodeState.enqueueFetchEventForTenant` (hash-routed by tenant_id
//! to the worker that issued the fetch).
//!
//! ## Streaming modes (preserves Phase 5 PR-1 contract)
//!
//! - `stream: false` (default) — body buffered up to
//!   `max_response_chunk_bytes`. On completion, ONE event with
//!   `final: true` + body bytes + terminal status fires. Any further
//!   bytes set `body_truncated` and abort the transfer.
//! - `stream: true` — each writeback emits an event with
//!   `final: false` immediately (split into `max_response_chunk_bytes`
//!   pieces if oversized). A separate empty-bytes event with
//!   `final: true` + terminal fields fires after the transfer
//!   completes, distinguishing "more frames" from "transfer done."
//!
//! Both modes always emit at least one `final: true` event — even
//! on transport error or cap-only abort.
//!
//! ## Cross-thread wake-up
//!
//! Workers calling `submit` or `cancel` push to a mutex-protected
//! queue and then call `Multi.wakeup` (wrapping `curl_multi_wakeup`,
//! libcurl 7.68+). The engine thread's `multi.poll(1000)` returns
//! immediately on wake; the engine drains the cross-thread queues
//! at the top of each loop iteration.
//!
//! ## Cancellation (`http.cancelFetch`)
//!
//! Cooperative: the engine drops the transfer from libcurl and frees
//! its state. An in-flight chunk that already landed in on_chunk
//! before the cancel ran is delivered as if the cancel hadn't
//! happened (the customer's chain ctx is the place to track "we
//! moved on" — see `curl-multi-plan.md` §5 invariant 3). The
//! terminal `final: true` event does NOT fire after a cancel — the
//! customer's chain just stops.

const std = @import("std");
const blob_curl_multi = @import("rove-blob").curl_multi;
const blob_sigv4 = @import("rove-blob").sigv4;
const components_mod = @import("components.zig");
const worker_mod = @import("worker.zig");
const globals = @import("globals.zig");
const ssrf_mod = @import("rove-ssrf");
const jwt = @import("rove-jwt");
const tenant_mod = @import("rove-tenant");
const files_mod = @import("rove-files");

const NodeState = worker_mod.NodeState;
const PendingFetch = globals.PendingFetch;
const UpstreamFetchEvent = components_mod.UpstreamFetchEvent;

/// How long the engine thread blocks in `multi.poll` between wakeups.
/// Long timeout is fine — `Multi.wakeup` unblocks on submit/cancel,
/// so this only governs idle latency for libcurl-internal events
/// (e.g., DNS cache expiry).
const ENGINE_POLL_TIMEOUT_MS: c_int = 1000;

/// Sanity cap on the in-flight transfer count. Not a throttle (the
/// engine runs as many as can be packed onto one thread); a guard
/// against runaway submissions exhausting fd or memory. If reached,
/// `submit` blocks the calling worker briefly (caller spins). Set
/// well above any plausible legitimate concurrent load.
const ENGINE_MAX_INFLIGHT: usize = 10_000;

/// `docs/curl-multi-plan.md` Phase 3 (gap 2.5): per-tenant cap on
/// simultaneous held subscriptions. Mirrors
/// `connection-actor-plan.md` §9.2's posture: bounded resource
/// per tenant so one chatty customer can't exhaust the node's
/// outbound socket / fd budget. Exceeded submissions emit a
/// defined `final: true, ok: false` rejection event so the
/// customer's `on_chunk` handler fires once and can take action.
const HELD_MAX_PER_TENANT: u32 = 16;

/// blob-storage-plan P1; `docs/architecture/routing-and-ingress.md`: the special origin the `blob.*`
/// JS shims target. Never resolved — `startTransfer` rewrites it to
/// the real S3 endpoint + tenant `app-blobs/` prefix and signs the
/// request before libcurl sees it. The `.internal` TLD is reserved
/// (RFC 8375-adjacent ICANN reservation), so the placeholder can
/// never collide with a real customer destination. Canonical
/// definition lives in `blob_sessions.zig` (leaf) so the P2 seal
/// binding can name it without an import cycle.
pub const BLOB_ORIGIN_PREFIX = @import("blob_sessions.zig").BLOB_ORIGIN_PREFIX;

/// The `rewind-logs.internal` trusted door (step3-auth-plan.md A2/A3;
/// rewind-cli-plan.md §7). The `__admin__` chokepoint fetches
/// `http://rewind-logs.internal/v1/{tenant}/...`; the fetch engine mints a
/// tenant-scoped `logs-read` capability token, rewrites the host to the
/// platform-configured internal log-server base, and attaches the token as
/// Bearer. Only `__admin__` may form this host (the routing gate). Mirrors
/// `BLOB_ORIGIN_PREFIX`'s own-tenant door, but cross-tenant by design.
pub const LOGS_ORIGIN_PREFIX = "http://rewind-logs.internal/";

/// The `rewind-cp.internal` trusted door (step3-auth-plan.md B4;
/// cp-desired-state-target.md). The `__admin__` chokepoint fetches
/// `http://rewind-cp.internal/_control/…` (or `/_cp/…` reads); the fetch engine
/// attaches the platform move-secret (`X-Rewind-Move-Secret`) and rewrites the
/// host to the configured CP base. So the operator does CP control ops
/// (provision / move / host / plan) through the OIDC dashboard with NO
/// operator-held CP secret — the worker holds it. Only `__admin__` may form
/// this host (the routing gate). Mirrors `LOGS_ORIGIN_PREFIX`.
pub const CP_ORIGIN_PREFIX = "http://rewind-cp.internal/";

/// The `rove-blob-read.internal` trusted door — the cross-tenant READ twin of
/// `platform.scope(t).blob.put` (which writes file-blobs). The `__admin__`
/// dashboard fetches `http://rove-blob-read.internal/{tenant}/blob/{hash}` (a
/// source/content blob from `{tenant}/file-blobs/`) or
/// `.../{tenant}/manifest/{dep_hex}` (the deployment manifest from
/// `{tenant}/deployments/`); the fetch engine rewrites to the real S3 endpoint
/// with the TARGET tenant's prefix + SigV4-signs it. Cross-tenant by design —
/// the tenant comes from the URL PATH, not `pf.tenant_id` (always `__admin__`
/// here); only `__admin__` may form this host (the routing gate). GET/HEAD
/// only. The dashboard composes the replay bundle / Code-tab sources in JS from
/// these reads (no native assembly). Mirrors `BLOB_ORIGIN_PREFIX`'s own-tenant
/// signing, `LOGS_ORIGIN_PREFIX`'s cross-tenant + __admin__-gated posture.
pub const BLOB_READ_ORIGIN_PREFIX = "http://rove-blob-read.internal/";

/// Upper bound on `REWIND_INTERNAL_FRONT` entries — one per front in
/// the deployment, and a deployment has at most a handful of fronts.
const MAX_DOOR_ADDRS = 4;

/// Default front public TLS port — the only port the tenant door fires
/// for unless `REWIND_INTERNAL_FRONT_PORT` overrides it (`door_port`).
/// `CURLOPT_RESOLVE` remaps the address of `host:port` but never the
/// port, and CP (`:9090`), worker h2c (`:8443`), and raft (`:8501`/
/// `:9101`) are co-located on the front boxes — so a `host:9090` URL
/// would otherwise pin straight at an internal service's private-plane
/// address. The door declines any other port (see `tenantDoorPin`), so
/// reaching an internal port is impossible by construction rather than
/// resting on the coincidence that those ports speak plaintext while the
/// door is https-only. Matches the front's `:443` listener (deploy plan
/// §2.5); test topologies set `REWIND_INTERNAL_FRONT_PORT` to the front's
/// high port.
const FRONT_TLS_PORT: u16 = 443;

pub const FetchEngine = struct {
    allocator: std.mem.Allocator,
    node: *NodeState,

    /// Tenant door (the inter-tenant fast path): when
    /// `REWIND_INTERNAL_FRONT` is set, an outbound fetch whose host is
    /// one of OUR platform tenant hostnames (`*.{REWIND_PUBLIC_SUFFIX}`
    /// / `*.{REWIND_SYSTEM_SUFFIX}`, label-boundary suffix match) pins
    /// its connect to these front addresses (the private plane —
    /// vRack/WireGuard IPs) instead of resolving public DNS, so
    /// tenant→tenant calls never hairpin through the public edge.
    /// Everything else about the transfer is identical to the public
    /// path: the URL/Host/SNI are untouched (the front routes by Host
    /// and serves the same wildcard cert on the private interface),
    /// TLS verification stays on, and the target tenant sees an
    /// ordinary inbound request. The entries are bare IPs and the door
    /// only fires for the front's TLS port (`FRONT_TLS_PORT`):
    /// CURLOPT_RESOLVE remaps the address of `host:port` but never the
    /// port, and CP/worker/raft are co-located on the front boxes, so a
    /// `host:9090` URL would otherwise pin at an internal port. Non-443
    /// door hosts fall to the public path instead (see `tenantDoorPin`).
    ///
    /// SSRF posture: a door-matched host skips DNS + the blocklist
    /// (the pinned address is platform-configured, never
    /// customer-controlled — same trust argument as the blob door
    /// above), but still passes the scheme gate via `ssrf.parseUrl`.
    /// The customer controls only WHICH tenant host is dialed, which
    /// the public path allows anyway.
    door_addrs: [MAX_DOOR_ADDRS]std.net.Address = undefined,
    door_addr_count: u8 = 0,
    door_suffixes: [2][]const u8 = .{ "", "" },
    door_suffix_count: u8 = 0,
    /// The URL port the door fires for — the front's TLS port. Defaults
    /// to `FRONT_TLS_PORT` (443); `REWIND_INTERNAL_FRONT_PORT` overrides
    /// it for test topologies whose front binds a high port. A door host
    /// on any other port is declined (`tenantDoorPin`).
    door_port: u16 = FRONT_TLS_PORT,

    thread: ?std.Thread = null,
    multi: ?*blob_curl_multi.Multi = null,
    stop: std.atomic.Value(bool) = .init(false),

    /// Cross-thread inbound queue. Workers push PendingFetches via
    /// `submit`; the engine thread drains at the top of each loop.
    /// Ownership transfers from submitter to engine on push.
    inbound_mu: std.Thread.Mutex = .{},
    inbound: std.ArrayListUnmanaged(PendingFetch) = .empty,

    /// Cross-thread cancel queue. Workers push allocator-owned
    /// fetch-id strings via `cancel`; the engine drains + matches
    /// against `inflight_by_id`. Cancel-of-unknown-id is a silent
    /// no-op (the fetch may already have completed or never existed).
    cancel_mu: std.Thread.Mutex = .{},
    cancel_ids: std.ArrayListUnmanaged([]u8) = .empty,

    /// Engine-thread-only: in-flight FetchCtxs keyed by `fetch_id`.
    /// Cancel uses this to map id → ctx; on_done removes via this
    /// map. Shutdown drains remaining entries to free their ctxs.
    /// String key borrows into `ctx.pf.id` (lives for the ctx's
    /// lifetime).
    inflight_by_id: std.StringHashMapUnmanaged(*FetchCtx) = .empty,

    /// Engine-thread-only: per-tenant count of held subscriptions
    /// currently in flight. Incremented on `startTransfer` with
    /// `pf.held == true`; decremented on completion (`onDoneCb`)
    /// or cancellation. The key is the tenant_id string,
    /// allocator-owned by this map. Entry is removed when the
    /// count drops to 0 to keep the map bounded.
    held_per_tenant: std.StringHashMapUnmanaged(u32) = .empty,

    /// One-shot warning latch for the "no workers registered yet"
    /// cold-start race. Logged once + dropped thereafter so log
    /// stays readable.
    no_inbox_warned: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, node: *NodeState) !*FetchEngine {
        const self = try allocator.create(FetchEngine);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .node = node };
        if (std.posix.getenv("REWIND_INTERNAL_FRONT")) |csv| {
            if (csv.len > 0) {
                try self.parseDoorConfig(
                    csv,
                    std.posix.getenv("REWIND_PUBLIC_SUFFIX"),
                    std.posix.getenv("REWIND_SYSTEM_SUFFIX"),
                );
                // The door fires only for the front's TLS port (443 in
                // prod). Test topologies whose front binds a high port
                // set REWIND_INTERNAL_FRONT_PORT so the door still applies.
                if (std.posix.getenv("REWIND_INTERNAL_FRONT_PORT")) |ps| {
                    self.door_port = std.fmt.parseInt(u16, ps, 10) catch {
                        std.log.err(
                            "rove-js fetch_engine: bad REWIND_INTERNAL_FRONT_PORT '{s}' — want a port number",
                            .{ps},
                        );
                        return error.TenantDoorMisconfig;
                    };
                }
            }
        }
        return self;
    }

    /// Parse + validate the tenant-door config (split from `init` so
    /// tests can drive it without env). Boot-time misconfig fails
    /// LOUD — a worker with a half-working door would silently route
    /// inter-tenant calls over the public edge, which is exactly the
    /// drift the door exists to prevent.
    fn parseDoorConfig(
        self: *FetchEngine,
        addrs_csv: []const u8,
        public_suffix: ?[]const u8,
        system_suffix: ?[]const u8,
    ) !void {
        if (public_suffix) |s| if (s.len > 0) {
            self.door_suffixes[self.door_suffix_count] = s;
            self.door_suffix_count += 1;
        };
        if (system_suffix) |s| if (s.len > 0) {
            self.door_suffixes[self.door_suffix_count] = s;
            self.door_suffix_count += 1;
        };
        if (self.door_suffix_count == 0) {
            std.log.err(
                "rove-js fetch_engine: REWIND_INTERNAL_FRONT is set but neither " ++
                    "REWIND_PUBLIC_SUFFIX nor REWIND_SYSTEM_SUFFIX is — the tenant " ++
                    "door has no hostnames to match",
                .{},
            );
            return error.TenantDoorMisconfig;
        }
        var it = std.mem.splitScalar(u8, addrs_csv, ',');
        while (it.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " ");
            if (entry.len == 0) continue;
            if (self.door_addr_count == MAX_DOOR_ADDRS) {
                std.log.err(
                    "rove-js fetch_engine: REWIND_INTERNAL_FRONT has more than {d} entries",
                    .{MAX_DOOR_ADDRS},
                );
                return error.TenantDoorMisconfig;
            }
            // Bare IPs only: CURLOPT_RESOLVE keeps the URL's port, so a
            // `:port` here would be dead config masquerading as live.
            self.door_addrs[self.door_addr_count] = std.net.Address.parseIp(entry, 0) catch {
                std.log.err(
                    "rove-js fetch_engine: bad REWIND_INTERNAL_FRONT entry '{s}' — " ++
                        "entries are bare IPs (the URL's port is preserved)",
                    .{entry},
                );
                return error.TenantDoorMisconfig;
            };
            self.door_addr_count += 1;
        }
        if (self.door_addr_count == 0) {
            std.log.err("rove-js fetch_engine: REWIND_INTERNAL_FRONT is set but empty", .{});
            return error.TenantDoorMisconfig;
        }
        std.log.info(
            "rove-js fetch_engine: tenant door enabled — {d} internal front addr(s), {d} suffix(es)",
            .{ self.door_addr_count, self.door_suffix_count },
        );
    }

    /// Is `host` one of our platform tenant hostnames? Label-boundary
    /// suffix match, ASCII case-insensitive: for suffix `rewindjs.app`,
    /// both `b.rewindjs.app` and the apex `rewindjs.app` match;
    /// `evil-rewindjs.app` does not.
    fn doorHostMatch(self: *const FetchEngine, host: []const u8) bool {
        for (self.door_suffixes[0..self.door_suffix_count]) |suffix| {
            if (host.len == suffix.len) {
                if (std.ascii.eqlIgnoreCase(host, suffix)) return true;
            } else if (host.len > suffix.len) {
                if (host[host.len - suffix.len - 1] == '.' and
                    std.ascii.eqlIgnoreCase(host[host.len - suffix.len ..], suffix))
                    return true;
            }
        }
        return false;
    }

    /// Tenant-door gate for one outbound URL: returns the
    /// CURLOPT_RESOLVE pin redirecting the host to the internal front
    /// addresses when the door is configured AND the URL's host is one
    /// of ours. Returns null whenever the door doesn't apply —
    /// INCLUDING on a URL that fails to parse — so the regular gate
    /// (`checkUrl`) owns the error taxonomy; this fast path never
    /// invents its own rejections.
    fn tenantDoorPin(self: *const FetchEngine, url: []const u8, buf: []u8) ?[:0]const u8 {
        if (self.door_addr_count == 0) return null;
        const parsed = ssrf_mod.parseUrl(url) catch return null;
        if (!self.doorHostMatch(parsed.host)) return null;
        // Only ever pin the front's TLS port (`door_port`, 443 in prod).
        // The pin preserves the URL's port, and CP/worker/raft are
        // co-located on the front boxes, so a `…:9090` / `…:8443` URL
        // would otherwise pin at an internal service's address. Decline
        // any other port: it falls to the public path (`checkUrl`), where
        // the host resolves to the front's PUBLIC address and the
        // internal port simply isn't exposed there. (`parseUrl` defaults
        // the port to 443 when the URL omits it, so ordinary door traffic
        // is unaffected.)
        if (parsed.port != self.door_port) return null;
        // NoSpaceLeft can only mean a host far beyond DNS's 255-byte
        // cap — decline the door; checkUrl rejects it as unresolvable.
        return buildResolvePin(buf, parsed.host, parsed.port, self.door_addrs[0..self.door_addr_count]) catch null;
    }

    /// Spawn the engine thread + create the curl_multi handle.
    /// Idempotent — second call is a no-op. Call after NodeState is
    /// wired + workers have spawned (so their fetch-chunk inboxes
    /// are registered before the first chunk hash-routes through).
    pub fn start(self: *FetchEngine) !void {
        if (self.thread != null) return;

        self.stop.store(false, .release);
        self.no_inbox_warned.store(false, .release);

        const multi = try blob_curl_multi.Multi.init(self.allocator);
        errdefer multi.deinit();
        self.multi = multi;

        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Signal the engine thread to stop + join. Drains any
    /// unprocessed inbound + cancel entries (frees them). Any
    /// in-flight transfers are removed from libcurl via
    /// `Multi.deinit`; their FetchCtxs are freed via the
    /// `inflight_by_id` walk. No on_done callbacks fire on
    /// shutdown — the customer's handler chain just stops.
    pub fn shutdown(self: *FetchEngine) void {
        if (self.thread == null) return;
        self.stop.store(true, .release);
        if (self.multi) |m| m.wakeup() catch {};
        self.thread.?.join();
        self.thread = null;

        // Free remaining inbound + cancel entries (the engine
        // exited before draining them).
        {
            self.inbound_mu.lock();
            defer self.inbound_mu.unlock();
            for (self.inbound.items) |*pf| pf.deinit(self.allocator);
            self.inbound.deinit(self.allocator);
            self.inbound = .empty;
        }
        {
            self.cancel_mu.lock();
            defer self.cancel_mu.unlock();
            for (self.cancel_ids.items) |id| self.allocator.free(id);
            self.cancel_ids.deinit(self.allocator);
            self.cancel_ids = .empty;
        }

        // Free in-flight FetchCtxs whose transfers Multi.deinit
        // already cleaned up. The map's keys borrow into
        // `ctx.pf.id` — free ctxs in a snapshot first to avoid
        // iterator invalidation.
        if (self.multi) |m| {
            var snap: std.ArrayList(*FetchCtx) = .empty;
            defer snap.deinit(self.allocator);
            var it = self.inflight_by_id.valueIterator();
            while (it.next()) |cp| snap.append(self.allocator, cp.*) catch {};
            for (snap.items) |ctx| ctx.deinit();
            self.inflight_by_id.deinit(self.allocator);
            m.deinit();
            self.multi = null;
        }
        // held_per_tenant: own the tenant_id keys.
        {
            var kit = self.held_per_tenant.keyIterator();
            while (kit.next()) |kp| self.allocator.free(kp.*);
            self.held_per_tenant.deinit(self.allocator);
        }
    }

    pub fn deinit(self: *FetchEngine) void {
        if (self.thread != null) self.shutdown();
        self.allocator.destroy(self);
    }

    /// Cross-thread: take ownership of `pf` + enqueue for the engine.
    /// Returns once the entry is in the queue; the engine thread
    /// runs it asynchronously. Fails only on `OutOfMemory` (queue
    /// growth); caller's `pf` ownership is unchanged on error so the
    /// caller can free.
    pub fn submit(self: *FetchEngine, pf: PendingFetch) !void {
        {
            self.inbound_mu.lock();
            defer self.inbound_mu.unlock();
            try self.inbound.append(self.allocator, pf);
        }
        if (self.multi) |m| m.wakeup() catch {};
    }

    /// Cross-thread: request cancellation of an in-flight fetch by
    /// id. Silently no-ops if the fetch already completed or never
    /// existed. `id` is borrowed — duped onto the queue.
    pub fn cancel(self: *FetchEngine, id: []const u8) void {
        const dup = self.allocator.dupe(u8, id) catch return;
        {
            self.cancel_mu.lock();
            defer self.cancel_mu.unlock();
            self.cancel_ids.append(self.allocator, dup) catch {
                self.allocator.free(dup);
                return;
            };
        }
        if (self.multi) |m| m.wakeup() catch {};
    }

    // ── Engine thread ─────────────────────────────────────────────────

    fn threadMain(self: *FetchEngine) void {
        while (!self.stop.load(.acquire)) {
            self.drainCancels();
            self.drainInbound();
            const multi = self.multi orelse return;
            _ = multi.poll(ENGINE_POLL_TIMEOUT_MS) catch |err| {
                std.log.warn("rove-js fetch_engine: poll: {s}", .{@errorName(err)});
                std.Thread.sleep(10 * std.time.ns_per_ms);
            };
            _ = multi.drainCompleted();
        }
    }

    fn drainInbound(self: *FetchEngine) void {
        var batch: std.ArrayList(PendingFetch) = .empty;
        defer batch.deinit(self.allocator);
        {
            self.inbound_mu.lock();
            defer self.inbound_mu.unlock();
            if (self.inbound.items.len == 0) return;
            std.mem.swap(std.ArrayList(PendingFetch), &batch, blk: {
                // Promote ArrayListUnmanaged → ArrayList for the
                // swap (the cross-thread queue stores unmanaged for
                // explicit-allocator hygiene; the engine-side batch
                // wants `.empty` semantics either way). Easier: drain
                // by element below.
                break :blk &batch; // unreachable; not used
            });
            // Drain by element move (no swap helper between the two
            // types in stdlib 0.15).
            batch.ensureUnusedCapacity(self.allocator, self.inbound.items.len) catch return;
            for (self.inbound.items) |pf| batch.appendAssumeCapacity(pf);
            self.inbound.clearRetainingCapacity();
        }

        for (batch.items) |pf_const| {
            var pf = pf_const;
            self.startTransfer(&pf) catch |err| {
                if (err == error.HeldCapExceeded) {
                    // Per-tenant cap rejection: defined `final: true,
                    // ok: false` event so the customer's `on_chunk`
                    // handler fires once and can surface the
                    // condition. NOT logged as a warning — this is
                    // the customer's responsibility to handle (same
                    // posture as rate-limit rejection).
                    emitFailedSetupEvent(self, &pf) catch {};
                } else {
                    std.log.warn(
                        "rove-js fetch_engine: startTransfer tenant={s} id={s}: {s}",
                        .{ pf.tenant_id, pf.id, @errorName(err) },
                    );
                    // Setup failure: same single-final-event posture
                    // so the customer's handler chain still runs.
                    emitFailedSetupEvent(self, &pf) catch {};
                }
                pf.deinit(self.allocator);
            };
        }
    }

    fn drainCancels(self: *FetchEngine) void {
        var batch: std.ArrayList([]u8) = .empty;
        defer batch.deinit(self.allocator);
        {
            self.cancel_mu.lock();
            defer self.cancel_mu.unlock();
            if (self.cancel_ids.items.len == 0) return;
            batch.ensureUnusedCapacity(self.allocator, self.cancel_ids.items.len) catch return;
            for (self.cancel_ids.items) |id| batch.appendAssumeCapacity(id);
            self.cancel_ids.clearRetainingCapacity();
        }
        defer for (batch.items) |id| self.allocator.free(id);

        for (batch.items) |id| {
            if (self.inflight_by_id.fetchRemove(id)) |kv| {
                const ctx = kv.value;
                if (ctx.held) self.bumpHeldCount(ctx.pf.tenant_id, -1);
                if (self.multi) |m| m.cancel(ctx.transfer);
                ctx.deinit();
            }
        }
    }

    /// Build the Transfer + FetchCtx + register on multi. Ownership of
    /// `pf` transfers into the new FetchCtx on success; caller's
    /// `pf.deinit` is skipped on success (the FetchCtx frees it on
    /// completion).
    fn startTransfer(self: *FetchEngine, pf: *PendingFetch) !void {
        if (self.inflight_by_id.count() >= ENGINE_MAX_INFLIGHT) {
            return error.TooManyInflight;
        }
        // Phase 3 (gap 2.5): per-tenant held-subscription cap. Check
        // BEFORE allocating any state so the rejection path is
        // cheap. The defined rejection (a single `final: true,
        // ok: false` event with `body_truncated = false`) fires
        // via `drainInbound`'s catch — return a sentinel error
        // here.
        if (pf.held) {
            const cur = if (self.held_per_tenant.get(pf.tenant_id)) |c| c else 0;
            if (cur >= HELD_MAX_PER_TENANT) return error.HeldCapExceeded;
        }

        var headers_list: std.ArrayListUnmanaged(blob_curl_multi.Header) = .empty;
        defer {
            for (headers_list.items) |h| {
                self.allocator.free(h.name);
                self.allocator.free(h.value);
            }
            headers_list.deinit(self.allocator);
        }
        try parseHeadersJson(self.allocator, pf.headers_json, &headers_list);

        const method = parseMethod(pf.method) orelse return error.UnsupportedMethod;

        // blob-storage-plan P1; `docs/architecture/routing-and-ingress.md`: the blob.* trusted door.
        // The JS shims fetch `http://rove-blob.internal/{hash}`; the
        // engine rewrites that to the calling tenant's `app-blobs/`
        // key on the real S3 endpoint and SigV4-signs it natively.
        // Tenant identity comes from `pf.tenant_id` (stamped by the
        // binding from the activation, never JS-supplied), so a
        // handler can only ever reach its own prefix; the signing
        // keys never enter JS space. Setup errors here surface as
        // the standard single `final: true, ok: false` event via
        // `drainInbound`'s catch.
        //
        // SSRF gate (PLAN §2.6): every CUSTOMER-supplied URL is
        // policy-checked per attempt (scheme ∈ http(s), TLS-always
        // unless the test hatch, no blocklisted resolution — see
        // rove-ssrf), and the vetted address is pinned via
        // CURLOPT_RESOLVE so a second DNS answer (rebinding) can't
        // move the connect. The blob door is exempt: its URL is
        // rewritten to the platform-configured S3 endpoint (which
        // may legitimately be private), never customer-controlled.
        // Customer transfers also run with redirects OFF (the
        // Request doc explains why); a blocked URL surfaces as the
        // standard failed-setup event (`terminal_ok=false`).
        var pin_buf: [768]u8 = undefined;
        var resolve_pin: ?[:0]const u8 = null;
        const is_blob_door = std.mem.startsWith(u8, pf.url, BLOB_ORIGIN_PREFIX);
        const is_blob_read_door = std.mem.startsWith(u8, pf.url, BLOB_READ_ORIGIN_PREFIX);
        const is_logs_door = std.mem.startsWith(u8, pf.url, LOGS_ORIGIN_PREFIX);
        const is_cp_door = std.mem.startsWith(u8, pf.url, CP_ORIGIN_PREFIX);
        if (is_blob_door) {
            try self.rewriteAndSignBlobFetch(pf, method, &headers_list);
        } else if (is_blob_read_door) {
            // Cross-tenant blob READ door: rewrite to the TARGET tenant's S3
            // prefix (from the URL path) + SigV4-sign. __admin__-gated; same
            // SSRF-exempt internal-origin posture as the blob/logs/cp doors.
            try self.rewriteAndSignBlobReadFetch(pf, method, &headers_list);
        } else if (is_logs_door) {
            // `rewind-logs.internal` door: rewrite to the internal log-server
            // base + attach a tenant-scoped `logs-read` token. Like the blob
            // door, the rewritten URL targets a platform-configured internal
            // origin (never customer-controlled), so it skips the SSRF gate.
            try self.rewriteAndAuthLogsFetch(pf, method, &headers_list);
        } else if (is_cp_door) {
            // `rewind-cp.internal` door: rewrite to the CP base + attach the
            // move-secret. Same SSRF-exempt internal-origin posture as the
            // logs/blob doors.
            try self.rewriteAndAuthCpFetch(pf, method, &headers_list);
        } else if (self.tenantDoorPin(pf.url, &pin_buf)) |pin| {
            // Tenant door: the host is one of OUR tenant hostnames —
            // pin the connect to the internal front addresses (private
            // plane) instead of public DNS. See the field doc on
            // `door_addrs` for the full semantics + SSRF argument.
            resolve_pin = pin;
            std.log.info(
                "rove-js fetch_engine: tenant door — outbound to {s} pinned to internal front (tenant={s} id={s})",
                .{ pf.url, pf.tenant_id, pf.id },
            );
        } else {
            const checked = ssrf_mod.checkUrl(self.allocator, pf.url) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    std.log.warn(
                        "rove-js fetch_engine: outbound blocked tenant={s} id={s}: {s} url={s}",
                        .{ pf.tenant_id, pf.id, @errorName(err), pf.url },
                    );
                    return error.OutboundBlocked;
                },
            };
            if (!checked.host_is_literal)
                resolve_pin = try buildResolvePin(
                    &pin_buf,
                    checked.host,
                    checked.port,
                    checked.addresses[0..checked.address_count],
                );
        }

        const req: blob_curl_multi.Request = .{
            .method = method,
            .url = pf.url,
            .headers = headers_list.items,
            .body = pf.body,
            // Held transfers: `timeout_ms = 0` means "no timeout"
            // per libcurl (CURLOPT_TIMEOUT_MS=0 is the documented
            // no-timeout sentinel). The binding already forces
            // `pf.timeout_ms = 0` for `http.subscribe`; we defend
            // here too in case a caller routes a held pf through
            // some other entry point.
            .timeout_ms = if (pf.held) 0 else pf.timeout_ms,
            .verify_tls = !ssrf_mod.test_allow_plaintext,
            .follow_redirects = is_blob_door or is_blob_read_door,
            .resolve_pin = resolve_pin,
            // The standalone log-server is h2c-only (nghttp2 prior-knowledge),
            // so a plaintext logs-door fetch must force cleartext HTTP/2 —
            // same stance as the worker→log push (`worker_log.sendPushChunk`).
            // A TLS internal base (https) negotiates h2 via ALPN as usual.
            .http2_prior_knowledge = (is_logs_door or is_cp_door) and std.mem.startsWith(u8, pf.url, "http://"),
        };

        const ctx = try self.allocator.create(FetchCtx);
        errdefer self.allocator.destroy(ctx);
        ctx.* = .{
            .engine = self,
            .allocator = self.allocator,
            .pf = pf.*, // take ownership; caller skips deinit on success
            .stream_mode = pf.stream,
            .max_chunk = @max(@as(usize, pf.max_response_chunk_bytes), 1),
            .max_total = pf.max_total_response_bytes,
            .effective_total_cap = if (pf.stream)
                pf.max_total_response_bytes
            else
                @as(u64, @max(@as(usize, pf.max_response_chunk_bytes), 1)),
            .held = pf.held,
            .transfer = undefined, // wired below
        };
        // From here on, the FetchCtx owns the pf — clear the
        // caller's slices so its deinit is a no-op.
        pf.* = .{
            .tenant_id = &.{},
            .id = &.{},
            .url = &.{},
            .method = &.{},
            .headers_json = &.{},
            .body = &.{},
            .timeout_ms = 0,
            .on_chunk_module = &.{},
            .ctx_json = &.{},
            .stream = false,
            .max_response_chunk_bytes = 0,
            .max_total_response_bytes = 0,
            .held = false,
        };

        const transfer = try blob_curl_multi.Transfer.initStreaming(
            self.allocator,
            req,
            &onChunkCb,
            &onHeaderLineCb,
            &onDoneCb,
            @ptrCast(ctx),
        );
        errdefer transfer.deinit();
        ctx.transfer = transfer;

        try self.inflight_by_id.put(self.allocator, ctx.pf.id, ctx);
        errdefer _ = self.inflight_by_id.remove(ctx.pf.id);

        try self.multi.?.add(transfer);

        if (ctx.held) self.bumpHeldCount(ctx.pf.tenant_id, 1);
    }

    /// blob-storage-plan P1; `docs/architecture/routing-and-ingress.md`: rewrite a `rove-blob.internal`
    /// placeholder URL to the calling tenant's content-addressed key
    /// on the real S3 endpoint and attach SigV4 auth headers.
    ///
    /// - Key shape is locked to `{key_prefix_base}{tenant}/app-blobs/
    ///   {sha256-hex}` — the tenant comes from `pf.tenant_id`, the
    ///   hash from the URL tail (validated 64 lowercase hex), so JS
    ///   cannot escape its own prefix by construction.
    /// - Method allowlist GET / PUT / HEAD. No DELETE through this
    ///   door (plan §7.1 — no customer delete at launch).
    /// - JS-supplied headers are dropped except `content-type`
    ///   (useful on PUT, not signed — only host / x-amz-date /
    ///   x-amz-content-sha256 enter the signature). Anything else a
    ///   shim set (or tried to spoof — `authorization`, `x-amz-*`)
    ///   never reaches the wire.
    fn rewriteAndSignBlobFetch(
        self: *FetchEngine,
        pf: *PendingFetch,
        method: blob_curl_multi.Method,
        headers_list: *std.ArrayListUnmanaged(blob_curl_multi.Header),
    ) !void {
        const cfg = &self.node.blob_backend_cfg;
        if (cfg.endpoint.len == 0) return error.BlobBackendUnconfigured;
        if (pf.tenant_id.len == 0) return error.BlobNoTenant;

        const hash = pf.url[BLOB_ORIGIN_PREFIX.len..];
        if (!isSha256HexLower(hash)) return error.BlobBadKey;

        const method_name = switch (method) {
            .GET => "GET",
            .PUT => "PUT",
            .HEAD => "HEAD",
            else => return error.BlobMethodDenied,
        };

        // Path used both for signing and the wire URL (path-style S3).
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/{s}{s}/app-blobs/{s}",
            .{ cfg.bucket, cfg.key_prefix_base, pf.tenant_id, hash },
        );
        defer self.allocator.free(path);

        const scheme = if (cfg.use_tls) "https" else "http";
        const new_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}://{s}{s}",
            .{ scheme, cfg.endpoint, path },
        );
        self.allocator.free(pf.url);
        pf.url = new_url;

        try self.signAndAttachS3(method_name, path, pf.body, headers_list);
    }

    /// SigV4-sign `path` (path-style S3) for the configured blob endpoint and
    /// attach the three auth headers, dropping every JS-supplied header except
    /// `content-type`. Shared by the own-tenant blob door and the cross-tenant
    /// blob-read door (the signing is identical — only the key prefix differs).
    fn signAndAttachS3(
        self: *FetchEngine,
        method_name: []const u8,
        path: []const u8,
        body: []const u8,
        headers_list: *std.ArrayListUnmanaged(blob_curl_multi.Header),
    ) !void {
        const cfg = &self.node.blob_backend_cfg;
        var ts_buf: [16]u8 = undefined;
        blob_sigv4.formatAmzDate(&ts_buf, std.time.timestamp());
        const signed = try blob_sigv4.sign(self.allocator, .{
            .method = method_name,
            .path = path,
            .host = cfg.endpoint,
            .body = body,
            .access_key = cfg.access_key,
            .secret_key = cfg.secret_key,
            .region = cfg.region,
            .service = "s3",
            .timestamp = &ts_buf,
        });
        const values = [3][]u8{ signed.authorization, signed.x_amz_date, signed.x_amz_content_sha256 };
        // Until a value is appended to `headers_list` (whose caller-side defer
        // frees name+value of every entry), it is ours to free on error.
        var attached: usize = 0;
        errdefer for (values[attached..]) |v| self.allocator.free(v);

        // Drop every JS-supplied header except content-type.
        var i: usize = 0;
        while (i < headers_list.items.len) {
            const h = headers_list.items[i];
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                i += 1;
                continue;
            }
            self.allocator.free(h.name);
            self.allocator.free(h.value);
            _ = headers_list.swapRemove(i);
        }

        // Attach the three SigV4 headers. Names are dup'd so every entry
        // uniformly owns name + value (the caller's defer frees both); the
        // signed values transfer ownership in.
        try headers_list.ensureUnusedCapacity(self.allocator, 3);
        const names = [3][]const u8{ "authorization", "x-amz-date", "x-amz-content-sha256" };
        for (names, values) |n, v| {
            const owned_name = try self.allocator.dupe(u8, n);
            headers_list.appendAssumeCapacity(.{ .name = owned_name, .value = v });
            attached += 1;
        }
    }

    /// Cross-tenant blob READ door (`rove-blob-read.internal`) — the read twin
    /// of `platform.scope(t).blob.put`. Rewrites
    /// `{tenant}/blob/{hash}` → `{key_prefix_base}{tenant}/file-blobs/{hash}`
    /// and `{tenant}/manifest/{dep_hex}` →
    /// `{key_prefix_base}{tenant}/deployments/{manifestKey}` on the real S3
    /// endpoint, then SigV4-signs. Only `__admin__` may form this host (the
    /// routing gate); the TARGET tenant comes from the URL PATH (cross-tenant
    /// by design). GET/HEAD only — there is no write/delete through this door.
    fn rewriteAndSignBlobReadFetch(
        self: *FetchEngine,
        pf: *PendingFetch,
        method: blob_curl_multi.Method,
        headers_list: *std.ArrayListUnmanaged(blob_curl_multi.Header),
    ) !void {
        // Routing gate: only the admin tenant may use the read door.
        if (!std.mem.eql(u8, pf.tenant_id, tenant_mod.ADMIN_INSTANCE_ID))
            return error.BlobReadForbidden;
        const cfg = &self.node.blob_backend_cfg;
        if (cfg.endpoint.len == 0) return error.BlobBackendUnconfigured;
        const method_name = switch (method) {
            .GET => "GET",
            .HEAD => "HEAD",
            else => return error.BlobMethodDenied,
        };

        // Parse `{tenant}/{kind}/{key}` from the URL tail.
        const remainder = pf.url[BLOB_READ_ORIGIN_PREFIX.len..];
        var it = std.mem.splitScalar(u8, remainder, '/');
        const tenant = it.next() orelse return error.BlobReadBadPath;
        const kind = it.next() orelse return error.BlobReadBadPath;
        const ukey = it.rest();
        if (!isValidScopeId(tenant)) return error.BlobReadBadPath;

        // Resolve the subdir + the actual blob key by kind. The charset/format
        // checks pin the key so it can't escape the tenant prefix.
        var key_buf: [25]u8 = undefined;
        var subdir: []const u8 = undefined;
        var blob_key: []const u8 = undefined;
        if (std.mem.eql(u8, kind, "blob")) {
            if (!isSha256HexLower(ukey)) return error.BlobReadBadPath;
            subdir = "file-blobs";
            blob_key = ukey;
        } else if (std.mem.eql(u8, kind, "manifest")) {
            const dep_id = std.fmt.parseInt(u64, ukey, 16) catch return error.BlobReadBadPath;
            subdir = "deployments";
            blob_key = files_mod.manifest_json.manifestKey(&key_buf, dep_id);
        } else return error.BlobReadBadPath;

        const path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/{s}{s}/{s}/{s}",
            .{ cfg.bucket, cfg.key_prefix_base, tenant, subdir, blob_key },
        );
        defer self.allocator.free(path);

        const scheme = if (cfg.use_tls) "https" else "http";
        const new_url = try std.fmt.allocPrint(self.allocator, "{s}://{s}{s}", .{ scheme, cfg.endpoint, path });
        self.allocator.free(pf.url);
        pf.url = new_url;

        try self.signAndAttachS3(method_name, path, pf.body, headers_list);
    }

    /// `rewind-logs.internal` trusted door (step3-auth-plan.md A2/A3). The
    /// `__admin__` chokepoint fetches `http://rewind-logs.internal/v1/{tenant}/…`;
    /// here we mint a TENANT-SCOPED `logs-read` capability token, rewrite the
    /// host to the platform-configured internal log-server base, and attach the
    /// token as `Authorization: Bearer`. The log-server then verifies cap +
    /// tenant (`standalone.zig`, `verifyWithCapAndTenant`).
    ///
    /// Two grants, decided by the calling tenant (step3-auth-plan.md §4,
    /// Option A):
    ///   • ANY tenant may read its OWN logs — the URL tenant in
    ///     `/v1/{tenant}/…` MUST equal `pf.tenant_id`. This is what the
    ///     browser-agent handler uses for `getReplay` (self-tenant,
    ///     safe-by-construction: the engine pins the token to the
    ///     caller's own tenant, so the URL can't reach another's logs).
    ///   • `__admin__` may target ANY tenant (the operator/cross-tenant
    ///     path) — its `pf.tenant_id` is `__admin__`, so the scope is
    ///     taken from the URL PATH instead.
    /// Either way the minted token is scoped to the URL's `target_tenant`,
    /// so the log-server's `verifyWithCapAndTenant` pins the read. The
    /// signing secret never enters JS space.
    fn rewriteAndAuthLogsFetch(
        self: *FetchEngine,
        pf: *PendingFetch,
        method: blob_curl_multi.Method,
        headers_list: *std.ArrayListUnmanaged(blob_curl_multi.Header),
    ) !void {
        const is_admin = std.mem.eql(u8, pf.tenant_id, tenant_mod.ADMIN_INSTANCE_ID);
        const secret = self.node.services_jwt_secret orelse return error.LogsDoorUnconfigured;
        const base = self.node.log_internal_base orelse return error.LogsDoorUnconfigured;
        // Read-only surface: the log query routes are all GET.
        if (method != .GET) return error.LogsMethodDenied;

        // Path after the door prefix, e.g. `v1/{tenant}/list?limit=20`.
        const remainder = pf.url[LOGS_ORIGIN_PREFIX.len..];
        const target_tenant = parseLogsTenant(remainder) orelse return error.LogsBadPath;

        // Self-tenant grant: a non-admin caller may only read its own
        // logs. __admin__ skips this (it reads from the URL path).
        if (!is_admin and !std.mem.eql(u8, pf.tenant_id, target_tenant))
            return error.LogsDoorForbidden;

        const now_ms: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
        const token = jwt.mint(self.allocator, secret, .{
            .exp_ms = now_ms + 60 * 1000,
            .caps = &.{jwt.Cap.LOGS_READ},
            .tenant = target_tenant,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // InvalidTenant: the path segment held a char outside [a-zA-Z0-9_-].
            else => return error.LogsBadPath,
        };
        defer self.allocator.free(token);

        // Rewrite the host to the internal log-server base. `base` carries no
        // trailing slash (e.g. `http://127.0.0.1:9000`); `remainder` carries no
        // leading slash, so one `/` joins them.
        const new_url = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base, remainder });
        self.allocator.free(pf.url);
        pf.url = new_url;

        // Drop any JS-supplied `authorization` header, then attach ours — the
        // handler never sets credentials; the engine owns this header.
        var i: usize = 0;
        while (i < headers_list.items.len) {
            const h = headers_list.items[i];
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                self.allocator.free(h.name);
                self.allocator.free(h.value);
                _ = headers_list.swapRemove(i);
                continue;
            }
            i += 1;
        }
        try headers_list.ensureUnusedCapacity(self.allocator, 1);
        const owned_name = try self.allocator.dupe(u8, "authorization");
        errdefer self.allocator.free(owned_name);
        const auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
        headers_list.appendAssumeCapacity(.{ .name = owned_name, .value = auth_value });
    }

    /// `rewind-cp.internal` trusted door (step3-auth-plan.md B4). The `__admin__`
    /// dashboard fetches `http://rewind-cp.internal/_control/…` (control ops) or
    /// `/_cp/…` (reads); here we attach the platform move-secret and rewrite the
    /// host to the configured CP base. So an operator drives CP control ops
    /// (provision/move/host/plan) through the OIDC dashboard with NO CP secret
    /// of their own — the worker holds it. Only `__admin__` may form this host
    /// (the routing gate); the move-secret never enters JS space. Restricted to
    /// the CP's `_control/`+`_cp/` surfaces so the door can't proxy arbitrary
    /// paths.
    fn rewriteAndAuthCpFetch(
        self: *FetchEngine,
        pf: *PendingFetch,
        method: blob_curl_multi.Method,
        headers_list: *std.ArrayListUnmanaged(blob_curl_multi.Header),
    ) !void {
        if (!std.mem.eql(u8, pf.tenant_id, tenant_mod.ADMIN_INSTANCE_ID))
            return error.CpDoorForbidden;
        const secret = self.node.move_secret orelse return error.CpDoorUnconfigured;
        const base = self.node.cp_internal_base orelse return error.CpDoorUnconfigured;
        if (method != .POST and method != .GET) return error.CpMethodDenied;

        // Path after the door prefix, e.g. `_control/provision` / `_cp/route?…`.
        const remainder = pf.url[CP_ORIGIN_PREFIX.len..];
        const path_only = if (std.mem.indexOfScalar(u8, remainder, '?')) |q| remainder[0..q] else remainder;
        if (!std.mem.startsWith(u8, path_only, "_control/") and
            !std.mem.startsWith(u8, path_only, "_cp/"))
            return error.CpBadPath;

        const new_url = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base, remainder });
        self.allocator.free(pf.url);
        pf.url = new_url;

        // Drop any JS-supplied move-secret header; attach the real one.
        var i: usize = 0;
        while (i < headers_list.items.len) {
            const h = headers_list.items[i];
            if (std.ascii.eqlIgnoreCase(h.name, "x-rewind-move-secret")) {
                self.allocator.free(h.name);
                self.allocator.free(h.value);
                _ = headers_list.swapRemove(i);
                continue;
            }
            i += 1;
        }
        try headers_list.ensureUnusedCapacity(self.allocator, 1);
        const owned_name = try self.allocator.dupe(u8, "x-rewind-move-secret");
        errdefer self.allocator.free(owned_name);
        const owned_val = try self.allocator.dupe(u8, secret);
        headers_list.appendAssumeCapacity(.{ .name = owned_name, .value = owned_val });
    }

    /// Adjust the per-tenant held count by `delta` (+1 or -1).
    /// Inserts a tenant-id-owning key on first-sight; drops the
    /// entry (and frees its key) when the count returns to 0.
    fn bumpHeldCount(self: *FetchEngine, tenant_id: []const u8, delta: i32) void {
        const gop = self.held_per_tenant.getOrPut(self.allocator, tenant_id) catch return;
        if (!gop.found_existing) {
            // First-sight: dup tenant_id as the map-owned key so
            // we outlive any single ctx (multiple held xfers per
            // tenant share this key).
            const owned_key = self.allocator.dupe(u8, tenant_id) catch {
                _ = self.held_per_tenant.remove(tenant_id);
                return;
            };
            // Replace the borrowed key with the owned copy by
            // re-inserting. (StringHashMap doesn't expose key
            // replacement; remove + put round-trips it.)
            _ = self.held_per_tenant.remove(tenant_id);
            self.held_per_tenant.put(self.allocator, owned_key, 0) catch {
                self.allocator.free(owned_key);
                return;
            };
            // Now re-fetch via the owned key.
            const v_ptr = self.held_per_tenant.getPtr(owned_key) orelse return;
            const new_count = @as(i64, @intCast(v_ptr.*)) + delta;
            if (new_count <= 0) {
                if (self.held_per_tenant.fetchRemove(owned_key)) |kv| {
                    self.allocator.free(kv.key);
                }
                return;
            }
            v_ptr.* = @intCast(new_count);
            return;
        }
        const new_count = @as(i64, @intCast(gop.value_ptr.*)) + delta;
        if (new_count <= 0) {
            if (self.held_per_tenant.fetchRemove(gop.key_ptr.*)) |kv| {
                self.allocator.free(kv.key);
            }
        } else {
            gop.value_ptr.* = @intCast(new_count);
        }
    }

    fn routeEvent(self: *FetchEngine, tenant_id: []const u8, ev: UpstreamFetchEvent) !void {
        var event = ev;
        // `docs/chunk-spool-plan.md` Phase 1: bound-fetch chunk bytes
        // become durable via the process-global blob coordinator at
        // upstream rate, decoupled from the held chain's raft commit
        // cadence. This stamps `coord_seq`/`coord_worker_id` on the
        // event; the consumer still reads inline `bytes` (no behavior
        // change). Phases 2-3 switch the consumer onto a spool that
        // reads bytes back from the coordinator.
        self.submitBoundChunkToCoord(&event);
        self.node.router.enqueueFetchEventForTenant(tenant_id, event) catch |err| {
            if (err == error.NoWorkers and
                !self.no_inbox_warned.swap(true, .acq_rel))
            {
                std.log.warn(
                    "rove-js fetch_engine: no worker inboxes registered; dropping fetch event tenant={s}",
                    .{tenant_id},
                );
            }
            return err;
        };
    }

    /// `docs/chunk-spool-plan.md` Phase 1: write a bound-fetch chunk's
    /// bytes to the process-global blob coordinator and stamp the
    /// resulting `(worker_id, seq)` on the event. The coordinator dups
    /// the bytes internally, so the event retains ownership of `bytes`
    /// and the inline copy stays the consumer's source of truth for
    /// Phase 1.
    ///
    /// Best-effort and side-effect-free on the read path: if this is
    /// not a bound chunk, the coordinator isn't up, the owner isn't
    /// registered yet, or the submit fails, the fields stay 0 and the
    /// consumer simply uses `bytes`. We submit under the owning
    /// worker's id (== its coord queue id, == its `log_worker_id`) so
    /// the consumer can later gate on `durableSeq(coord_worker_id)`;
    /// that's the same owner the slim Msg routes to via
    /// `bound_fetch_owners`.
    fn submitBoundChunkToCoord(self: *FetchEngine, ev: *UpstreamFetchEvent) void {
        if (!ev.bind) return;
        if (ev.bytes.len == 0) return;
        const coord = self.node.blob_coord.coordinator orelse return;
        const owner_idx = self.node.router.lookupBoundFetchOwner(ev.fetch_id) orelse return;
        const wid = std.math.cast(u8, owner_idx) orelse return;
        const seq = coord.submit(wid, ev.bytes) catch |err| {
            std.log.warn(
                "rove-js chunk-spool: coord.submit fetch_id={s} seq={d} bytes={d}: {s}",
                .{ ev.fetch_id, ev.seq, ev.bytes.len, @errorName(err) },
            );
            return;
        };
        ev.coord_seq = seq;
        ev.coord_worker_id = wid;
        ev.coord_submitted = true;
    }
};

// ── Per-transfer streaming state ──────────────────────────────────────

/// Per-transfer state — mirrors `fetch_pool.StreamState` field-for-field,
/// just heap-allocated (Phase 1's `Transfer` does not own this).
/// Lifetime: created in `startTransfer`, freed in `onDoneCb`.
const FetchCtx = struct {
    engine: *FetchEngine,
    allocator: std.mem.Allocator,
    /// Owned. Slices are freed via `pf.deinit` on completion.
    pf: PendingFetch,
    /// Borrowed back-pointer to the Transfer (we own the FetchCtx;
    /// libcurl owns the Transfer via Multi). Used only by
    /// `FetchEngine.cancel` to dispatch `Multi.cancel`.
    transfer: *blob_curl_multi.Transfer,

    stream_mode: bool,
    max_chunk: usize,
    max_total: u64,
    effective_total_cap: u64,
    /// `docs/curl-multi-plan.md` Phase 3: held subscription. When
    /// true the engine counts this against the per-tenant held cap
    /// and treats completion as "subscription ended" rather than
    /// "fetch succeeded."
    held: bool,

    /// Raw response header block (libcurl-delivered `Name: value\r\n`
    /// lines + status + blank terminator). Parsed into a JSON object
    /// on the seq-0 emit.
    headers: std.ArrayListUnmanaged(u8) = .empty,

    emitted_seq: u32 = 0,
    byte_offset: u64 = 0,
    total: u64 = 0,

    failed: bool = false,
    capped: bool = false,

    /// `stream: false` mode: body buffered here, emitted as one
    /// `final: true` event in `onDoneCb`. Empty in `stream: true`.
    body_buf: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *FetchCtx) void {
        var pf = self.pf;
        pf.deinit(self.allocator);
        self.headers.deinit(self.allocator);
        self.body_buf.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Build + route one chunk event for `bytes` (borrowed — dup'd
    /// into the event). Returns false on alloc / route failure
    /// (caller sets `failed`).
    fn emitChunk(self: *FetchCtx, bytes: []const u8) bool {
        var headers_json: ?[]u8 = null;
        if (self.emitted_seq == 0 and self.headers.items.len > 0) {
            headers_json = parseHeadersWireToJson(self.allocator, self.headers.items) catch null;
        }
        const ev = buildChunkEvent(
            self.allocator,
            &self.pf,
            self.emitted_seq,
            self.byte_offset,
            bytes,
            headers_json,
        ) catch {
            if (headers_json) |hj| self.allocator.free(hj);
            return false;
        };
        self.engine.routeEvent(self.pf.tenant_id, ev) catch |err| {
            var e = ev;
            UpstreamFetchEvent.deinitItem(&e, self.allocator);
            std.log.warn(
                "rove-js fetch_engine: route chunk seq={d}: {s}",
                .{ self.emitted_seq, @errorName(err) },
            );
            return false;
        };
        self.emitted_seq += 1;
        self.byte_offset += bytes.len;
        return true;
    }
};

// ── curl_multi callback bridges ───────────────────────────────────────

/// Per-writeback chunk callback — engine-thread, fires inside
/// `multi.poll`. Mirrors `fetch_pool.onBody` exactly.
fn onChunkCb(bytes: []const u8, ctx: ?*anyopaque) bool {
    const s: *FetchCtx = @ptrCast(@alignCast(ctx.?));
    if (s.failed or s.capped) return false;
    if (bytes.len == 0) return true;

    var take = bytes;
    const remaining: usize = @intCast(s.effective_total_cap - s.total);
    if (bytes.len >= remaining) {
        take = bytes[0..remaining];
        s.capped = true;
    }
    s.total += take.len;

    if (s.stream_mode) {
        // Stream mode: emit per writeback, split into ≤ max_chunk.
        var off: usize = 0;
        while (off < take.len) {
            const end = @min(off + s.max_chunk, take.len);
            if (!s.emitChunk(take[off..end])) {
                s.failed = true;
                return false;
            }
            off = end;
        }
        return !s.capped;
    } else {
        // Single-chunk: buffer; emit ONE final event in onDoneCb.
        s.body_buf.appendSlice(s.allocator, take) catch {
            s.failed = true;
            return false;
        };
        return !s.capped;
    }
}

/// Per-header-line callback — accumulates the raw block.
fn onHeaderLineCb(line: []const u8, ctx: ?*anyopaque) void {
    const s: *FetchCtx = @ptrCast(@alignCast(ctx.?));
    if (s.failed) return;
    s.headers.appendSlice(s.allocator, line) catch {
        s.failed = true;
    };
}

/// Transfer completion — fires inside `multi.drainCompleted`. Emit
/// the terminal event, remove from inflight_by_id, free the ctx.
fn onDoneCb(transfer: *blob_curl_multi.Transfer, result: blob_curl_multi.Result, ctx: ?*anyopaque) void {
    const s: *FetchCtx = @ptrCast(@alignCast(ctx.?));

    // Transport-only: libcurl finished cleanly AND we hit no
    // alloc/route failure. Cap-only truncation is NOT a failure
    // (the customer explicitly bounded the response).
    const transport_ok = result.ok and !s.failed;
    if (!result.ok) {
        // Operator-readable transport failure — the customer-visible
        // outcome is just `ok=false`, so this line is the only place
        // the curl reason (timeout vs DNS vs connect vs policy)
        // surfaces.
        std.log.warn(
            "rove-js fetch_engine: transport failed tenant={s} id={s} curl_code={d} err={s}",
            .{ s.pf.tenant_id, s.pf.id, result.curl_code, std.mem.sliceTo(&transfer.err_buf, 0) },
        );
    }

    if (!s.stream_mode) {
        // Phase 5 PR-1: ONE event with `final: true` + the body +
        // terminal fields.
        emitFinalWithBody(s, result.status, transport_ok) catch |err|
            std.log.warn(
                "rove-js fetch_engine: emit final tenant={s} id={s}: {s}",
                .{ s.pf.tenant_id, s.pf.id, @errorName(err) },
            );
    } else {
        // Stream mode: per-writeback events already fired with
        // final=false. A separate empty-bytes event carries the
        // terminal — distinguishes "more frames" from "complete."
        emitFinalEmpty(s, result.status, transport_ok) catch |err|
            std.log.warn(
                "rove-js fetch_engine: emit final-empty tenant={s} id={s}: {s}",
                .{ s.pf.tenant_id, s.pf.id, @errorName(err) },
            );
    }

    // Engine-thread bookkeeping: remove from inflight + free ctx.
    // Held subscriptions also decrement the per-tenant cap counter.
    if (s.held) s.engine.bumpHeldCount(s.pf.tenant_id, -1);
    _ = s.engine.inflight_by_id.remove(s.pf.id);
    s.deinit();
}

/// `"{host}:{port}:{ip1,ip2,…}"` for `CURLOPT_RESOLVE` — pins the
/// transfer's connect to the SSRF-vetted address set. The WHOLE
/// vetted set is pinned (every address was blocklist-checked), not
/// just the first, so curl keeps its normal multi-address connect
/// fallback — e.g. `*.localhost` resolves to both `::1` and
/// `127.0.0.1` while the test echo node binds v4 only. IPv6 goes in
/// brackets (curl's requirement for numeric v6); the host is
/// lowercased in place so curl's case-insensitive host match hits
/// the entry. Only called for DNS-name hosts (a literal-IP URL has
/// nothing to rebind).
fn buildResolvePin(buf: []u8, host: []const u8, port: u16, addrs: []const std.net.Address) ![:0]const u8 {
    var n: usize = 0;
    n += (try std.fmt.bufPrint(buf[n..], "{s}:{d}:", .{ host, port })).len;
    for (addrs, 0..) |addr, i| {
        if (i != 0) {
            if (n + 1 >= buf.len) return error.NoSpaceLeft;
            buf[n] = ',';
            n += 1;
        }
        n += (try printPinIp(buf[n..], addr)).len;
    }
    if (n >= buf.len) return error.NoSpaceLeft;
    buf[n] = 0;
    const pin = buf[0..n :0];
    for (pin[0..host.len]) |*ch| ch.* = std.ascii.toLower(ch.*);
    return pin;
}

fn printPinIp(buf: []u8, addr: std.net.Address) ![]const u8 {
    return switch (addr.any.family) {
        std.posix.AF.INET => blk: {
            const o: [4]u8 = @bitCast(addr.in.sa.addr);
            break :blk try std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ o[0], o[1], o[2], o[3] });
        },
        std.posix.AF.INET6 => blk: {
            const b = addr.in6.sa.addr;
            break :blk try std.fmt.bufPrint(buf, "[{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}]", .{
                std.mem.readInt(u16, b[0..2], .big),   std.mem.readInt(u16, b[2..4], .big),
                std.mem.readInt(u16, b[4..6], .big),   std.mem.readInt(u16, b[6..8], .big),
                std.mem.readInt(u16, b[8..10], .big),  std.mem.readInt(u16, b[10..12], .big),
                std.mem.readInt(u16, b[12..14], .big), std.mem.readInt(u16, b[14..16], .big),
            });
        },
        else => error.OutboundBlocked,
    };
}

test "buildResolvePin: v4 + v6 set + lowercasing" {
    var buf: [768]u8 = undefined;
    const v4 = try std.net.Address.parseIp("93.184.216.34", 443);
    const pin4 = try buildResolvePin(&buf, "Example.COM", 443, &.{v4});
    try std.testing.expectEqualStrings("example.com:443:93.184.216.34", pin4);

    var buf2: [768]u8 = undefined;
    const v6 = try std.net.Address.parseIp("::1", 8443);
    const v4b = try std.net.Address.parseIp("127.0.0.1", 8443);
    const pin = try buildResolvePin(&buf2, "wb.localhost", 8443, &.{ v6, v4b });
    try std.testing.expectEqualStrings("wb.localhost:8443:[0:0:0:0:0:0:0:1],127.0.0.1", pin);
}

test "tenant door: parseDoorConfig + label-boundary host match" {
    var fe: FetchEngine = .{ .allocator = std.testing.allocator, .node = undefined };
    try fe.parseDoorConfig("10.99.0.1, 10.99.0.2", "rewindjs.app", "rewindjs.com");
    try std.testing.expectEqual(@as(u8, 2), fe.door_addr_count);
    try std.testing.expectEqual(@as(u8, 2), fe.door_suffix_count);

    try std.testing.expect(fe.doorHostMatch("b.rewindjs.app"));
    try std.testing.expect(fe.doorHostMatch("B.REWINDJS.APP"));
    try std.testing.expect(fe.doorHostMatch("rewindjs.app")); // apex
    try std.testing.expect(fe.doorHostMatch("docs.rewindjs.com"));
    try std.testing.expect(!fe.doorHostMatch("evil-rewindjs.app")); // label boundary
    try std.testing.expect(!fe.doorHostMatch("rewindjs.app.evil.com"));
    try std.testing.expect(!fe.doorHostMatch("example.com"));

    // Misconfig fails loud at boot: door with no suffixes; `ip:port`
    // entry (dead config — CURLOPT_RESOLVE keeps the URL's port).
    var fe2: FetchEngine = .{ .allocator = std.testing.allocator, .node = undefined };
    try std.testing.expectError(error.TenantDoorMisconfig, fe2.parseDoorConfig("10.99.0.1", null, null));
    var fe3: FetchEngine = .{ .allocator = std.testing.allocator, .node = undefined };
    try std.testing.expectError(error.TenantDoorMisconfig, fe3.parseDoorConfig("10.99.0.1:443", "rewindjs.app", null));
}

test "tenant door: pin redirects host to internal fronts, only port 443" {
    var fe: FetchEngine = .{ .allocator = std.testing.allocator, .node = undefined };
    try fe.parseDoorConfig("10.99.0.1,10.99.0.2", "rewindjs.app", null);

    var buf: [768]u8 = undefined;
    const pin = fe.tenantDoorPin("https://B.rewindjs.app/x", &buf).?;
    try std.testing.expectEqualStrings("b.rewindjs.app:443:10.99.0.1,10.99.0.2", pin);

    // A door host on a NON-443 port (e.g. the co-located CP :9090 or
    // worker h2c :8443) is declined — the pin would otherwise aim at an
    // internal service on the front's private-plane address. Declining
    // sends it to the public path, where the host's public address has
    // no such port exposed.
    var buf2: [768]u8 = undefined;
    try std.testing.expect(fe.tenantDoorPin("https://b.rewindjs.app:8443/x", &buf2) == null);
    try std.testing.expect(fe.tenantDoorPin("https://b.rewindjs.app:9090/x", &buf2) == null);

    // door_port override (test topologies whose front binds a high port,
    // via REWIND_INTERNAL_FRONT_PORT): the matching port now pins, and
    // 443 — along with every other port — is declined.
    fe.door_port = 8443;
    const pin_hi = fe.tenantDoorPin("https://b.rewindjs.app:8443/x", &buf2).?;
    try std.testing.expectEqualStrings("b.rewindjs.app:8443:10.99.0.1,10.99.0.2", pin_hi);
    try std.testing.expect(fe.tenantDoorPin("https://b.rewindjs.app/x", &buf2) == null);
    fe.door_port = 443;

    // Non-matching host / unparseable URL → the door declines and the
    // regular checkUrl gate owns the verdict.
    var buf3: [768]u8 = undefined;
    try std.testing.expect(fe.tenantDoorPin("https://example.com/", &buf3) == null);
    try std.testing.expect(fe.tenantDoorPin("not a url", &buf3) == null);
    // The scheme gate still applies on the door path (https-only
    // outside the test hatch).
    try std.testing.expect(fe.tenantDoorPin("http://b.rewindjs.app/", &buf3) == null);

    // Unconfigured door is inert.
    const fe2: FetchEngine = .{ .allocator = std.testing.allocator, .node = undefined };
    try std.testing.expect(fe2.tenantDoorPin("https://b.rewindjs.app/", &buf3) == null);
}

/// Setup-failure path: fire a single empty `final: true` event with
/// ok=false. Mirrors `fetch_pool.pushFinalEmpty` on the catch path.
/// The pf isn't owned by an engine ctx in this path — borrows from
/// the caller (drainInbound, which frees pf separately).
fn emitFailedSetupEvent(engine: *FetchEngine, pf: *PendingFetch) !void {
    const a = engine.allocator;
    var ev = try buildChunkEvent(a, pf, 0, 0, &.{}, null);
    ev.final = true;
    ev.terminal_status = 0;
    ev.terminal_ok = false;
    ev.body_truncated = false;
    engine.routeEvent(pf.tenant_id, ev) catch |err| {
        var e = ev;
        UpstreamFetchEvent.deinitItem(&e, a);
        return err;
    };
}

fn emitFinalEmpty(s: *FetchCtx, status: u16, ok: bool) !void {
    const a = s.allocator;
    var ev = try buildChunkEvent(a, &s.pf, s.emitted_seq, s.byte_offset, &.{}, null);
    ev.final = true;
    ev.terminal_status = status;
    ev.terminal_ok = ok;
    ev.body_truncated = s.capped;
    s.engine.routeEvent(s.pf.tenant_id, ev) catch |err| {
        var e = ev;
        UpstreamFetchEvent.deinitItem(&e, a);
        return err;
    };
    s.emitted_seq += 1;
}

fn emitFinalWithBody(s: *FetchCtx, status: u16, ok: bool) !void {
    const a = s.allocator;
    var ev = try buildChunkEvent(a, &s.pf, s.emitted_seq, s.byte_offset, s.body_buf.items, null);
    if (s.emitted_seq == 0 and s.headers.items.len > 0) {
        ev.fetch_headers = parseHeadersWireToJson(a, s.headers.items) catch null;
    }
    ev.final = true;
    ev.terminal_status = status;
    ev.terminal_ok = ok;
    ev.body_truncated = s.capped;
    s.engine.routeEvent(s.pf.tenant_id, ev) catch |err| {
        var e = ev;
        UpstreamFetchEvent.deinitItem(&e, a);
        return err;
    };
    s.emitted_seq += 1;
}

// ── Shared helpers (ported verbatim from fetch_pool.zig) ──────────────

fn parseMethod(s: []const u8) ?blob_curl_multi.Method {
    if (std.ascii.eqlIgnoreCase(s, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(s, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(s, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(s, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(s, "HEAD")) return .HEAD;
    return null;
}

/// `blob.*` key validator: exactly 64 lowercase hex chars (a sha256
/// digest as `crypto.sha256` renders it). Anything else — uppercase,
/// path separators, traversal attempts — is rejected before the key
/// is interpolated into an S3 path.
/// Extract `{tenant}` from a `v1/{tenant}/…` log-query path (the part after
/// the `rewind-logs.internal/` door prefix), ignoring any `?query`. Returns
/// null if the shape doesn't match. The tenant's character set is enforced
/// downstream by `jwt.mint` (rejects anything outside `[a-zA-Z0-9_-]`).
fn parseLogsTenant(remainder: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, remainder, '?');
    const path = if (q) |i| remainder[0..i] else remainder;
    const v1 = "v1/";
    if (!std.mem.startsWith(u8, path, v1)) return null;
    const after = path[v1.len..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
    const tenant = after[0..slash];
    if (tenant.len == 0) return null;
    return tenant;
}

test "parseLogsTenant pulls the tenant from v1/{tenant}/… (and ignores query)" {
    try std.testing.expectEqualStrings("acme", parseLogsTenant("v1/acme/list").?);
    try std.testing.expectEqualStrings("acme", parseLogsTenant("v1/acme/list?limit=20").?);
    try std.testing.expectEqualStrings("globex", parseLogsTenant("v1/globex/show/abc123").?);
    try std.testing.expect(parseLogsTenant("v1/acme") == null); // no trailing route
    try std.testing.expect(parseLogsTenant("v1//list") == null); // empty tenant
    try std.testing.expect(parseLogsTenant("health") == null); // not a v1 path
    try std.testing.expect(parseLogsTenant("v2/acme/list") == null);
}

/// Tenant-id charset gate for the cross-tenant read door — `[A-Za-z0-9_-]`,
/// 1..64. Forbidding `/` and `.` means a path segment can't escape the
/// constructed `{tenant}/{subdir}/...` S3 prefix.
fn isValidScopeId(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |b| {
        const ok = (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or
            (b >= '0' and b <= '9') or b == '_' or b == '-';
        if (!ok) return false;
    }
    return true;
}

fn isSha256HexLower(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |b| {
        const ok = (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f');
        if (!ok) return false;
    }
    return true;
}

test "isSha256HexLower accepts a digest and rejects malformed keys" {
    try std.testing.expect(isSha256HexLower("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
    try std.testing.expect(!isSha256HexLower("E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"));
    try std.testing.expect(!isSha256HexLower("e3b0c44298fc1c149afbf4c8996fb924"));
    try std.testing.expect(!isSha256HexLower("../../../../../../../etc/passwd0000000000000000000000000000000000"));
    try std.testing.expect(!isSha256HexLower(""));
}

fn parseHeadersJson(
    a: std.mem.Allocator,
    json_src: []const u8,
    out: *std.ArrayListUnmanaged(blob_curl_multi.Header),
) !void {
    if (json_src.len == 0) return;
    var parsed = std.json.parseFromSlice(std.json.Value, a, json_src, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;
    var it = root.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .string) continue;
        const name = try a.dupe(u8, kv.key_ptr.*);
        errdefer a.free(name);
        const value = try a.dupe(u8, kv.value_ptr.*.string);
        errdefer a.free(value);
        try out.append(a, .{ .name = name, .value = value });
    }
}

fn buildChunkEvent(
    a: std.mem.Allocator,
    pf: *const PendingFetch,
    seq: u32,
    byte_offset: u64,
    bytes: []const u8,
    headers_json: ?[]u8,
) !UpstreamFetchEvent {
    var ev: UpstreamFetchEvent = .{
        .seq = seq,
        .byte_offset = byte_offset,
        .bind = pf.bind,
        .stream = pf.stream,
    };
    errdefer UpstreamFetchEvent.deinit(a, (&ev)[0..1]);
    if (headers_json) |hj| ev.fetch_headers = hj;
    ev.fetch_id = try a.dupe(u8, pf.id);
    ev.tenant_id = try a.dupe(u8, pf.tenant_id);
    ev.ctx_json = try a.dupe(u8, pf.ctx_json);
    ev.on_chunk_module = try a.dupe(u8, pf.on_chunk_module);
    ev.bytes = try a.dupe(u8, bytes);
    if (pf.bound_send_id.len > 0) ev.bound_send_id = try a.dupe(u8, pf.bound_send_id);
    if (pf.name.len > 0) ev.name = try a.dupe(u8, pf.name);
    return ev;
}

fn parseHeadersWireToJson(a: std.mem.Allocator, wire: []const u8) ![]u8 {
    var obj: std.json.ObjectMap = .init(a);
    defer {
        var it = obj.iterator();
        while (it.next()) |entry| {
            a.free(@constCast(entry.key_ptr.*));
            a.free(@constCast(entry.value_ptr.*.string));
        }
        obj.deinit();
    }
    var line_it = std.mem.splitSequence(u8, wire, "\r\n");
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " ");
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (name.len == 0) continue;
        const lname = try a.alloc(u8, name.len);
        errdefer a.free(lname);
        for (name, 0..) |ch, i| lname[i] = std.ascii.toLower(ch);
        const lval = try a.dupe(u8, value);
        errdefer a.free(lval);
        if (try obj.fetchPut(lname, .{ .string = lval })) |prev| {
            a.free(@constCast(prev.key));
            a.free(@constCast(prev.value.string));
        }
    }
    const val: std.json.Value = .{ .object = obj };
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    {
        var aw = std.Io.Writer.Allocating.fromArrayList(a, &buf);
        defer buf = aw.toArrayList();
        try std.json.Stringify.value(val, .{}, &aw.writer);
    }
    return try buf.toOwnedSlice(a);
}
