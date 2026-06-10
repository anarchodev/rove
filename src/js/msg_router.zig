//! `MsgRouter` — async-activation routing for the rove-js worker node.
//!
//! Extracted from `NodeState` (worker.zig) as the first step of the
//! NodeState decomposition. Owns the per-worker inbox registries (the
//! unified `effect.MsgInbox` + the kv-wake `KvWakeInbox`) and the
//! cross-worker held-state owner registries (`bound_fetch_owners` /
//! `bound_send_owners`), plus every enqueue/broadcast path that routes
//! a cross-thread `effect.Msg` to the worker that should service it.
//!
//! Routing rules:
//!   - default: `hash(tenant_id) % N_inboxes` — *consistent*, NOT
//!     affinity with the SO_REUSEPORT inbound pick. Inbound HTTP lands
//!     on a kernel-chosen worker (4-tuple hash); this routing only
//!     guarantees that every producer of a given tenant's async
//!     activations picks the same worker. For stateless activations
//!     (cron / boot / kv-react / stateless callbacks) any worker can
//!     service the message, so consistency is sufficient.
//!   - held state (bound fetch / held-sync send): the owning worker
//!     registered itself by id at binding time; routing consults the
//!     owner registry and bypasses the hash via `enqueueMsgToWorker`.
//!     This is the correction for the SO_REUSEPORT vs hash(tenant_id)
//!     divergence — see `docs/cross-worker-held-state-plan.md`.
//!
//! Dependency surface is intentionally tiny: `allocator` only. The
//! typed input/payload types come from `effect`, `components`, and the
//! `KvWakeInbox` / `SubscriptionFireQueueInput` definitions that still
//! live next to their producers in `worker.zig` / `worker_streaming.zig`.

const std = @import("std");
const effect_mod = @import("effect/root.zig");
const components_mod = @import("components.zig");
const worker_mod = @import("worker.zig");
const worker_streaming = @import("worker_streaming.zig");
const globals = @import("globals.zig");

const KvWakeInbox = worker_mod.KvWakeInbox;
const SubscriptionFireQueueInput = worker_streaming.SubscriptionFireQueueInput;

