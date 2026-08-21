// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `MsgRouter` — async-activation routing for the rove-js worker node.
//!
//! Owns the per-worker inbox registries (the unified `effect.MsgInbox`
//! + the kv-wake `KvWakeInbox`) and the cross-worker held-state owner
//! registries (`bound_fetch_owners` / `bound_send_owners`), plus every
//! enqueue/broadcast path that routes a cross-thread `effect.Msg` to
//! the worker that should service it.
//!
//! Routing rules:
//!   - default: `hash(tenant_id) % N_inboxes` — *consistent*, NOT
//!     affinity with the SO_REUSEPORT inbound pick. Inbound HTTP lands
//!     on a kernel-chosen worker (4-tuple hash); this routing only
//!     guarantees that every producer of a given tenant's async
//!     activations picks the same worker. For stateless activations
//!     (cron / kv-react / stateless callbacks) any worker can
//!     service the message, so consistency is sufficient.
//!   - held state (bound fetch / held-sync send): the owning worker
//!     registered itself by id at binding time; routing consults the
//!     owner registry and bypasses the hash via `enqueueMsgToWorker`.
//!     This is the correction for the SO_REUSEPORT vs hash(tenant_id)
//!     divergence — see held state in
//!     `docs/architecture/effects-and-handlers.md`.
//!
//! Dependency surface is intentionally tiny: `allocator` only. The
//! typed input/payload types come from `effect`, `components`, and the
//! `KvWakeInbox` definitions that live next to their producers in
//! `worker.zig` / `worker_streaming.zig`.

const std = @import("std");
const effect_mod = @import("effect/root.zig");
const components_mod = @import("components.zig");
const worker_mod = @import("worker.zig");
const worker_streaming = @import("worker_streaming.zig");
const globals = @import("globals.zig");
const builtin_modules = @import("builtin_modules.zig");
const log_mod = @import("rove-log");

const KvWakeInbox = worker_mod.KvWakeInbox;

/// One CAS→connection relay hand-off (`docs/architecture/routing-and-ingress.md`):
/// either a run of upstream bytes destined for the bound entity's
/// `StreamChunks` (no activation), or the transfer's terminal event —
/// which rides the SAME per-worker FIFO so it can never overtake the
/// bytes ahead of it. The worker re-injects the terminal into the
/// normal bound-fetch dispatch once every byte before it has been
/// appended, which is what keeps the "exactly one terminal
/// activation observes the outcome" contract ordered.
pub const RelayItem = struct {
    /// Allocator-owned dupe; names the bound fetch this item belongs to.
    fetch_id: []u8,
    payload: union(enum) {
        /// Allocator-owned upstream bytes (one libcurl writeback's worth).
        bytes: []u8,
        /// The transfer's terminal `UpstreamFetchEvent` (owned slices).
        terminal: components_mod.UpstreamFetchEvent,
    },

    pub fn deinit(item: *RelayItem, allocator: std.mem.Allocator) void {
        if (item.fetch_id.len > 0) allocator.free(item.fetch_id);
        switch (item.payload) {
            .bytes => |b| if (b.len > 0) allocator.free(b),
            .terminal => |*ev| components_mod.UpstreamFetchEvent.deinitItem(ev, allocator),
        }
        item.* = .{ .fetch_id = &.{}, .payload = .{ .bytes = &.{} } };
    }
};

/// Cross-thread FIFO from the fetch-engine thread to one worker —
/// the relay's transport lane. Deliberately NOT an `effect.MsgInbox`
/// variant: every `effect.Msg` IS an activation, and a relay byte-run
/// is precisely not one. Mutex-guarded; the worker drains per tick
/// (`drainRelay`) into its per-fetch backlogs.
pub const RelayInbox = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayListUnmanaged(RelayItem) = .empty,

    /// Ownership of `item`'s slices transfers in on success; on error
    /// the caller retains and frees.
    pub fn push(self: *RelayInbox, allocator: std.mem.Allocator, item: RelayItem) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, item);
    }

    /// Move every queued item into `out` (ownership transfers). On
    /// append failure the un-moved tail stays queued for next tick.
    pub fn drainInto(
        self: *RelayInbox,
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(RelayItem),
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len == 0) return;
        out.ensureUnusedCapacity(allocator, self.items.items.len) catch return;
        for (self.items.items) |it| out.appendAssumeCapacity(it);
        self.items.clearRetainingCapacity();
    }

    /// Free any still-queued items (shutdown path).
    pub fn deinit(self: *RelayInbox, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |*it| it.deinit(allocator);
        self.items.deinit(allocator);
        self.items = .empty;
    }
};

