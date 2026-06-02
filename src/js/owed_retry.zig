//! `owed_retry.zig` — leader-side `_send/owed/` retry sweep.
//!
//! Extracted from `worker.zig`. This is the fire mechanism for the
//! `webhook.send` / `email.send` durability shim: customer JS writes a
//! durable `_send/owed/{id}` marker (an ordinary envelope-0 kv key);
//! the leader's per-worker partitioned sweep walks each owned tenant's
//! `_send/owed/` prefix once per `SEND_SWEEP_INTERVAL_NS`, and for each
//! due marker builds a `PendingFetch` (`buildRetryFetch`) handed to the
//! node's `FetchEngine`. See `docs/effect-reification-plan.md` Phase 5
//! PR-3 + `docs/durability-as-js-shim` notes.
//!
//! Free functions taking `worker: anytype` (the established worker-
//! system pattern); `worker.zig` re-exports the public entry points
//! (`sweepOwedRetries*`, `OWED_PREFIX`, `scanLoneOwedSendId`) so
//! existing callers keep working unchanged.

const std = @import("std");
const kv_mod = @import("raft-kv");
const globals = @import("globals.zig");
const deployment_cache = @import("deployment_cache.zig");

const PendingFetch = globals.PendingFetch;
const TenantSlot = deployment_cache.TenantSlot;
const testing = std.testing;

/// `_send/owed/` kv prefix — the durable marker key the JS-shim
/// `webhook.send` writes (Phase 5 PR-3). Inlined here (and in
/// `worker_dispatch.zig`) after the `send_outbox.zig` module
/// retired with the SendDispatch kernel; the prefix itself stays
/// because the marker key shape didn't change — only the producer
/// (Zig → JS) and the consumer (SendDispatch → `sweepOwedRetries`).
pub const OWED_PREFIX: []const u8 = "_send/owed/";

/// §6.4 binding source: scan a writeset op-slice for exactly one
/// `_send/owed/{id}` put and return the borrowed `{id}` suffix (a slice
/// into the matched op's key). Returns null when zero or more-than-one
/// owed-puts are present — the "ambiguous / deadline-only" case where
/// the resume binds to no send. Allocation-free: the returned slice
/// borrows into `ops`; callers that need it to outlive the writeset
/// dupe it themselves. Shared by the inbound open-hop
/// (`worker_dispatch`) and the cont / bound-fetch repark hops
/// (`worker_drain`); pass a pre-sliced `ops` to scope the scan to one
/// request's contribution (the open-hop cuts at `ws_pre_len`).
pub fn scanLoneOwedSendId(ops: []const kv_mod.WriteSetOp) ?[]const u8 {
    var only: ?[]const u8 = null;
    var n: usize = 0;
    for (ops) |op| switch (op) {
        .put => |p| if (std.mem.startsWith(u8, p.key, OWED_PREFIX)) {
            n += 1;
            only = p.key[OWED_PREFIX.len..];
        },
        .delete => {},
    };
    if (n != 1) return null;
    return only;
}

/// Phase 5 PR-3: per-worker `_send/owed/` retry sweep cadence. Each
/// leader-side worker walks its partition of loaded tenants at most
/// once per this interval; the boot variant (`sweepOwedRetriesOnPromotion`)
/// is unthrottled. The interval matches `CRON_SWEEP_INTERVAL_NS` —
/// retries are second-resolution against `next_at_ns`, which the
/// JS shim's onresult sets with exponential backoff (1s, 2s, 4s, …
/// capped at 60s); a 1Hz sweep wakes due retries within one window
/// of their target time.
pub const SEND_SWEEP_INTERVAL_NS: i64 = 1 * std.time.ns_per_s;

