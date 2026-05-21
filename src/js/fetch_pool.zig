//! Gap 2.3 Phase C2 — the outbound `http.fetch` pool.
//!
//! ## Why a dedicated pool (not `SendDispatch`'s threads)
//!
//! `http.send` is durable + at-least-once + raft-replicated; its
//! transport lives inside `SendDispatch` because firing piggybacks
//! on a leader-only in-flight set + `_send/owed/` markers + boot-scan
//! recovery. `http.fetch` is transient + best-effort + best-latency:
//! a chunk lost on node crash is just gone (the handler chain dies
//! with it). Separate saturation domain → separate pool.
//!
//! ## Shape
//!
//! Workers (any thread) accumulate `PendingFetch`es in a per-request
//! list, then flush to `NodeState.fetch_pending` at handler success.
//! `FetchPool` threads (N = `FETCH_POOL_SIZE`) wait on a condition
//! variable, drain entries, fire libcurl synchronously, split the
//! response body into `max_response_chunk_bytes` units, and push one
//! `UpstreamFetchEvent` per chunk + one terminal event to the per-
//! worker `FetchChunkInbox` via hash-routed
//! `enqueueFetchEventForTenant`.
//!
//! v1 uses libcurl's buffered `Easy.request` — body is captured in
//! memory, then re-chunked. For SSE / LLM-streaming use cases this
//! breaks at upstream-timeout. Real streaming via
//! `CURLOPT_WRITEFUNCTION` lands as an incremental follow-up that
//! swaps the call site here; the rest of the pipeline (events,
//! inboxes, dispatch) is identical.

const std = @import("std");
const blob_curl = @import("rove-blob").curl;
const components_mod = @import("components.zig");
const worker_mod = @import("worker.zig");
const globals = @import("globals.zig");
const sched_thread = @import("rove-schedule-server").thread;

const NodeState = worker_mod.NodeState;
const PendingFetch = globals.PendingFetch;
const UpstreamFetchEvent = components_mod.UpstreamFetchEvent;

/// Outbound-fetch pool size. Matches `SendDispatch.FIRE_POOL_SIZE`
/// (8) so the two outbound paths have symmetric concurrency
/// budgets. Const for now; a config knob is a later refinement.
const FETCH_POOL_SIZE: u16 = 8;