pub const MsgRouter = struct {
    allocator: std.mem.Allocator,

    /// Registry of per-worker kv-wake inboxes — the kv-wake fan-out
    /// path (`docs/architecture/effects-and-handlers.md`). Workers
    /// register their inbox at startup; producers
    /// (apply.zig writeset apply on followers + worker_dispatch.zig
    /// leader-side eager fire) call `broadcastKvWake` to fan out.
    /// Per-worker (not node-wide) so each worker only scans cells it
    /// owns — the registry-is-per-worker invariant. The
    /// `mutex` guards the registry vector itself (registration races
    /// at worker startup); individual inboxes have their own mutex.
    wake_inboxes_mutex: std.Thread.Mutex = .{},
    wake_inboxes: std.ArrayListUnmanaged(*KvWakeInbox) = .empty,

    /// Unified per-worker Msg inbox registry — one registry, one push
    /// path, `hash(tenant_id) % N_inboxes` for hash-by-tenant
    /// stickiness.
    /// Producers from non-worker threads (`deployment_loader` for
    /// boot, the `FetchEngine` libcurl thread) call
    /// `enqueueMsgForTenant`; the typed wrappers
    /// `enqueueFetchEventForTenant` build the matching `effect.Msg`
    /// variant and route through it.
    /// A worker's slot index is its routing identity for the life of
    /// the process: `bound_fetch_owners` / `bound_send_owners` store
    /// it, `relay_inboxes` is keyed by it, and `sweepDurableWakes`
    /// partitions tenants by matching `hash(tenant_id) % N` against
    /// it. So slots are TOMBSTONED on unregister, never compacted —
    /// removing one by swapping the tail down would silently re-point
    /// every registration naming the moved worker, and shrink the `N`
    /// that both sides of the sweep's equality test divide by.
    msg_inboxes_mutex: std.Thread.Mutex = .{},
    msg_inboxes: std.ArrayListUnmanaged(?*effect_mod.MsgInbox) = .empty,

    /// Per-worker relay inboxes (the CAS→connection relay,
    /// `docs/architecture/routing-and-ingress.md`), keyed by the SAME
    /// index `registerMsgInbox` returned for that worker — the relay
    /// producer targets `bound_fetch_owners[fetch_id]`, whose values
    /// are msg-inbox indexes, so the two registries must share the
    /// key space. Borrowed pointers; workers unregister before
    /// tearing their inbox down.
    relay_inboxes_mutex: std.Thread.Mutex = .{},
    relay_inboxes: std.AutoHashMapUnmanaged(usize, *RelayInbox) = .empty,

    /// Held-state ownership registries (held state in
    /// `docs/architecture/effects-and-handlers.md`). The accept worker
    /// (SO_REUSEPORT pick) can differ
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
    /// resumes or its held-send deadline fires.
    ///
    /// Keys are allocator-owned dupes. Values are the owning worker's
    /// `msg_inbox_idx`. Mutex-guarded.
    held_owners_mutex: std.Thread.Mutex = .{},
    bound_fetch_owners: std.StringHashMapUnmanaged(usize) = .empty,
    bound_send_owners: std.StringHashMapUnmanaged(usize) = .empty,

    /// Instrumentation — observability for the owner-routing path.
    /// `cross_worker_routes` counts decisions where the owner worker
    /// differs from `hash(tenant_id) % N` (the path owner-routing
    /// corrects); `same_worker_routes` counts decisions where they
    /// happen to coincide (correct but doesn't exercise the
    /// owner-routing path). A smoke that sees zero cross-worker
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
        self.relay_inboxes.deinit(self.allocator);

        // Free every owned key in the held-state registries (held
        // state in `docs/architecture/effects-and-handlers.md`). Values
        // are POD usize, no
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

    /// Register a worker's unified Msg inbox. The producer-side
    /// enqueueXxxForTenant functions
    /// hash-route to one of these by `hash(tenant_id) % N`. Returns
    /// the inbox's slot index in `msg_inboxes` — workers store it so
    /// the per-worker partitioned sweeps (`sweepDurableWakes`) can
    /// match the same `hash(tenant_id) % N` that `enqueueMsgForTenant`
    /// would route to.
    pub fn registerMsgInbox(self: *MsgRouter, inbox: *effect_mod.MsgInbox) !usize {
        self.msg_inboxes_mutex.lock();
        defer self.msg_inboxes_mutex.unlock();
        const idx = self.msg_inboxes.items.len;
        try self.msg_inboxes.append(self.allocator, inbox);
        return idx;
    }

    /// Tombstone a worker's slot. The slot stays, so every other
    /// worker keeps the index it was handed; a message routed to a
    /// departed worker gets `error.NoWorkers`, which every producer
    /// already handles.
    pub fn unregisterMsgInbox(self: *MsgRouter, inbox: *effect_mod.MsgInbox) void {
        self.msg_inboxes_mutex.lock();
        defer self.msg_inboxes_mutex.unlock();
        for (self.msg_inboxes.items) |*slot| {
            if (slot.* == inbox) {
                slot.* = null;
                return;
            }
        }
    }

    /// Register a worker's relay inbox under its msg-inbox index
    /// (`registerMsgInbox`'s return — the identity the bound-fetch
    /// owner registry speaks). Pointer is borrowed; the worker must
    /// `unregisterRelayInbox` before tearing the inbox down.
    pub fn registerRelayInbox(self: *MsgRouter, msg_inbox_idx: usize, inbox: *RelayInbox) !void {
        self.relay_inboxes_mutex.lock();
        defer self.relay_inboxes_mutex.unlock();
        try self.relay_inboxes.put(self.allocator, msg_inbox_idx, inbox);
    }

    pub fn unregisterRelayInbox(self: *MsgRouter, msg_inbox_idx: usize) void {
        self.relay_inboxes_mutex.lock();
        defer self.relay_inboxes_mutex.unlock();
        _ = self.relay_inboxes.remove(msg_inbox_idx);
    }

    /// Push one relay item onto the worker at `msg_inbox_idx`.
    /// Ownership of `item` transfers on success; on error the caller
    /// retains and frees. `error.NoWorkers` when the worker never
    /// registered a relay inbox (or already unregistered) — the
    /// producer treats that as fatal for the transfer (abort, never a
    /// silent byte drop).
    pub fn enqueueRelayToWorker(
        self: *MsgRouter,
        msg_inbox_idx: usize,
        item: RelayItem,
    ) !void {
        self.relay_inboxes_mutex.lock();
        const inbox = self.relay_inboxes.get(msg_inbox_idx) orelse {
            self.relay_inboxes_mutex.unlock();
            return error.NoWorkers;
        };
        self.relay_inboxes_mutex.unlock();
        try inbox.push(self.allocator, item);
    }

    /// Hash-route `msg` onto the destination worker's `MsgInbox` by
    /// `hash(tenant_id) % N`. The typed wrappers
    /// (`enqueueFetchEventForTenant`, `enqueueDurableWakeForTenant`)
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
        const inbox = self.msg_inboxes.items[inbox_idx] orelse {
            self.msg_inboxes_mutex.unlock();
            return error.NoWorkers;
        };
        self.msg_inboxes_mutex.unlock();
        std.log.debug(
            "rove-js msg-route: kind={s} tenant={s} -> worker {d}/{d}",
            .{ @tagName(msg.kind()), tenant_id, inbox_idx, n },
        );
        try inbox.push(msg);
    }

    // ── Held-state ownership registries ────────────────────────────
    // Held state in `docs/architecture/effects-and-handlers.md`.

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

    /// Route a fetch event (chunk / end / pipe_done) to the
    /// destination worker's unified `MsgInbox` as the matching
    /// `effect.Msg` variant. Caller-side ownership of every owned slice
    /// in `ev` transfers in on success; on `error.NoWorkers` the caller
    /// retains and is responsible for `UpstreamFetchEvent.deinitItem`.
    ///
    /// Owner routing (held state in
    /// `docs/architecture/effects-and-handlers.md`): when `ev.bind`
    /// is true AND `bound_fetch_owners[ev.fetch_id]` resolves, route
    /// directly to the owning worker's inbox. Otherwise fall back to
    /// `hash(tenant_id)` — the behavior for unbound (Pattern A)
    /// fetches, subscription fires, kv-react, etc.
    ///
    /// The owner-routing path closes the cross-worker bind gap: the
    /// inbound that registered the bound fetch may live on a
    /// kernel-chosen worker (SO_REUSEPORT) different from
    /// `hash(tenant_id) % N`; without owner routing the chunk arrives
    /// on the wrong worker and the bound resume fails silently until
    /// the held-fetch 25s deadline.
    pub fn enqueueFetchEventForTenant(
        self: *MsgRouter,
        tenant_id: []const u8,
        ev: components_mod.UpstreamFetchEvent,
    ) !void {
        // Single `fetch_chunk` Msg variant; the event's `final` flag
        // distinguishes streaming intermediates from the terminal.
        const msg: effect_mod.Msg = .{ .fetch_chunk = ev };
        // Bound fetch chunks route to the held-state owner via
        // `bound_fetch_owners`. webhook.send callback chunks (the
        // fetch has no bind:true, but its bound_send_id names the
        // cont's send_id) route via `bound_send_owners`. Either path
        // skips `hash(tenant_id)` to land on the worker that holds the
        // resume target. Unbound / non-webhook fetches fall through to
        // hash routing.
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

    /// Owner-routing helper (held state in
    /// `docs/architecture/effects-and-handlers.md`): push a Msg
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
        const inbox = self.msg_inboxes.items[worker_idx] orelse {
            self.msg_inboxes_mutex.unlock();
            return error.NoWorkers;
        };
        self.msg_inboxes_mutex.unlock();
        try inbox.push(msg);
    }

    /// Hash-route a chained dispatch — a `__rove_next` returned from a
    /// `fetch_chunk` handler — to the destination
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
        saga_id: ?[]const u8,
    ) !void {
        // The hop's target is customer data on every route that reaches here
        // (`blob.put`'s `on`, `webhook.send`'s `on_result`), and dispatch
        // grants `is_system_module` from the module PATH — so a baked target
        // is only dispatchable if it opted in (rove#643). Dropped rather than
        // errored: a refused hop is not an enqueue failure, it is a target
        // that was never dispatchable, and the same drop the wake route makes
        // for a refused entry. Gated HERE, at the router's single funnel, so a
        // future second producer of a chained dispatch inherits it.
        if (builtin_modules.isBuiltinPath(module_path) and
            !builtin_modules.isContinuationTargetable(module_path))
        {
            std.log.warn(
                "rove-js chained dispatch: refusing baked target {s} for tenant={s} — not continuation-targetable",
                .{ module_path, tenant_id },
            );
            return;
        }

        const allocator = self.allocator;
        const tid = try allocator.dupe(u8, tenant_id);
        errdefer allocator.free(tid);
        const mod = try allocator.dupe(u8, module_path);
        errdefer allocator.free(mod);
        const ctx = try allocator.dupe(u8, ctx_json);
        errdefer allocator.free(ctx);
        const fn_dup: ?[]u8 = if (fn_name) |f| try allocator.dupe(u8, f) else null;
        errdefer if (fn_dup) |f| allocator.free(f);
        const saga_dup: ?[]u8 = if (saga_id) |c| try allocator.dupe(u8, c) else null;
        errdefer if (saga_dup) |c| allocator.free(c);

        const payload: effect_mod.msg.SendCallback = .{
            .tenant_id = tid,
            .module_path = mod,
            .ctx_json = ctx,
            .fn_name = fn_dup,
            .saga_id = saga_dup,
        };
        try self.enqueueMsgForTenant(tenant_id, .{ .send_callback = payload });
    }

    /// Route a PLATFORM action into `tenant_id`'s scope (rove#691) — the
    /// primitive that unfuses *whose code runs* from *whose data it runs
    /// against*.
    ///
    /// `dispatcher_is_platform` is read from the DISPATCHING tenant's
    /// identity at the call site, never inferred from a module path. That
    /// distinction is the whole lesson of rove#643, where dispatch granted
    /// `is_system_module` from the path and so handed the exemption to
    /// anything a customer could arm. A path says what code will run; only
    /// the caller's identity says who is entitled to run it somewhere else.
    ///
    /// Two rules, both here at the funnel so a second producer inherits
    /// them, exactly as `isContinuationTargetable` is:
    ///
    ///   1. **Only a platform-bound dispatcher may target another scope.**
    ///   2. **Only BAKED code may be the target.** Platform actions ship in
    ///      the binary — public, scope-agnostic, and resolvable from the
    ///      binary at replay, which is why they need no foreign-code
    ///      mechanism and raise no question about a customer reading code
    ///      they cannot see. Admitting a deployment path here would reopen
    ///      both.
    ///
    /// There is no `saga_id` parameter, and that is deliberate: the
    /// dispatcher's saga is not addressable in this tenant's namespace, so
    /// the activation roots a new one. Absent by construction beats elided
    /// by discipline — `_parent` is inherited BY DEFAULT elsewhere (stamped
    /// from `armed_by` through `_sched/` state), so a field that existed
    /// here would eventually get threaded through.
    ///
    /// Refusals DROP with a warning rather than erroring, matching the
    /// chained-dispatch gate above: a refused dispatch is not an enqueue
    /// failure, it is a call that was never permitted.
    pub fn enqueuePlatformDispatchForTenant(
        self: *MsgRouter,
        tenant_id: []const u8,
        module_path: []const u8,
        ctx_json: []const u8,
        fn_name: ?[]const u8,
        actor: log_mod.PlatformActor,
        /// Report completion HERE — the dispatching tenant's own scope — by
        /// resolving `dispatch_id`'s owed marker. Both empty for a dispatch
        /// with no marker, and for the result hop itself, which must not
        /// produce a result of its own or two tenants would volley forever.
        origin_tenant: []const u8,
        dispatch_id: []const u8,
        dispatcher_is_platform: bool,
    ) !void {
        if (!dispatcher_is_platform) {
            std.log.warn(
                "rove-js platform dispatch: refusing target tenant={s} module={s} — dispatcher is not platform-bound",
                .{ tenant_id, module_path },
            );
            return;
        }
        if (!builtin_modules.isBuiltinPath(module_path)) {
            std.log.warn(
                "rove-js platform dispatch: refusing non-baked target {s} for tenant={s}",
                .{ module_path, tenant_id },
            );
            return;
        }

        const allocator = self.allocator;
        const tid = try allocator.dupe(u8, tenant_id);
        errdefer allocator.free(tid);
        const mod = try allocator.dupe(u8, module_path);
        errdefer allocator.free(mod);
        const ctx = try allocator.dupe(u8, ctx_json);
        errdefer allocator.free(ctx);
        const fn_dup: ?[]u8 = if (fn_name) |f| try allocator.dupe(u8, f) else null;
        errdefer if (fn_dup) |f| allocator.free(f);
        const origin_dup = try allocator.dupe(u8, origin_tenant);
        errdefer allocator.free(origin_dup);
        const did_dup = try allocator.dupe(u8, dispatch_id);
        errdefer allocator.free(did_dup);

        const payload: effect_mod.msg.PlatformDispatch = .{
            .tenant_id = tid,
            .module_path = mod,
            .ctx_json = ctx,
            .fn_name = fn_dup,
            .actor = actor,
            .origin_tenant = origin_dup,
            .dispatch_id = did_dup,
        };
        try self.enqueueMsgForTenant(tenant_id, .{ .platform_dispatch = payload });
    }

    /// Durable-wake: hash-route a `durable_wake` activation — one
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

        const armed_by: ?[]u8 = if (input.armed_by) |ab| try a.dupe(u8, ab) else null;
        errdefer if (armed_by) |ab| a.free(ab);

        const payload: effect_mod.msg.DurableWake = .{
            .tenant_id = tid,
            .module_path = target,
            .id = id,
            .key = key,
            .msg_json = msg_json,
            .scheduled_at_ns = input.scheduled_at_ns,
            .cleanup_keys = cleanup,
            .armed_by = armed_by,
        };
        try self.enqueueMsgForTenant(input.tenant_id, .{ .durable_wake = payload });
    }

    /// Fan out one kv-write event to every registered worker inbox.
    /// Called from `apply.zig` (follower path) and `worker_dispatch.zig`
    /// (leader path) so a write on any node reaches every locally-held
    /// stream regardless of which node + worker hosts it. A per-inbox
    /// push failure is logged and swallowed — the "spurious +
    /// overflow" thesis lets us drop a wake; the worker that lost it
    /// will refetch authoritative state on its next activation anyway.
    /// `write_version` is the producer store's write clock for
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

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