/// Phase 5 PR-3: per-worker partitioned retry sweep — the leader-
/// side mechanism that replaces SendDispatch's leader-thread fire.
///
/// Each leader worker, at most once per `SEND_SWEEP_INTERVAL_NS`,
/// walks every loaded tenant whose `hash(tenant_id) % N_msg_inboxes`
/// matches THIS worker's `msg_inbox_idx`. For each tenant it scans
/// the `_send/owed/` kv prefix and, for entries whose `next_at_ns`
/// has fallen due, constructs a `PendingFetch` with
/// `on_chunk = "__system/webhook_onresult"` (the shim's built-in
/// onresult handler — PR-2b's first baked module) and pushes it
/// onto the node's `fetch_pending` queue.
///
/// The partition matches `enqueueMsgForTenant`'s
/// `hash(tenant_id) % N` routing so the entire retry chain (sweep →
/// fetch → onresult activation → kv ops on the marker) stays on one
/// worker per tenant — no cross-worker coordination, parallel
/// enumeration across the leader's workers.
///
/// Inert until the JS shim flip lands (PR-3 step 2): without the
/// shim, no `_send/owed/{id}` marker is ever written by anything
/// other than legacy `http.send` (which apply.zig still classifies
/// into SendDispatch), so the sweep finds an empty prefix every
/// tick. This is the shape that lets PR-3 step 1 land first as a
/// safety net for the atomic flip in steps 2-4.
pub fn sweepOwedRetries(worker: anytype) void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    if (now_ns - worker.last_send_sweep_ns < SEND_SWEEP_INTERVAL_NS) return;
    worker.last_send_sweep_ns = now_ns;
    sweepOwedRetriesAllPartitioned(worker, now_ns);
}

/// Phase 5 PR-3: unthrottled variant for false→true leadership
/// transition. Runs ONCE across all partitioned tenants for orphan
/// recovery — picks up `_send/owed/{id}` markers a previous leader
/// wrote but never fired (or whose retry window expired during the
/// failover gap). Equivalent to SendDispatch.recover()'s boot-scan,
/// rebuilt as the JS-shim path's recovery primitive.
pub fn sweepOwedRetriesOnPromotion(worker: anytype) void {
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    // Bump the throttle baseline so the regular sweep doesn't
    // immediately re-walk the same prefix on the next tick.
    worker.last_send_sweep_ns = now_ns;
    sweepOwedRetriesAllPartitioned(worker, now_ns);
}

fn sweepOwedRetriesAllPartitioned(worker: anytype, now_ns: i64) void {
    const n_inboxes = blk: {
        worker.node.router.msg_inboxes_mutex.lock();
        defer worker.node.router.msg_inboxes_mutex.unlock();
        break :blk worker.node.router.msg_inboxes.items.len;
    };
    if (n_inboxes == 0) return; // pre-registration cold start

    var it = worker.node.deploy.tenant_files_map.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr.*;
        const inbox_idx = std.hash.Wyhash.hash(0, slot.instance_id) % n_inboxes;
        if (inbox_idx != worker.msg_inbox_idx) continue;
        sweepTenantOwed(worker, slot, now_ns);
    }
}

