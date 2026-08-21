// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! `export-fixture` — transcode a captured recording (the base64-tape fixture
//! `rewind pull` writes, which `rewind replay` consumes) into a **declarative
//! world** (the authored form `rewind sim` consumes). This is the bridge from
//! the replay corner to the sim corner: "what happened in prod" becomes an
//! editable, offline, fail-loud regression scenario
//! (`docs/architecture/replay-and-sim.md` §6).
//!
//! A recording and an authored world are the same world, differently sourced
//! (§1), so this is a transcode, not a re-run. The non-obvious part is the KV
//! channel: the recording is an **ordered cursor** of reads (get/prefix +
//! outcome), but a declarative world is a **closed-world key→value map**. The
//! map seeds the *initial* value per key (the first taped read) and the rows a
//! prefix scan returned; read-modify-read is reproduced by the sim host's
//! write-through overlay. A recorded `not_found` read is simply omitted — the
//! key isn't in the map, so replay resolves it to not_found (a *new* read the
//! original never made surfaces the same way, visible in the effect log).
//!
//! A payload over the inline cap is not on the tape: the entry keeps a POINTER
//! (a body-pool slice, or a slice of one of the tenant's content-addressed
//! objects) and the bytes stay in object storage. Nothing here can follow
//! either pointer — the puller resolves them through the log-server's body door
//! and inlines the bytes as `resolved_bodies` (`outOfLinePayloads` names what
//! to fetch). When one is still unreachable the emitted world OMITS
//! `request.body`, so a captured world's read-your-tape refusal fires on the
//! first payload read instead of the handler running against `""`. A missing
//! input must present as a refusal, never as a plausible empty value.
//!
//! Scope: faithful for `inbound` activations, `wake_batch` (
//! the fired-watch batch rides `activation_bytes`, ctx rides
//! `trigger_payload`, the resolved export rides `export`), and
//! `send_callback` (the whole callee-outcome envelope rides
//! `trigger_payload`; split here into the flattened result surface + the
//! metadata bag + the bare threaded ctx). `fetch_chunk` transcodes its
//! whole-body case (the matrix smoke proves it) but streamed multi-chunk
//! stays best-effort; other non-inbound activations lose their result
//! surface (`docs/architecture/replay-and-sim.md` §5 G1/G3) — the caller is warned via
//! `isFaithfulTranscode`.

const std = @import("std");
const decode = @import("tape_decode.zig");
const reserved = @import("rove-reserved");
const world = @import("world.zig"); // test-only: round-trip the emitted world

pub const Error = error{
    BadFixture,
    WriteFailed, // std.Io.Writer.Allocating sink surfaces OOM as WriteFailed
} || decode.Error || std.mem.Allocator.Error;

/// True when the pulled fixture's activation can be transcoded faithfully
/// — its whole input rides the decoded channels. The inbound family, plus
/// `wake_batch` (ctx via trigger_payload, the fired-watch
/// batch via activation_bytes, the resolved export via `export`) and
/// `send_callback` (the callee-outcome envelope via
/// trigger_payload, the resolved export via `export`).
pub fn isFaithfulTranscode(activation: []const u8) bool {
    return std.mem.eql(u8, activation, "inbound") or
        std.mem.eql(u8, activation, "inbound_headers") or
        std.mem.eql(u8, activation, "wake_batch") or
        std.mem.eql(u8, activation, "send_callback");
}

/// Parse the activation field of a pulled fixture (for the caller's warning).
pub fn activationOf(a: std.mem.Allocator, fixture_json: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, fixture_json, .{}) catch return "inbound";
    if (parsed.value != .object) return "inbound";
    return jStr(parsed.value.object, "activation") orelse "inbound";
}

