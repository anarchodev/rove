//! Request-object construction — the `request.*` surface split out of
//! globals.zig so that file can stay the binding-assembly root.
//!
//! `installRequest` builds the per-request `request`/`response` globals on
//! every activation (method/path/body plus lazy getters for headers, bytes,
//! cookies, and client IP); the read-taping (`recordRequestRead`) that feeds
//! deterministic replay lives here too. globals.zig re-exports
//! `installRequest` so the public API and its dispatcher.zig caller are
//! unchanged; the shared `DispatchState`/`getState`/`c` come back from
//! globals.zig via the `globals_mod` alias (the two files import each other,
//! the same mutual-import shape used elsewhere in the worker).

const std = @import("std");
const qjs = @import("rove-qjs");
const rove = @import("rove");
const h2 = @import("rove-h2");
const log_mod = @import("rove-log");
const tape_mod = @import("rove-tape");
const reserved = @import("reserved.zig");
const reserved_headers = @import("reserved_headers.zig");

const c = qjs.c;

const globals_mod = @import("globals.zig");
const DispatchState = globals_mod.DispatchState;
const getState = globals_mod.getState;
const js_exception = globals_mod.js_exception;
const js_undefined = globals_mod.js_undefined;
const js_null = globals_mod.js_null;
const js_true = globals_mod.js_true;
const valueToOwnedString = globals_mod.valueToOwnedString;
const js_false = globals_mod.js_false;

/// Install the per-request pieces of the global surface: attach
/// `state` as the context opaque, and create `request`/`response`
/// globals populated from the incoming request. Called AFTER
/// `Snapshot.restore` on every request. Cheap — just a handful of
/// `JS_SetPropertyStr` calls.
/// Lift a held chain's `next({ctx})` payload onto `request.ctx`, given a
/// synthesized `{"ctx":<ctx_json>}` body. The continuation resumes whose
/// `Request.body` IS that envelope (`.ws_message`, `.disconnect`) share
/// this so every held-connection `on*` handler reads ctx the same way the
/// fetch-resume path does. NUL-terminate before `JS_ParseJSON` (quickjs
/// requires it); a non-JSON / ctx-less body simply leaves `request.ctx`
/// unset. The kinds that REPLACE `request.body` (bound fetch, inbound
/// chunk) lift their ctx inline before the swap instead.
fn liftThreadedCtx(ctx: *c.JSContext, req_obj: c.JSValue, body: []const u8, allocator: std.mem.Allocator) void {
    if (body.len == 0) return;
    const buf = allocator.allocSentinel(u8, body.len, 0) catch return;
    defer allocator.free(buf);
    @memcpy(buf, body);
    const parsed = c.JS_ParseJSON(ctx, buf.ptr, body.len, "<chain ctx>");
    if (c.JS_IsException(parsed)) {
        _ = c.JS_GetException(ctx); // clear; leave request.ctx unset
        return;
    }
    defer c.JS_FreeValue(ctx, parsed);
    // Setter consumes the ctx_val reference.
    _ = c.JS_SetPropertyStr(ctx, req_obj, "ctx", c.JS_GetPropertyStr(ctx, parsed, "ctx"));
}