/// Walk one tenant's `_send/owed/` prefix; for each entry that's
/// due, build a `PendingFetch` aimed at `__system/webhook_onresult`
/// and accumulate it. Pages through the prefix 64 keys at a time so
/// a tenant with thousands of in-flight markers doesn't hold the
/// LMDB txn open for an entire pass — the kvexp prefix cursor is
/// closed between pages.
///
/// PendingFetch construction mirrors the customer-side `http.fetch`
/// path (`bindings/http.zig:buildFetchRow`) but with platform-
/// stamped headers: `X-Rove-Schedule-Id: {owed_id}` for idempotency
/// continuity with the legacy SendDispatch path, and
/// `X-Rove-Schedule-Version: {attempts+1}` so the upstream can
/// distinguish retries of the same logical send.
fn sweepTenantOwed(worker: anytype, slot: *TenantSlot, now_ns: i64) void {
    const a = worker.node.allocator;
    var fetches: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer {
        // Anything that didn't transfer ownership into the node's
        // queue (every item on early-return paths) must be freed.
        for (fetches.items) |*pf| pf.deinit(a);
        fetches.deinit(a);
    }

    const PREFIX = "_send/owed/";
    var cursor_owned: ?[]u8 = null;
    defer if (cursor_owned) |c| a.free(c);

    while (true) {
        const cursor: []const u8 = cursor_owned orelse "";
        var page = slot.app_kv.prefix(PREFIX, cursor, 64) catch |err| {
            std.log.warn(
                "rove-js send sweep ({s}): prefix scan failed: {s}",
                .{ slot.instance_id, @errorName(err) },
            );
            return;
        };
        defer page.deinit();
        if (page.entries.len == 0) break;

        for (page.entries) |entry| {
            // Key shape: "_send/owed/<owed_id>".
            if (entry.key.len <= PREFIX.len) continue;
            const owed_id = entry.key[PREFIX.len..];

            buildRetryFetch(a, slot.instance_id, owed_id, entry.value, now_ns, &fetches) catch |err| switch (err) {
                error.NotDue, error.MalformedMarker => continue, // log inside on Malformed
                else => {
                    std.log.warn(
                        "rove-js send sweep ({s}/{s}): build fetch failed: {s}",
                        .{ slot.instance_id, owed_id, @errorName(err) },
                    );
                    continue;
                },
            };
        }

        if (page.entries.len < 64) break;

        // Advance the cursor to the last key returned. The key
        // bytes are owned by the RangeResult's allocator and freed
        // at `page.deinit` — dup so we keep them across the
        // boundary.
        const last_key = page.entries[page.entries.len - 1].key;
        if (cursor_owned) |c| a.free(c);
        cursor_owned = a.dupe(u8, last_key) catch return;
    }

    if (fetches.items.len == 0) return;
    worker.node.enqueuePendingFetches(fetches.items) catch |err| {
        std.log.warn(
            "rove-js send sweep ({s}): enqueuePendingFetches failed: {s}",
            .{ slot.instance_id, @errorName(err) },
        );
        return; // caller's defer frees the partial list
    };
    // Ownership transferred to the node queue. The defer above
    // walks an empty list (no double-free).
    fetches.clearRetainingCapacity();
}

const RetryFetchError = error{
    NotDue,
    MalformedMarker,
    OutOfMemory,
    WriteFailed,
};