/// Transcode `fixture_json` (a `rewind pull` fixture) into a declarative world
/// JSON, written to `out`.
pub fn transcode(a: std.mem.Allocator, fixture_json: []const u8, out: *std.ArrayList(u8)) Error!void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, fixture_json, .{}) catch
        return Error.BadFixture;
    if (parsed.value != .object) return Error.BadFixture;
    const obj = parsed.value.object;

    const entry = jStr(obj, "entry") orelse "index.mjs";
    const activation = jStr(obj, "activation") orelse "inbound";
    const req = if (obj.get("request")) |v| (if (v == .object) v.object else null) else null;
    const method = if (req) |r| (jStr(r, "method") orelse "GET") else "GET";
    const path = if (req) |r| (jStr(r, "path") orelse "/") else "/";
    const host = if (req) |r| (jStr(r, "host") orelse "") else "";

    const export_name = jStr(obj, "export"); // recorded resolved export ({on}) — G3
    const recorded = if (obj.get("recorded")) |v| (if (v == .object) v.object else null) else null;

    const tapes = if (obj.get("tapes")) |v| (if (v == .object) v.object else null) else null;
    const kv_entries: []const decode.KvEntry = blk: {
        const b64 = if (tapes) |t| jStr(t, "kv_b64") else null;
        if (b64) |s| break :blk try decode.decodeKv(a, try b64decode(a, s));
        break :blk &.{};
    };
    const reads: []const decode.RequestReadEntry = blk: {
        const b64 = if (tapes) |t| jStr(t, "request_reads_b64") else null;
        if (b64) |s| break :blk try decode.decodeRequestReads(a, try b64decode(a, s));
        break :blk &.{};
    };
    const body_bytes: ?[]const u8 = blk: {
        const b64 = if (tapes) |t| jStr(t, "request_body_b64") else null;
        if (b64) |s| break :blk try b64decode(a, s);
        break :blk null;
    };
    // A corrupt or version-mismatched channel is a decode ERROR, not zero
    // entries: swallowing it turns an unreadable recording into a world that
    // asserts the activation had no fetch result and no trigger payload — a
    // fixture that passes while proving nothing.
    const fetch_resp: []const decode.FetchResponseEntry = blk: {
        const b64 = if (tapes) |t| jStr(t, "fetch_responses_b64") else null;
        if (b64) |s| break :blk try decode.decodeFetchResponses(a, try b64decode(a, s));
        break :blk &.{};
    };
    const trigger: []const decode.TriggerPayloadEntry = blk: {
        const b64 = if (tapes) |t| jStr(t, "trigger_payload_b64") else null;
        if (b64) |s| break :blk try decode.decodeTriggerPayload(a, try b64decode(a, s));
        break :blk &.{};
    };
    // Out-of-line payloads the puller already fetched through the log-server's
    // body door, keyed by channel then RAW entry ordinal.
    const resolved_fetch = resolvedChannel(obj, "fetch_responses");
    const resolved_trigger = resolvedChannel(obj, "trigger_payload");
    const activation_bytes: ?[]const u8 = blk: {
        const b64 = if (tapes) |t| jStr(t, "activation_bytes_b64") else null;
        if (b64) |s| break :blk try b64decode(a, s);
        break :blk null;
    };
    const seed = jStr(obj, "seed");
    const ts_ns = jStr(obj, "timestamp_ns");
    // The engine word's high bit = the request COMPLETED under the GC
    // arena regime (qjs version.zig ENGINE_ARENA_GC_BIT). Carry it so
    // the driver replays under the same regime — a GC-completed churny
    // request OOMs under bump.
    const arena_gc = blk: {
        const ev = obj.get("js_engine_version") orelse break :blk false;
        if (ev != .integer) break :blk false;
        break :blk (ev.integer & 0x8000) != 0;
    };

    // ── KV: get(ok) → seed the map; prefix → seed the map with the returned
    // rows (so a replay-time re-scan finds them). Closed world: a not_found read
    // is simply omitted (the key isn't in the map → not_found on replay). No
    // exact prefix-rows are kept: replay reconstructs the scan from the map
    // (+ the handler's own re-executed writes), honoring cursor/limit. ──
    var seen = std.StringHashMapUnmanaged(void){};
    var kv = std.ArrayList(KvPair){};
    // Guard refusals the capture recorded (KvOutcome.refused; value = the
    // code) → the world's `kv_refusals`, so replay throws the recorded
    // verdict instead of re-deciding the rules (outcome-replay).
    var refusals = std.ArrayList(struct { op: []const u8, key: []const u8, code: []const u8 }){};
    // Reads the capture's kv budget dropped (`KvOutcome.elided`) → the world's
    // `kv_elided`, which replay REFUSES. Omitting them instead would leave the
    // key absent from the map, and a closed-world miss answers `not_found` —
    // a plausible value where the live run read real data.
    // `sealed` distinguishes a value that is STILL THERE and merely
    // unopenable from one the budget dropped. Both refuse, and must —
    // serving a plausible value where the live run saw real data is the
    // failure the discipline exists to prevent — but a reader told the
    // wrong one either reports an erasure that did not happen or hides one
    // that did.
    var elided = std.ArrayList(struct {
        op: []const u8,
        key: []const u8,
        bytes: u64,
        sealed: bool = false,
    }){};
    for (kv_entries) |e| switch (e.op) {
        .get => {
            if (seen.contains(e.key)) continue; // re-read / post-write — overlay reproduces it
            try seen.put(a, e.key, {});
            switch (e.outcome) {
                // A SEALED value cannot travel into the world at all: the
                // world is JSON, and JSON strings are Unicode text, so the
                // `0xFF` marker has no representation there — the same
                // property that makes the marker unambiguous makes it
                // unencodable. Classifying here, where the tape's raw bytes
                // still exist, is therefore the only place this decision
                // can be made; passing the value through would silently
                // transcode it into different bytes.
                .ok => if (reserved.isSealedValue(e.value)) try elided.append(a, .{
                    .op = "get",
                    .key = e.key,
                    .bytes = e.value.len,
                    .sealed = true,
                }) else try kv.append(a, .{ .key = e.key, .value = e.value }),
                .elided => try elided.append(a, .{
                    .op = "get",
                    .key = e.key,
                    .bytes = std.fmt.parseInt(u64, e.value, 10) catch 0,
                }),
                .not_found, .err, .refused => {}, // omit — closed world resolves to not_found
            }
        },
        .prefix => {
            // An elided page carries no rows by construction (all-or-nothing:
            // a partial page would replay as a complete, shorter one).
            if (e.outcome == .elided) {
                try elided.append(a, .{
                    .op = "prefix",
                    .key = e.key,
                    .bytes = std.fmt.parseInt(u64, e.value, 10) catch 0,
                });
                continue;
            }
            for (e.results) |row| {
                if (seen.contains(row.key)) continue;
                try seen.put(a, row.key, {});
                // One sealed row refuses the whole PAGE, not just itself: a
                // page short by a row replays as a complete, shorter one,
                // which is the all-or-nothing rule the elided page above
                // already follows.
                if (reserved.isSealedValue(row.value)) {
                    try elided.append(a, .{
                        .op = "prefix",
                        .key = e.key,
                        .bytes = row.value.len,
                        .sealed = true,
                    });
                    break;
                }
                try kv.append(a, .{ .key = row.key, .value = row.value });
            }
        },
        .set, .delete => {
            if (e.outcome == .refused) {
                try refusals.append(a, .{
                    .op = if (e.op == .delete) "delete" else "set",
                    .key = e.key,
                    .code = e.value,
                });
            }
        },
    };

    // ── request surface: request_reads ──
    var headers = std.ArrayList(decode.RequestReadEntry){};
    var ip: ?[]const u8 = null;
    // The operator-root verdict, present iff the recorded activation was
    // platform-bound AND read it. `""` is a recorded false, not an absence —
    // absence means `request.rewind` never existed, so the world must not
    // declare it. The bearer is not on the tape and never was
    // (`src/js/reserved_headers.zig` PLATFORM_CREDENTIAL_HEADERS).
    var is_root: ?bool = null;
    var body_read = body_bytes != null;
    for (reads) |r| switch (r.kind) {
        .header_value => try headers.append(a, r),
        .body_read => body_read = true,
        .ip_masked => ip = r.value,
        .root_verdict => is_root = std.mem.eql(u8, r.value, "1"),
        .header_names, .ip_raw => {},
    };

    // ── fetch result (fetch_chunk): status/done/fetchId + the body. No `ok`
    // — status is the single success signal (#7); the request surface has no
    // `ok` field (world.zig REQ_KEYS), so emitting one makes the world
    // malformed and replay produces nothing. ──
    var fetch_status: ?u16 = null;
    var fetch_done: ?bool = null;
    var fetch_id: ?[]const u8 = null;
    var fetch_body: ?[]const u8 = null;
    if (fetch_resp.len != 0) {
        // Every chunk contributes or the body is a LIE: a partly-spilled
        // multi-chunk fetch concatenated from the carried chunks alone is
        // plausible-but-short, which replays as real data. One unreachable
        // chunk sinks the whole body.
        var body = std.ArrayList(u8){};
        var whole = true;
        for (fetch_resp, 0..) |e, i| {
            if (entryBytes(a, decode.fetchPayloadFate(e), resolved_fetch, i)) |b|
                try body.appendSlice(a, b)
            else
                whole = false;
        }
        if (whole) fetch_body = body.items;
        // The event metadata is recorded on the entry itself, so it stays
        // true even when the payload is unreachable.
        const last = fetch_resp[fetch_resp.len - 1];
        fetch_id = last.fetch_id;
        fetch_done = last.final;
        if (last.final) fetch_status = last.terminal_status;
    }
    // The trigger_payload entry: an inbound activation's request body, else a
    // resume's `{"ctx":…}` envelope. Null when the entry names bytes that are
    // not reachable from the record.
    const trigger_env: ?[]const u8 = if (trigger.len != 0)
        entryBytes(a, decode.triggerPayloadFate(trigger[0]), resolved_trigger, 0)
    else
        null;
    const trigger_is_body = std.mem.eql(u8, activation, "inbound") or
        std.mem.eql(u8, activation, "inbound_headers") or
        std.mem.eql(u8, activation, "inbound_chunk");

    // request.body: the fetch result body (fetch_chunk) else the inbound body.
    // `null` here means the payload is UNREACHABLE, not empty — the world then
    // omits `request.body` entirely, which leaves a captured world's payload
    // accessors on their read-your-tape refusal (epilogue's `miss`) instead of
    // serving `""` as if the handler had really read nothing.
    const eff_body: ?[]const u8 = blk: {
        if (fetch_resp.len != 0) break :blk fetch_body;
        if (body_bytes) |b| break :blk b;
        // A body over the inline cap is absent from `request_body_b64` and
        // present only as the trigger entry's pointer, so THAT entry — not the
        // missing inline field — decides between "empty" and "elsewhere".
        if (trigger_is_body and trigger.len != 0) break :blk trigger_env;
        // Nothing out of line: a read body with no recorded bytes was empty.
        break :blk if (body_read) "" else null;
    };

    // ── ctx (from the trigger_payload `{"ctx": …}` envelope) ──
    const ctx_json: ?[]const u8 = blk: {
        const env = trigger_env orelse break :blk null;
        if (env.len == 0) break :blk null;
        break :blk extractCtx(a, env);
    };

    // ── send_callback: the trigger_payload envelope IS the Msg
    // — `{"ctx":{result, context}}` for a result delivery (a `webhook.send`
    // / `blob.put` `{on}` hop or a held-sync resume). Split it exactly the
    // way prod's install hoist does (globals.zig): `result` → the flattened
    // surface (`request.status`/`done`/body + the `request.activation`
    // metadata bag), `context` → the world `ctx`. A bare-ctx envelope (no
    // `result` object — an internal chained hop) keeps the whole-ctx lift
    // `ctx_json` already did, matching the hoist's fallback. ──
    var scb_result: ?std.json.ObjectMap = null;
    var scb_ctx_json: ?[]const u8 = null;
    if (std.mem.eql(u8, activation, "send_callback") and
        trigger_env != null and trigger_env.?.len != 0)
    scb: {
        const env = std.json.parseFromSlice(std.json.Value, a, trigger_env.?, .{}) catch break :scb;
        if (env.value != .object) break :scb;
        const cv = env.value.object.get("ctx") orelse break :scb;
        if (cv != .object) break :scb;
        const rv = cv.object.get("result") orelse break :scb;
        if (rv != .object) break :scb;
        scb_result = rv.object;
        if (cv.object.get("context")) |cx| {
            scb_ctx_json = std.json.Stringify.valueAlloc(a, cx, .{}) catch null;
        }
    }
    // With a result split, the world ctx is the bare threaded `context`
    // (prod's `request.ctx`), not the whole `{result, context}` envelope.
    const eff_ctx_json: ?[]const u8 = if (scb_result != null) scb_ctx_json else ctx_json;

    // ── ws_message frame: activation_bytes = [opcode][data] ──
    var ws_opcode: ?u8 = null;
    var ws_data: ?[]const u8 = null;
    if (std.mem.eql(u8, activation, "ws_message")) {
        if (activation_bytes) |ab| if (ab.len >= 1) {
            ws_opcode = ab[0];
            ws_data = ab[1..];
        };
    }

    // ── wake_batch: activation_bytes = the wakes JSON —
    // the drained fired-watch batch, recorded verbatim in the JS-facing
    // encoding by `captureWakeBatchTapes`. Passed through into the
    // world's `request.activation` bag so replay observes the same
    // `request.activation.wakes` the live hop did.
    var wake_batch_json: ?[]const u8 = null;
    if (std.mem.eql(u8, activation, "wake_batch")) {
        if (activation_bytes) |ab| if (ab.len >= 1 and ab[0] == '[') {
            wake_batch_json = ab;
        };
    }

    // ── emit the world ──
    var aw = std.Io.Writer.Allocating.fromArrayList(a, out);
    defer out.* = aw.toArrayList();
    const w = &aw.writer;

    try w.writeAll("{\n  \"entry\": ");
    try jsonStr(w, entry);
    try w.writeAll(",\n  \"activation\": ");
    try jsonStr(w, activation);
    if (export_name) |e| {
        try w.writeAll(",\n  \"export\": ");
        try jsonStr(w, e);
    }
    try w.writeAll(",\n  \"request\": {\n    \"method\": ");
    try jsonStr(w, method);
    try w.writeAll(", \"path\": ");
    try jsonStr(w, path);
    try w.writeAll(", \"host\": ");
    try jsonStr(w, host);
    if (headers.items.len != 0) {
        try w.writeAll(",\n    \"headers\": {");
        for (headers.items, 0..) |h, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll(" ");
            try jsonStr(w, h.name);
            try w.writeAll(": ");
            try jsonStr(w, h.value);
        }
        try w.writeAll(" }");
    }
    // Emitted only with bytes in hand. An absent `request.body` is what makes
    // an unreachable payload REFUSE on replay rather than read as empty.
    if (eff_body) |b| {
        try w.writeAll(",\n    \"body\": ");
        try jsonStr(w, b);
    }
    if (ip) |v| {
        try w.writeAll(",\n    \"ip\": ");
        try jsonStr(w, v);
    }
    if (is_root) |b| try w.writeAll(if (b) ",\n    \"isRoot\": true" else ",\n    \"isRoot\": false");
    // flattened fetch-result surface (fetch_chunk) — no `ok` (see above)
    if (fetch_status) |s| try w.print(",\n    \"status\": {d}", .{s});
    if (fetch_done) |b| try w.writeAll(if (b) ",\n    \"done\": true" else ",\n    \"done\": false");
    if (fetch_id) |id| {
        try w.writeAll(",\n    \"fetchId\": ");
        try jsonStr(w, id);
    }
    // wake batch → request.activation {kind:"wake_batch", wakes:[…]}
    // (the same bag shape an authored `rewind:test` world carries).
    if (wake_batch_json) |wj| {
        try w.writeAll(",\n    \"activation\": { \"kind\": \"wake_batch\", \"wakes\": ");
        try w.writeAll(wj);
        try w.writeAll(" }");
    }
    // send_callback result → the flattened callee-outcome surface +
    // the request.activation metadata bag — the same shape
    // an authored `rewind:test` sendCallback world carries. The result
    // bytes ride base64url-no-pad in the envelope (`body_b64`); the
    // world carries them as standard-base64 `bodyB64` so replay's
    // `request.bytes` is byte-exact. A `body`-string-only producer
    // (held-sync deadline events) passes through as a string body.
    if (scb_result) |res| {
        if (res.get("status")) |sv| {
            if (sv == .integer) try w.print(",\n    \"status\": {d}", .{sv.integer});
        }
        try w.writeAll(",\n    \"done\": true");
        if (res.get("body_truncated")) |btv| {
            if (btv == .bool) try w.writeAll(if (btv.bool) ",\n    \"bodyTruncated\": true" else ",\n    \"bodyTruncated\": false");
        }
        body: {
            if (res.get("body_b64")) |bv| {
                if (bv == .string) {
                    const dec = std.base64.url_safe_no_pad.Decoder;
                    const n = dec.calcSizeForSlice(bv.string) catch break :body;
                    const raw = try a.alloc(u8, n);
                    dec.decode(raw, bv.string) catch break :body;
                    try w.writeAll(",\n    \"bodyB64\": ");
                    try jsonB64(a, w, raw);
                    break :body;
                }
            }
            if (res.get("body")) |bv| {
                if (bv == .string) {
                    try w.writeAll(",\n    \"body\": ");
                    try jsonStr(w, bv.string);
                }
            }
        }
        // Delivery metadata → the bag, passed through as recorded
        // (absent fields stay absent → `undefined` on replay, matching
        // prod's hoist; `ok` is deliberately NOT surfaced — status is
        // the single success signal).
        try w.writeAll(",\n    \"activation\": { \"kind\": \"send_callback\"");
        const meta_keys = [_][]const u8{ "attempts", "error", "id", "headers", "hash" };
        for (meta_keys) |mk| {
            if (res.get(mk)) |mv| {
                try w.writeAll(", ");
                try jsonStr(w, mk);
                try w.writeAll(": ");
                try std.json.Stringify.value(mv, .{}, w);
            }
        }
        try w.writeAll(" }");
    }
    // ws frame → request.activation {opcode, data | dataB64}
    if (ws_opcode) |op| {
        try w.print(",\n    \"activation\": {{ \"opcode\": {d}, ", .{op});
        if (op == 2) { // binary → base64 (Uint8Array)
            try w.writeAll("\"dataB64\": ");
            try jsonB64(a, w, ws_data orelse "");
        } else {
            try w.writeAll("\"data\": ");
            try jsonStr(w, ws_data orelse "");
        }
        try w.writeAll(" }");
    }
    try w.writeAll("\n  }");
    if (eff_ctx_json) |cj| {
        try w.writeAll(",\n  \"ctx\": ");
        try w.writeAll(cj);
    }
    try w.writeAll(",\n  \"kv\": {");
    for (kv.items, 0..) |p, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("\n    ");
        try jsonStr(w, p.key);
        try w.writeAll(": ");
        try jsonStr(w, p.value);
    }
    try w.writeAll(if (kv.items.len != 0) "\n  }" else "}");
    if (refusals.items.len != 0) {
        try w.writeAll(",\n  \"kv_refusals\": [");
        for (refusals.items, 0..) |r, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll("\n    { \"op\": ");
            try jsonStr(w, r.op);
            try w.writeAll(", \"key\": ");
            try jsonStr(w, r.key);
            try w.writeAll(", \"code\": ");
            try jsonStr(w, r.code);
            try w.writeAll(" }");
        }
        try w.writeAll("\n  ]");
    }
    if (elided.items.len != 0) {
        try w.writeAll(",\n  \"kv_elided\": [");
        for (elided.items, 0..) |e, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll("\n    { \"op\": ");
            try jsonStr(w, e.op);
            try w.writeAll(", \"key\": ");
            try jsonStr(w, e.key);
            try w.print(", \"bytes\": {d}", .{e.bytes});
            if (e.sealed) try w.writeAll(", \"sealed\": true");
            try w.writeAll(" }");
        }
        try w.writeAll("\n  ]");
    }
    // The recorded status becomes an `expected` assertion — replay verifies the
    // re-run reproduces it.
    if (recorded) |r| {
        if (r.get("status")) |sv| if (sv == .integer) {
            try w.print(",\n  \"expected\": {{ \"response\": {{ \"status\": {d} }} }}", .{sv.integer});
        };
    }
    if (seed) |s| {
        const n = std.fmt.parseInt(u64, s, 10) catch 0;
        try w.print(",\n  \"seed\": {d}", .{n});
    }
    if (arena_gc) try w.writeAll(",\n  \"arena_gc\": true");
    // Mark the world's provenance: transcoded-from-capture worlds keep the
    // strict read-your-tape posture and the retired driver-only surfaces
    // (`request.body`, `on.*`) so pinned old deployments replay; authored
    // worlds (no flag) mirror the live surface (world.zig `captured`).
    try w.writeAll(",\n  \"captured\": true");
    if (ts_ns) |s| {
        const ns = std.fmt.parseInt(i64, s, 10) catch 0;
        if (ns > 0) try w.print(",\n  \"now_ms\": {d}", .{@divTrunc(ns, std.time.ns_per_ms)});
    }
    // sources: pass through verbatim so the world is self-contained.
    if (obj.get("sources")) |sv| {
        try w.writeAll(",\n  \"sources\": ");
        try std.json.Stringify.value(sv, .{}, w);
    }
    try w.writeAll("\n}\n");
}

