//! Async serve-or-forward engine — Phase 7 (zero-downtime move) follow-up.
//!
//! When a DP (`rewind`) cluster receives a request for a tenant it does
//! NOT own (a stale public route, or a post-move source), it must
//! reverse-proxy the request to the cluster that DOES own it. The
//! original implementation (`worker_dispatch.tryForwardToOwner`) did
//! this with **blocking libcurl on the worker's poll loop**: one
//! synchronous `GET /_cp/route` to the control plane, then a
//! synchronous forward to the owner. Under a post-move routing burst
//! that stalls the whole worker — every mis-routed request blocks the
//! loop for a full cross-cluster round-trip.
//!
//! This engine moves both stages OFF the worker loop, mirroring the
//! `FetchEngine` (`fetch_engine.zig`) model: one thread driving a
//! `curl_multi` handle that holds many concurrent transfers. The
//! worker **parks** the h2 stream (see `worker.forward_pending` +
//! `ForwardWait`) and `submit()`s a `ProxyJobSpec`; the engine runs
//! the two-stage chain internally and pushes a `ProxyResult` back to
//! the originating worker's `ProxyResultInbox`, which `drainForwardPending`
//! turns into the final response. The worker loop never blocks.
//!
//! ## The two-stage chain (engine-thread state machine)
//!
//! A `ProxyJob` runs both stages so the worker parks exactly once:
//!
//!  1. **CP route-query** — `GET {cp_urls[i]}/_cp/route?host=`. Try each
//!     CP node until one answers (reads work on any node, apply-driven
//!     projection); a reachable non-200 is authoritative (unknown host)
//!     → `.local_miss`. A 200 carries `{cluster, nodes}`. If `cluster`
//!     is THIS cluster (or nodes empty / unparseable) → `.local_miss`
//!     (the request is genuinely for us but the tenant isn't here →
//!     404). Otherwise advance to stage 2 with the owner's nodes.
//!  2. **Forward** — proxy the original request to `{nodes[i]}{path}`,
//!     leader-aware (retry the next node on a `503` follower). The
//!     owner's response (any status) becomes `.forwarded`.
//!
//! ## Why a dedicated engine (not `FetchEngine`)
//!
//! `FetchEngine` is JS-handler shaped: its results are `UpstreamFetchEvent`s
//! that re-enter a customer JS continuation, hash-routed by tenant. A
//! serve-or-forward proxy has **no tenant on this node and no JS handler** —
//! its result is a raw HTTP response delivered straight to a parked h2
//! stream. Keeping this engine separate leaves the `FetchEngine` path
//! untouched; the only shared machinery is the generic `curl_multi`
//! transport in `rove-blob`.

const std = @import("std");
const blob_curl_multi = @import("rove-blob").curl_multi;
const worker_mod = @import("worker.zig");

const NodeState = worker_mod.NodeState;
const Multi = blob_curl_multi.Multi;
const Transfer = blob_curl_multi.Transfer;
const Request = blob_curl_multi.Request;
const Result = blob_curl_multi.Result;
const Header = blob_curl_multi.Header;
const Method = blob_curl_multi.Method;

/// How long the engine thread blocks in `multi.poll` between wakeups.
/// `Multi.wakeup` unblocks on submit, so this only governs idle
/// latency for libcurl-internal events.
const ENGINE_POLL_TIMEOUT_MS: c_int = 1000;

/// Per-stage transport timeout. The forward to the owner cluster is a
/// same-region cluster-to-cluster hop; 15s matches the front door's
/// proxy budget.
const STAGE_TIMEOUT_MS: u32 = 15_000;

/// The terminal disposition of a proxy job. Every variant owns its own
/// allocations (independent of the consumed `ProxyJobSpec`) so the
/// result can outlive the job on the worker side.
pub const ProxyOutcome = union(enum) {
    /// The owner cluster answered. `body` is engine-allocated and
    /// transfers to the h2 response on `finalizeResponse` (no copy).
    forwarded: struct { status: u16, body: []u8 },
    /// This cluster is the named owner (or the host is unknown /
    /// unroutable) → the worker builds the diagnostic 404. `host` is
    /// engine-allocated; the worker frees it after building the body.
    local_miss: struct { host: []u8 },
    /// Every CP node was unreachable → the worker responds 503.
    cp_unreachable,
    /// The owner was named but the forward failed at the transport
    /// layer on every node → the worker responds 502.
    transport_error,

    pub fn deinit(self: *ProxyOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .forwarded => |f| allocator.free(f.body),
            .local_miss => |m| allocator.free(m.host),
            .cp_unreachable, .transport_error => {},
        }
        self.* = undefined;
    }
};