/// Parse one `_send/owed/{id}` marker; if due, append a
/// `PendingFetch` aimed at `__system/webhook_onresult` to `out`. On
/// `NotDue` the entry is silently skipped (the sweep will revisit
/// next pass). On `MalformedMarker` we log + skip — the marker is
/// owned by the JS shim, and a customer-corrupted marker is
/// recoverable only by the shim itself rewriting it.
fn buildRetryFetch(
    a: std.mem.Allocator,
    tenant_id: []const u8,
    owed_id: []const u8,
    marker_json: []const u8,
    now_ns: i64,
    out: *std.ArrayListUnmanaged(globals.PendingFetch),
) RetryFetchError!void {
    var parsed = std.json.parseFromSlice(std.json.Value, a, marker_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        std.log.warn(
            "rove-js send sweep ({s}/{s}): _send/owed/ JSON parse failed; skipping",
            .{ tenant_id, owed_id },
        );
        return error.MalformedMarker;
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            std.log.warn(
                "rove-js send sweep ({s}/{s}): _send/owed/ not a JSON object; skipping",
                .{ tenant_id, owed_id },
            );
            return error.MalformedMarker;
        },
    };

    // `next_at_ns` rides as a BigInt-as-string (the shim's
    // `computeNextAtNs` returns `String(BigInt(...))`). Parse to i64
    // — Date.now()*1e6 fits comfortably until the year 2262, well
    // past the platform's relevance horizon. Treat missing/0 as
    // "due now" (first-attempt fire path; the shim writes the
    // marker, then http.fetch fires immediately, with next_at_ns
    // unset until the first retry).
    const next_at_ns: i64 = switch (obj.get("next_at_ns") orelse std.json.Value{ .null = {} }) {
        .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        .integer => |n| n,
        else => 0,
    };
    if (next_at_ns > now_ns) return error.NotDue;

    const url = jsonStringField(obj, "url") orelse {
        std.log.warn(
            "rove-js send sweep ({s}/{s}): _send/owed/ missing `url`; skipping",
            .{ tenant_id, owed_id },
        );
        return error.MalformedMarker;
    };
    const method = jsonStringField(obj, "method") orelse "POST";
    const body = jsonStringField(obj, "body") orelse "";
    const attempts: u32 = switch (obj.get("attempts") orelse std.json.Value{ .integer = 0 }) {
        .integer => |n| if (n < 0) 0 else @intCast(@min(n, std.math.maxInt(u32))),
        .float => |f| if (f < 0) 0 else @intFromFloat(@min(f, @as(f64, @floatFromInt(std.math.maxInt(u32))))),
        else => 0,
    };

    // Stamp platform headers onto whatever the shim handed us.
    // Stable shape across the legacy SendDispatch + new JS-shim
    // path so upstream services that key on `X-Rove-Schedule-Id`
    // for idempotency keep working.
    const headers_in_json = headersJsonFromMarker(a, obj) catch return error.OutOfMemory;
    defer a.free(headers_in_json);
    const headers_json = try stampPlatformHeaders(a, headers_in_json, owed_id, attempts + 1);
    errdefer a.free(headers_json);

    // ctx for webhook_onresult.mjs: `{id, on_result, context}`.
    // `on_result` is optional (customer didn't pass one →
    // null in the marker). `context` is the customer-supplied
    // payload, opaque to the platform.
    const ctx_json = try buildOnresultCtxJson(a, owed_id, obj);
    errdefer a.free(ctx_json);

    // Fetch id: a stable hex tag per (tenant, owed_id, attempt)
    // so two retries don't collide. Uses sha256 of "RETRY|" +
    // tenant + "|" + owed + "|" + attempts (decimal). 64 hex
    // chars, matches the deterministic-id shape used elsewhere.
    const fetch_id = try retryFetchIdHex(a, tenant_id, owed_id, attempts);
    errdefer a.free(fetch_id);

    const url_dup = try a.dupe(u8, url);
    errdefer a.free(url_dup);
    const method_dup = try a.dupe(u8, method);
    errdefer a.free(method_dup);
    const body_dup = try a.dupe(u8, body);
    errdefer a.free(body_dup);
    const on_chunk_dup = try a.dupe(u8, "__system/webhook_onresult");
    errdefer a.free(on_chunk_dup);
    const tenant_dup = try a.dupe(u8, tenant_id);
    errdefer a.free(tenant_dup);
    // `docs/cross-worker-held-state-plan.md` Phase 2B: retry-sweep
    // PendingFetches are webhook.send callbacks — same routing
    // contract as the JS-shim's direct fetch (carry the owed_id
    // as bound_send_id so chunks route to the cont's owning
    // worker via bound_send_owners).
    const bound_send_id_dup = try a.dupe(u8, owed_id);
    errdefer a.free(bound_send_id_dup);

    try out.ensureUnusedCapacity(a, 1);
    out.appendAssumeCapacity(.{
        .tenant_id = tenant_dup,
        .id = fetch_id,
        .url = url_dup,
        .method = method_dup,
        .headers_json = headers_json,
        .body = body_dup,
        .timeout_ms = 30_000,
        .on_chunk_module = on_chunk_dup,
        .ctx_json = ctx_json,
        .stream = false,
        .max_response_chunk_bytes = 256 * 1024,
        .max_total_response_bytes = 50 * 1024 * 1024,
        .bound_send_id = bound_send_id_dup,
    });
}