/// The `resolved_bodies.<channel>` map a puller writes into the fixture:
/// `{ "<raw entry ordinal>": "<standard base64>" }`, addressed exactly the way
/// the log-server's body door is (channel + raw ordinal, never a raw
/// a `BodyRef` — see `outOfLinePayloads`).
fn resolvedChannel(obj: std.json.ObjectMap, channel: []const u8) ?std.json.ObjectMap {
    const rb = obj.get("resolved_bodies") orelse return null;
    if (rb != .object) return null;
    const ch = rb.object.get(channel) orelse return null;
    return if (ch == .object) ch.object else null;
}

/// The bytes for one tape entry: carried on the entry, else the resolution the
/// puller inlined, else null — "this payload is named by the record but is not
/// reachable from it". Nothing offline can follow a pool or content pointer, so
/// null is the honest answer, and every caller must express it as an absence
/// rather than as empty bytes.
fn entryBytes(
    a: std.mem.Allocator,
    fate: decode.PayloadFate,
    resolved: ?std.json.ObjectMap,
    index: usize,
) ?[]const u8 {
    switch (fate) {
        .carried => |b| return b,
        .empty => return "",
        // `not_recorded` is unresolvable at the door too (the payload was
        // recorded as nothing); it looks here only so a puller that somehow
        // supplied bytes is still believed.
        .pool, .content, .not_recorded => {
            const m = resolved orelse return null;
            var key_buf: [24]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{d}", .{index}) catch return null;
            const v = m.get(key) orelse return null;
            if (v != .string) return null;
            return b64decode(a, v.string) catch null;
        },
    }
}