pub const FetchPool = struct {
    allocator: std.mem.Allocator,
    node: *NodeState,

    threads: []std.Thread = &.{},
    easy_pool: ?*blob_curl.EasyPool = null,

    stop: std.atomic.Value(bool) = .init(false),
    /// One-shot warning latch — if the very first chunk's
    /// hash-route fails because no workers are registered yet
    /// (cold-start race), we log once + drop. Subsequent failures
    /// stay quiet to keep the log readable. Reset at `start`.
    no_inbox_warned: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, node: *NodeState) !*FetchPool {
        const self = try allocator.create(FetchPool);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .node = node };
        return self;
    }

    pub fn start(self: *FetchPool) !void {
        if (self.threads.len > 0) return; // already started

        self.stop.store(false, .release);
        self.no_inbox_warned.store(false, .release);

        self.easy_pool = try blob_curl.EasyPool.init(self.allocator, FETCH_POOL_SIZE);
        errdefer {
            self.easy_pool.?.deinit();
            self.easy_pool = null;
        }

        self.threads = try self.allocator.alloc(std.Thread, FETCH_POOL_SIZE);
        errdefer {
            self.allocator.free(self.threads);
            self.threads = &.{};
        }

        var spawned: usize = 0;
        errdefer {
            // Join whatever spawned so far on partial-spawn error.
            // Set stop FIRST so threads exit their wait loops.
            self.stop.store(true, .release);
            self.node.fetch_pending_mutex.lock();
            self.node.fetch_pending_cond.broadcast();
            self.node.fetch_pending_mutex.unlock();
            for (self.threads[0..spawned]) |t| t.join();
        }

        while (spawned < FETCH_POOL_SIZE) : (spawned += 1) {
            self.threads[spawned] = try std.Thread.spawn(.{}, threadMain, .{self});
        }
    }

    /// Signal all pool threads to stop. Idempotent. Threads exit
    /// their wait loops on the next cond broadcast or wake.
    pub fn shutdown(self: *FetchPool) void {
        if (self.threads.len == 0) return;
        self.stop.store(true, .release);
        // Broadcast under the queue mutex so every thread that's
        // currently in `cond.wait` sees the stop signal on wakeup.
        self.node.fetch_pending_mutex.lock();
        self.node.fetch_pending_cond.broadcast();
        self.node.fetch_pending_mutex.unlock();
        for (self.threads) |t| t.join();
        self.allocator.free(self.threads);
        self.threads = &.{};
    }

    pub fn deinit(self: *FetchPool) void {
        // Defensive — `shutdown()` should already have joined.
        if (self.threads.len > 0) self.shutdown();
        if (self.easy_pool) |ep| {
            ep.deinit();
            self.easy_pool = null;
        }
        self.allocator.destroy(self);
    }

    fn threadMain(self: *FetchPool) void {
        const a = self.allocator;
        while (true) {
            // Wait on the cond + drain one entry under the mutex.
            self.node.fetch_pending_mutex.lock();
            while (self.node.fetch_pending.items.len == 0 and
                !self.stop.load(.acquire))
            {
                self.node.fetch_pending_cond.wait(&self.node.fetch_pending_mutex);
            }
            if (self.stop.load(.acquire)) {
                self.node.fetch_pending_mutex.unlock();
                return;
            }
            var pf = self.node.fetch_pending.orderedRemove(0);
            self.node.fetch_pending_mutex.unlock();

            // Run libcurl outside the mutex. `pf` owns all its
            // slices; we free them via `pf.deinit` before looping.
            self.runOne(&pf) catch |err| {
                std.log.warn(
                    "rove-js fetch_pool: runOne tenant={s} id={s} err={s}",
                    .{ pf.tenant_id, pf.id, @errorName(err) },
                );
            };
            pf.deinit(a);
        }
    }

    /// Execute one buffered fetch + push events. Errors here are
    /// the pool's own (alloc, transport setup); the upstream's
    /// own !2xx status surfaces as a successful `end` event with
    /// `terminal_ok = false`.
    fn runOne(self: *FetchPool, pf: *PendingFetch) !void {
        const a = self.allocator;
        const pool = self.easy_pool orelse return error.NoEasyPool;
        const easy = pool.acquire();
        defer pool.release(easy);

        // Headers JSON → `[]Header`. PendingFetch carries the
        // already-validated JSON object from buildFetchRow; here
        // we re-parse it onto the curl-side slice. Empty object is
        // the common case (no custom headers).
        var headers_list: std.ArrayListUnmanaged(blob_curl.Header) = .empty;
        defer {
            for (headers_list.items) |h| {
                a.free(h.name);
                a.free(h.value);
            }
            headers_list.deinit(a);
        }
        try parseHeadersJson(a, pf.headers_json, &headers_list);

        const method = parseMethod(pf.method) orelse return error.UnsupportedMethod;
        const req: blob_curl.Request = .{
            .method = method,
            .url = pf.url,
            .headers = headers_list.items,
            .body = pf.body,
            .timeout_ms = pf.timeout_ms,
            // Test-harness escape hatch: `--dev-webhook-unsafe` flips
            // the same process-wide flag `http.send`'s fire path
            // reads, so smokes can `http.fetch` an on-box echo with
            // a self-signed cert. Production leaves it false →
            // full TLS verification.
            .verify_tls = !sched_thread.test_allow_plaintext,
        };

        var resp = easy.request(a, req) catch |err| {
            // Transport-level failure: push a single `end` event
            // with `terminal_ok = false`. The handler's `on_done`
            // sees the failure shape and can react.
            try self.pushTerminal(pf, 0, false);
            return err;
        };
        defer resp.deinit(a);

        // Re-chunk the body into `max_response_chunk_bytes` pieces.
        // For the v1 buffered path, this happens after the full
        // response is in memory — latency-wise equivalent to a
        // single chunk for the customer. Streaming via writefn
        // landing as an incremental upgrade keeps the per-chunk
        // shape identical so customer handlers don't break.
        const body = resp.body orelse &[_]u8{};
        const cap = if (pf.max_response_chunk_bytes == 0)
            @as(usize, std.math.maxInt(usize))
        else
            @as(usize, pf.max_response_chunk_bytes);

        // Cap total response bytes (caller-supplied caps protect
        // against runaway upstream sizes). Truncate silently if
        // exceeded — the terminal event still fires with the
        // upstream status.
        const total = if (pf.max_total_response_bytes != 0 and
            body.len > pf.max_total_response_bytes)
            @as(usize, @intCast(pf.max_total_response_bytes))
        else
            body.len;

        // Serialize response headers for seq=0's `fetch_headers`
        // field. Wire format mirrors libcurl's input shape:
        // `Name: value\r\n` lines, one per header.
        const headers_blob = try serializeHeaders(a, resp.headers);
        defer a.free(headers_blob);

        var offset: usize = 0;
        var seq: u32 = 0;
        while (offset < total) {
            const next = @min(offset + cap, total);
            const slice = body[offset..next];

            const id_dup = try a.dupe(u8, pf.id);
            errdefer a.free(id_dup);
            const tid_dup = try a.dupe(u8, pf.tenant_id);
            errdefer a.free(tid_dup);
            const ctx_dup = try a.dupe(u8, pf.ctx_json);
            errdefer a.free(ctx_dup);
            const chunk_mod_dup = try a.dupe(u8, pf.on_chunk_module);
            errdefer a.free(chunk_mod_dup);
            const bytes_dup = try a.dupe(u8, slice);
            errdefer a.free(bytes_dup);
            const headers_dup: ?[]u8 = if (seq == 0 and headers_blob.len > 0)
                try a.dupe(u8, headers_blob)
            else
                null;
            errdefer if (headers_dup) |h| a.free(h);

            const ev: UpstreamFetchEvent = .{
                .kind = .chunk,
                .fetch_id = id_dup,
                .tenant_id = tid_dup,
                .ctx_json = ctx_dup,
                .on_chunk_module = chunk_mod_dup,
                .seq = seq,
                .byte_offset = @intCast(offset),
                .bytes = bytes_dup,
                .fetch_headers = headers_dup,
            };
            self.routeEvent(pf.tenant_id, ev) catch |err| {
                // Ownership of `ev`'s slices stays with us on err.
                // Free them inline; loop continues to terminal.
                a.free(id_dup);
                a.free(tid_dup);
                a.free(ctx_dup);
                a.free(chunk_mod_dup);
                a.free(bytes_dup);
                if (headers_dup) |h| a.free(h);
                std.log.warn(
                    "rove-js fetch_pool: route chunk seq={d}: {s}",
                    .{ seq, @errorName(err) },
                );
                return;
            };

            offset = next;
            seq += 1;
        }

        // Terminal event. Reports upstream's actual status; ok =
        // 2xx-class (lets the handler short-circuit on success/
        // failure without re-parsing).
        try self.pushTerminal(pf, resp.status, resp.status >= 200 and resp.status < 300);
    }

    /// Push a `kind = .end` terminal event for `pf`'s chain.
    fn pushTerminal(
        self: *FetchPool,
        pf: *PendingFetch,
        status: u16,
        ok: bool,
    ) !void {
        const a = self.allocator;
        const id_dup = try a.dupe(u8, pf.id);
        errdefer a.free(id_dup);
        const tid_dup = try a.dupe(u8, pf.tenant_id);
        errdefer a.free(tid_dup);
        const ctx_dup = try a.dupe(u8, pf.ctx_json);
        errdefer a.free(ctx_dup);
        const done_mod_dup = try a.dupe(u8, pf.on_done_module);
        errdefer a.free(done_mod_dup);

        const ev: UpstreamFetchEvent = .{
            .kind = .end,
            .fetch_id = id_dup,
            .tenant_id = tid_dup,
            .ctx_json = ctx_dup,
            .on_done_module = done_mod_dup,
            .terminal_status = status,
            .terminal_ok = ok,
        };
        self.routeEvent(pf.tenant_id, ev) catch |err| {
            a.free(id_dup);
            a.free(tid_dup);
            a.free(ctx_dup);
            a.free(done_mod_dup);
            return err;
        };
    }

    /// Hash-route + push, with first-time warn on `NoWorkers`.
    fn routeEvent(
        self: *FetchPool,
        tenant_id: []const u8,
        ev: UpstreamFetchEvent,
    ) !void {
        self.node.enqueueFetchEventForTenant(tenant_id, ev) catch |err| {
            if (err == error.NoWorkers and
                !self.no_inbox_warned.swap(true, .acq_rel))
            {
                std.log.warn(
                    "rove-js fetch_pool: no worker inboxes registered; dropping fetch event tenant={s}",
                    .{tenant_id},
                );
            }
            return err;
        };
    }
};