pub fn installRequest(
    ctx: *c.JSContext,
    state: *DispatchState,
    request: anytype,
) void {
    c.JS_SetContextOpaque(ctx, state);

    // Within-activation non-determinism replay
    // (`docs/architecture/replay-and-sim.md`): seed arenajs's per-request
    // xorshift64star with this dispatch's seed. Math.random and
    // crypto.* both draw from this state, so replay reproduces the
    // entire random stream by re-seeding with the recorded value.
    // Test paths without a readset get `0` (arenajs maps that to
    // `1` internally — xorshift64 requires non-zero state).
    const seed: u64 = if (state.readset) |rs| rs.seed else 0;
    c.JS_SetRandomSeed(ctx, seed);

    // Within-activation non-determinism replay
    // (`docs/architecture/replay-and-sim.md`): pin Date.now() to the
    // request's start time in ms. Every `Date.now()` and `new Date()`
    // (no args) inside the handler returns this scalar — same
    // posture as Cloudflare Workers / Lambda SnapStart, and the
    // single input replay needs to reproduce the clock sequence
    // (no per-call tape entries). Test paths without a readset
    // pass `-1` which unpins (arenajs falls through to
    // gettimeofday).
    const date_now_ms: i64 = if (state.readset) |rs|
        @divTrunc(rs.timestamp_ns, std.time.ns_per_ms)
    else
        -1;
    c.JS_SetDateNow(ctx, date_now_ms);

    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);

    // request = { method, path, host, body, query, headers, cookies,
    //             ip, unmaskedIp() }
    //
    // The request surface is READ-TAPED (`docs/handler-shape.md`):
    // method/path/host/query are eager data properties (they already
    // live on the LogRecord's dedicated fields), but everything else
    // is a lazy accessor that records the read into
    // `readset.request_reads` on first access — the tape stores
    // exactly the inputs the handler observed, nothing else.
    //
    // `query` is the raw URL query string (everything after `?`) or
    // null when the URL had none. Parsing is the handler's job —
    // QuickJS-ng doesn't ship `URL` / `URLSearchParams`, and a
    // manual `split("&").reduce(...)` is a few lines in the
    // handler. If customer demand for `URLSearchParams` shows up,
    // it can land as another polyfill alongside TextEncoder.
    //
    // `headers` is a flat object, lowercase keys per HTTP/2, one
    // recording GETTER per header. Pseudo-headers (`:method`,
    // `:path`, `:scheme`, `:authority`) are filtered out — they're
    // already exposed as `request.method` / `request.path` etc. —
    // and so are the IP transport headers (`x-forwarded-for`,
    // `x-real-ip`, `cf-connecting-ip`, `forwarded`): the client IP
    // is reachable ONLY via `request.ip` (masked) /
    // `request.unmaskedIp()` (raw, the deliberate taped
    // escalation). Duplicate header names: last value wins,
    // first-occurrence enumeration position. Assigning to
    // `request.headers.x` throws in module (strict) code — the
    // properties are accessors without setters.
    //
    // `cookies` is a parsed `{name: value}` from the `cookie` header
    // (RFC 6265, semicolon-separated), materialized on first access;
    // the access records the whole `cookie` header as read. Empty /
    // no-cookie → `{}`.
    //
    // `body` is a lazy accessor too: first access records the
    // body-read marker that keeps the body's tape/log reference
    // alive (unread bodies are elided from the replay record —
    // `Readset.elideUnreadBody`).
    const req_obj = c.JS_NewObject(ctx);
    // The shared payload prototype (globals/request.js): `text`/`json`
    // accessors deriving from `request.bytes`
    // (decisions.md §4.11). Baked into the base snapshot;
    // one JS_SetPrototype per activation. Test contexts built without
    // the globals install simply skip it.
    const payload_proto = c.JS_GetPropertyStr(ctx, global, "__rove_request_proto");
    if (!c.JS_IsUndefined(payload_proto)) _ = c.JS_SetPrototype(ctx, req_obj, payload_proto);
    c.JS_FreeValue(ctx, payload_proto);
    state.req_headers = request.headers;
    state.req_body = request.body;
    _ = c.JS_SetPropertyStr(ctx, req_obj, "method", c.JS_NewStringLen(ctx, request.method.ptr, request.method.len));
    _ = c.JS_SetPropertyStr(ctx, req_obj, "path", c.JS_NewStringLen(ctx, request.path.ptr, request.path.len));
    _ = c.JS_SetPropertyStr(ctx, req_obj, "host", c.JS_NewStringLen(ctx, request.host.ptr, request.host.len));
    // `bytes` — the uniform payload view. On plain inbound (buffered or
    // headers-first) `Request.body` IS the customer payload, so `bytes`
    // is a read-recording lazy accessor exactly like `body`. Every other
    // payload-carrying kind (`inbound_chunk`, bound `fetch_chunk`,
    // `ws_message`, `send_callback`) defines its own `bytes` data
    // property in its arm below; the remaining kinds carry an internal
    // ctx envelope (or nothing) in `Request.body`, which must NOT leak
    // through a payload surface — they get no `bytes` at all.
    if (request.activation == .inbound or request.activation == .inbound_headers) {
        definePropertyGetter(ctx, req_obj, "bytes", c.JS_NewCFunction2(ctx, @ptrCast(&jsBytesGetter), "bytes", 0, c.JS_CFUNC_getter_magic, 0));
    }
    if (request.query) |q| {
        _ = c.JS_SetPropertyStr(ctx, req_obj, "query", c.JS_NewStringLen(ctx, q.ptr, q.len));
    } else {
        _ = c.JS_SetPropertyStr(ctx, req_obj, "query", js_null);
    }
    installHeaders(ctx, state, req_obj, request.headers);
    definePropertyGetter(ctx, req_obj, "cookies", c.JS_NewCFunction2(ctx, @ptrCast(&jsCookiesGetter), "cookies", 0, c.JS_CFUNC_getter_magic, 0));
    definePropertyGetter(ctx, req_obj, "ip", c.JS_NewCFunction2(ctx, @ptrCast(&jsIpGetter), "ip", 0, c.JS_CFUNC_getter_magic, 0));
    _ = c.JS_SetPropertyStr(ctx, req_obj, "unmaskedIp", c.JS_NewCFunction2(ctx, jsUnmaskedIp, "unmaskedIp", 0, c.JS_CFUNC_generic, 0));
    // request.tag(key, value): attach a low-cardinality index tag to
    // this request's log record (see `jsRequestTag`).
    _ = c.JS_SetPropertyStr(ctx, req_obj, "tag", c.JS_NewCFunction2(ctx, jsRequestTag, "tag", 2, c.JS_CFUNC_generic, 0));
    // request.correlation_id: the engine per-chain id (stable across a
    // held connection's activations). The reserved `_corr` index tag is
    // derived from it; a handler can also store it to map its own app
    // session id ↔ correlation_id across reconnects. Empty string when
    // the dispatch carries no chain context.
    _ = c.JS_SetPropertyStr(ctx, req_obj, "correlation_id", c.JS_NewStringLen(ctx, state.correlation_id.ptr, state.correlation_id.len));
    // request.tenant: the handler's own instance id. Needed to address
    // the self-tenant `rewind-logs.internal/v1/{tenant}/…` door (the
    // engine pins the read to this same id, so it can't reach another
    // tenant's logs). Not a secret — it's the tenant's own id.
    _ = c.JS_SetPropertyStr(ctx, req_obj, "tenant", c.JS_NewStringLen(ctx, state.instance_id.ptr, state.instance_id.len));

    // request.session = {id: "<64hex>"} when the worker resolved a
    // session cookie (or freshly minted one) for this request, else
    // null. Customer JS branches on `request.session === null` for
    // the "called outside browser context" cases (callbacks, signup,
    // sim/dry-run). Eager mint on browser-facing handler invocations
    // means the null branch is rare in production handler code.
    if (state.session_id) |sid| {
        const session_obj = c.JS_NewObject(ctx);
        // Customer-visible: opaque `sess_<64hex>` form (§7.5). The cookie
        // / internal store keep the bare hex.
        var sid_buf: [log_mod.SESSION_ID_PREFIX.len + 64]u8 = undefined;
        @memcpy(sid_buf[0..log_mod.SESSION_ID_PREFIX.len], log_mod.SESSION_ID_PREFIX);
        @memcpy(sid_buf[log_mod.SESSION_ID_PREFIX.len..], &sid);
        _ = c.JS_SetPropertyStr(ctx, session_obj, "id", c.JS_NewStringLen(ctx, &sid_buf, sid_buf.len));
        _ = c.JS_SetPropertyStr(ctx, req_obj, "session", session_obj);
    } else {
        _ = c.JS_SetPropertyStr(ctx, req_obj, "session", js_null);
    }

    // request.activation = { kind, ...payload }
    // — streaming handlers (`docs/architecture/effects-and-handlers.md`):
    // every handler run is a recorded
    // "request," and the activation source is one field on the
    // request shape the handler can branch on. The `wake_batch`
    // variant (fired-prefix contract) carries
    // `wakes: [{kind:"kv",prefix,firedAt} | {kind:"timer",firedAt}]`
    // — the ARMED prefix that fired, never matched keys (the handler
    // re-reads authoritative kv; handler-shape.md §7). The singular
    // `.kv_wake` source maps to `kind:"kv"` but carries no payload;
    // live kv fan-out rides `.wake_batch`.
    const activation_obj = c.JS_NewObject(ctx);
    const kind: []const u8 = switch (request.activation.source()) {
        .inbound => "inbound",
        .send_callback => "send_callback",
        .timer => "timer",
        .disconnect => "disconnect",
        .kv_wake => "kv",
        .wake_batch => "wake_batch",
        .subscription_fire => "subscription_fire",
        // Single fetch activation kind; `final` flag
        // distinguishes streaming intermediates from the terminal.
        .fetch_chunk => "fetch_chunk",
        // §2.6 durable scheduled wake.
        .durable_wake => "durable_wake",
        // `docs/architecture/websockets.md`: one inbound WS data frame.
        .ws_message => "ws_message",
        // blob ingress (`docs/architecture/routing-and-ingress.md`):
        // headers-first inbound — body still
        // inbound, handler decides from headers alone.
        .inbound_headers => "inbound_headers",
        // gap 2.4 (`docs/architecture/effects-and-handlers.md`): streaming inbound body chunk.
        .inbound_chunk => "inbound_chunk",
    };
    _ = c.JS_SetPropertyStr(ctx, activation_obj, "kind", c.JS_NewStringLen(ctx, kind.ptr, kind.len));
    if (request.activation == .wake_batch) {
        const wb = request.activation.wake_batch;
        // wakes: [{kind:"kv",prefix,firedAt}|{kind:"timer",firedAt}, ...]
        // — one entry per fired ARM, identical on every
        // resume path (stream / held / WS). No overflow signal: a
        // bit-per-arm can't lose fires.
        const wakes_arr = c.JS_NewArray(ctx);
        for (wb.wakes, 0..) |w, i| {
            const entry = c.JS_NewObject(ctx);
            switch (w.tag) {
                .kv => {
                    _ = c.JS_SetPropertyStr(ctx, entry, "kind", c.JS_NewStringLen(ctx, "kv", 2));
                    _ = c.JS_SetPropertyStr(ctx, entry, "prefix", c.JS_NewStringLen(ctx, w.prefix.ptr, w.prefix.len));
                },
                .timer => {
                    _ = c.JS_SetPropertyStr(ctx, entry, "kind", c.JS_NewStringLen(ctx, "timer", 5));
                },
            }
            // `firedAt` in MILLISECONDS since epoch — matches every other
            // JS-facing timestamp; `fired_at_ns` stays the internal wall
            // clock. Mirrored in the sim (rewind_test.mjs).
            _ = c.JS_SetPropertyStr(ctx, entry, "firedAt", c.JS_NewInt64(ctx, @divFloor(w.fired_at_ns, std.time.ns_per_ms)));
            _ = c.JS_SetPropertyUint32(ctx, wakes_arr, @intCast(i), entry);
        }
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "wakes", wakes_arr);
    }

    // stream.write is lossless — the runtime never drops; it backpressures the
    // producer or throws loudly on a single-activation overrun. So there is no
    // `write_pressure.dropped_chunks` surface (§9.4) to populate here.

    // Gap 2.1 subscription_fire payload. The activation's `name`
    // is the subscription's directory name; `source` carries the
    // kind-specific payload (kv key+op
    // deployment_id).
    if (request.activation == .subscription_fire) {
        const sf = request.activation.subscription_fire;
        if (sf.name) |n| {
            _ = c.JS_SetPropertyStr(ctx, activation_obj, "name", c.JS_NewStringLen(ctx, n.ptr, n.len));
        }
        const source_obj = c.JS_NewObject(ctx);
        if (sf.source) |src| switch (src) {
            .kv => |kv| {
                // Coalesced level-trigger (durable-kv-subscriptions):
                // the fire names the DIRTY PREFIX, never a key/op — N
                // writes coalesce into ≥1 fire; the handler reads
                // current committed state under the prefix.
                _ = c.JS_SetPropertyStr(ctx, source_obj, "kind", c.JS_NewStringLen(ctx, "kv", 2));
                _ = c.JS_SetPropertyStr(ctx, source_obj, "prefix", c.JS_NewStringLen(ctx, kv.prefix.ptr, kv.prefix.len));
            },
        };
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "source", source_obj);
    }

    // Single `fetch_chunk` activation kind. Every
    // event carries `fetch_id` / `seq` / `byteOffset` / `bytes`
    // (+ `headers` on seq 0). The LAST event for a fetch has
    // `final: true` and carries the terminal fields (`status`,
    // `ok`, `body_truncated`); intermediates have `final: false`
    // and only the per-chunk fields.
    if (request.activation == .fetch_chunk) {
        const fc = request.activation.fetch_chunk;
        if (fc.id) |fid| {
            // Customer-visible: opaque `ftch_<hex>` form (§7.5). The
            // msg-router key / S3 upload key keep the bare hex.
            var fid_buf: [log_mod.FETCH_ID_PREFIX.len + 64]u8 = undefined;
            @memcpy(fid_buf[0..log_mod.FETCH_ID_PREFIX.len], log_mod.FETCH_ID_PREFIX);
            @memcpy(fid_buf[log_mod.FETCH_ID_PREFIX.len..][0..fid.len], fid);
            const fid_str = fid_buf[0 .. log_mod.FETCH_ID_PREFIX.len + fid.len];
            _ = c.JS_SetPropertyStr(ctx, activation_obj, "fetchId", c.JS_NewStringLen(ctx, fid_str.ptr, fid_str.len));
        }
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "seq", c.JS_NewInt64(ctx, @intCast(fc.seq)));
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "byteOffset", c.JS_NewInt64(ctx, @intCast(fc.byte_offset)));
        // `bytes`: a fresh Uint8Array copy — the handler owns it
        // outright, no lifetime coupling to the event. May be empty
        // on a transport-error / empty-body final event.
        _ = c.JS_SetPropertyStr(
            ctx,
            activation_obj,
            "bytes",
            c.JS_NewUint8ArrayCopy(ctx, fc.bytes.ptr, fc.bytes.len),
        );
        // `headers` (seq 0 only): the activation carries the
        // PARSED headers as a JSON-encoded `{"name":"value", ...}`
        // string — decode back into a JS object here so the
        // handler sees a plain map. The FetchPool side handles
        // the wire-format parse + last-wins for repeated headers.
        if (fc.headers) |hjson| {
            // `JS_ParseJSON` requires a NUL-terminated buffer
            // (`buf[buf_len] = '\0'` per vendor/arenajs/quickjs.h:1060).
            // Our slice doesn't carry the trailing NUL — copy into a
            // sentinel-terminated buffer before parsing. Without this
            // the parse silently fails (returns an exception that the
            // IsException branch swallows) and `a.headers` lands as an
            // empty `{}` — observable as `content-type` going missing
            // on the seq-0 chunk activation (fetch_chunk_smoke gate).
            if (state.allocator.allocSentinel(u8, hjson.len, 0)) |buf| {
                defer state.allocator.free(buf);
                @memcpy(buf, hjson);
                const hdr_val = c.JS_ParseJSON(ctx, buf.ptr, hjson.len, "<fetch headers>");
                if (c.JS_IsException(hdr_val)) {
                    _ = c.JS_GetException(ctx); // clear; fall through with empty headers
                    _ = c.JS_SetPropertyStr(ctx, activation_obj, "headers", c.JS_NewObject(ctx));
                } else {
                    _ = c.JS_SetPropertyStr(ctx, activation_obj, "headers", hdr_val);
                }
            } else |_| {
                _ = c.JS_SetPropertyStr(ctx, activation_obj, "headers", c.JS_NewObject(ctx));
            }
        }
        // `final` + terminal fields. `JS_NewBool`'s cimport-translated
        // body is itself non-compilable (translate-c bug — `int != 0`
        // lands in an i32 field); use the module's prebuilt bool
        // JSValue constants instead.
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "final", if (fc.final) js_true else js_false);
        if (fc.final) {
            // `status` is the SINGLE source of truth for a fetch/callback
            // result (handler-shape.md §3): `200 ≤ status < 300` is
            // success, `status === 0` is a hard transport failure (no HTTP
            // response reached us). There is deliberately no derived `ok`
            // boolean — it was redundant with `status` and drifted into
            // three disagreeing definitions.
            _ = c.JS_SetPropertyStr(ctx, activation_obj, "status", c.JS_NewInt64(ctx, @intCast(fc.terminal_status)));
            _ = c.JS_SetPropertyStr(ctx, activation_obj, "bodyTruncated", if (fc.body_truncated) js_true else js_false);
        }
        // UNBOUND (Pattern-A `on_chunk:"module"`) fires carry the
        // synthesized `{"ctx":…}` envelope in `Request.body`; there is
        // no `request.body`, so lift it so the internal shim modules
        // (webhook/blob onresult) read `request.ctx` like every other
        // callback.
        if (request.activation_entity == null) {
            liftThreadedCtx(ctx, req_obj, request.body, state.allocator);
        }
        // `docs/handler-shape.md` §3 + §7: the customer's
        // onFetchChunk handler (BOUND fetch path — bind:true) reads
        // `request.body` (chunk bytes), `request.done` (final),
        // `request.fetchId`, `request.chunkSeq` at the TOP LEVEL of
        // request. The UNBOUND fetch path (Pattern A
        // `on_chunk: "module"`, separate chain) keeps
        // `request.body` as the synthesized `{"ctx":...}` JSON —
        // existing handlers read `request.activation.bytes` for the
        // chunk and `JSON.parse(request.body).ctx.*` for ctx
        // round-trip. The discriminator is `activation_entity`: set
        // only by `resumeBoundFetchChain`, null in
        // `fireFetchEventActivation`'s unbound path.
        if (request.activation_entity != null) {
            // handler-shape §7: fetch resumes carry `request.ctx`
            // (the fetch's `ctx:` option). The resume path
            // synthesized `Request.body` as `{"ctx":...}` but the
            // bound surface replaces `request.body` with the chunk
            // bytes below — lift the ctx to its documented home
            // first. Same NUL-terminated-buffer rule as the
            // fetch-headers parse above.
            if (request.body.len > 0) {
                if (state.allocator.allocSentinel(u8, request.body.len, 0)) |buf| {
                    defer state.allocator.free(buf);
                    @memcpy(buf, request.body);
                    const parsed = c.JS_ParseJSON(ctx, buf.ptr, request.body.len, "<fetch ctx>");
                    if (c.JS_IsException(parsed)) {
                        _ = c.JS_GetException(ctx); // clear; no ctx
                    } else {
                        // `request.ctx` = the resume envelope's ctx — the fetch's
                        // own ctx, or the chain's `next()` ctx when the fetch
                        // carried none (the override resolved worker-side, see
                        // worker_streaming.fetchResumeCtx; decisions.md §4.14).
                        const ctx_val = c.JS_GetPropertyStr(ctx, parsed, "ctx");
                        // Setter consumes the ctx_val reference.
                        _ = c.JS_SetPropertyStr(ctx, req_obj, "ctx", ctx_val);
                        c.JS_FreeValue(ctx, parsed);
                    }
                } else |_| {}
            }
            // The uniform payload view (§2.2): `bytes` = the chunk
            // payload (the activation's Msg, recorded on the
            // fetch_responses tape — never read-elided); `text`/`json`
            // derive on the prototype. (There is no `request.body`.)
            _ = c.JS_DefinePropertyValueStr(
                ctx,
                req_obj,
                "bytes",
                c.JS_NewUint8ArrayCopy(ctx, fc.bytes.ptr, fc.bytes.len),
                c.JS_PROP_C_W_E,
            );
            _ = c.JS_SetPropertyStr(ctx, req_obj, "done", if (fc.final) js_true else js_false);
            if (fc.id) |fid| {
                // ftch_-prefixed — the SAME string after.fetch() returned
                // (decisions.md §4.9).
                var tfid_buf: [log_mod.FETCH_ID_PREFIX.len + 64]u8 = undefined;
                @memcpy(tfid_buf[0..log_mod.FETCH_ID_PREFIX.len], log_mod.FETCH_ID_PREFIX);
                @memcpy(tfid_buf[log_mod.FETCH_ID_PREFIX.len..][0..fid.len], fid);
                _ = c.JS_SetPropertyStr(ctx, req_obj, "fetchId", c.JS_NewStringLen(ctx, &tfid_buf, log_mod.FETCH_ID_PREFIX.len + fid.len));
            }
            _ = c.JS_SetPropertyStr(ctx, req_obj, "chunkSeq", c.JS_NewInt64(ctx, @intCast(fc.seq)));
            // Pending bound-fetch count including this one.
            // Customer branches on
            // `request.done && request.fetchesPending === 1` to
            // detect "last chunk of last fetch."
            _ = c.JS_SetPropertyStr(ctx, req_obj, "fetchesPending", c.JS_NewInt64(ctx, @intCast(request.activation_fetches_pending)));
            // Terminal-only fields. Customer's onFetchChunk branches on
            // `request.done` and inspects `request.status` to decide
            // between "all good" (2xx), "upstream error" (non-zero
            // non-2xx), and "transport failure" (status 0) — the same
            // `status` fields that ride on the unbound
            // `request.activation.{status,body_truncated}`, hoisted to
            // the top level for the bound surface. No derived `ok`.
            if (fc.final) {
                _ = c.JS_SetPropertyStr(ctx, req_obj, "status", c.JS_NewInt64(ctx, @intCast(fc.terminal_status)));
                _ = c.JS_SetPropertyStr(ctx, req_obj, "bodyTruncated", if (fc.body_truncated) js_true else js_false);
            }
        }
    }

    // `docs/architecture/websockets.md`: one inbound WS data frame →
    // `request.activation = { kind:"ws_message", opcode, data }`.
    // opcode 1 (text) surfaces `data` as a string; opcode 2 (binary)
    // as a fresh Uint8Array copy the handler owns outright (no lifetime
    // coupling to the borrowed frame payload). The handler replies with
    // `stream.write(...)` and parks for the next frame via `next()`.
    if (request.activation == .ws_message) {
        const wm = request.activation.ws_message;
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "opcode", c.JS_NewInt64(ctx, @intCast(wm.opcode)));
        const data_val = if (wm.opcode == 2)
            c.JS_NewUint8ArrayCopy(ctx, wm.data.ptr, wm.data.len)
        else
            c.JS_NewStringLen(ctx, wm.data.ptr, wm.data.len);
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "data", data_val);
        // The uniform payload view (§2.2): `bytes` = the frame payload,
        // raw, regardless of opcode (a text frame's bytes are its
        // UTF-8); `opcode` stays on request.activation for handlers
        // that care about text-vs-binary framing.
        _ = c.JS_DefinePropertyValueStr(
            ctx,
            req_obj,
            "bytes",
            c.JS_NewUint8ArrayCopy(ctx, wm.data.ptr, wm.data.len),
            c.JS_PROP_C_W_E,
        );
    }

    // Endpoint A — uniform ctx threading (decisions.md): every activation
    // that is a continuation of a prior
    // `next({ctx})` reads that payload as `request.ctx`. These kinds carry
    // it as the synthesized `{"ctx":<ctx_json>}` body (the WS / SSE / wake
    // / continuation resume paths all build that envelope), so lift it once
    // here. The kinds that REPLACE `request.body` with their own bytes
    // (`fetch_chunk`, `inbound_chunk`) lift inline before the swap; the
    // result-bearing `send_callback` lifts in its hoist below. `request.ctx`
    // is simply undefined on the first activation of a chain (no prior
    // `next`).
    if (request.activation == .ws_message or
        request.activation == .disconnect or
        request.activation == .kv_wake or
        request.activation == .wake_batch or
        request.activation == .timer)
    {
        liftThreadedCtx(ctx, req_obj, request.body, state.allocator);
    }

    // gap 2.4 (`docs/architecture/effects-and-handlers.md`): streaming inbound body chunk.
    // `Request.body` carries the raw chunk; re-surface it as a
    // Uint8Array (chunks are arbitrary bytes — same posture as the
    // bound-fetch chunk surface above), add the documented top-level
    // `request.done` + `request.chunkSeq` (handler-shape §7), mirror
    // the per-chunk fields on the activation object, and lift the
    // held chain's `next({ctx})` payload to `request.ctx`.
    if (request.activation == .inbound_chunk) {
        const ic = request.activation.inbound_chunk;
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "seq", c.JS_NewInt64(ctx, @intCast(ic.seq)));
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "byteOffset", c.JS_NewInt64(ctx, @intCast(ic.byte_offset)));
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "done", if (ic.done) js_true else js_false);
        // The uniform payload view (§2.2): `bytes` = this chunk.
        // (There is no `request.body` — the accessors are the payload
        // surface; decisions.md §4.11.)
        _ = c.JS_DefinePropertyValueStr(
            ctx,
            req_obj,
            "bytes",
            c.JS_NewUint8ArrayCopy(ctx, request.body.ptr, request.body.len),
            c.JS_PROP_C_W_E,
        );
        _ = c.JS_SetPropertyStr(ctx, req_obj, "done", if (ic.done) js_true else js_false);
        _ = c.JS_SetPropertyStr(ctx, req_obj, "chunkSeq", c.JS_NewInt64(ctx, @intCast(ic.seq)));
        if (ic.ctx_json) |cj| {
            if (state.allocator.allocSentinel(u8, cj.len, 0)) |buf| {
                defer state.allocator.free(buf);
                @memcpy(buf, cj);
                const parsed = c.JS_ParseJSON(ctx, buf.ptr, cj.len, "<chunk ctx>");
                if (c.JS_IsException(parsed)) {
                    _ = c.JS_GetException(ctx); // clear; no ctx
                } else {
                    _ = c.JS_SetPropertyStr(ctx, req_obj, "ctx", parsed);
                }
            } else |_| {}
        }
    }

    // §2.6 durable-wake payload: `{ id, key, scheduled_at_ns, msg }`.
    // `msg` is the customer payload, JSON-decoded back to a JS value
    // (mirrors the fetch-headers decode above). `key` is omitted (not
    // null) when `at()` was called without one — matches the JS lib's
    // `get()` shape.
    if (request.activation == .durable_wake) {
        const dw = request.activation.durable_wake;
        if (dw.id) |id| {
            _ = c.JS_SetPropertyStr(ctx, activation_obj, "id", c.JS_NewStringLen(ctx, id.ptr, id.len));
        }
        if (dw.key) |k| {
            _ = c.JS_SetPropertyStr(ctx, activation_obj, "key", c.JS_NewStringLen(ctx, k.ptr, k.len));
        }
        // Scheduled fire time fits comfortably in a JS Number until
        // the year 2262 (Date.now()*1e6); surface as a plain number
        // for ergonomic `scheduled_at_ns` math.
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "scheduledAtNs", c.JS_NewInt64(ctx, dw.scheduled_at_ns));
        const mjson = dw.msg_json orelse "null";
        if (state.allocator.allocSentinel(u8, mjson.len, 0)) |buf| {
            defer state.allocator.free(buf);
            @memcpy(buf, mjson);
            const msg_val = c.JS_ParseJSON(ctx, buf.ptr, mjson.len, "<durable_wake msg>");
            if (c.JS_IsException(msg_val)) {
                _ = c.JS_GetException(ctx); // clear; leave request.ctx unset
            } else {
                // One-ctx rule (decisions.md §4.9): the
                // schedule/cron target reads its threaded payload as
                // `request.ctx` like every other callback.
                _ = c.JS_SetPropertyStr(ctx, req_obj, "ctx", msg_val);
            }
        } else |_| {}
    }

    // ── Unified effect-result surface (handler-shape.md §7, Endpoint A) ──
    // A customer `on_result` hop (`webhook.send` / `blob.put` / `retry.send`)
    // AND a §6.4 held-sync resume both arrive as `.send_callback` with
    // `request.body = {"ctx":{result, context}}` — the held-sync producer
    // (worker_drain.resumeContinuation) wraps the outcome into the SAME
    // shape, so there is ONE surface. Present it exactly like a bound-fetch
    // FINAL: `request.body` = the response bytes, top-level
    // `request.status`/`.ok`/`.done`; the THREADED ctx (the echoed `context`
    // for an on_result hop, the held handler's `next({ctx})` for held-sync)
    // on `request.ctx`; and the per-delivery metadata that is NOT part of the
    // universal response surface (`attempts`/`error`/`id`/`headers` for
    // webhook, `hash` for blob) on `request.activation.*` — "why/how this
    // activation fired." This keeps the one rule whole: `request.ctx` = what
    // you threaded, `request.body`/`.status` = the result, `request.activation`
    // = metadata. There is no `request.result`.
    if (request.activation == .send_callback and request.body.len > 0) hoist: {
        const buf = state.allocator.allocSentinel(u8, request.body.len, 0) catch break :hoist;
        defer state.allocator.free(buf);
        @memcpy(buf, request.body);
        const parsed = c.JS_ParseJSON(ctx, buf.ptr, request.body.len, "<send_callback>");
        if (c.JS_IsException(parsed)) {
            _ = c.JS_GetException(ctx); // not JSON — leave request as-is
            break :hoist;
        }
        defer c.JS_FreeValue(ctx, parsed);

        const cb_ctx = c.JS_GetPropertyStr(ctx, parsed, "ctx");
        defer c.JS_FreeValue(ctx, cb_ctx);
        if (!c.JS_IsObject(cb_ctx)) break :hoist;
        const result = c.JS_GetPropertyStr(ctx, cb_ctx, "result");
        defer c.JS_FreeValue(ctx, result);
        if (!c.JS_IsObject(result)) {
            // Not a result delivery (a webhook_onresult self-hop /
            // internal chained dispatch): the envelope's ctx IS the
            // hop's payload — lift it whole so the target reads
            // `request.ctx` (there is no request.body).
            _ = c.JS_SetPropertyStr(ctx, req_obj, "ctx", c.JS_DupValue(ctx, cb_ctx));
            break :hoist;
        }

        // Result → the universal response surface (§2.2): the envelope
        // carries the response bytes as base64url-no-pad `body_b64` (a
        // JSON envelope can't hold raw bytes); decode once onto
        // `request.bytes` — `text`/`json` derive on the prototype.
        // (There is no `request.body`.) A producer that only carries a
        // `body` string (held-sync deadline events) still yields bytes
        // from its UTF-8.
        var payload_done = false;
        const b64_val = c.JS_GetPropertyStr(ctx, result, "body_b64");
        if (c.JS_IsString(b64_val)) b64: {
            var b64_len: usize = 0;
            const b64_c = c.JS_ToCStringLen(ctx, &b64_len, b64_val);
            if (b64_c == null) break :b64;
            defer c.JS_FreeCString(ctx, b64_c);
            const b64_slice = @as([*]const u8, @ptrCast(b64_c))[0..b64_len];
            const dec = std.base64.url_safe_no_pad.Decoder;
            const raw_len = dec.calcSizeForSlice(b64_slice) catch break :b64;
            const raw = state.allocator.alloc(u8, raw_len) catch break :b64;
            defer state.allocator.free(raw);
            dec.decode(raw, b64_slice) catch break :b64;
            _ = c.JS_DefinePropertyValueStr(ctx, req_obj, "bytes", c.JS_NewUint8ArrayCopy(ctx, raw.ptr, raw.len), c.JS_PROP_C_W_E);
            payload_done = true;
        }
        c.JS_FreeValue(ctx, b64_val);
        if (!payload_done) {
            const legacy_body = c.JS_GetPropertyStr(ctx, result, "body");
            if (c.JS_IsString(legacy_body)) {
                var lb_len: usize = 0;
                const lb_c = c.JS_ToCStringLen(ctx, &lb_len, legacy_body);
                if (lb_c != null) {
                    defer c.JS_FreeCString(ctx, lb_c);
                    _ = c.JS_DefinePropertyValueStr(ctx, req_obj, "bytes", c.JS_NewUint8ArrayCopy(ctx, @ptrCast(lb_c), lb_len), c.JS_PROP_C_W_E);
                }
            }
            c.JS_FreeValue(ctx, legacy_body);
        }
        // `status` is the single success signal — no derived `ok`.
        // A shim result's own `ok`/`error` (webhook delivery `< 400`,
        // etc.) rides `request.activation.error` for diagnosis; the
        // handler branches on `request.status` (0 = transport failure).
        _ = c.JS_SetPropertyStr(ctx, req_obj, "status", c.JS_GetPropertyStr(ctx, result, "status"));
        _ = c.JS_SetPropertyStr(ctx, req_obj, "done", js_true);
        _ = c.JS_SetPropertyStr(ctx, req_obj, "bodyTruncated", c.JS_GetPropertyStr(ctx, result, "body_truncated"));

        // request.ctx = the bare threaded value (what the customer passed
        // as `context:` / `next({ctx})`) — NOT an envelope.
        _ = c.JS_SetPropertyStr(ctx, req_obj, "ctx", c.JS_GetPropertyStr(ctx, cb_ctx, "context"));

        // Delivery metadata → request.activation.* (absent fields read
        // undefined: blob has no attempts/error; webhook has no hash).
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "attempts", c.JS_GetPropertyStr(ctx, result, "attempts"));
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "error", c.JS_GetPropertyStr(ctx, result, "error"));
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "id", c.JS_GetPropertyStr(ctx, result, "id"));
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "headers", c.JS_GetPropertyStr(ctx, result, "headers"));
        _ = c.JS_SetPropertyStr(ctx, activation_obj, "hash", c.JS_GetPropertyStr(ctx, result, "hash"));
    }

    _ = c.JS_SetPropertyStr(ctx, req_obj, "activation", activation_obj);

    _ = c.JS_SetPropertyStr(ctx, global, "request", req_obj);

    // response = { status: 200, headers: {}, cookies: [] }
    //
    // Response body comes from the exported function's return value —
    // not from `response.body`. The `response` global is ONLY for
    // metadata: status, custom headers, and Set-Cookie entries.
    // Handlers mutate these freely; the dispatcher reads them after
    // the call and merges with the JSON-serialized return value.
    const resp_obj = c.JS_NewObject(ctx);
    _ = c.JS_SetPropertyStr(ctx, resp_obj, "status", c.JS_NewInt32(ctx, 200));
    _ = c.JS_SetPropertyStr(ctx, resp_obj, "headers", c.JS_NewObject(ctx));
    _ = c.JS_SetPropertyStr(ctx, resp_obj, "cookies", c.JS_NewArray(ctx));
    _ = c.JS_SetPropertyStr(ctx, global, "response", resp_obj);
}

