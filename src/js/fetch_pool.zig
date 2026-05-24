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
//! `UpstreamFetchEvent` per chunk + one terminal event to the
//! destination worker's unified `effect.MsgInbox`
//! (effect-reification Phase 2E) via hash-routed
//! `enqueueFetchEventForTenant`.
//!
//! ## Streaming transport
//!
//! The libcurl call is `Easy.requestStreaming` — a
//! `CURLOPT_WRITEFUNCTION`-driven transfer that delivers the
//! response body incrementally as it arrives.
//!
//! Two modes (Phase 5 PR-1):
//!
//! - `stream: false` (default) — the first writeback is captured
//!   (up to `max_response_chunk_bytes`); any further bytes set
//!   `body_truncated` and abort the transfer (writeback returns
//!   0). One `on_chunk` event fires with `final: true`. Predictable
//!   tape cost; the common shape for webhooks / one-shot APIs.
//!
//! - `stream: true` — `onBody` re-chunks each writeback and routes
//!   one event per chunk AS THE BYTES ARRIVE, so an SSE / LLM-token
//!   upstream drives the customer's `on_chunk` in real time. The
//!   LAST event carries `final: true` + terminal fields.
//!
//! Both modes always emit at least one `final: true` event — even
//! on a 204 / transport error / cap-only abort the customer sees
//! one callback with empty `bytes` and `ok: false` (transport
//! errors) or the upstream status.

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
    /// sink. Two modes (Phase 5 PR-1):
    ///
    /// - `stream: false` — `onBody` accepts up to
    ///   `max_response_chunk_bytes` of body; any further bytes set
    ///   `body_truncated` and the writeback returns 0 to abort the
    ///   transfer. Exactly one event fires (with `final: true`).
    /// - `stream: true` — `onBody` routes one event per writeback,
    ///   each up to `max_response_chunk_bytes`. `max_total_response_bytes`
    ///   caps the total body; cap-overflow sets `body_truncated`.
    ///   The LAST event carries `final: true` + terminal fields.
    ///
    /// Always emits at least one `final: true` event — empty body,
    /// transport error, cap-only abort all surface as one
    /// final-event callback (with empty `bytes` if no body arrived).
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
            .stream_mode = pf.stream,
            // buildFetchRow guarantees ≥ 1; @max is belt-and-braces.
            .max_chunk = @max(@as(usize, pf.max_response_chunk_bytes), 1),
            .max_total = pf.max_total_response_bytes,
            // `stream: false` overrides the total cap with the
            // chunk cap (single-chunk delivery; any overflow
            // truncates).
            .effective_total_cap = if (pf.stream)
                pf.max_total_response_bytes
            else
                @as(u64, @max(@as(usize, pf.max_response_chunk_bytes), 1)),
        };
        defer state.deinit();

        const result = easy.requestStreaming(a, req, .{
            .ctx = @ptrCast(&state),
            .on_body = onBody,
            .on_header = onHeader,
        }) catch |err| {
            // Pre-perform setup failure (OOM building the request).
            // No chunks emitted; fire a single final event with
            // empty bytes + ok=false so the customer's handler
            // still runs.
            try self.pushFinalEmpty(pf, &state, 0, false);
            return err;
        };

        // Terminal `ok`: transport-only — libcurl completed cleanly
        // (perform_ok) AND we hit no internal alloc / route error.
        // Cap-only truncation is NOT a failure (the customer
        // explicitly bounded the response and got what fit). HTTP
        // status interpretation is left to the JS layer.
        const transport_ok = result.perform_ok and !state.failed;

        if (!pf.stream) {
            // Phase 5 PR-1 contract: ONE event with `final: true` +
            // the body + terminal fields. `onBody` buffered the
            // body into `state.body_buf`; emit it now as the sole
            // event the customer sees.
            try self.pushFinalWithBody(pf, &state, result.status, transport_ok);
            return;
        }

        // Stream mode: `onBody` already emitted per-writeback events
        // with `final: false`. Stamp the terminal as a separate
        // empty-bytes event with `final: true` so the customer can
        // distinguish "more frames coming" from "transfer complete".
        // If the upstream returned 0 bytes (or transport failed
        // pre-body), this is the only event the customer sees.
        try self.pushFinalEmpty(pf, &state, result.status, transport_ok);
    }

    /// Fire one final event with no body bytes, carrying the
    /// terminal `status` / `ok` / `body_truncated` fields. Used
    /// for the canonical "fetch complete" signal — fires AFTER
    /// any body events and is always the customer's last
    /// activation for this fetch.
    fn pushFinalEmpty(
        self: *FetchPool,
        pf: *PendingFetch,
        state: *StreamState,
        status: u16,
        ok: bool,
    ) !void {
        const a = self.allocator;
        // Build a zero-byte chunk event at the next seq, with
        // final flag set. Reuses buildChunkEvent for ownership
        // discipline.
        var ev = buildChunkEvent(a, pf, state.emitted_seq, state.byte_offset, &.{}, null) catch |err| return err;
        ev.final = true;
        ev.terminal_status = status;
        ev.terminal_ok = ok;
        ev.body_truncated = state.capped;
        self.routeEvent(pf.tenant_id, ev) catch |err| {
            var e = ev;
            UpstreamFetchEvent.deinitItem(&e, a);
            return err;
        };
        state.emitted_seq += 1;
    }

    /// Phase 5 PR-1 contract: in `stream: false` mode, fire ONE
    /// event carrying the body bytes + `final: true` + terminal
    /// fields. Replaces the prior two-event split (body event with
    /// `final: false` THEN empty event with `final: true`) — that
    /// shape broke webhook_onresult, which only processes the
    /// `final: true` event and so saw the body as empty.
    fn pushFinalWithBody(
        self: *FetchPool,
        pf: *PendingFetch,
        state: *StreamState,
        status: u16,
        ok: bool,
    ) !void {
        const a = self.allocator;
        var ev = buildChunkEvent(
            a,
            pf,
            state.emitted_seq,
            state.byte_offset,
            state.body_buf.items,
            null,
        ) catch |err| return err;
        // Headers ride on seq 0 (no prior events in single-chunk
        // mode). Parse from the accumulated wire-format buffer.
        if (state.emitted_seq == 0 and state.headers.items.len > 0) {
            ev.fetch_headers = parseHeadersWireToJson(a, state.headers.items) catch null;
        }
        ev.final = true;
        ev.terminal_status = status;
        ev.terminal_ok = ok;
        ev.body_truncated = state.capped;
        self.routeEvent(pf.tenant_id, ev) catch |err| {
            var e = ev;
            UpstreamFetchEvent.deinitItem(&e, a);
            return err;
        };
        state.emitted_seq += 1;
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

// ── Streaming sink: re-chunking + per-chunk event emission ─────────

/// Per-fetch state threaded through `requestStreaming`'s sink
/// callbacks. Lives on `runOne`'s stack — `requestStreaming` is
/// synchronous, so `onBody` / `onHeader` (which run inside it) see
/// a live pointer for the whole transfer.
const StreamState = struct {
    pool: *FetchPool,
    pf: *const PendingFetch,
    allocator: std.mem.Allocator,
    /// `true` ⇔ caller set `stream: true`. False = single-chunk
    /// mode: first writeback is captured; further bytes set
    /// `capped` and abort the transfer.
    stream_mode: bool,
    /// Per-chunk size *ceiling*. In stream mode each writeback is
    /// emitted as it arrives (split if oversized) so a slow SSE
    /// drip ships each frame immediately. In single-chunk mode
    /// this caps the one event's body size.
    max_chunk: usize,
    /// Caller's overall response-size cap from PendingFetch
    /// (`buildFetchRow` guarantees ≥ 1). Distinct from
    /// `effective_total_cap`: in single-chunk mode the effective
    /// cap is `max_chunk`, not this.
    max_total: u64,
    /// The cap that ACTUALLY bounds `total`: `max_total` in stream
    /// mode, `max_chunk` in single-chunk mode. Once `total` reaches
    /// it the transfer aborts.
    effective_total_cap: u64,
    /// Accumulated raw response-header lines (libcurl delivers them
    /// pre-formatted as `Name: value\r\n`). Parsed into a JSON
    /// object on the seq-0 emit.
    headers: std.ArrayListUnmanaged(u8) = .empty,
    /// Next event's seq. Bumped on every routed event (including
    /// the final-empty event from `pushFinalEmpty`). At the end of
    /// runOne this is the total count of events emitted.
    emitted_seq: u32 = 0,
    /// Cumulative bytes emitted in prior events — the next event's
    /// `byte_offset`.
    byte_offset: u64 = 0,
    /// Cumulative bytes accepted from libcurl (for the cap check).
    total: u64 = 0,
    /// Our own failure (alloc / route) — aborts the transfer and
    /// makes the terminal `ok = false`.
    failed: bool = false,
    /// Hit `effective_total_cap` — aborts the transfer, but the
    /// terminal still reports the upstream status (a deliberate
    /// truncation, not a failure). Surfaces as `body_truncated`.
    capped: bool = false,
    /// Phase 5 PR-1 contract: in `stream: false` (single-chunk)
    /// mode the body is buffered here and emitted as ONE final
    /// event with `final: true` + the body bytes + terminal
    /// fields. Lifts the body off the prior "body event + empty
    /// final event" two-event split that broke webhook_onresult's
    /// `final-event-carries-the-body` contract. In `stream: true`
    /// mode this stays empty — events emit per writeback.
    body_buf: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *StreamState) void {
        self.headers.deinit(self.allocator);
        self.body_buf.deinit(self.allocator);
    }

    /// Build + route one chunk event for `bytes` (borrowed —
    /// dup'd into the event). Headers (parsed JSON) ride seq 0
    /// only. Returns false on alloc / route failure (caller sets
    /// `failed`).
    fn emitChunk(self: *StreamState, bytes: []const u8) bool {
        const a = self.allocator;
        // Parse the wire-format header block into a JSON object
        // on seq 0; null on subsequent events (no re-ship).
        var headers_json: ?[]u8 = null;
        if (self.emitted_seq == 0 and self.headers.items.len > 0) {
            headers_json = parseHeadersWireToJson(a, self.headers.items) catch null;
        }
        const ev = buildChunkEvent(
            a,
            self.pf,
            self.emitted_seq,
            self.byte_offset,
            bytes,
            headers_json,
        ) catch {
            if (headers_json) |hj| a.free(hj);
            return false;
        };
        self.pool.routeEvent(self.pf.tenant_id, ev) catch |err| {
            // routeEvent didn't take ownership — free the event's
            // slices via the component deinit + drop.
            var e = ev;
            UpstreamFetchEvent.deinitItem(&e, a);
            std.log.warn(
                "rove-js fetch_pool: route chunk seq={d}: {s}",
                .{ self.emitted_seq, @errorName(err) },
            );
            return false;
        };
        self.emitted_seq += 1;
        self.byte_offset += bytes.len;
        return true;
    }
};