/// Pushed back to the originating worker. Matched to a parked entity by
/// `forward_id` in `drainForwardPending`.
pub const ProxyResult = struct {
    forward_id: u64,
    outcome: ProxyOutcome,
};

/// One per worker thread. The engine pushes a `ProxyResult` here from
/// its own thread; the owning worker drains on its tick. Mirrors
/// `effect.MsgInbox` (a plain mutex+list; the worker's 1ms poll
/// cadence services it — no eventfd wake needed).
pub const ProxyResultInbox = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayListUnmanaged(ProxyResult) = .empty,

    pub fn deinit(self: *ProxyResultInbox, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |*r| r.outcome.deinit(allocator);
        self.items.deinit(allocator);
    }

    pub fn push(self: *ProxyResultInbox, allocator: std.mem.Allocator, r: ProxyResult) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, r);
    }

    /// Move all queued results into `out`; inbox empty after. Caller
    /// owns each result (and its outcome's allocations).
    pub fn drainInto(self: *ProxyResultInbox, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(ProxyResult)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try out.appendSlice(allocator, self.items.items);
        self.items.clearRetainingCapacity();
    }
};

/// Everything the engine needs to run one job. Built + owned by the
/// submitting worker; ownership transfers to the engine on `submit`,
/// which frees every slice when the job finishes. `headers`/`body` are
/// the original request's, pre-filtered by the worker (hop-by-hop
/// stripped, Host preserved) so the engine stays parsing-free.
pub const ProxyJobSpec = struct {
    forward_id: u64,
    /// `worker.msg_inbox_idx` of the parking worker — the index into
    /// `NodeState.proxy_result_inboxes` the result routes back to.
    worker_idx: usize,
    /// This cluster's id (`REWIND_CLUSTER_ID`). A CP answer naming this
    /// cluster as owner is a local miss, not a forward.
    my_cluster_id: []u8,
    /// CP node origins to try for the route-query, in order.
    cp_urls: []const []u8,
    host: []u8,
    method: Method,
    path: []u8,
    headers: []Header,
    /// Allocator-owned backing for every `headers[i].name`/`.value`.
    /// One arena-ish blob freed wholesale: the worker dupes each name
    /// and value into its own slice and we free them in `deinit`.
    headers_owned: bool,
    body: []u8,

    pub fn deinit(self: *ProxyJobSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.my_cluster_id);
        for (self.cp_urls) |u| allocator.free(u);
        allocator.free(self.cp_urls);
        allocator.free(self.host);
        allocator.free(self.path);
        if (self.headers_owned) {
            for (self.headers) |h| {
                allocator.free(@constCast(h.name));
                allocator.free(@constCast(h.value));
            }
        }
        allocator.free(self.headers);
        allocator.free(self.body);
        self.* = undefined;
    }
};

const Stage = enum { cp_query, forward };

/// Engine-thread-only job state. Lives in `ProxyEngine.jobs` from
/// admission until it finishes. The `on_done` callback only mutates
/// flags + advances indices (and dupes any retained bytes); the engine
/// loop reads `needs_next` / `done` after `drainCompleted` and either
/// builds the next transfer or pushes the result.
const ProxyJob = struct {
    engine: *ProxyEngine,
    spec: ProxyJobSpec,
    stage: Stage = .cp_query,
    /// Index into `spec.cp_urls` for the current/next CP query attempt.
    cp_idx: usize = 0,
    /// Owner cluster's node origins (parsed from the CP answer); owned.
    owner_nodes: []const []u8 = &.{},
    /// Index into `owner_nodes` for the current/next forward attempt.
    node_idx: usize = 0,
    /// Engine loop should build + add the next transfer (stage/index
    /// already advanced).
    needs_next: bool = false,
    /// Job is finished; `outcome` holds the disposition to push.
    done: bool = false,
    outcome: ProxyOutcome = .cp_unreachable,

    fn deinit(self: *ProxyJob, allocator: std.mem.Allocator) void {
        self.spec.deinit(allocator);
        for (self.owner_nodes) |n| allocator.free(n);
        allocator.free(self.owner_nodes);
    }
};