// The IP-transport strip list lives in `reserved_headers.zig`
// (shared with the sim's authored-header hygiene, so the two filters
// can't drift). The worker's own native XFF uses (proxy warning, the
// IP derivation below) read the wire directly and are unaffected.
const isStrippedIpHeader = reserved_headers.isStrippedIpHeader;

/// Record one request-surface read into the readset, if one is
/// attached (unit-test paths run without). Failure to record is a
/// warn, not a throw — it can only happen on OOM, and the divergence
/// error on a later replay points straight back here.
fn recordRequestRead(
    state: *DispatchState,
    kind: tape_mod.RequestReadKind,
    name: []const u8,
    value: []const u8,
) void {
    const rs = state.readset orelse return;
    rs.request_reads.appendRequestReadOnce(kind, name, value) catch |err| {
        std.log.warn("rove-js request_reads: record {s} '{s}': {s}", .{
            @tagName(kind), name, @errorName(err),
        });
    };
}

/// Define `name` on `obj` as an accessor with the given getter
/// JSValue and no setter (assignment throws in strict module code).
/// ENUMERABLE + CONFIGURABLE — configurable is what lets the
/// self-replacing getters swap themselves for a data property on
/// first access, and lets duplicate header names re-define (last
/// value wins, first occurrence keeps the enumeration slot).
/// Consumes the getter ref (JS_DefinePropertyGetSet frees it).
fn definePropertyGetter(
    ctx: *c.JSContext,
    obj: c.JSValue,
    name: []const u8,
    getter: c.JSValue,
) void {
    const atom = c.JS_NewAtomLen(ctx, name.ptr, name.len);
    defer c.JS_FreeAtom(ctx, atom);
    _ = c.JS_DefinePropertyGetSet(
        ctx,
        obj,
        atom,
        getter,
        js_undefined,
        c.JS_PROP_ENUMERABLE | c.JS_PROP_CONFIGURABLE,
    );
}