/// Build a fully-owned `UpstreamFetchEvent` (chunk-with-optional-final
/// shape post-PR-1; caller stamps `final` / terminal fields if this
/// is the final event). On any dup failure the `errdefer` deinits
/// the partially-built event — each field is independently freed
/// (empty fields no-op), so there is no leak and no double-free.
///
/// `headers_json` (if non-null) is taken by ownership — caller has
/// already allocated it and the event-free path frees it. Pass null
/// for non-seq-0 events.
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
    };
    errdefer UpstreamFetchEvent.deinit(a, (&ev)[0..1]);
    // Take headers ownership FIRST so a later dup failure frees it
    // via the errdefer.
    if (headers_json) |hj| ev.fetch_headers = hj;
    ev.fetch_id = try a.dupe(u8, pf.id);
    ev.tenant_id = try a.dupe(u8, pf.tenant_id);
    ev.ctx_json = try a.dupe(u8, pf.ctx_json);
    ev.on_chunk_module = try a.dupe(u8, pf.on_chunk_module);
    ev.bytes = try a.dupe(u8, bytes);
    return ev;
}

/// Parse libcurl's accumulated `Name: value\r\n…` block into a JSON
/// object `{"name":"value", ...}`. Last-wins on repeated headers
/// (HTTP/1.1 §3.2.2 allows it). Header names are lower-cased so the
/// customer sees a consistent map regardless of upstream casing.
/// Returns an allocator-owned UTF-8 JSON slice.
fn parseHeadersWireToJson(a: std.mem.Allocator, wire: []const u8) ![]u8 {
    var obj: std.json.ObjectMap = .init(a);
    defer {
        // The values were dupe'd via Value.string — std.json's
        // ObjectMap doesn't free its values on deinit; release via
        // the parsed JSON's allocator.
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
        // Lower-case for stable customer-side lookup.
        const lname = try a.alloc(u8, name.len);
        errdefer a.free(lname);
        for (name, 0..) |ch, i| lname[i] = std.ascii.toLower(ch);
        const lval = try a.dupe(u8, value);
        errdefer a.free(lval);
        // putMove transfers ownership of both key + value
        // strings into the map (last-wins replaces both).
        if (try obj.fetchPut(lname, .{ .string = lval })) |prev| {
            a.free(@constCast(prev.key));
            a.free(@constCast(prev.value.string));
        }
    }
    const val: std.json.Value = .{ .object = obj };
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    {
        // Inner scope so the writer's internal buffer is synced
        // back into `buf` BEFORE we read `buf.items`.
        var aw = std.Io.Writer.Allocating.fromArrayList(a, &buf);
        defer buf = aw.toArrayList();
        try std.json.Stringify.value(val, .{}, &aw.writer);
    }
    return try buf.toOwnedSlice(a);
}