pub const ProxyEngine = struct {
    allocator: std.mem.Allocator,
    node: *NodeState,

    thread: ?std.Thread = null,
    multi: ?*Multi = null,
    stop: std.atomic.Value(bool) = .init(false),

    /// Cross-thread inbound queue. Workers push specs via `submit`; the
    /// engine drains at the top of each loop. Ownership transfers on push.
    inbound_mu: std.Thread.Mutex = .{},
    inbound: std.ArrayListUnmanaged(ProxyJobSpec) = .empty,

    /// Engine-thread-only: live jobs (each may span several transfers).
    jobs: std.ArrayListUnmanaged(*ProxyJob) = .empty,

    pub fn init(allocator: std.mem.Allocator, node: *NodeState) !*ProxyEngine {
        const self = try allocator.create(ProxyEngine);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .node = node };
        return self;
    }

    /// Spawn the engine thread + create the curl_multi handle.
    /// Idempotent.
    pub fn start(self: *ProxyEngine) !void {
        if (self.thread != null) return;
        self.stop.store(false, .release);
        const multi = try Multi.init(self.allocator);
        errdefer multi.deinit();
        self.multi = multi;
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Signal stop + join. Frees undrained inbound specs and any live
    /// jobs; no result is pushed for an in-flight job at shutdown (the
    /// parked worker stream is torn down by the worker's own deinit).
    pub fn shutdown(self: *ProxyEngine) void {
        if (self.thread == null) return;
        self.stop.store(true, .release);
        if (self.multi) |m| m.wakeup() catch {};
        self.thread.?.join();
        self.thread = null;

        {
            self.inbound_mu.lock();
            defer self.inbound_mu.unlock();
            for (self.inbound.items) |*s| s.deinit(self.allocator);
            self.inbound.deinit(self.allocator);
            self.inbound = .empty;
        }
        for (self.jobs.items) |job| {
            job.deinit(self.allocator);
            self.allocator.destroy(job);
        }
        self.jobs.deinit(self.allocator);
        self.jobs = .empty;
        if (self.multi) |m| {
            m.deinit();
            self.multi = null;
        }
    }

    pub fn deinit(self: *ProxyEngine) void {
        if (self.thread != null) self.shutdown();
        self.allocator.destroy(self);
    }

    /// Cross-thread: take ownership of `spec` + enqueue. The engine runs
    /// it asynchronously. On `error.OutOfMemory` the caller's ownership
    /// is unchanged (so it can free).
    pub fn submit(self: *ProxyEngine, spec: ProxyJobSpec) !void {
        {
            self.inbound_mu.lock();
            defer self.inbound_mu.unlock();
            try self.inbound.append(self.allocator, spec);
        }
        if (self.multi) |m| m.wakeup() catch {};
    }

    // ── Engine thread ─────────────────────────────────────────────────

    fn threadMain(self: *ProxyEngine) void {
        while (!self.stop.load(.acquire)) {
            self.drainInbound();
            const multi = self.multi orelse return;
            _ = multi.poll(ENGINE_POLL_TIMEOUT_MS) catch |err| {
                std.log.warn("rove-js proxy_engine: poll: {s}", .{@errorName(err)});
                std.Thread.sleep(10 * std.time.ns_per_ms);
            };
            _ = multi.drainCompleted(); // fires onTransferDone → advances jobs
            self.processJobs();
        }
    }

    /// Admit queued specs as new jobs (each starts at stage `cp_query`,
    /// `needs_next = true`). `processJobs` builds their first transfer.
    fn drainInbound(self: *ProxyEngine) void {
        var batch: std.ArrayListUnmanaged(ProxyJobSpec) = .empty;
        defer batch.deinit(self.allocator);
        {
            self.inbound_mu.lock();
            defer self.inbound_mu.unlock();
            if (self.inbound.items.len == 0) return;
            std.mem.swap(std.ArrayListUnmanaged(ProxyJobSpec), &batch, &self.inbound);
        }
        for (batch.items) |spec| {
            const job = self.allocator.create(ProxyJob) catch {
                var s = spec;
                s.deinit(self.allocator);
                continue;
            };
            job.* = .{ .engine = self, .spec = spec, .needs_next = true };
            // A spec with no CP nodes can't be routed — finish immediately.
            if (spec.cp_urls.len == 0) {
                job.needs_next = false;
                job.done = true;
                job.outcome = .cp_unreachable;
            }
            self.jobs.append(self.allocator, job) catch {
                job.deinit(self.allocator);
                self.allocator.destroy(job);
                continue;
            };
        }
    }

    /// After `drainCompleted`: build the next transfer for `needs_next`
    /// jobs, and push + free `done` jobs.
    fn processJobs(self: *ProxyEngine) void {
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            const job = self.jobs.items[i];
            if (job.done) {
                self.finishJob(job);
                _ = self.jobs.swapRemove(i);
                continue; // don't advance i — swapRemove moved a job into slot i
            }
            if (job.needs_next) {
                job.needs_next = false;
                self.startTransfer(job);
                // startTransfer may have set job.done on an alloc/curl
                // failure — handle it next pass; cheap and avoids
                // re-checking here.
            }
            i += 1;
        }
    }

    /// Build + add the transfer for the job's current stage/index.
    fn startTransfer(self: *ProxyEngine, job: *ProxyJob) void {
        const multi = self.multi orelse {
            job.done = true;
            job.outcome = .cp_unreachable;
            return;
        };
        const req: Request = switch (job.stage) {
            .cp_query => blk: {
                const url = std.fmt.allocPrint(self.allocator, "{s}/_cp/route?host={s}", .{ job.spec.cp_urls[job.cp_idx], job.spec.host }) catch {
                    job.done = true;
                    job.outcome = .cp_unreachable;
                    return;
                };
                // `url` is duped by Transfer.init (dupeZ); free after.
                break :blk .{ .method = .GET, .url = url, .timeout_ms = STAGE_TIMEOUT_MS, .verify_tls = false, .http2_prior_knowledge = true };
            },
            .forward => blk: {
                const url = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ job.owner_nodes[job.node_idx], job.spec.path }) catch {
                    job.done = true;
                    job.outcome = .transport_error;
                    return;
                };
                break :blk .{
                    .method = job.spec.method,
                    .url = url,
                    .headers = job.spec.headers,
                    .body = job.spec.body,
                    .timeout_ms = STAGE_TIMEOUT_MS,
                    .verify_tls = false,
                    .http2_prior_knowledge = true,
                };
            },
        };
        // The url was allocPrinted above; Transfer.init copies it.
        defer self.allocator.free(@constCast(req.url));

        const transfer = Transfer.init(self.allocator, req, onTransferDone, job) catch {
            // Couldn't even build the easy handle — treat as a transport
            // failure of this attempt and let the stage logic retry/fail.
            onAttemptFailed(job);
            return;
        };
        multi.add(transfer) catch {
            transfer.deinit();
            onAttemptFailed(job);
        };
    }

    fn finishJob(self: *ProxyEngine, job: *ProxyJob) void {
        const idx = job.spec.worker_idx;
        const inboxes = self.node.proxy_result_inboxes;
        if (idx < inboxes.len) {
            inboxes[idx].push(self.allocator, .{ .forward_id = job.spec.forward_id, .outcome = job.outcome }) catch {
                // Drop on OOM: free the outcome's allocations so they
                // don't leak; the parked worker stream times out to 504.
                var o = job.outcome;
                o.deinit(self.allocator);
            };
        } else {
            // No such worker inbox (shouldn't happen) — free the outcome.
            var o = job.outcome;
            o.deinit(self.allocator);
        }
        // The outcome's allocations are now owned by the pushed result
        // (or already freed); don't double-free in job.deinit.
        job.outcome = .cp_unreachable;
        job.deinit(self.allocator);
        self.allocator.destroy(job);
    }
};