/// Build `request.headers`: one recording getter per non-pseudo,
/// non-IP-transport header (flat lowercase names per HTTP/2), plus
/// the once-per-activation `header_names` tape entry that makes
/// `Object.keys(request.headers)` replay faithfully without forcing
/// every value onto the tape. Values are recorded only when a getter
/// actually fires. Last-write-wins on duplicate header names —
/// re-defining the accessor keeps the first occurrence's enumeration
/// position.
fn installHeaders(
    ctx: *c.JSContext,
    state: *DispatchState,
    req_obj: c.JSValue,
    hdrs_opt: ?h2.ReqHeaders,
) void {
    const headers_obj = c.JS_NewObject(ctx);

    if (hdrs_opt) |hdrs| if (hdrs.fields) |fields_ptr| {
        const fields = fields_ptr[0..hdrs.count];

        // First-occurrence name list for the `header_names` entry.
        // Deduped the same way the property table dedupes (duplicate
        // names re-define in place).
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(state.allocator);

        for (fields, 0..) |f, i| {
            const name = f.name[0..f.name_len];

            // Skip pseudo-headers (`:method`, `:path`, `:scheme`,
            // `:authority`) — already exposed as `request.method` /
            // `request.path` etc. — and the IP transport headers
            // (reserved_headers.zig STRIPPED_IP_HEADERS).
            if (name.len > 0 and name[0] == ':') continue;
            if (isStrippedIpHeader(name)) continue;

            // Strip platform-reserved internal headers (`x-rewind-*`,
            // `x-rove-internal-*`) so the customer handler can neither read
            // internal topology nor spoof a header an internal endpoint
            // might trust. See `reserved_headers.zig`. (`x-rove-correlation-id`
            // is NOT reserved and stays visible.)
            if (reserved_headers.isReservedInternalHeader(name)) continue;

            // The getter's magic is the FIELD INDEX — no per-getter
            // heap state; the getter reads name+value back out of
            // `state.req_headers` on call. Duplicate names: the later
            // define replaces the accessor → its (later) index wins.
            definePropertyGetter(
                ctx,
                headers_obj,
                name,
                c.JS_NewCFunction2(ctx, @ptrCast(&jsHeaderGetter), "header", 0, c.JS_CFUNC_getter_magic, @intCast(i)),
            );

            if (state.readset != null) {
                var seen = false;
                for (names.items) |n| {
                    if (std.mem.eql(u8, n, name)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) names.append(state.allocator, name) catch {};
            }
        }

        // Record the enumerable name set once per activation —
        // `Object.keys` / `for..in` observe it without firing any
        // getter, so replay needs it independently of the values.
        if (state.readset != null) {
            const json = stringSliceToJson(state.allocator, names.items) catch |err| blk: {
                std.log.warn("rove-js request_reads: header_names json: {s}", .{@errorName(err)});
                break :blk null;
            };
            if (json) |j| {
                defer state.allocator.free(j);
                recordRequestRead(state, .header_names, "", j);
            }
        }
    };

    _ = c.JS_SetPropertyStr(ctx, req_obj, "headers", headers_obj);
}

/// JSON-encode a list of strings as a JSON array. Caller frees.
fn stringSliceToJson(
    allocator: std.mem.Allocator,
    items: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    {
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &buf);
        defer buf = aw.toArrayList();
        try std.json.Stringify.value(items, .{}, &aw.writer);
    }
    return try buf.toOwnedSlice(allocator);
}