/// One payload the record names by POINTER instead of carrying — the address
/// the log-server's body door takes
/// (`GET /v1/{tenant}/body/{request_id}/{channel}/{index}`). `index` is the RAW
/// entry ordinal within the channel, never a filtered one, because the door
/// derives the reference server-side from the record: a caller-supplied
/// `BodyRef` would address the cross-tenant body pool directly and let anyone
/// past the tenant gate walk a neighbour's bytes.
pub const OutOfLine = struct {
    channel: []const u8,
    index: u32,
};

/// Enumerate every out-of-line payload in a pulled bundle, so the puller can
/// resolve each through the door and inline the bytes back as
/// `resolved_bodies` before the transcode runs. Returns an empty slice when the
/// whole recording rode inline (the common case) — and, deliberately, when a
/// channel does not decode: an unreadable tape is the transcode's error to
/// report, not a reason for the puller to fail first.
pub fn outOfLinePayloads(a: std.mem.Allocator, fixture_json: []const u8) Error![]const OutOfLine {
    const parsed = std.json.parseFromSlice(std.json.Value, a, fixture_json, .{}) catch
        return Error.BadFixture;
    if (parsed.value != .object) return Error.BadFixture;
    const tapes = if (parsed.value.object.get("tapes")) |v|
        (if (v == .object) v.object else return &.{})
    else
        return &.{};

    var out = std.ArrayList(OutOfLine){};
    if (jStr(tapes, "trigger_payload_b64")) |s| {
        if (decode.decodeTriggerPayload(a, try b64decode(a, s))) |entries| {
            for (entries, 0..) |e, i| switch (decode.triggerPayloadFate(e)) {
                .pool => try out.append(a, .{ .channel = "trigger_payload", .index = @intCast(i) }),
                else => {},
            };
        } else |_| {}
    }
    if (jStr(tapes, "fetch_responses_b64")) |s| {
        if (decode.decodeFetchResponses(a, try b64decode(a, s))) |entries| {
            for (entries, 0..) |e, i| switch (decode.fetchPayloadFate(e)) {
                .pool, .content => try out.append(a, .{ .channel = "fetch_responses", .index = @intCast(i) }),
                else => {},
            };
        } else |_| {}
    }
    return out.toOwnedSlice(a);
}

/// Extract the threaded ctx from a trigger_payload `{"ctx": <value>}` envelope —
/// the inner value re-serialised as JSON text (→ `world.ctx`). null when not a
/// ctx envelope.
fn extractCtx(a: std.mem.Allocator, envelope: []const u8) ?[]const u8 {
    const p = std.json.parseFromSlice(std.json.Value, a, envelope, .{}) catch return null;
    if (p.value != .object) return null;
    const c = p.value.object.get("ctx") orelse return null;
    return std.json.Stringify.valueAlloc(a, c, .{}) catch null;
}

fn jsonB64(a: std.mem.Allocator, w: *std.Io.Writer, bytes: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    const buf = try a.alloc(u8, enc.calcSize(bytes.len));
    defer a.free(buf);
    _ = enc.encode(buf, bytes);
    try jsonStr(w, buf);
}

const KvPair = struct { key: []const u8, value: []const u8 };

fn jStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn b64decode(a: std.mem.Allocator, s: []const u8) Error![]u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch return Error.BadFixture;
    const buf = try a.alloc(u8, n);
    dec.decode(buf, s) catch return Error.BadFixture;
    return buf;
}

fn jsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{b}),
        else => try w.writeByte(b),
    };
    try w.writeByte('"');
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a base64 kv tape with the given entries (mirrors the encodeEntry
/// format `tape_decode` reads), for a round-trip test.
fn b64KvTape(a: std.mem.Allocator, entries: []const decode.KvEntry) ![]const u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], decode.MAGIC, .big);
    std.mem.writeInt(u16, hdr[4..6], decode.VERSION, .big);
    std.mem.writeInt(u16, hdr[6..8], @intFromEnum(decode.Channel.kv), .big);
    std.mem.writeInt(u32, hdr[8..12], @intCast(entries.len), .big);
    try buf.appendSlice(a, &hdr);
    for (entries) |e| {
        var ent = std.ArrayList(u8){};
        defer ent.deinit(a);
        try ent.append(a, @intFromEnum(e.op));
        try ent.append(a, @intFromEnum(e.outcome));
        try putLen(&ent, a, e.key);
        if (e.op == .prefix) {
            // [cursor][limit u32][count u32][rows…][value] — `value` trails
            // the rows on a prefix entry (v9), carrying an elided page's lost
            // row bytes.
            try putLen(&ent, a, "");
            var n: [4]u8 = undefined;
            std.mem.writeInt(u32, &n, 0, .big); // limit
            try ent.appendSlice(a, &n);
            std.mem.writeInt(u32, &n, @intCast(e.results.len), .big);
            try ent.appendSlice(a, &n);
            for (e.results) |row| {
                try putLen(&ent, a, row.key);
                try putLen(&ent, a, row.value);
            }
            try putLen(&ent, a, e.value);
            var l2: [4]u8 = undefined;
            std.mem.writeInt(u32, &l2, @intCast(ent.items.len), .big);
            try buf.appendSlice(a, &l2);
            try buf.appendSlice(a, ent.items);
            continue;
        }
        try putLen(&ent, a, e.value);
        var l: [4]u8 = undefined;
        std.mem.writeInt(u32, &l, @intCast(ent.items.len), .big);
        try buf.appendSlice(a, &l);
        try buf.appendSlice(a, ent.items);
    }
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(buf.items.len));
    _ = enc.encode(out, buf.items);
    return out;
}
fn putLen(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    var l: [4]u8 = undefined;
    std.mem.writeInt(u32, &l, @intCast(s.len), .big);
    try buf.appendSlice(a, &l);
    try buf.appendSlice(a, s);
}