/// A transfer that never reached completion (couldn't build / add).
/// Advance the stage's attempt index as if it failed at transport.
fn onAttemptFailed(job: *ProxyJob) void {
    switch (job.stage) {
        .cp_query => {
            job.cp_idx += 1;
            if (job.cp_idx >= job.spec.cp_urls.len) {
                job.done = true;
                job.outcome = .cp_unreachable;
            } else {
                job.needs_next = true;
            }
        },
        .forward => {
            job.node_idx += 1;
            if (job.node_idx >= job.owner_nodes.len) {
                job.done = true;
                job.outcome = .transport_error;
            } else {
                job.needs_next = true;
            }
        },
    }
}

/// Completion callback (engine thread, inside `drainCompleted`). Only
/// mutates job flags + dupes retained bytes — the engine loop's
/// `processJobs` performs any libcurl `add`.
fn onTransferDone(transfer: *Transfer, result: Result, ctx: ?*anyopaque) void {
    _ = transfer;
    const job: *ProxyJob = @ptrCast(@alignCast(ctx.?));
    const engine = job.engine;
    switch (job.stage) {
        .cp_query => onCpQueryDone(engine, job, result),
        .forward => onForwardDone(engine, job, result),
    }
}

fn onCpQueryDone(engine: *ProxyEngine, job: *ProxyJob, result: Result) void {
    if (!result.ok) {
        onAttemptFailed(job); // transport error → try next CP node
        return;
    }
    // A reachable CP node that didn't answer 200 is authoritative:
    // unknown host / not-an-owner → fall through to the local 404.
    if (result.status != 200) {
        finishLocalMiss(engine, job);
        return;
    }
    const Parsed = struct { cluster: []const u8, nodes: [][]const u8 };
    var parsed = std.json.parseFromSlice(Parsed, engine.allocator, result.body, .{ .ignore_unknown_fields = true }) catch {
        finishLocalMiss(engine, job);
        return;
    };
    defer parsed.deinit();
    // This cluster IS the named owner but lacks the tenant → genuine miss.
    if (std.mem.eql(u8, parsed.value.cluster, job.spec.my_cluster_id) or parsed.value.nodes.len == 0) {
        finishLocalMiss(engine, job);
        return;
    }
    // Own the owner node list (the parsed arena is freed on return).
    var nodes = engine.allocator.alloc([]u8, parsed.value.nodes.len) catch {
        finishLocalMiss(engine, job);
        return;
    };
    var filled: usize = 0;
    for (parsed.value.nodes, 0..) |n, k| {
        nodes[k] = engine.allocator.dupe(u8, n) catch {
            for (nodes[0..filled]) |d| engine.allocator.free(d);
            engine.allocator.free(nodes);
            finishLocalMiss(engine, job);
            return;
        };
        filled += 1;
    }
    job.owner_nodes = nodes;
    job.stage = .forward;
    job.node_idx = 0;
    job.needs_next = true;
}

fn onForwardDone(engine: *ProxyEngine, job: *ProxyJob, result: Result) void {
    if (!result.ok) {
        onAttemptFailed(job); // transport error → try next owner node
        return;
    }
    // Leader-aware: a follower answers 503; retry the next node.
    if (result.status == 503 and job.node_idx + 1 < job.owner_nodes.len) {
        job.node_idx += 1;
        job.needs_next = true;
        return;
    }
    // Terminal: deliver the owner's response (the borrowed body must be
    // duped before the Transfer is freed by drainCompleted).
    const body = engine.allocator.dupe(u8, result.body) catch {
        job.done = true;
        job.outcome = .transport_error;
        return;
    };
    job.done = true;
    job.outcome = .{ .forwarded = .{ .status = result.status, .body = body } };
}

fn finishLocalMiss(engine: *ProxyEngine, job: *ProxyJob) void {
    const host = engine.allocator.dupe(u8, job.spec.host) catch {
        job.done = true;
        job.outcome = .transport_error;
        return;
    };
    job.done = true;
    job.outcome = .{ .local_miss = .{ .host = host } };
}