/// `request.headers.<name>` accessor (JS_CFUNC_getter_magic). The
/// magic int is the index into `state.req_headers.fields`. Live mode
/// only — replay builds its own getter surface in JS from the tape
/// (web/replay/_static/request-replay.mjs).
fn jsHeaderGetter(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    magic: c_int,
) callconv(.c) c.JSValue {
    _ = this_val;
    const state = getState(ctx);
    const hdrs = state.req_headers orelse return js_undefined;
    const fields_ptr = hdrs.fields orelse return js_undefined;
    const idx: usize = @intCast(magic);
    std.debug.assert(idx < hdrs.count);
    const f = fields_ptr[idx];
    const name = f.name[0..f.name_len];
    const value = f.value[0..f.value_len];
    recordRequestRead(state, .header_value, name, value);
    return c.JS_NewStringLen(ctx, value.ptr, value.len);
}

/// Self-replace an accessor with a data property holding `value` and
/// return it. The define consumes one ref; the returned value is a
/// fresh dup for the caller. Keeps object identity stable across
/// repeat reads (`request.cookies === request.cookies`) and avoids
/// re-materializing large bodies per access.
fn selfReplaceWithValue(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    name: [*:0]const u8,
    value: c.JSValue,
) c.JSValue {
    _ = c.JS_DefinePropertyValueStr(ctx, this_val, name, c.JS_DupValue(ctx, value), c.JS_PROP_C_W_E);
    return value;
}