test "transcode: an elided read becomes a refusal, not an absent key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The capture resolved both reads; the budget dropped their values. If the
    // transcode simply omitted them, the closed world would answer `not_found`
    // — a plausible absence where the live run read 900 KB of real data.
    const kv_b64 = try b64KvTape(a, &.{
        .{ .op = .get, .outcome = .ok, .key = "user/jess", .value = "{\"n\":1}" },
        .{ .op = .get, .outcome = .elided, .key = "big/blob", .value = "900000" },
        .{ .op = .prefix, .outcome = .elided, .key = "feed/", .value = "400000" },
    });
    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"inbound",
        \\   "request": {{ "method":"GET", "path":"/x", "host":"h" }},
        \\   "seed":"42", "timestamp_ns":"1700000000000000000",
        \\   "tapes": {{ "kv_b64":"{s}" }}, "sources":[] }}
    , .{kv_b64});

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try transcode(a, fixture, &out);

    const wp = try std.json.parseFromSlice(std.json.Value, a, out.items, .{});
    const wo = wp.value.object;
    // The kept read still lands in the map…
    try testing.expectEqualStrings("{\"n\":1}", wo.get("kv").?.object.get("user/jess").?.string);
    // …and neither elided read does.
    try testing.expect(wo.get("kv").?.object.get("big/blob") == null);
    const el = wo.get("kv_elided").?.array.items;
    try testing.expectEqual(@as(usize, 2), el.len);
    try testing.expectEqualStrings("get", el[0].object.get("op").?.string);
    try testing.expectEqualStrings("big/blob", el[0].object.get("key").?.string);
    try testing.expectEqual(@as(i64, 900000), el[0].object.get("bytes").?.integer);
    try testing.expectEqualStrings("prefix", el[1].object.get("op").?.string);
    try testing.expectEqualStrings("feed/", el[1].object.get("key").?.string);

    // And the world parses back with the refusals attached.
    const w = try world.fromValue(a, wp.value);
    try testing.expectEqual(@as(usize, 2), w.kv_elided.len);
}

test "transcode: kv reads → closed-world map; not-found is omitted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const kv_b64 = try b64KvTape(a, &.{
        .{ .op = .get, .outcome = .ok, .key = "user/jess", .value = "{\"n\":1}" },
        .{ .op = .get, .outcome = .not_found, .key = "user/ghost" },
        .{ .op = .get, .outcome = .ok, .key = "user/jess", .value = "{\"n\":2}" }, // re-read → skipped
    });
    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"inbound",
        \\   "request": {{ "method":"POST", "path":"/x", "host":"h" }},
        \\   "seed":"42", "timestamp_ns":"1700000000000000000",
        \\   "tapes": {{ "kv_b64":"{s}" }}, "sources":[] }}
    , .{kv_b64});

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try transcode(a, fixture, &out);

    // round-trip-parse the emitted world and assert the transcode
    const wp = try std.json.parseFromSlice(std.json.Value, a, out.items, .{});
    const wo = wp.value.object;
    // no missPolicy / kvAbsent — closed world
    try testing.expect(wo.get("missPolicy") == null);
    try testing.expect(wo.get("kvAbsent") == null);
    // provenance: a transcoded world is marked captured
    try testing.expect(wo.get("captured").?.bool);
    // kv: the FIRST value for user/jess, not the re-read
    const kvm = wo.get("kv").?.object;
    try testing.expectEqualStrings("{\"n\":1}", kvm.get("user/jess").?.string);
    // the not-found read is simply omitted (absent from the map → not_found)
    try testing.expect(kvm.get("user/ghost") == null);
    try testing.expectEqual(@as(i64, 42), wo.get("seed").?.integer);
    try testing.expectEqual(@as(i64, 1700000000000), wo.get("now_ms").?.integer);
}

test "transcode: wake_batch activation_bytes -> request.activation.wakes (issue #62)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const wakes_json = "[{\"kind\":\"kv\",\"prefix\":\"feed/\",\"firedAt\":1700000000123},{\"kind\":\"timer\",\"firedAt\":1700000000456}]";
    var ab_b64_buf: [256]u8 = undefined;
    const ab_b64 = std.base64.standard.Encoder.encode(&ab_b64_buf, wakes_json);

    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"wake_batch", "export":"feed.onFeed",
        \\   "request": {{ "method":"POST", "path":"/feed", "host":"h" }},
        \\   "seed":"7", "timestamp_ns":"1700000000000000000",
        \\   "tapes": {{ "activation_bytes_b64":"{s}" }}, "sources":[] }}
    , .{ab_b64});

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try transcode(a, fixture, &out);

    const wp = try std.json.parseFromSlice(std.json.Value, a, out.items, .{});
    const wo = wp.value.object;
    try testing.expectEqualStrings("wake_batch", wo.get("activation").?.string);
    // The resolved wake export (G3) survives the transcode.
    try testing.expectEqualStrings("feed.onFeed", wo.get("export").?.string);
    // The recorded batch lands on request.activation.{kind,wakes}
    // -- the same bag shape an authored rewind:test world carries.
    const req = wo.get("request").?.object;
    const bag = req.get("activation").?.object;
    try testing.expectEqualStrings("wake_batch", bag.get("kind").?.string);
    const wakes = bag.get("wakes").?.array;
    try testing.expectEqual(@as(usize, 2), wakes.items.len);
    const w0 = wakes.items[0].object;
    try testing.expectEqualStrings("kv", w0.get("kind").?.string);
    try testing.expectEqualStrings("feed/", w0.get("prefix").?.string);
    try testing.expectEqual(@as(i64, 1700000000123), w0.get("firedAt").?.integer);
    const w1 = wakes.items[1].object;
    try testing.expectEqualStrings("timer", w1.get("kind").?.string);
}

/// A pool-backed ref for these hand-written tapes. The seed stands in for a
/// sealed object's identity; only distinguishability matters here.
fn poolRef(seed: u8, len: u32) decode.PoolRef {
    return .{
        .written_unix_ms = 1_700_000_000_000 + @as(u64, seed),
        .digest = [_]u8{seed} ** decode.POOL_DIGEST_LEN,
        .offset = 0,
        .len = len,
    };
}

/// Append a `PoolRef` in wire order (`src/tape/root.zig` `appendBodyRef`).
fn putPoolRef(ent: *std.ArrayList(u8), a: std.mem.Allocator, ref: decode.PoolRef) !void {
    var b8: [8]u8 = undefined;
    std.mem.writeInt(u64, &b8, ref.written_unix_ms, .big);
    try ent.appendSlice(a, &b8);
    try ent.appendSlice(a, &ref.digest);
    var b4: [4]u8 = undefined;
    std.mem.writeInt(u32, &b4, ref.offset, .big);
    try ent.appendSlice(a, &b4);
    std.mem.writeInt(u32, &b4, ref.len, .big);
    try ent.appendSlice(a, &b4);
}