fn jsonStringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (obj.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Serialize the marker's `headers` object back to a JSON string
/// (the wire format `FetchPool` consumes). Missing/non-object
/// `headers` → `"{}"` — the platform always stamps `X-Rove-*`
/// headers on top in `stampPlatformHeaders`.
fn headersJsonFromMarker(a: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    const hv = obj.get("headers") orelse return a.dupe(u8, "{}");
    if (hv != .object) return a.dupe(u8, "{}");
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    {
        var aw = std.Io.Writer.Allocating.fromArrayList(a, &buf);
        defer buf = aw.toArrayList();
        try std.json.Stringify.value(hv, .{}, &aw.writer);
    }
    return try buf.toOwnedSlice(a);
}

/// Append `X-Rove-Schedule-Id` + `X-Rove-Schedule-Version` to
/// `headers_in_json`. Tolerates a leading whitespace/closing-brace
/// shape — the marker's `headers` round-trip through `std.json` so
/// the output is always `{...}` or `{}`.
fn stampPlatformHeaders(
    a: std.mem.Allocator,
    headers_in_json: []const u8,
    schedule_id: []const u8,
    version: u32,
) ![]u8 {
    // Strip trailing `}`, splice in the platform fields, re-close.
    var trimmed = std.mem.trim(u8, headers_in_json, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
        // Malformed — fall back to a fresh object with only the
        // platform stamps.
        return std.fmt.allocPrint(
            a,
            "{{\"X-Rove-Schedule-Id\":\"{s}\",\"X-Rove-Schedule-Version\":\"{d}\"}}",
            .{ schedule_id, version },
        );
    }
    // `{...}` → inner = `...`. If inner is empty, no leading comma.
    const inner = trimmed[1 .. trimmed.len - 1];
    const inner_trimmed = std.mem.trim(u8, inner, " \t\r\n");
    const sep: []const u8 = if (inner_trimmed.len == 0) "" else ",";
    return std.fmt.allocPrint(
        a,
        "{{{s}{s}\"X-Rove-Schedule-Id\":\"{s}\",\"X-Rove-Schedule-Version\":\"{d}\"}}",
        .{ inner, sep, schedule_id, version },
    );
}

/// Build the ctx JSON passed to `__system/webhook_onresult` — the
/// shape it expects (`webhook_onresult.mjs`): `{id, on_result,
/// context}`. `on_result` defaults to the JSON literal `null` when
/// the marker omits it; `context` defaults to `null` likewise.
fn buildOnresultCtxJson(
    a: std.mem.Allocator,
    owed_id: []const u8,
    marker: std.json.ObjectMap,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    {
        var aw = std.Io.Writer.Allocating.fromArrayList(a, &buf);
        defer buf = aw.toArrayList();
        const w = &aw.writer;

        try w.writeAll("{\"id\":");
        try writeJsonString(w, owed_id);
        try w.writeAll(",\"on_result\":");
        const on_result_v = marker.get("on_result") orelse std.json.Value{ .null = {} };
        try std.json.Stringify.value(on_result_v, .{}, w);
        try w.writeAll(",\"context\":");
        const context_v = marker.get("context") orelse std.json.Value{ .null = {} };
        try std.json.Stringify.value(context_v, .{}, w);
        try w.writeAll("}");
    }
    return try buf.toOwnedSlice(a);
}

/// JSON string-escape (RFC 8259 minimal). Mirrors apply.zig's
/// private helper but inlined here so the sweep doesn't reach
/// across modules for a five-line escape routine.
fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |b| switch (b) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{b}),
        else => try writer.writeByte(b),
    };
    try writer.writeByte('"');
}

/// Deterministic id-per-attempt: sha256("RETRY|" || tenant || "|"
/// || owed_id || "|" || attempts-decimal). 64 lowercase hex.
/// The sweep doesn't need replay-stability across runs (it's not
/// taped — only the resulting onresult handler activation is) but
/// per-attempt determinism keeps log lines greppable and inflight-
/// set collisions impossible.
fn retryFetchIdHex(
    a: std.mem.Allocator,
    tenant_id: []const u8,
    owed_id: []const u8,
    attempts: u32,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("RETRY|");
    hasher.update(tenant_id);
    hasher.update("|");
    hasher.update(owed_id);
    hasher.update("|");
    var att_buf: [11]u8 = undefined;
    const att_str = std.fmt.bufPrint(&att_buf, "{d}", .{attempts}) catch unreachable;
    hasher.update(att_str);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return a.dupe(u8, &hex);
}