pub const MsgRouter = struct {
    allocator: std.mem.Allocator,

    /// streaming-handlers-plan §4.6: registry of per-worker kv-wake
    /// inboxes. Workers register their inbox at startup; producers
    /// (apply.zig writeset apply on followers + worker_dispatch.zig
    /// leader-side eager fire) call `broadcastKvWake` to fan out.
    /// Per-worker (not node-wide) so each worker only scans cells it
    /// owns — matches plan §4.1's "registry is per-worker" rule. The
    /// `mutex` guards the registry vector itself (registration races
    /// at worker startup); individual inboxes have their own mutex.
    wake_inboxes_mutex: std.Thread.Mutex = .{},
    wake_inboxes: std.ArrayListUnmanaged(*KvWakeInbox) = .empty,

    /// Effect-reification Phase 2E: unified per-worker Msg inbox
    /// registry. Replaces the pre-2E pair (`sub_fire_inboxes` +
    /// `fetch_chunk_inboxes`) — one registry, one push path,
    /// `hash(tenant_id) % N_inboxes` for hash-by-tenant stickiness.
    /// Producers from non-worker threads (`deployment_loader` for
    /// boot, the cron sweeper, the `FetchEngine` libcurl thread) call
    /// `enqueueMsgForTenant`; the typed wrappers
    /// `enqueueSubscriptionFireForTenant` /
    /// `enqueueFetchEventForTenant` build the matching `effect.Msg`
    /// variant and route through it.
    msg_inboxes_mutex: std.Thread.Mutex = .{},
    msg_inboxes: std.ArrayListUnmanaged(*effect_mod.MsgInbox) = .empty,

    /// `docs/cross-worker-held-state-plan.md`: held-state ownership
    /// registries. The accept worker (SO_REUSEPORT pick) can differ
    /// from the async-wake worker (`hash(tenant_id) % N`). These maps
    /// record which worker holds the held state for a given
    /// async-effect id, so wake routing can target the owning worker
    /// directly instead of the tenant-hashed one.
    ///
    /// `bound_fetch_owners` is keyed by `fetch_id` and populated at
    /// `http.fetch({bind: true})` binding-call time (via
    /// `registerBoundFetchOwner`); drained on terminal chunk /
    /// held-client disconnect.
    ///
    /// `bound_send_owners` is keyed by `send_id` (the
    /// `_send/owed/{id}` suffix) and populated when a `webhook.send` +
    /// `next()` writes the `_send/owed/` marker; drained when the cont
    /// resumes or its §6.4 deadline fires.
    ///
    /// Keys are allocator-owned dupes. Values are the owning worker's
    /// `msg_inbox_idx`. Mutex-guarded.
    held_owners_mutex: std.Thread.Mutex = .{},
    bound_fetch_owners: std.StringHashMapUnmanaged(usize) = .empty,
    bound_send_owners: std.StringHashMapUnmanaged(usize) = .empty,

    /// Phase 2A instrumentation — observability for the owner-routing
    /// path. `cross_worker_routes` counts decisions where the owner
    /// worker differs from `hash(tenant_id) % N` (i.e., the path that
    /// would have failed pre-Phase-2A); `same_worker_routes` counts
    /// decisions where they happen to coincide (correct but doesn't
    /// exercise the bug fix). A smoke that sees zero cross-worker
    /// routes hasn't actually tested the routing — its kernel
    /// SO_REUSEPORT spread happened to coincide with the tenant hash.
    /// Counters never reset; surfaced on `/_system/metrics` as
    /// `bound_fetch_cross_worker_routes_total` /
    /// `bound_fetch_same_worker_routes_total`.
    bound_fetch_cross_worker_routes: std.atomic.Value(u64) = .init(0),
    bound_fetch_same_worker_routes: std.atomic.Value(u64) = .init(0),

    pub fn init(allocator: std.mem.Allocator) MsgRouter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MsgRouter) void {
        // Drop the inbox registries — workers destroy their inboxes in
        // their own deinit, so by the time this tears down, every
        // inbox should already be unregistered. The lists themselves
        // are owned by this allocator.
        self.wake_inboxes.deinit(self.allocator);
        self.msg_inboxes.deinit(self.allocator);

        // `docs/cross-worker-held-state-plan.md`: free every owned key
        // in the held-state registries. Values are POD usize, no
        // per-entry cleanup. The owning workers' local registries were
        // drained in their own deinit paths; this is the catchall for
        // any straggler keys at shutdown.
        self.held_owners_mutex.lock();
        defer self.held_owners_mutex.unlock();
        var it_f = self.bound_fetch_owners.iterator();
        while (it_f.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.bound_fetch_owners.deinit(self.allocator);
        var it_s = self.bound_send_owners.iterator();
        while (it_s.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.bound_send_owners.deinit(self.allocator);
    }

    /// Register a worker's wake inbox at worker startup. Worker keeps
    /// the inbox; this registry just borrows the pointer so producers
    /// can fan out. The pointer must outlive every `broadcastKvWake`
    /// call — workers must `unregisterWakeInbox` from their destroy
    /// path before tearing down.
    pub fn registerWakeInbox(self: *MsgRouter, inbox: *KvWakeInbox) !void {
        self.wake_inboxes_mutex.lock();
        defer self.wake_inboxes_mutex.unlock();
        try self.wake_inboxes.append(self.allocator, inbox);
    }

    pub fn unregisterWakeInbox(self: *MsgRouter, inbox: *KvWakeInbox) void {
        self.wake_inboxes_mutex.lock();
        defer self.wake_inboxes_mutex.unlock();
        var i: usize = 0;
        while (i < self.wake_inboxes.items.len) : (i += 1) {
            if (self.wake_inboxes.items[i] == inbox) {
                _ = self.wake_inboxes.swapRemove(i);
                return;
            }
        }
    }

    /// Effect-reification Phase 2E: register a worker's unified Msg
    /// inbox. The producer-side enqueueXxxForTenant functions
    /// hash-route to one of these by `hash(tenant_id) % N`. Returns
    /// the inbox's slot index in `msg_inboxes` — workers store it so
    /// the per-worker partitioned sweeps (`sweepOwedRetries`) can
    /// match the same `hash(tenant_id) % N` that `enqueueMsgForTenant`
    /// would route to.
    pub fn registerMsgInbox(self: *MsgRouter, inbox: *effect_mod.MsgInbox) !usize {
        self.msg_inboxes_mutex.lock();
        defer self.msg_inboxes_mutex.unlock();
        const idx = self.msg_inboxes.items.len;
        try self.msg_inboxes.append(self.allocator, inbox);
        return idx;
    }

    pub fn unregisterMsgInbox(self: *MsgRouter, inbox: *effect_mod.MsgInbox) void {
        self.msg_inboxes_mutex.lock();
        defer self.msg_inboxes_mutex.unlock();
        var i: usize = 0;
        while (i < self.msg_inboxes.items.len) : (i += 1) {
            if (self.msg_inboxes.items[i] == inbox) {
                _ = self.msg_inboxes.swapRemove(i);
                return;
            }
        }
    }

    /// Hash-route `msg` onto the destination worker's `MsgInbox` by
    /// `hash(tenant_id) % N`. The typed wrappers
    /// (`enqueueSubscriptionFireForTenant`, `enqueueFetchEventForTenant`)
    /// build the variant + call this. On success ownership of `msg`'s
    /// owned bytes transfers to the inbox; on error.NoWorkers the
    /// caller retains and MUST `effect.freeOwnedMsg` to free.
    pub fn enqueueMsgForTenant(
        self: *MsgRouter,
        tenant_id: []const u8,
        msg: effect_mod.Msg,
    ) !void {
        self.msg_inboxes_mutex.lock();
        const n = self.msg_inboxes.items.len;
        if (n == 0) {
            self.msg_inboxes_mutex.unlock();
            return error.NoWorkers;
        }
        const inbox_idx = std.hash.Wyhash.hash(0, tenant_id) % n;
        const inbox = self.msg_inboxes.items[inbox_idx];
        self.msg_inboxes_mutex.unlock();
        try inbox.push(msg);
    }

    // ── docs/cross-worker-held-state-plan.md ───────────────────────
    // Held-state ownership registries.

    /// Register `fetch_id → owner_worker_idx` for a bound
    /// `http.fetch({bind: true})`. Idempotent on owner-collision
    /// (logs + drops the second registration — fetch_ids are supposed
    /// to be unique within a node). Duping the key here so the
    /// caller's slice can be freed independently. Returns false on
    /// allocator failure / collision; the caller doesn't need to act
    /// on the failure (wake routing falls back to hash(tenant_id) when
    /// the registry misses).
    pub fn registerBoundFetchOwner(
        self: *MsgRouter,
        fetch_id: []const u8,
        worker_idx: usize,
    ) bool {
        self.held_owners_mutex.lock();
        defer self.held_owners_mutex.unlock();
        const gop = self.bound_fetch_owners.getOrPut(self.allocator, fetch_id) catch return false;
        if (gop.found_existing) {
            std.log.warn(
                "rove-js held-state: bound_fetch_owners collision for fetch_id={s} (old={d}, new={d}); keeping old",
                .{ fetch_id, gop.value_ptr.*, worker_idx },
            );
            return false;
        }
        const key_dup = self.allocator.dupe(u8, fetch_id) catch {
            _ = self.bound_fetch_owners.remove(fetch_id);
            return false;
        };
        gop.key_ptr.* = key_dup;
        gop.value_ptr.* = worker_idx;
        return true;
    }

    /// Lookup the owning worker for a bound fetch. Returns null on
    /// miss (routing falls back to hash(tenant_id)).
    pub fn lookupBoundFetchOwner(self: *MsgRouter, fetch_id: []const u8) ?usize {
        self.held_owners_mutex.lock();
        defer self.held_owners_mutex.unlock();
        return self.bound_fetch_owners.get(fetch_id);
    }

    /// Drop the registry entry. Idempotent (no-op on miss).
    pub fn unregisterBoundFetchOwner(self: *MsgRouter, fetch_id: []const u8) void {
        self.held_owners_mutex.lock();
        defer self.held_owners_mutex.unlock();
        const entry = self.bound_fetch_owners.fetchRemove(fetch_id) orelse return;
        self.allocator.free(entry.key);
    }

    /// Sibling of `registerBoundFetchOwner` for held-sync sends.
    /// Keyed by the `_send/owed/{id}` suffix. Same semantics: duped
    /// key, mutex-guarded, idempotent on collision.
    pub fn registerBoundSendOwner(
        self: *MsgRouter,
        send_id: []const u8,
        worker_idx: usize,
    ) bool {
        self.held_owners_mutex.lock();
        defer self.held_owners_mutex.unlock();
        const gop = self.bound_send_owners.getOrPut(self.allocator, send_id) catch return false;
        if (gop.found_existing) {
            std.log.warn(
                "rove-js held-state: bound_send_owners collision for send_id={s} (old={d}, new={d}); keeping old",
                .{ send_id, gop.value_ptr.*, worker_idx },
            );
            return false;
        }
        const key_dup = self.allocator.dupe(u8, send_id) catch {
            _ = self.bound_send_owners.remove(send_id);
            return false;
        };
        gop.key_ptr.* = key_dup;
        gop.value_ptr.* = worker_idx;
        return true;
    }

    pub fn lookupBoundSendOwner(self: *MsgRouter, send_id: []const u8) ?usize {
        self.held_owners_mutex.lock();
        defer self.held_owners_mutex.unlock();
        return self.bound_send_owners.get(send_id);
    }

    pub fn unregisterBoundSendOwner(self: *MsgRouter, send_id: []const u8) void {
        self.held_owners_mutex.lock();
        defer self.held_owners_mutex.unlock();
        const entry = self.bound_send_owners.fetchRemove(send_id) orelse return;
        self.allocator.free(entry.key);
    }

    /// Gap 2.3 Phase C2 + effect-reification Phase 2E: route a fetch
    /// event (chunk / end / pipe_done) to the destination worker's
    /// unified `MsgInbox` as the matching `effect.Msg` variant.
    /// Caller-side ownership of every owned slice in `ev` transfers in
    /// on success; on `error.NoWorkers` the caller retains and is
    /// responsible for `UpstreamFetchEvent.deinitItem`.
    ///
    /// `docs/cross-worker-held-state-plan.md` Phase 2A: when `ev.bind`
    /// is true AND `bound_fetch_owners[ev.fetch_id]` resolves, route
    /// directly to the owning worker's inbox. Otherwise fall back to
    /// `hash(tenant_id)` — the existing behavior for unbound (Pattern
    /// A) fetches, subscription fires, cron, kv-react, etc.
    ///
    /// The owner-routing path closes the cross-worker bind gap: the
    /// inbound that registered the bound fetch may live on a
    /// kernel-chosen worker (SO_REUSEPORT) different from
    /// `hash(tenant_id) % N`; without owner routing the chunk arrives
    /// on the wrong worker and the bound resume fails silently until
    /// the §6.4 25s deadline.
    pub fn enqueueFetchEventForTenant(
        self: *MsgRouter,
        tenant_id: []const u8,
        ev: components_mod.UpstreamFetchEvent,
    ) !void {
        // Phase 5 PR-1: single `fetch_chunk` Msg variant; the event's
        // `final` flag distinguishes streaming intermediates from the
        // terminal.
        const msg: effect_mod.Msg = .{ .fetch_chunk = ev };
        // Phase 2A: bound fetch chunks route to the held-state owner
        // via `bound_fetch_owners`. Phase 2B: webhook.send callback
        // chunks (the fetch has no bind:true, but its bound_send_id
        // names the cont's send_id) route via `bound_send_owners`.
        // Either path skips `hash(tenant_id)` to land on the worker
        // that holds the resume target. Unbound / non-webhook fetches
        // fall through to today's hash routing.
        const owner_opt: ?usize = blk: {
            if (ev.bind) {
                if (self.lookupBoundFetchOwner(ev.fetch_id)) |idx| break :blk idx;
            }
            if (ev.bound_send_id.len > 0) {
                if (self.lookupBoundSendOwner(ev.bound_send_id)) |idx| break :blk idx;
            }
            break :blk null;
        };
        if (owner_opt) |owner_idx| {
            // Instrumentation: count cross-worker vs same-worker routes
            // so smokes can assert the path actually fires. A
            // "same-worker" route is correct but doesn't exercise the
            // cross-worker bug fix.
            self.msg_inboxes_mutex.lock();
            const n = self.msg_inboxes.items.len;
            self.msg_inboxes_mutex.unlock();
            const hash_idx = if (n > 0) std.hash.Wyhash.hash(0, tenant_id) % n else 0;
            if (owner_idx != hash_idx) {
                _ = self.bound_fetch_cross_worker_routes.fetchAdd(1, .monotonic);
            } else {
                _ = self.bound_fetch_same_worker_routes.fetchAdd(1, .monotonic);
            }
            return self.enqueueMsgToWorker(owner_idx, msg);
        }
        try self.enqueueMsgForTenant(tenant_id, msg);
    }

    /// `docs/cross-worker-held-state-plan.md` Phase 2A: push a Msg
    /// directly to the worker at `worker_idx` (bypassing
    /// `hash(tenant_id)`). Used by the held-state owner routing path:
    /// when a bound fetch's chunk arrives, we know which worker holds
    /// the receiving entity and route the event there. Returns
    /// `error.NoWorkers` if the registry has no inbox at that index
    /// (cold start, or registry torn down).
    pub fn enqueueMsgToWorker(
        self: *MsgRouter,
        worker_idx: usize,
        msg: effect_mod.Msg,
    ) !void {
        self.msg_inboxes_mutex.lock();
        if (worker_idx >= self.msg_inboxes.items.len) {
            self.msg_inboxes_mutex.unlock();
            return error.NoWorkers;
        }
        const inbox = self.msg_inboxes.items[worker_idx];
        self.msg_inboxes_mutex.unlock();
        try inbox.push(msg);
    }

    /// Gap 2.1 Phase D + effect-reification Phase 2E: hash-route a
    /// subscription fire (kv-react / boot) to the destination
    /// worker's unified `MsgInbox` as a `SubscriptionFire` variant.
    /// Producer (loader / sweeper) owns the input slices borrowed;
    /// this fn dupes onto the payload before pushing. Returns
    /// `error.NoWorkers` if no inbox is registered yet (cold start
    /// before any worker spawned).
    pub fn enqueueSubscriptionFireForTenant(
        self: *MsgRouter,
        in: SubscriptionFireQueueInput,
    ) !void {
        const allocator = self.allocator;
        const tid = try allocator.dupe(u8, in.tenant_id);
        errdefer allocator.free(tid);
        const name = try allocator.dupe(u8, in.subscription_name);
        errdefer allocator.free(name);
        const path = try allocator.dupe(u8, in.module_path);
        errdefer allocator.free(path);

        const source: effect_mod.msg.SubscriptionFire.Source = switch (in.source) {
            .kv => |k| blk: {
                const key_dup = try allocator.dupe(u8, k.key);
                break :blk .{ .kv = .{ .key = key_dup, .op = k.op } };
            },
            .boot => |b| .{ .boot = .{ .deployment_id = b.deployment_id } },
        };
        errdefer switch (source) {
            .kv => |kv| allocator.free(kv.key),
            else => {},
        };

        const payload: effect_mod.msg.SubscriptionFire = .{
            .tenant_id = tid,
            .subscription_name = name,
            .module_path = path,
            .source = source,
        };
        try self.enqueueMsgForTenant(in.tenant_id, .{ .subscription_fire = payload });
    }

    /// Phase 5 PR-2: hash-route a chained dispatch — a `__rove_next`
    /// returned from a `fetch_chunk` handler — to the destination
    /// worker's MsgInbox as a `SendCallback` variant. The customer's
    /// next-hop handler runs there with `request.activation.kind ==
    /// "send_callback"` and the cont's ctx wrapped as
    /// `request.body = {"ctx": <ctx>}`. Producer-owned slices are
    /// dup'd onto the payload; on `error.NoWorkers` the caller retains
    /// and frees them.
    pub fn enqueueChainedDispatchForTenant(
        self: *MsgRouter,
        tenant_id: []const u8,
        module_path: []const u8,
        ctx_json: []const u8,
        fn_name: ?[]const u8,
        correlation_id: ?[]const u8,
    ) !void {
        const allocator = self.allocator;
        const tid = try allocator.dupe(u8, tenant_id);
        errdefer allocator.free(tid);
        const mod = try allocator.dupe(u8, module_path);
        errdefer allocator.free(mod);
        const ctx = try allocator.dupe(u8, ctx_json);
        errdefer allocator.free(ctx);
        const fn_dup: ?[]u8 = if (fn_name) |f| try allocator.dupe(u8, f) else null;
        errdefer if (fn_dup) |f| allocator.free(f);
        const corr_dup: ?[]u8 = if (correlation_id) |c| try allocator.dupe(u8, c) else null;
        errdefer if (corr_dup) |c| allocator.free(c);

        const payload: effect_mod.msg.SendCallback = .{
            .tenant_id = tid,
            .module_path = mod,
            .ctx_json = ctx,
            .fn_name = fn_dup,
            .correlation_id = corr_dup,
        };
        try self.enqueueMsgForTenant(tenant_id, .{ .send_callback = payload });
    }

    /// §2.6 durable-wake: hash-route a `durable_wake` activation — one
    /// due `_sched/by_time` entry the baked `__system/scheduler_tick`
    /// fanned out via `__rove_fire_wake` — to the entry's owning
    /// worker's MsgInbox. The target handler runs there with
    /// `request.activation.kind == "durable_wake"`; the dispatch path
    /// (`fireDurableWakeActivation`) injects the entry's `cleanup_keys`
    /// as deletes into the handler's writeset. All borrowed slices in
    /// `input` are dup'd onto the payload here; on `error.NoWorkers`
    /// the caller (the builtin) surfaces a throw and `scheduler_tick`
    /// leaves the entry for the next tick.
    pub fn enqueueDurableWakeForTenant(
        self: *MsgRouter,
        input: globals.FireWakeInput,
    ) !void {
        const a = self.allocator;
        const tid = try a.dupe(u8, input.tenant_id);
        errdefer a.free(tid);
        const target = try a.dupe(u8, input.target);
        errdefer a.free(target);
        const id = try a.dupe(u8, input.id);
        errdefer a.free(id);
        const key: ?[]u8 = if (input.key) |k| try a.dupe(u8, k) else null;
        errdefer if (key) |k| a.free(k);
        const msg_json = try a.dupe(u8, input.msg_json);
        errdefer a.free(msg_json);

        // Dup the cleanup-key slices into an owned slice-of-owned-slices.
        var cleanup = try a.alloc([]u8, input.cleanup_keys.len);
        var dup_count: usize = 0;
        errdefer {
            for (cleanup[0..dup_count]) |k| a.free(k);
            a.free(cleanup);
        }
        for (input.cleanup_keys, 0..) |k, i| {
            cleanup[i] = try a.dupe(u8, k);
            dup_count = i + 1;
        }

        const payload: effect_mod.msg.DurableWake = .{
            .tenant_id = tid,
            .module_path = target,
            .id = id,
            .key = key,
            .msg_json = msg_json,
            .scheduled_at_ns = input.scheduled_at_ns,
            .cleanup_keys = cleanup,
        };
        try self.enqueueMsgForTenant(input.tenant_id, .{ .durable_wake = payload });
    }

    /// Fan out one kv-write event to every registered worker inbox.
    /// Called from `apply.zig` (follower path) and `worker_dispatch.zig`
    /// (leader path) so a write on any node reaches every locally-held
    /// stream regardless of which node + worker hosts it. A per-inbox
    /// push failure is logged and swallowed — the §9.4 "spurious +
    /// overflow" thesis lets us drop a wake; the worker that lost it
    /// will refetch authoritative state on its next activation anyway.
    /// `write_version` is the producer store's §8.4 write clock for
    /// this write (or the `maxInt` fire-always sentinel); it rides each
    /// event so `matchEventsToWakes` can gate on the watch baseline.
    pub fn broadcastKvWake(
        self: *MsgRouter,
        tenant_id: []const u8,
        key: []const u8,
        op: u8,
        write_version: u64,
    ) void {
        self.wake_inboxes_mutex.lock();
        defer self.wake_inboxes_mutex.unlock();
        for (self.wake_inboxes.items) |inbox| {
            inbox.push(tenant_id, key, op, write_version) catch |err| {
                std.log.warn(
                    "rove-js kv-wake broadcast: push tenant={s} key={s}: {s}",
                    .{ tenant_id, key, @errorName(err) },
                );
            };
        }
    }
};