/// One trigger_payload entry as the tape records it. A non-`none` `pool_ref`
/// with empty `inline_bytes` is the SPILLED shape — a body over the inline cap,
/// whose bytes live in the body pool and never touch the tape. Test helpers
/// that can only produce the inline shape make the spilled branches
/// unreachable, so a test over them proves nothing.
const TriggerRec = struct {
    /// Seed of the pool object this entry names; 0 means it names none.
    pool_seed: u8 = 0,
    ref_len: u32,
    inline_bytes: []const u8 = "",

    fn ref(self: TriggerRec) decode.PoolRef {
        return if (self.pool_seed == 0)
            .{ .len = self.ref_len }
        else
            poolRef(self.pool_seed, self.ref_len);
    }
};

fn b64TriggerTapeRecs(a: std.mem.Allocator, recs: []const TriggerRec) ![]const u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], decode.MAGIC, .big);
    std.mem.writeInt(u16, hdr[4..6], decode.VERSION, .big);
    std.mem.writeInt(u16, hdr[6..8], @intFromEnum(decode.Channel.trigger_payload), .big);
    std.mem.writeInt(u32, hdr[8..12], @intCast(recs.len), .big);
    try buf.appendSlice(a, &hdr);
    for (recs) |r| {
        var ent = std.ArrayList(u8){};
        defer ent.deinit(a);
        try putPoolRef(&ent, a, r.ref());
        try putLen(&ent, a, r.inline_bytes);
        var b4: [4]u8 = undefined;
        std.mem.writeInt(u32, &b4, @intCast(ent.items.len), .big);
        try buf.appendSlice(a, &b4);
        try buf.appendSlice(a, ent.items);
    }
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(buf.items.len));
    _ = enc.encode(out, buf.items);
    return out;
}

/// Build a base64 trigger_payload tape carrying one inline envelope
/// (mirrors the encodeEntry format `decodeTriggerPayload` reads).
fn b64TriggerTape(a: std.mem.Allocator, envelope: []const u8) ![]const u8 {
    return b64TriggerTapeRecs(a, &.{.{ .ref_len = @intCast(envelope.len), .inline_bytes = envelope }});
}

test "transcode: send_callback envelope -> flattened result surface + bag + bare ctx (issue #67)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // body_b64 is base64url-no-pad("pong") — the envelope's wire encoding.
    const envelope =
        \\{"ctx":{"result":{"status":202,"body_b64":"cG9uZw","attempts":2,"error":null,"id":"snd_1","headers":{"x":"y"},"body_truncated":false},"context":{"orderId":7}}}
    ;
    const tp_b64 = try b64TriggerTape(a, envelope);

    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"hooks.mjs", "activation":"send_callback",
        \\   "request": {{ "method":"POST", "path":"/hooks", "host":"h" }},
        \\   "seed":"7", "timestamp_ns":"1700000000000000000",
        \\   "tapes": {{ "trigger_payload_b64":"{s}" }}, "sources":[] }}
    , .{tp_b64});

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try transcode(a, fixture, &out);

    const wp = try std.json.parseFromSlice(std.json.Value, a, out.items, .{});
    const wo = wp.value.object;
    try testing.expectEqualStrings("send_callback", wo.get("activation").?.string);
    // result → the flattened surface: status/done + byte-exact bodyB64
    // (standard base64 of the decoded body_b64 bytes).
    const req = wo.get("request").?.object;
    try testing.expectEqual(@as(i64, 202), req.get("status").?.integer);
    try testing.expectEqual(true, req.get("done").?.bool);
    try testing.expectEqual(false, req.get("bodyTruncated").?.bool);
    try testing.expectEqualStrings("cG9uZw==", req.get("bodyB64").?.string);
    // delivery metadata → the request.activation bag (the same shape an
    // authored rewind:test sendCallback world carries).
    const bag = req.get("activation").?.object;
    try testing.expectEqualStrings("send_callback", bag.get("kind").?.string);
    try testing.expectEqual(@as(i64, 2), bag.get("attempts").?.integer);
    try testing.expect(bag.get("error").? == .null);
    try testing.expectEqualStrings("snd_1", bag.get("id").?.string);
    try testing.expectEqualStrings("y", bag.get("headers").?.object.get("x").?.string);
    try testing.expect(bag.get("hash") == null); // absent in the envelope → absent in the bag
    // context → the BARE world ctx (not the whole {result, context}).
    const ctx = wo.get("ctx").?.object;
    try testing.expectEqual(@as(i64, 7), ctx.get("orderId").?.integer);
    try testing.expect(ctx.get("result") == null);
}

test "transcode: send_callback bare-ctx envelope (no result) lifts ctx whole (issue #67)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tp_b64 = try b64TriggerTape(a, "{\"ctx\":{\"step\":1}}");
    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"send_callback",
        \\   "request": {{ "method":"POST", "path":"/x", "host":"h" }},
        \\   "seed":"1", "timestamp_ns":"1700000000000000000",
        \\   "tapes": {{ "trigger_payload_b64":"{s}" }}, "sources":[] }}
    , .{tp_b64});

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try transcode(a, fixture, &out);

    const wp = try std.json.parseFromSlice(std.json.Value, a, out.items, .{});
    const wo = wp.value.object;
    // No result → no flattened surface, no bag; the envelope's ctx IS
    // the hop's payload (prod's hoist lifts it whole to request.ctx).
    const req = wo.get("request").?.object;
    try testing.expect(req.get("status") == null);
    try testing.expect(req.get("activation") == null);
    try testing.expectEqual(@as(i64, 1), wo.get("ctx").?.object.get("step").?.integer);
}

/// One fetch_responses chunk as the tape records it. The three pointer shapes
/// are reachable from here — carried (`inline_bytes`), pool (`pool_seed`),
/// content (`content_hash` + `ref_len`, bytes left in content-addressed
/// storage) — plus the metadata-only fate (`ref_len > 0` with no bytes and no
/// pointer). A helper that could only write the carried shape left every other
/// branch untestable.
const FetchRec = struct {
    fid: []const u8 = "ftch_1",
    seq: u32 = 0,
    byte_offset: u64 = 0,
    /// Seed of the pool object this chunk names; 0 means it names none.
    pool_seed: u8 = 0,
    ref_len: u32,
    final: bool = true,
    status: u16 = 200,
    body: []const u8 = "",
    content_hash: []const u8 = "",

    fn ref(self: FetchRec) decode.PoolRef {
        return if (self.pool_seed == 0)
            .{ .len = self.ref_len }
        else
            poolRef(self.pool_seed, self.ref_len);
    }
};

fn b64FetchTapeRecs(a: std.mem.Allocator, recs: []const FetchRec) ![]const u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], decode.MAGIC, .big);
    std.mem.writeInt(u16, hdr[4..6], decode.VERSION, .big);
    std.mem.writeInt(u16, hdr[6..8], @intFromEnum(decode.Channel.fetch_responses), .big);
    std.mem.writeInt(u32, hdr[8..12], @intCast(recs.len), .big);
    try buf.appendSlice(a, &hdr);
    for (recs) |r| {
        var ent = std.ArrayList(u8){};
        defer ent.deinit(a);
        var b8: [8]u8 = undefined;
        var b4: [4]u8 = undefined;
        var b2: [2]u8 = undefined;
        try putLen(&ent, a, r.fid); // fetch_id
        std.mem.writeInt(u32, &b4, r.seq, .big); // seq
        try ent.appendSlice(a, &b4);
        std.mem.writeInt(u64, &b8, r.byte_offset, .big); // byte_offset
        try ent.appendSlice(a, &b8);
        try putPoolRef(&ent, a, r.ref());
        try ent.append(a, if (r.final) 1 else 0); // final
        std.mem.writeInt(u16, &b2, r.status, .big); // status
        try ent.appendSlice(a, &b2);
        try ent.append(a, 1); // ok (recorded on the tape, but NOT surfaced — status is the single signal, #7)
        try ent.append(a, 0); // trunc
        try putLen(&ent, a, "{}"); // headers
        try putLen(&ent, a, r.body); // inline_bytes
        try putLen(&ent, a, r.content_hash); // v6 trailing content hash
        std.mem.writeInt(u32, &b4, @intCast(ent.items.len), .big);
        try buf.appendSlice(a, &b4);
        try buf.appendSlice(a, ent.items);
    }
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(buf.items.len));
    _ = enc.encode(out, buf.items);
    return out;
}