/// First tenant id (of the form `t<N>`) that hash-routes to `want`
/// under a registry of `n` slots.
fn tenantHashingTo(buf: []u8, want: usize, n: usize) []const u8 {
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const id = std.fmt.bufPrint(buf, "t{d}", .{i}) catch unreachable;
        if (std.hash.Wyhash.hash(0, id) % n == want) return id;
    }
    unreachable;
}

test "a bound fetch routes to its held-state owner, not to hash(tenant)" {
    const a = testing.allocator;
    var router = MsgRouter.init(a);
    defer router.deinit();

    var inboxes: [4]effect_mod.MsgInbox = undefined;
    for (&inboxes) |*ib| ib.* = effect_mod.MsgInbox.init(a);
    defer for (&inboxes) |*ib| ib.deinit();
    for (&inboxes) |*ib| _ = try router.registerMsgInbox(ib);

    var buf: [32]u8 = undefined;
    const tenant = tenantHashingTo(&buf, 0, 4);
    const owner = 2; // deliberately not the hash slot

    try testing.expect(router.registerBoundFetchOwner("f1", owner));
    try router.enqueueFetchEventForTenant(tenant, .{
        .fetch_id = try a.dupe(u8, "f1"),
        .tenant_id = try a.dupe(u8, tenant),
        .bind = true,
    });

    // The whole point of the registry: inbound HTTP lands on a
    // kernel-chosen worker, so the worker holding the bound fetch's
    // parked continuation is not the one `hash(tenant_id)` names.
    try testing.expectEqual(@as(usize, 1), inboxes[owner].items.items.len);
    try testing.expectEqual(@as(usize, 0), inboxes[0].items.items.len);
    try testing.expectEqual(@as(u64, 1), router.bound_fetch_cross_worker_routes.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), router.bound_fetch_same_worker_routes.load(.monotonic));
}