/// `request.bytes` accessor (plain inbound only — the other payload
/// kinds define `bytes` as a data property at install): same
/// read-recording as `jsBodyGetter` — the two record the SAME body-read
/// fact, so reading either (or both) keeps the tape/log body reference
/// alive exactly once — then self-replaces with a Uint8Array of the raw
/// payload (decisions.md §4.11).
fn jsBytesGetter(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    magic: c_int,
) callconv(.c) c.JSValue {
    _ = magic;
    const state = getState(ctx);
    if (state.readset) |rs| rs.body_read = true;
    recordRequestRead(state, .body_read, "", "");
    const bytes_val = c.JS_NewUint8ArrayCopy(ctx, state.req_body.ptr, state.req_body.len);
    return selfReplaceWithValue(ctx, this_val, "bytes", bytes_val);
}

/// `request.cookies` accessor: counts as a read of the whole
/// `cookie` header (recorded via the same `header_value` kind a
/// direct `request.headers.cookie` read uses, so the two dedupe
/// against each other), parses it (RFC 6265), and self-replaces with
/// the parsed object.
fn jsCookiesGetter(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    magic: c_int,
) callconv(.c) c.JSValue {
    _ = magic;
    const state = getState(ctx);
    const cookies_obj = c.JS_NewObject(ctx);

    // Last `cookie` field wins — same rule as duplicate header
    // values generally (RFC 7230 says clients SHOULD send one).
    var cookie_value: []const u8 = "";
    var have_cookie = false;
    if (state.req_headers) |hdrs| if (hdrs.fields) |fields_ptr| {
        for (fields_ptr[0..hdrs.count]) |f| {
            if (std.mem.eql(u8, f.name[0..f.name_len], "cookie")) {
                cookie_value = f.value[0..f.value_len];
                have_cookie = true;
            }
        }
    };
    if (have_cookie) {
        recordRequestRead(state, .header_value, "cookie", cookie_value);
        parseCookies(ctx.?, state, cookies_obj, cookie_value);
    }
    return selfReplaceWithValue(ctx, this_val, "cookies", cookies_obj);
}