/// Build a base64 fetch_responses tape with one terminal, inline-body entry
/// (mirrors the encodeEntry format `decodeFetchResponses` reads).
fn b64FetchTape(a: std.mem.Allocator, fid: []const u8, status: u16, body: []const u8) ![]const u8 {
    return b64FetchTapeRecs(a, &.{.{
        .fid = fid,
        .status = status,
        .ref_len = @intCast(body.len),
        .body = body,
    }});
}

test "transcode: fetch_chunk emits a world world.zig accepts — no stray `ok` key (issue #214)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fr_b64 = try b64FetchTape(a, "ftch_1", 200, "upstream-body");
    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"fetch_chunk", "export":"onUpstream",
        \\   "request": {{ "method":"POST", "path":"/x", "host":"h" }},
        \\   "recorded": {{ "status": 200 }},
        \\   "seed":"7", "timestamp_ns":"1700000000000000000",
        \\   "tapes": {{ "fetch_responses_b64":"{s}" }}, "sources":[] }}
    , .{fr_b64});

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try transcode(a, fixture, &out);

    const wp = try std.json.parseFromSlice(std.json.Value, a, out.items, .{});
    // The regression: the emitted world MUST parse under world.zig's strict
    // key rejection. An `ok` field on the flattened fetch surface (retired
    // per #7 — status is the single success signal) makes `request` carry an
    // unknown key, so `fromValue` rejects the world and replay produces an
    // empty body. Round-tripping here is the guard the smokes (not in CI)
    // couldn't be.
    const w = try world.fromValue(a, wp.value);
    try testing.expectEqualStrings("fetch_chunk", w.activation);
    try testing.expectEqualStrings("onUpstream", w.export_name.?); // {on} export survives (G3)
    try testing.expectEqual(@as(?i64, 200), w.status);
    try testing.expect(w.done.?);
    try testing.expectEqualStrings("upstream-body", w.body.?); // → request.bytes on replay
    // And explicitly: no `ok` on the request surface.
    try testing.expect(wp.value.object.get("request").?.object.get("ok") == null);
}

/// A base64 request_reads tape carrying a single `body_read` entry — the
/// recorded fact that the handler read its payload. It is what makes the
/// spilled-body case sharp: `body_read` is TRUE while the bytes are absent.
fn b64BodyReadTape(a: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], decode.MAGIC, .big);
    std.mem.writeInt(u16, hdr[4..6], decode.VERSION, .big);
    std.mem.writeInt(u16, hdr[6..8], @intFromEnum(decode.Channel.request_reads), .big);
    std.mem.writeInt(u32, hdr[8..12], 1, .big);
    try buf.appendSlice(a, &hdr);
    var ent = std.ArrayList(u8){};
    defer ent.deinit(a);
    try ent.append(a, @intFromEnum(decode.RequestReadKind.body_read));
    try putLen(&ent, a, "");
    try putLen(&ent, a, "");
    var b4: [4]u8 = undefined;
    std.mem.writeInt(u32, &b4, @intCast(ent.items.len), .big);
    try buf.appendSlice(a, &b4);
    try buf.appendSlice(a, ent.items);
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(buf.items.len));
    _ = enc.encode(out, buf.items);
    return out;
}

/// Parse an emitted world and hand back its `request` object.
fn reqOf(a: std.mem.Allocator, out: []const u8) !std.json.ObjectMap {
    const wp = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    return wp.value.object.get("request").?.object;
}

test "transcode: a spilled inbound body REFUSES — it never becomes an empty body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The recording says the handler READ a body; the body was over the inline
    // cap, so the record carries no `request_body_b64` and the trigger entry
    // holds a body-pool pointer instead of the bytes.
    const reads_b64 = try b64BodyReadTape(a);
    const tp_b64 = try b64TriggerTapeRecs(a, &.{.{ .pool_seed = 42, .ref_len = 65536 }});
    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"inbound",
        \\   "request": {{ "method":"POST", "path":"/upload", "host":"h" }},
        \\   "seed":"1", "timestamp_ns":"1700000000000000000",
        \\   "tapes": {{ "request_reads_b64":"{s}", "trigger_payload_b64":"{s}" }}, "sources":[] }}
    , .{ reads_b64, tp_b64 });

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try transcode(a, fixture, &out);

    // THE regression: `"body": ""` here asserts an empty payload the handler
    // would read as real. The world must carry no body at all, which leaves a
    // captured world's payload accessors on their read-your-tape refusal.
    const req = try reqOf(a, out.items);
    try testing.expect(req.get("body") == null);
    const wp = try std.json.parseFromSlice(std.json.Value, a, out.items, .{});
    const wv = try world.fromValue(a, wp.value);
    try testing.expect(wv.body == null);
    try testing.expect(wv.captured);

    // And the address the puller needs to fix it, in the door's own terms.
    const pending = try outOfLinePayloads(a, fixture);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqualStrings("trigger_payload", pending[0].channel);
    try testing.expectEqual(@as(u32, 0), pending[0].index);
}

test "transcode: a resolved spilled body is inlined verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const reads_b64 = try b64BodyReadTape(a);
    const tp_b64 = try b64TriggerTapeRecs(a, &.{.{ .pool_seed = 42, .ref_len = 11 }});
    var body_b64_buf: [32]u8 = undefined;
    const body_b64 = std.base64.standard.Encoder.encode(&body_b64_buf, "spilled-BODY");
    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"inbound",
        \\   "request": {{ "method":"POST", "path":"/upload", "host":"h" }},
        \\   "seed":"1", "timestamp_ns":"1700000000000000000",
        \\   "resolved_bodies": {{ "trigger_payload": {{ "0": "{s}" }} }},
        \\   "tapes": {{ "request_reads_b64":"{s}", "trigger_payload_b64":"{s}" }}, "sources":[] }}
    , .{ body_b64, reads_b64, tp_b64 });

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try transcode(a, fixture, &out);

    const req = try reqOf(a, out.items);
    try testing.expectEqualStrings("spilled-BODY", req.get("body").?.string);
}

test "transcode: an empty body that WAS read stays an empty body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No trigger entry is recorded for a zero-length body, so `body_read`
    // with nothing out of line means the payload really was empty — the one
    // case where `""` is the truth and not a fabrication.
    const reads_b64 = try b64BodyReadTape(a);
    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"inbound",
        \\   "request": {{ "method":"POST", "path":"/x", "host":"h" }},
        \\   "seed":"1", "timestamp_ns":"1700000000000000000",
        \\   "tapes": {{ "request_reads_b64":"{s}" }}, "sources":[] }}
    , .{reads_b64});

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try transcode(a, fixture, &out);
    const req = try reqOf(a, out.items);
    try testing.expectEqualStrings("", req.get("body").?.string);
}