test "an owner that happens to sit on the hash slot counts as same-worker" {
    const a = testing.allocator;
    var router = MsgRouter.init(a);
    defer router.deinit();

    var inboxes: [4]effect_mod.MsgInbox = undefined;
    for (&inboxes) |*ib| ib.* = effect_mod.MsgInbox.init(a);
    defer for (&inboxes) |*ib| ib.deinit();
    for (&inboxes) |*ib| _ = try router.registerMsgInbox(ib);

    var buf: [32]u8 = undefined;
    const tenant = tenantHashingTo(&buf, 3, 4);

    try testing.expect(router.registerBoundFetchOwner("f1", 3));
    try router.enqueueFetchEventForTenant(tenant, .{
        .fetch_id = try a.dupe(u8, "f1"),
        .tenant_id = try a.dupe(u8, tenant),
        .bind = true,
    });

    try testing.expectEqual(@as(usize, 1), inboxes[3].items.items.len);
    try testing.expectEqual(@as(u64, 0), router.bound_fetch_cross_worker_routes.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), router.bound_fetch_same_worker_routes.load(.monotonic));
}

test "an unbound fetch hash-routes and moves neither owner counter" {
    const a = testing.allocator;
    var router = MsgRouter.init(a);
    defer router.deinit();

    var inboxes: [4]effect_mod.MsgInbox = undefined;
    for (&inboxes) |*ib| ib.* = effect_mod.MsgInbox.init(a);
    defer for (&inboxes) |*ib| ib.deinit();
    for (&inboxes) |*ib| _ = try router.registerMsgInbox(ib);

    var buf: [32]u8 = undefined;
    const tenant = tenantHashingTo(&buf, 1, 4);

    try router.enqueueFetchEventForTenant(tenant, .{
        .fetch_id = try a.dupe(u8, "f1"),
        .tenant_id = try a.dupe(u8, tenant),
        .bind = false,
    });

    try testing.expectEqual(@as(usize, 1), inboxes[1].items.items.len);
    try testing.expectEqual(@as(u64, 0), router.bound_fetch_cross_worker_routes.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), router.bound_fetch_same_worker_routes.load(.monotonic));
}