/// `request.ip` accessor — the MASKED client IP (IPv4: last octet
/// zeroed; IPv6: /48 kept, rest zeroed), or null when no edge proxy
/// reported one (or it didn't parse). Masked is the default surface:
/// coarse geo / abuse heuristics work, and the tape stays clear of
/// precise personal data. The raw IP is `request.unmaskedIp()`.
fn jsIpGetter(
    ctx: ?*c.JSContext,
    this_val: c.JSValue,
    magic: c_int,
) callconv(.c) c.JSValue {
    _ = magic;
    const state = getState(ctx);
    var buf: [64]u8 = undefined;
    const masked: ?[]const u8 = if (deriveClientIp(state.req_headers)) |raw|
        maskIp(&buf, raw)
    else
        null;
    recordRequestRead(state, .ip_masked, "", masked orelse "");
    const val = if (masked) |m| c.JS_NewStringLen(ctx, m.ptr, m.len) else js_null;
    return selfReplaceWithValue(ctx, this_val, "ip", val);
}

/// `request.unmaskedIp()` — the deliberate raw-IP escalation. A
/// method, not a property: the call shape is the "do you need this?"
/// friction, and the call is the taped, controller-responsibility
/// moment (the raw IP lands on the replay tape). Returns null when
/// no edge proxy reported a client IP.
fn jsUnmaskedIp(
    ctx: ?*c.JSContext,
    this: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    _ = this;
    _ = argc;
    _ = argv;
    const state = getState(ctx);
    const raw = deriveClientIp(state.req_headers);
    recordRequestRead(state, .ip_raw, "", raw orelse "");
    if (raw) |r| return c.JS_NewStringLen(ctx, r.ptr, r.len);
    return js_null;
}