/// `requestStreaming` body sink — emit writebacks per the stream
/// mode. Runs on the fetch-pool thread inside `curl_easy_perform`.
///
/// - `stream: true` — each writeback is emitted as it arrives
///   (split if it exceeds `max_chunk`). No buffering: a slow SSE
///   drip ships each frame immediately.
/// - `stream: false` — buffer up to `max_chunk` total bytes into
///   a single event, returning 0 from the writeback when full so
///   libcurl aborts the transfer.
fn onBody(chunk: []const u8, ctx: *anyopaque) bool {
    const s: *StreamState = @ptrCast(@alignCast(ctx));
    if (s.failed or s.capped) return false;
    if (chunk.len == 0) return true;

    // Enforce the effective response-size cap. `effective_total_cap`
    // is always ≥ 1 and `total` strictly < `effective_total_cap`
    // here (we return early once `capped`), so `remaining` ≥ 1.
    var take = chunk;
    const remaining: usize = @intCast(s.effective_total_cap - s.total);
    if (chunk.len >= remaining) {
        take = chunk[0..remaining];
        s.capped = true;
    }
    s.total += take.len;

    if (s.stream_mode) {
        // Stream mode: emit `take` now, split into ≤ `max_chunk`
        // pieces. The final event is the `pushFinalEmpty` after
        // runOne; intermediates here have `final: false`.
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
        // Phase 5 PR-1 contract: ONE event for the whole fetch
        // (final=true, bytes=body, terminal status carried). Buffer
        // here; `runOne` consolidates after `requestStreaming`
        // returns. `effective_total_cap = max_chunk` so the buffer
        // stays bounded by `max_response_chunk_bytes`.
        s.body_buf.appendSlice(s.allocator, take) catch {
            s.failed = true;
            return false;
        };
        return !s.capped;
    }
}

/// `requestStreaming` header sink — accumulate the raw header
/// block (`Name: value\r\n` lines, plus the status line + blank
/// terminator; the parser skips colon-less lines).
fn onHeader(line: []const u8, ctx: *anyopaque) void {
    const s: *StreamState = @ptrCast(@alignCast(ctx));
    if (s.failed) return;
    s.headers.appendSlice(s.allocator, line) catch {
        s.failed = true;
    };
}