test "a departed worker's slot is tombstoned, so its siblings keep their index" {
    const a = testing.allocator;
    var router = MsgRouter.init(a);
    defer router.deinit();

    var inboxes: [3]effect_mod.MsgInbox = undefined;
    for (&inboxes) |*ib| ib.* = effect_mod.MsgInbox.init(a);
    defer for (&inboxes) |*ib| ib.deinit();
    for (&inboxes, 0..) |*ib, i| try testing.expectEqual(i, try router.registerMsgInbox(ib));

    var buf: [32]u8 = undefined;
    const to_two = tenantHashingTo(&buf, 2, 3);

    // Worker 1 tears down mid-shutdown. Compacting the registry here
    // would slide worker 2 into slot 1, silently re-pointing every
    // `bound_*_owners` entry that names 2 and changing the `% N` both
    // sides of `sweepDurableWakes`'s ownership test divide by.
    router.unregisterMsgInbox(&inboxes[1]);

    try router.enqueueMsgForTenant(to_two, .{ .timer = .{} });
    try testing.expectEqual(@as(usize, 1), inboxes[2].items.items.len);
    try testing.expectEqual(@as(usize, 0), inboxes[0].items.items.len);

    // Owner routing to the departed worker is refused, not misdelivered.
    try testing.expectError(error.NoWorkers, router.enqueueMsgToWorker(1, .{ .timer = .{} }));

    // And a fresh registration takes a NEW slot rather than reusing the
    // tombstone — reuse would hand a new worker a departed one's
    // identity, and with it that worker's held-state registrations.
    var late = effect_mod.MsgInbox.init(a);
    defer late.deinit();
    try testing.expectEqual(@as(usize, 3), try router.registerMsgInbox(&late));
}