test "buildRetryFetch: due marker → PendingFetch with stamped headers + ctx" {
    const a = testing.allocator;
    const marker =
        \\{"url":"https://hooks.example.com/webhook","method":"POST",
        \\"body":"{\"event\":\"order.paid\"}","headers":{"Content-Type":"application/json"},
        \\"attempts":0,"next_at_ns":"0","on_result":"hooks/onResult","context":{"tag":"ord-1"}}
    ;
    var out: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer {
        for (out.items) |*pf| pf.deinit(a);
        out.deinit(a);
    }
    try buildRetryFetch(a, "tenant-acme", "wh-deadbeef", marker, 1_000_000_000_000_000_000, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    const pf = &out.items[0];
    try testing.expectEqualStrings("tenant-acme", pf.tenant_id);
    try testing.expectEqualStrings("https://hooks.example.com/webhook", pf.url);
    try testing.expectEqualStrings("POST", pf.method);
    try testing.expectEqualStrings("__system/webhook_onresult", pf.on_chunk_module);
    try testing.expectEqual(false, pf.stream);
    // Stamped headers — both X-Rove-* fields and the original
    // Content-Type round-trip through.
    try testing.expect(std.mem.indexOf(u8, pf.headers_json, "\"X-Rove-Schedule-Id\":\"wh-deadbeef\"") != null);
    try testing.expect(std.mem.indexOf(u8, pf.headers_json, "\"X-Rove-Schedule-Version\":\"1\"") != null);
    try testing.expect(std.mem.indexOf(u8, pf.headers_json, "\"Content-Type\":\"application/json\"") != null);
    // ctx shape: {id, on_result, context} — webhook_onresult.mjs reads
    // these three keys.
    try testing.expect(std.mem.indexOf(u8, pf.ctx_json, "\"id\":\"wh-deadbeef\"") != null);
    try testing.expect(std.mem.indexOf(u8, pf.ctx_json, "\"on_result\":\"hooks/onResult\"") != null);
    try testing.expect(std.mem.indexOf(u8, pf.ctx_json, "\"context\":") != null);
    try testing.expect(std.mem.indexOf(u8, pf.ctx_json, "\"tag\":\"ord-1\"") != null);
}

test "buildRetryFetch: not-due marker → error.NotDue, no entry appended" {
    const a = testing.allocator;
    const marker =
        \\{"url":"https://x.test/","method":"POST","body":"","headers":{},
        \\"attempts":2,"next_at_ns":"2000000000000000000"}
    ;
    var out: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer out.deinit(a);
    const err = buildRetryFetch(a, "t", "wh", marker, 1_000_000_000_000_000_000, &out);
    try testing.expectError(error.NotDue, err);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "buildRetryFetch: malformed JSON → error.MalformedMarker" {
    const a = testing.allocator;
    var out: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer out.deinit(a);
    const err = buildRetryFetch(a, "t", "wh", "not-json{{{", 1_000_000_000_000_000_000, &out);
    try testing.expectError(error.MalformedMarker, err);
}

test "buildRetryFetch: missing url field → error.MalformedMarker" {
    const a = testing.allocator;
    const marker =
        \\{"method":"POST","body":"","attempts":0,"next_at_ns":"0"}
    ;
    var out: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer out.deinit(a);
    const err = buildRetryFetch(a, "t", "wh", marker, 1_000_000_000_000_000_000, &out);
    try testing.expectError(error.MalformedMarker, err);
}

test "buildRetryFetch: attempts increment bumps X-Rove-Schedule-Version" {
    const a = testing.allocator;
    const marker =
        \\{"url":"https://x.test/","method":"POST","body":"","headers":{},
        \\"attempts":3,"next_at_ns":"0"}
    ;
    var out: std.ArrayListUnmanaged(globals.PendingFetch) = .empty;
    defer {
        for (out.items) |*pf| pf.deinit(a);
        out.deinit(a);
    }
    try buildRetryFetch(a, "t", "wh-id", marker, 1_000_000_000_000_000_000, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    // attempts=3 in marker → fire stamps version=attempts+1=4.
    try testing.expect(std.mem.indexOf(u8, out.items[0].headers_json, "\"X-Rove-Schedule-Version\":\"4\"") != null);
}

test "retryFetchIdHex: stable per attempt, distinct across attempts" {
    const a = testing.allocator;
    const id_a = try retryFetchIdHex(a, "tenant-x", "wh-1", 0);
    defer a.free(id_a);
    const id_a_again = try retryFetchIdHex(a, "tenant-x", "wh-1", 0);
    defer a.free(id_a_again);
    const id_b = try retryFetchIdHex(a, "tenant-x", "wh-1", 1);
    defer a.free(id_b);
    const id_c = try retryFetchIdHex(a, "tenant-x", "wh-2", 0);
    defer a.free(id_c);
    try testing.expectEqualStrings(id_a, id_a_again); // determinism
    try testing.expect(!std.mem.eql(u8, id_a, id_b)); // attempts differ
    try testing.expect(!std.mem.eql(u8, id_a, id_c)); // owed-id differs
    try testing.expectEqual(@as(usize, 64), id_a.len); // sha256 hex
}
