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
//! variable, drain entries, and fire libcurl. Each upstream response
//! is re-chunked into `max_response_chunk_bytes` units, pushed one
//! `UpstreamFetchEvent` per chunk + one terminal event to the per-
//! worker `FetchChunkInbox` via hash-routed
//! `enqueueFetchEventForTenant`.
//!
//! ## Streaming transport
//!
//! The libcurl call is `Easy.requestStreaming` — a
//! `CURLOPT_WRITEFUNCTION`-driven transfer that delivers the
//! response body incrementally as it arrives. `onBody` re-chunks
//! each writeback and routes a chunk event AS THE BYTES ARRIVE, so
//! an SSE / LLM-token upstream drives the customer's `on_chunk` /
//! pipe in real time instead of stalling until the connection
//! closes (or `timeout_ms` fires). Small responses still produce
//! the same chunk sequence — they just arrive in fewer writebacks;
//! the re-chunker normalizes regardless of writeback boundaries.

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

    /// Execute one fetch, streaming the upstream response. libcurl
    /// delivers the body incrementally via `requestStreaming`'s
    /// sink; `onBody` re-chunks each writeback into
    /// `max_response_chunk_bytes` units + routes a chunk event per
    /// unit AS THE BYTES ARRIVE — so an SSE / LLM-token upstream
    /// drives the customer's `on_chunk` / pipe in real time instead
    /// of waiting for the connection to close. Errors returned here
    /// are the pool's own (alloc, transport setup); an upstream
    /// `!2xx` status surfaces as a terminal with `terminal_ok=false`.
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

        var state: StreamState = .{
            .pool = self,
            .pf = pf,
            .allocator = a,
            // buildFetchRow guarantees ≥ 1; @max is belt-and-braces.
            .max_chunk = @max(@as(usize, pf.max_response_chunk_bytes), 1),
            .max_total = pf.max_total_response_bytes,
        };
        defer state.deinit();

        const result = easy.requestStreaming(a, req, .{
            .ctx = @ptrCast(&state),
            .on_body = onBody,
            .on_header = onHeader,
        }) catch |err| {
            // Pre-perform setup failure (OOM building the request).
            // No chunks emitted; fire a failure terminal.
            try self.pushTerminal(pf, 0, false);
            return err;
        };

        // No flush step — `onBody` emits every writeback as it
        // arrives, so nothing is left buffered when perform returns.

        // Terminal `ok`: the transfer must have completed cleanly
        // (or stopped exactly at the size cap — a deliberate
        // truncation, NOT a failure), we hit no internal alloc /
        // route error, and the upstream returned 2xx.
        const ok = result.perform_ok and !state.failed and
            result.status >= 200 and result.status < 300;
        try self.pushTerminal(pf, result.status, ok);
    }

    /// Push the terminal event for `pf`'s chain — `kind = .pipe_done`
    /// for a Pattern B (`pipe_to`) fetch, `kind = .end` for Pattern
    /// A. The worker branches on `kind` to pick the terminal path.
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
        const pipe_corr_dup = try a.dupe(u8, pf.pipe_correlation_id);
        errdefer a.free(pipe_corr_dup);

        const ev: UpstreamFetchEvent = .{
            .kind = if (pf.pipe_to_held) .pipe_done else .end,
            .fetch_id = id_dup,
            .tenant_id = tid_dup,
            .ctx_json = ctx_dup,
            .on_done_module = done_mod_dup,
            .pipe_to_held = pf.pipe_to_held,
            .pipe_correlation_id = pipe_corr_dup,
            .terminal_status = status,
            .terminal_ok = ok,
        };
        self.routeEvent(pf.tenant_id, ev) catch |err| {
            a.free(id_dup);
            a.free(tid_dup);
            a.free(ctx_dup);
            a.free(done_mod_dup);
            a.free(pipe_corr_dup);
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
// ── Streaming sink: re-chunking + per-chunk event emission ─────────

/// Per-fetch state threaded through `requestStreaming`'s sink
/// callbacks. Lives on `runOne`'s stack — `requestStreaming` is
/// synchronous, so `onBody` / `onHeader` (which run inside it) see
/// a live pointer for the whole transfer.
const StreamState = struct {
    pool: *FetchPool,
    pf: *const PendingFetch,
    allocator: std.mem.Allocator,
    /// Per-chunk size *ceiling*. NOT a batching target — each
    /// libcurl writeback is emitted the moment it arrives (a slow
    /// SSE drip ships each frame immediately, no buffering); a
    /// writeback larger than `max_chunk` is split into ≤ `max_chunk`
    /// pieces so one chunk never blows the handler / tape budget.
    max_chunk: usize,
    /// Caller's overall response-size cap (`buildFetchRow`
    /// guarantees ≥ 1). Once `total` reaches it the transfer aborts.
    max_total: u64,
    /// Accumulated raw response-header lines (libcurl delivers them
    /// pre-formatted as `Name: value\r\n`). Shipped on seq 0's
    /// `fetch_headers`.
    headers: std.ArrayListUnmanaged(u8) = .empty,
    seq: u32 = 0,
    /// Cumulative bytes emitted in prior chunks — the next chunk's
    /// `byte_offset`.
    byte_offset: u64 = 0,
    /// Cumulative bytes accepted from libcurl (for the max_total cap).
    total: u64 = 0,
    /// Our own failure (alloc / route) — aborts the transfer and
    /// makes the terminal `ok = false`.
    failed: bool = false,
    /// Hit `max_total` — aborts the transfer, but the terminal
    /// still reports the upstream status (a deliberate truncation,
    /// not a failure).
    capped: bool = false,

    fn deinit(self: *StreamState) void {
        self.headers.deinit(self.allocator);
    }

    /// Build + route one chunk event for `bytes` (borrowed —
    /// dup'd into the event). Headers ride seq 0 only. Returns
    /// false on alloc / route failure (caller sets `failed`).
    fn emitChunk(self: *StreamState, bytes: []const u8) bool {
        const a = self.allocator;
        const headers_blob: ?[]const u8 = if (self.seq == 0 and self.headers.items.len > 0)
            self.headers.items
        else
            null;
        const ev = buildChunkEvent(
            a,
            self.pf,
            self.seq,
            self.byte_offset,
            bytes,
            headers_blob,
        ) catch return false;
        self.pool.routeEvent(self.pf.tenant_id, ev) catch |err| {
            // routeEvent didn't take ownership — free the event's
            // slices via the component deinit + drop.
            var e = ev;
            UpstreamFetchEvent.deinit(a, (&e)[0..1]);
            std.log.warn(
                "rove-js fetch_pool: route chunk seq={d}: {s}",
                .{ self.seq, @errorName(err) },
            );
            return false;
        };
        self.seq += 1;
        self.byte_offset += bytes.len;
        return true;
    }
};

/// Build a fully-owned `.chunk` `UpstreamFetchEvent`. On any dup
/// failure the `errdefer` deinits the partially-built event —
/// each component field is independently freed (empty fields
/// no-op), so there is no leak and no double-free.
fn buildChunkEvent(
    a: std.mem.Allocator,
    pf: *const PendingFetch,
    seq: u32,
    byte_offset: u64,
    bytes: []const u8,
    headers_blob: ?[]const u8,
) !UpstreamFetchEvent {
    var ev: UpstreamFetchEvent = .{
        .kind = .chunk,
        .seq = seq,
        .byte_offset = byte_offset,
        .pipe_to_held = pf.pipe_to_held,
    };
    errdefer UpstreamFetchEvent.deinit(a, (&ev)[0..1]);
    ev.fetch_id = try a.dupe(u8, pf.id);
    ev.tenant_id = try a.dupe(u8, pf.tenant_id);
    ev.ctx_json = try a.dupe(u8, pf.ctx_json);
    ev.on_chunk_module = try a.dupe(u8, pf.on_chunk_module);
    ev.pipe_correlation_id = try a.dupe(u8, pf.pipe_correlation_id);
    ev.bytes = try a.dupe(u8, bytes);
    if (headers_blob) |hb| {
        if (hb.len > 0) ev.fetch_headers = try a.dupe(u8, hb);
    }
    return ev;
}

/// `requestStreaming` body sink — emit each writeback immediately
/// (split if it exceeds `max_chunk`). Runs on the fetch-pool thread
/// inside `curl_easy_perform`. No buffering: a writeback that
/// arrives IS a chunk (or a few, if oversized) the moment it lands.
fn onBody(chunk: []const u8, ctx: *anyopaque) bool {
    const s: *StreamState = @ptrCast(@alignCast(ctx));
    if (s.failed or s.capped) return false;
    if (chunk.len == 0) return true;

    // Enforce the overall response-size cap. `max_total` is always
    // ≥ 1 and `total` strictly < `max_total` here (we return early
    // once `capped`), so `remaining` ≥ 1.
    var take = chunk;
    const remaining: usize = @intCast(s.max_total - s.total);
    if (chunk.len >= remaining) {
        take = chunk[0..remaining];
        s.capped = true;
    }
    s.total += take.len;

    // Emit `take` now, split into ≤ `max_chunk` pieces.
    var off: usize = 0;
    while (off < take.len) {
        const end = @min(off + s.max_chunk, take.len);
        if (!s.emitChunk(take[off..end])) {
            s.failed = true;
            return false;
        }
        off = end;
    }
    // A capping writeback was the last one we accept.
    return !s.capped;
}

/// `requestStreaming` header sink — accumulate the raw header
/// block (`Name: value\r\n` lines, plus the status line + blank
/// terminator; the JS-side parser skips colon-less lines).
fn onHeader(line: []const u8, ctx: *anyopaque) void {
    const s: *StreamState = @ptrCast(@alignCast(ctx));
    if (s.failed) return;
    s.headers.appendSlice(s.allocator, line) catch {
        s.failed = true;
    };
}