// ── platform dispatch: the authority gate (rove#691) ──────────────────

/// Drain and free whatever a test enqueued, so the inbox owns nothing at
/// teardown. The payloads are allocator-owned by the enqueue path.
fn drainAndFree(a: std.mem.Allocator, ib: *effect_mod.MsgInbox) usize {
    var n: usize = 0;
    for (ib.items.items) |*m| {
        effect_mod.freeOwnedMsg(a, m);
        n += 1;
    }
    ib.items.clearRetainingCapacity();
    return n;
}

test "platform dispatch: only a platform-bound dispatcher may target another scope" {
    const a = testing.allocator;
    var router = MsgRouter.init(a);
    defer router.deinit();

    var inboxes: [4]effect_mod.MsgInbox = undefined;
    for (&inboxes) |*ib| ib.* = effect_mod.MsgInbox.init(a);
    defer for (&inboxes) |*ib| ib.deinit();
    for (&inboxes) |*ib| _ = try router.registerMsgInbox(ib);

    var buf: [32]u8 = undefined;
    const tenant = tenantHashingTo(&buf, 1, 4);

    // The confused-deputy case (rove#643's shape): a caller that is NOT
    // platform-bound naming a perfectly legitimate baked module. Authority
    // comes from the DISPATCHER's identity, never from the target path — so
    // this is refused even though the path is one the platform itself uses.
    try router.enqueuePlatformDispatchForTenant(
        tenant, "__system/static.mjs", "null", null, .system, "", "", false,
    );
    try testing.expectEqual(@as(usize, 0), inboxes[1].items.items.len);

    // Same call, platform-bound dispatcher: admitted.
    try router.enqueuePlatformDispatchForTenant(
        tenant, "__system/static.mjs", "null", null, .system, "", "", true,
    );
    try testing.expectEqual(@as(usize, 1), inboxes[1].items.items.len);
    try testing.expectEqual(effect_mod.msg.ActivationSource.platform_dispatch, inboxes[1].items.items[0].kind());
    _ = drainAndFree(a, &inboxes[1]);
}