/// Derive the client IP from the wire headers: the last
/// `cf-connecting-ip` value if present (the edge's authoritative
/// single-value header), else the RIGHTMOST entry of the last
/// `x-forwarded-for` header — the entry the trusted edge appended;
/// anything a spoofing client sent rides further left. Returns a
/// trimmed slice borrowing the header storage, or null when neither
/// header is present / the result is empty.
fn deriveClientIp(hdrs_opt: ?h2.ReqHeaders) ?[]const u8 {
    const hdrs = hdrs_opt orelse return null;
    const fields_ptr = hdrs.fields orelse return null;
    var cf: ?[]const u8 = null;
    var xff: ?[]const u8 = null;
    for (fields_ptr[0..hdrs.count]) |f| {
        const name = f.name[0..f.name_len];
        if (std.mem.eql(u8, name, "cf-connecting-ip")) {
            cf = f.value[0..f.value_len];
        } else if (std.mem.eql(u8, name, "x-forwarded-for")) {
            xff = f.value[0..f.value_len];
        }
    }
    const candidate: []const u8 = if (cf) |v|
        v
    else if (xff) |v| blk: {
        const comma = std.mem.lastIndexOfScalar(u8, v, ',');
        break :blk if (comma) |i| v[i + 1 ..] else v;
    } else return null;
    const trimmed = std.mem.trim(u8, candidate, " \t");
    return if (trimmed.len == 0) null else trimmed;
}

// The mask rule lives in `ip_mask.zig` — shared with the sim's world
// build (src/replay/root.zig derives the masked channel from an authored
// ip), so the two surfaces can't drift.
const maskIp = @import("ip_mask.zig").maskIp;

/// RFC 6265 cookie-string parser: semicolon-separated `name=value`
/// pairs, optional whitespace around the separator. Sets each into
/// `cookies_obj` as a string property. Empty `cookie_value` → no-op.
fn parseCookies(
    ctx: *c.JSContext,
    state: *DispatchState,
    cookies_obj: c.JSValue,
    cookie_value: []const u8,
) void {
    if (cookie_value.len == 0) return;

    var it = std.mem.splitScalar(u8, cookie_value, ';');
    while (it.next()) |raw| {
        const pair = std.mem.trim(u8, raw, " \t");
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const name = std.mem.trim(u8, pair[0..eq], " \t");
        // Trim whitespace from the value too. RFC 6265 strictly only
        // trims when parsing Set-Cookie, but every practical Cookie
        // parser (browsers, Express, Hono) trims both sides — matches
        // customer expectations.
        const value = std.mem.trim(u8, pair[eq + 1 ..], " \t");
        if (name.len == 0) continue;

        const name_z = state.allocator.allocSentinel(u8, name.len, 0) catch continue;
        defer state.allocator.free(name_z);
        @memcpy(name_z, name);

        _ = c.JS_SetPropertyStr(
            ctx,
            cookies_obj,
            name_z.ptr,
            c.JS_NewStringLen(ctx, value.ptr, value.len),
        );
    }
}

// ── request.tag(key, value) ─────────────────────────────────────────
//
// Attach a low-cardinality index tag to this request's log record.
// Indexed by the log-server so a later query can filter
// `?tag.<key>=<value>` (and the `/session/{id}` sugar route filters
// `tag.session`). The browser-agent tags its connection
// `session = <app sid>` so the brain's `getReplay` pulls just this
// session's activations. Bounded + fail-loud (a cap/charset violation
// is a handler bug → throws, surfacing in the record's exception/console
// rather than silently dropping). Re-tagging an existing key updates it.
fn jsRequestTag(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const state = getState(ctx);
    if (argc < 2 or !c.JS_IsString(argv[0]) or !c.JS_IsString(argv[1])) {
        _ = c.JS_ThrowTypeError(ctx, "request.tag(key, value) requires two string arguments");
        return js_exception;
    }
    const key = valueToOwnedString(state, ctx, argv[0]) catch return js_exception;
    defer state.allocator.free(key);
    const val = valueToOwnedString(state, ctx, argv[1]) catch return js_exception;
    defer state.allocator.free(val);

    if (key.len == 0 or key.len > log_mod.MAX_TAG_KEY_LEN) {
        _ = c.JS_ThrowTypeError(ctx, "request.tag: key length must be 1..32 bytes");
        return js_exception;
    }
    if (key[0] == '_') {
        _ = c.JS_ThrowTypeError(ctx, "request.tag: keys starting with '_' are reserved");
        return js_exception;
    }
    for (key) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_';
        if (!ok) {
            _ = c.JS_ThrowTypeError(ctx, "request.tag: key must match [a-z0-9_]");
            return js_exception;
        }
    }
    if (val.len == 0 or val.len > log_mod.MAX_TAG_VALUE_LEN) {
        _ = c.JS_ThrowTypeError(ctx, "request.tag: value length must be 1..64 bytes");
        return js_exception;
    }
    for (val) |ch| {
        if (ch < 0x20) {
            _ = c.JS_ThrowTypeError(ctx, "request.tag: value must not contain control characters");
            return js_exception;
        }
    }

    // Update in place if the key is already set this activation.
    for (state.tags.items) |*t| {
        if (std.mem.eql(u8, t.key, key)) {
            const new_v = state.allocator.dupe(u8, val) catch return js_exception;
            state.allocator.free(t.value);
            t.value = new_v;
            return js_undefined;
        }
    }
    // New key — enforce the per-record cap (fail loud, don't truncate).
    if (state.tags.items.len >= log_mod.MAX_TAGS) {
        _ = c.JS_ThrowTypeError(ctx, "request.tag: too many tags (max 4 per request)");
        return js_exception;
    }
    const k = state.allocator.dupe(u8, key) catch return js_exception;
    const v = state.allocator.dupe(u8, val) catch {
        state.allocator.free(k);
        return js_exception;
    };
    state.tags.append(state.allocator, .{ .key = k, .value = v }) catch {
        state.allocator.free(k);
        state.allocator.free(v);
        return js_exception;
    };
    return js_undefined;
}