fn parseMethod(s: []const u8) ?blob_curl.Method {
    if (std.ascii.eqlIgnoreCase(s, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(s, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(s, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(s, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(s, "HEAD")) return .HEAD;
    return null;
}

/// Parse the headers_json object `{"Name":"value", ...}` carried
/// on PendingFetch into a list of allocator-owned `Header`s.
fn parseHeadersJson(
    a: std.mem.Allocator,
    json_src: []const u8,
    out: *std.ArrayListUnmanaged(blob_curl.Header),
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

/// Serialize response headers to `Name: value\r\n` wire format.
/// Returns an allocator-owned slice; empty (length 0) if no
/// headers.
fn serializeHeaders(
    a: std.mem.Allocator,
    headers: []const blob_curl.Header,
) ![]u8 {
    if (headers.len == 0) return try a.alloc(u8, 0);
    var total: usize = 0;
    for (headers) |h| total += h.name.len + 2 + h.value.len + 2;
    var buf = try a.alloc(u8, total);
    errdefer a.free(buf);
    var i: usize = 0;
    for (headers) |h| {
        @memcpy(buf[i..][0..h.name.len], h.name);
        i += h.name.len;
        buf[i] = ':';
        buf[i + 1] = ' ';
        i += 2;
        @memcpy(buf[i..][0..h.value.len], h.value);
        i += h.value.len;
        buf[i] = '\r';
        buf[i + 1] = '\n';
        i += 2;
    }
    return buf;
}