test "platform dispatch: the target must be baked, never customer code" {
    const a = testing.allocator;
    var router = MsgRouter.init(a);
    defer router.deinit();

    var inboxes: [4]effect_mod.MsgInbox = undefined;
    for (&inboxes) |*ib| ib.* = effect_mod.MsgInbox.init(a);
    defer for (&inboxes) |*ib| ib.deinit();
    for (&inboxes) |*ib| _ = try router.registerMsgInbox(ib);

    var buf: [32]u8 = undefined;
    const tenant = tenantHashingTo(&buf, 2, 4);

    // Platform-bound dispatcher, ordinary module path. Refused: admitting a
    // deployment path here would reopen both questions baked code closes —
    // a customer reading code they cannot see, and replay resolving a
    // dep_id out of the wrong tenant's namespace.
    for ([_][]const u8{ "index.mjs", "handlers/admin.mjs", "" }) |path| {
        try router.enqueuePlatformDispatchForTenant(
            tenant, path, "null", null, .operator, "", "", true,
        );
    }
    try testing.expectEqual(@as(usize, 0), inboxes[2].items.items.len);
}

test "platform dispatch: the actor rides the message, and there is no saga to inherit" {
    const a = testing.allocator;
    var router = MsgRouter.init(a);
    defer router.deinit();

    var inboxes: [2]effect_mod.MsgInbox = undefined;
    for (&inboxes) |*ib| ib.* = effect_mod.MsgInbox.init(a);
    defer for (&inboxes) |*ib| ib.deinit();
    for (&inboxes) |*ib| _ = try router.registerMsgInbox(ib);

    var buf: [32]u8 = undefined;
    const tenant = tenantHashingTo(&buf, 0, 2);

    // All three attribution values survive the hop distinctly: "was this me,
    // or was this them?" is the split a reader most wants, and collapsing it
    // to one value is what the vocabulary exists to prevent.
    for ([_]log_mod.PlatformActor{ .tenant_user, .operator, .system }) |actor| {
        try router.enqueuePlatformDispatchForTenant(
            tenant, "__system/static.mjs", "{\"a\":1}", "onThing", actor, "", "", true,
        );
    }
    try testing.expectEqual(@as(usize, 3), inboxes[0].items.items.len);
    for (inboxes[0].items.items, [_]log_mod.PlatformActor{ .tenant_user, .operator, .system }) |m, want| {
        const pd = m.platform_dispatch;
        try testing.expectEqual(want, pd.actor);
        try testing.expectEqualStrings(tenant, pd.tenant_id);
        try testing.expectEqualStrings("{\"a\":1}", pd.ctx_json);
        try testing.expectEqualStrings("onThing", pd.fn_name.?);
    }
    _ = drainAndFree(a, &inboxes[0]);

    // The Msg has no saga field at all. A cross-scope hop has no parent
    // addressable in this tenant's namespace, and `_parent` is inherited BY
    // DEFAULT elsewhere — so absence by construction is what keeps a later
    // caller from threading one through.
    try testing.expect(!@hasField(effect_mod.msg.PlatformDispatch, "saga_id"));
}