test "transcode: one unreachable chunk sinks the whole fetch body — no silent truncation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A two-chunk fetch where the second spilled to the pool. Concatenating
    // only the carried chunk yields "head" — plausible, short, and wrong.
    const fr_b64 = try b64FetchTapeRecs(a, &.{
        .{ .seq = 0, .final = false, .status = 0, .ref_len = 4, .body = "head" },
        .{ .seq = 1, .final = true, .status = 200, .byte_offset = 4, .pool_seed = 9, .ref_len = 40000 },
    });
    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"fetch_chunk", "export":"onUpstream",
        \\   "request": {{ "method":"POST", "path":"/x", "host":"h" }},
        \\   "seed":"7", "timestamp_ns":"1700000000000000000",
        \\   "tapes": {{ "fetch_responses_b64":"{s}" }}, "sources":[] }}
    , .{fr_b64});

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try transcode(a, fixture, &out);

    const req = try reqOf(a, out.items);
    try testing.expect(req.get("body") == null);
    // The event metadata is recorded on the entry, so it survives intact.
    try testing.expectEqual(@as(i64, 200), req.get("status").?.integer);
    try testing.expect(req.get("done").?.bool);

    // The door address is the RAW ordinal within the channel — index 1, not
    // "the first out-of-line one".
    const pending = try outOfLinePayloads(a, fixture);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqualStrings("fetch_responses", pending[0].channel);
    try testing.expectEqual(@as(u32, 1), pending[0].index);

    // Resolved, the body is whole.
    var tail_buf: [32]u8 = undefined;
    const tail_b64 = std.base64.standard.Encoder.encode(&tail_buf, "-tail");
    const resolved_fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"fetch_chunk", "export":"onUpstream",
        \\   "request": {{ "method":"POST", "path":"/x", "host":"h" }},
        \\   "seed":"7", "timestamp_ns":"1700000000000000000",
        \\   "resolved_bodies": {{ "fetch_responses": {{ "1": "{s}" }} }},
        \\   "tapes": {{ "fetch_responses_b64":"{s}" }}, "sources":[] }}
    , .{ tail_b64, fr_b64 });
    var out2 = std.ArrayList(u8){};
    defer out2.deinit(a);
    try transcode(a, resolved_fixture, &out2);
    try testing.expectEqualStrings("head-tail", (try reqOf(a, out2.items)).get("body").?.string);
}

test "transcode: a content-referenced chunk is addressed, not dropped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A `blob.get` chunk leaves its bytes in content-addressed storage: the
    // entry names the object and carries no pool ref, so a check that looked
    // only at the pool ref reads it as inline-and-empty.
    const hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    const fr_b64 = try b64FetchTapeRecs(a, &.{
        .{ .seq = 0, .final = true, .status = 200, .ref_len = 4096, .content_hash = hash },
    });
    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"fetch_chunk",
        \\   "request": {{ "method":"GET", "path":"/x", "host":"h" }},
        \\   "seed":"7", "timestamp_ns":"1700000000000000000",
        \\   "tapes": {{ "fetch_responses_b64":"{s}" }}, "sources":[] }}
    , .{fr_b64});

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try transcode(a, fixture, &out);
    try testing.expect((try reqOf(a, out.items)).get("body") == null);

    const pending = try outOfLinePayloads(a, fixture);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqualStrings("fetch_responses", pending[0].channel);
    try testing.expectEqual(@as(u32, 0), pending[0].index);
}

test "transcode: terminal-only chunk is empty; a claimed-but-unkept payload refuses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ref_len 0 — a transport failure closes the chain with a status and no
    // bytes. That IS an empty body.
    const empty_b64 = try b64FetchTapeRecs(a, &.{.{ .final = true, .status = 0, .ref_len = 0 }});
    const empty_fx = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"fetch_chunk",
        \\   "request": {{ "method":"GET", "path":"/x", "host":"h" }},
        \\   "seed":"1", "timestamp_ns":"1700000000000000000",
        \\   "tapes": {{ "fetch_responses_b64":"{s}" }}, "sources":[] }}
    , .{empty_b64});
    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try transcode(a, empty_fx, &out);
    try testing.expectEqualStrings("", (try reqOf(a, out.items)).get("body").?.string);

    // ref_len > 0 with no bytes and no pointer — the entry claims a payload it
    // kept nowhere. Nothing can resolve it, so it must refuse rather than read
    // as the empty body above.
    const lost_b64 = try b64FetchTapeRecs(a, &.{.{ .final = true, .status = 200, .ref_len = 1024 }});
    const lost_fx = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"fetch_chunk",
        \\   "request": {{ "method":"GET", "path":"/x", "host":"h" }},
        \\   "seed":"1", "timestamp_ns":"1700000000000000000",
        \\   "tapes": {{ "fetch_responses_b64":"{s}" }}, "sources":[] }}
    , .{lost_b64});
    var out2 = std.ArrayList(u8){};
    defer out2.deinit(a);
    try transcode(a, lost_fx, &out2);
    try testing.expect((try reqOf(a, out2.items)).get("body") == null);
    // It is not a door address either — the door has nothing to fetch.
    try testing.expectEqual(@as(usize, 0), (try outOfLinePayloads(a, lost_fx)).len);
}

test "transcode: a send_callback envelope over the cap loses its result surface, not silently" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An over-cap envelope records a metadata-only entry: the record says an
    // envelope existed and kept none of it.
    const tp_b64 = try b64TriggerTapeRecs(a, &.{.{ .ref_len = 20000 }});
    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"hooks.mjs", "activation":"send_callback",
        \\   "request": {{ "method":"POST", "path":"/hooks", "host":"h" }},
        \\   "seed":"7", "timestamp_ns":"1700000000000000000",
        \\   "tapes": {{ "trigger_payload_b64":"{s}" }}, "sources":[] }}
    , .{tp_b64});

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try transcode(a, fixture, &out);

    const wp = try std.json.parseFromSlice(std.json.Value, a, out.items, .{});
    const req = wp.value.object.get("request").?.object;
    // No fabricated outcome: no flattened result, no bag, and no payload —
    // so the first payload read on replay refuses.
    try testing.expect(req.get("status") == null);
    try testing.expect(req.get("activation") == null);
    try testing.expect(req.get("body") == null);
    try testing.expect(req.get("bodyB64") == null);
    try testing.expect(wp.value.object.get("ctx") == null);
}

test "transcode: a corrupt tape channel fails loud, not as zero entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Swallowing the decode error would emit a world asserting the activation
    // had no fetch result — a green fixture over an unreadable recording.
    var raw = std.ArrayList(u8){};
    defer raw.deinit(a);
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], decode.MAGIC, .big);
    std.mem.writeInt(u16, hdr[4..6], decode.VERSION + 1, .big); // a version this reader cannot know
    std.mem.writeInt(u16, hdr[6..8], @intFromEnum(decode.Channel.fetch_responses), .big);
    std.mem.writeInt(u32, hdr[8..12], 0, .big);
    try raw.appendSlice(a, &hdr);
    const enc = std.base64.standard.Encoder;
    const b64 = try a.alloc(u8, enc.calcSize(raw.items.len));
    _ = enc.encode(b64, raw.items);

    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"fetch_chunk",
        \\   "request": {{ "method":"GET", "path":"/x", "host":"h" }},
        \\   "tapes": {{ "fetch_responses_b64":"{s}" }}, "sources":[] }}
    , .{b64});

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try testing.expectError(decode.Error.BadVersion, transcode(a, fixture, &out));
}

test "outOfLinePayloads: an all-inline recording needs no door" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fr_b64 = try b64FetchTape(a, "ftch_1", 200, "upstream-body");
    const tp_b64 = try b64TriggerTape(a, "{\"ctx\":{\"x\":1}}");
    const fixture = try std.fmt.allocPrint(a,
        \\{{ "entry":"index.mjs", "activation":"fetch_chunk",
        \\   "tapes": {{ "fetch_responses_b64":"{s}", "trigger_payload_b64":"{s}" }} }}
    , .{ fr_b64, tp_b64 });
    try testing.expectEqual(@as(usize, 0), (try outOfLinePayloads(a, fixture)).len);
    // And a fixture with no tapes at all.
    try testing.expectEqual(@as(usize, 0), (try outOfLinePayloads(a, "{}")).len);
}

test "isFaithfulTranscode" {
    try testing.expect(isFaithfulTranscode("inbound"));
    try testing.expect(isFaithfulTranscode("inbound_headers"));
    try testing.expect(!isFaithfulTranscode("fetch_chunk"));
    // A wake_batch's whole input is recorded (ctx + wakes),
    // so it transcodes faithfully.
    try testing.expect(isFaithfulTranscode("wake_batch"));
    // A send_callback's whole input is recorded (the callee-
    // outcome envelope + the resolved export), so it transcodes faithfully.
    try testing.expect(isFaithfulTranscode("send_callback"));
}