test "platform dispatch: the result hop carries no origin, so results cannot volley" {
    const a = testing.allocator;
    var router = MsgRouter.init(a);
    defer router.deinit();

    var inboxes: [2]effect_mod.MsgInbox = undefined;
    for (&inboxes) |*ib| ib.* = effect_mod.MsgInbox.init(a);
    defer for (&inboxes) |*ib| ib.deinit();
    for (&inboxes) |*ib| _ = try router.registerMsgInbox(ib);

    var buf: [32]u8 = undefined;
    const tenant = tenantHashingTo(&buf, 0, 2);

    // A dispatch that names a marker: the target's completion has somewhere
    // to report, so the origin can stop retrying.
    try router.enqueuePlatformDispatchForTenant(
        tenant, "__system/static.mjs", "null", null, .system, "acme", "d-1", true,
    );
    // The result hop itself: no origin, no marker. A result that produced a
    // result would bounce between two tenants forever, so absence here is
    // structural rather than a caller remembering to pass empties.
    try router.enqueuePlatformDispatchForTenant(
        tenant, "__system/dispatch_result.mjs", "{\"id\":\"d-1\"}", null, .system, "", "", true,
    );

    try testing.expectEqual(@as(usize, 2), inboxes[0].items.items.len);
    const first = inboxes[0].items.items[0].platform_dispatch;
    try testing.expectEqualStrings("acme", first.origin_tenant);
    try testing.expectEqualStrings("d-1", first.dispatch_id);
    const second = inboxes[0].items.items[1].platform_dispatch;
    try testing.expectEqual(@as(usize, 0), second.origin_tenant.len);
    try testing.expectEqual(@as(usize, 0), second.dispatch_id.len);
    _ = drainAndFree(a, &inboxes[0]);
}
