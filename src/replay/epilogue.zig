// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! Replay-side `request` reconstruction — the Zig port of
//! `rewind-apps/replay/_static/request-replay.mjs` `buildRequestEpilogue`.
//! Returns a JS source string the driver APPENDS to the entry
//! module's source before `arena_run_module`. Appended lines never shift the
//! original source's line numbers, so the trace timeline stays aligned.
//!
//! The epilogue:
//!   - rebuilds `globalThis.request` with the lazy-accessor shape the worker
//!     installs (`src/js/globals.zig` installRequest): header getters from the
//!     recorded `request_reads` name set, values from recorded reads; body /
//!     cookies / ip accessors; `unmaskedIp()`;
//!   - throws a loud REPLAY-DIVERGENCE error when the handler reads anything the
//!     capture tape didn't record (never a silent undefined);
//!   - installs a CAPTURING console (the bare arena has none) so the replayed
//!     run's logs land in the output;
//!   - invokes the activation's export via `__arena_entry_ns()` and parks the
//!     run output — response / result / error / console — through the
//!     `__rove_park_output` native (kv_binding.zig), the side channel the
//!     native driver reads back (the reactor's result context is static /
//!     unreachable). Not a kv write: through the guarded binding, the
//!     sentinel key would need a customer-reachable exemption.

const std = @import("std");
const decode = @import("tape_decode.zig");
const host = @import("host.zig");
const reserved = @import("rove-reserved");

pub const Opts = struct {
    method: []const u8 = "GET",
    /// The raw request path, query string included (split on '?' here).
    path: []const u8 = "/",
    host: []const u8 = "",
    /// Parsed `request_reads` entries (capture order). Empty for records with
    /// no recorded reads.
    request_reads: []const decode.RequestReadEntry = &.{},
    /// The request body bytes, when the handler read them and they rode inline
    /// in the record (≤16 KB). null otherwise.
    body_bytes: ?[]const u8 = null,
    /// The export the activation invokes ("default", "onChunk", ...).
    export_name: []const u8 = "default",
    /// The activation KIND ("inbound", "disconnect", ...) — drives the
    /// missing-export disposition (prod: disconnect = no-op, inbound_headers /
    /// inbound_chunk fall back to the buffered default, else 404).
    activation: []const u8 = "inbound",
    /// Chunk activations (`inbound_chunk` / `fetch_chunk`): the live
    /// `request.body` is a byte-exact Uint8Array, so the replay body is base64
    /// (binary), not a decoded string.
    binary_body: bool = false,

    // ── non-inbound activation surface (`docs/architecture/replay-and-sim.md` §3) ──
    /// The threaded `Ctx` as JSON text → `request.ctx`. null on the first
    /// activation of a chain (and for inbound, which has no ctx).
    ctx_json: ?[]const u8 = null,
    /// `request.activation.*` metadata as JSON text (wakes / msg / …).
    activation_json: ?[]const u8 = null,
    /// Injected `request.session` as JSON text (worker-resolved in prod).
    session_json: ?[]const u8 = null,
    /// Per-chain identity the engine pins on every activation → `request.tenant`
    /// / `request.sagaId`. Plain strings (null → not set).
    tenant: ?[]const u8 = null,
    saga_id: ?[]const u8 = null,
    /// The RESOLVED specifier of the tenant's real `_middlewares` module
    /// (`_middlewares/index.mjs` or the `.js` spelling — prod probes both,
    /// `.mjs` first) whose `before` runs ahead of the handler (inbound trust
    /// boundary only) — it may mutate `request` (e.g. `request.auth`) or
    /// short-circuit. null = no resolvable middleware / not a trust-boundary
    /// activation → the import is never emitted.
    middleware_path: ?[]const u8 = null,
    /// The flattened fetch/callback result → top-level `request.*`.
    result: ?Result = null,
    /// The world was transcoded from a CAPTURE (world.zig `captured`), not
    /// authored. Captured worlds keep the strict read-your-tape posture
    /// (unread payload/ip → REPLAY DIVERGENCE) and the retired driver-only
    /// surfaces (`request.body`, the pre-rename `on.*` alias) so pinned old
    /// deployments replay. Authored worlds mirror the LIVE surface: payload
    /// accessors read `undefined` on payload-less kinds, identity is always
    /// pinned (`session` null / `tenant` / `sagaId` ""), the ip
    /// channels default to null, and the retired surfaces don't exist.
    captured: bool = false,
    /// World-build warnings (e.g. an authored header the prod filter would
    /// strip, root.zig's authored-header hygiene) — surfaced as
    /// `{kind:"log", level:"warn"}` entries at the head of the bundle's
    /// effect log. Empty for replayed (captured) worlds.
    warnings: []const []const u8 = &.{},
    /// Registered kv triggers (issue #38): `_triggers/<prefix>/index` modules
    /// whose before/after chains run on a matching customer `kv.set`/`kv.delete`
    /// (mutate the value, or reject as `Error{code:"trigger_rejected"}`). Each is
    /// statically imported as a namespace and dispatched from the epilogue kv
    /// wrapper, so mutation/rejection are shared with the recorder.
    triggers: []const TriggerReg = &.{},
};

/// A registered kv trigger: the watched key `prefix` + the resolved `module`
/// specifier of its `_triggers/<prefix>/index.{mjs,js}` handler.
pub const TriggerReg = struct { prefix: []const u8, module: []const u8 };

/// The flattened fetch/callback result surface (handler-shape §7) — the fields
/// a `request.body` already covers (the bytes) live in `Opts.body_bytes`;
/// these are the scalar siblings.
pub const Result = struct {
    status: ?i64 = null,
    done: ?bool = null,
    fetch_id: ?[]const u8 = null,
    chunk_seq: ?i64 = null,
    fetches_pending: ?i64 = null,
    body_truncated: ?bool = null,
};

/// Mirror `rpc_dispatch.defaultExportForKind` / the mjs `exportForActivation`.
pub fn exportForActivation(activation: []const u8) []const u8 {
    const map = .{
        .{ "wake_batch", "onWake" },
        .{ "kv_wake", "onWake" },
        .{ "timer", "onWake" },
        // `durable_wake` (a fired schedule/cron target) is NOT here: like the
        // runtime (`rpc_dispatch.defaultExportForKind`), it falls through to
        // `default` — a schedule `target` is a module invoked at its default
        // export (a `module.method` target names the export explicitly).
        .{ "disconnect", "onDisconnect" },
        .{ "ws_message", "onMessage" },
        .{ "inbound_headers", "onHeaders" },
        .{ "inbound_chunk", "onChunk" },
        // A fetch result's *real* export is the resolved name (onFetchResult /
        // onFetchChunk / onFetchDone) carried on the wake, not derivable from
        // the kind (`docs/architecture/replay-and-sim.md` §2). For an authored world
        // we default to the whole-body case; an explicit `export` overrides for
        // chunk/done. (At runtime this kind is dispatched by `resolvedExport`,
        // never this fallback.)
        .{ "fetch_chunk", "onFetchResult" },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, activation, pair[0])) return pair[1];
    }
    return "default";
}

const Folded = struct {
    names_json: []const u8 = "[]", // header_names value (already a JSON array)
    values: []const decode.RequestReadEntry = &.{}, // header_value entries
    body_read: bool = false,
    ip_masked: ?[]const u8 = null,
    ip_raw: ?[]const u8 = null,
    /// `request.rewind.isRoot` — `"1"` / `""`. Absent ⇒ the activation was not
    /// platform-bound, so `request.rewind` is not installed.
    root_verdict: ?[]const u8 = null,
};

fn fold(a: std.mem.Allocator, entries: []const decode.RequestReadEntry) !Folded {
    var out = Folded{};
    var values = std.ArrayList(decode.RequestReadEntry){};
    for (entries) |e| switch (e.kind) {
        .header_names => out.names_json = if (validJsonArray(e.value)) e.value else "[]",
        .header_value => try values.append(a, e),
        .body_read => out.body_read = true,
        .ip_masked => out.ip_masked = e.value,
        .ip_raw => out.ip_raw = e.value,
        .root_verdict => out.root_verdict = e.value,
    };
    out.values = values.items;
    return out;
}

fn validJsonArray(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t\r\n");
    return t.len >= 2 and t[0] == '[';
}

/// Build the epilogue source. The caller owns the returned slice (allocated
/// from `a`).
pub fn build(a: std.mem.Allocator, opts: Opts) ![]u8 {
    const f = try fold(a, opts.request_reads);

    const q = std.mem.indexOfScalar(u8, opts.path, '?');
    const path = if (q) |i| opts.path[0..i] else opts.path;
    const query: ?[]const u8 = if (q) |i| opts.path[i + 1 ..] else null;
    const body_read = f.body_read or opts.body_bytes != null;

    var buf = std.ArrayList(u8){};
    var aw = std.Io.Writer.Allocating.fromArrayList(a, &buf);
    const w = &aw.writer;

    // ── kv trigger registry (issue #38) ──
    // Set BEFORE the IIFE so the kv wrapper sees it when the handler writes; the
    // `ns` fields reference the `import * as __rove_trig_N` namespaces appended
    // below (hoisted, so available here despite source order).
    if (opts.triggers.len > 0) {
        try w.writeAll("\n;globalThis.__rove_triggers = [");
        for (opts.triggers, 0..) |t, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll("{prefix:");
            try jsonStr(w, t.prefix);
            try w.writeAll(",module:");
            try jsonStr(w, t.module);
            try w.print(",ns:__rove_trig_{d}}}", .{i});
        }
        try w.writeAll("];\n");
    }

    // ── the data object `D` (a JS object literal, JSON-safe) ──
    // Async IIFE — the handler (and middleware `before`) may be async; the
    // driver drains microtasks before returning, so the OUTPUT_KEY write lands.
    try w.writeAll("\n;(async () => {\n  const D = {");
    try w.writeAll("\"method\":");
    try jsonStr(w, opts.method);
    try w.writeAll(",\"path\":");
    try jsonStr(w, path);
    try w.writeAll(",\"query\":");
    if (query) |qq| try jsonStr(w, qq) else try w.writeAll("null");
    try w.writeAll(",\"host\":");
    try jsonStr(w, opts.host);
    try w.writeAll(",\"names\":");
    try w.writeAll(f.names_json); // already a JSON array literal
    try w.writeAll(",\"values\":{");
    for (f.values, 0..) |v, i| {
        if (i != 0) try w.writeByte(',');
        try jsonStr(w, v.name);
        try w.writeByte(':');
        try jsonStr(w, v.value);
    }
    try w.writeAll("},\"bodyRead\":");
    try w.writeAll(if (body_read) "true" else "false");
    // body (text) vs bodyB64 (binary, chunk activations).
    try w.writeAll(",\"body\":");
    if (opts.binary_body or opts.body_bytes == null) {
        try w.writeAll("null");
    } else {
        try jsonStr(w, opts.body_bytes.?);
    }
    try w.writeAll(",\"bodyB64\":");
    if (opts.binary_body and opts.body_bytes != null) {
        try jsonB64(a, w, opts.body_bytes.?);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"ipMasked\":");
    try optValue(w, f.ip_masked);
    try w.writeAll(",\"ipRaw\":");
    try optValue(w, f.ip_raw);
    try w.writeAll(",\"rootVerdict\":");
    try optValue(w, f.root_verdict);
    // ctx / activation are pre-serialized JSON values (null for inbound, so the
    // inbound surface carries neither).
    try w.writeAll(",\"ctx\":");
    try w.writeAll(opts.ctx_json orelse "null");
    try w.writeAll(",\"activation\":");
    try w.writeAll(opts.activation_json orelse "null");
    try w.writeAll(",\"session\":");
    try w.writeAll(opts.session_json orelse "null");
    try w.writeAll(",\"tenant\":");
    if (opts.tenant) |t| try jsonStr(w, t) else try w.writeAll("null");
    try w.writeAll(",\"sagaId\":");
    if (opts.saga_id) |cid| try jsonStr(w, cid) else try w.writeAll("null");
    try w.writeAll(",\"result\":");
    if (opts.result) |r| {
        try w.writeAll("{\"status\":");
        try optInt(w, r.status);
        try w.writeAll(",\"done\":");
        try optBool(w, r.done);
        try w.writeAll(",\"fetchId\":");
        if (r.fetch_id) |s| try jsonStr(w, s) else try w.writeAll("null");
        try w.writeAll(",\"chunkSeq\":");
        try optInt(w, r.chunk_seq);
        try w.writeAll(",\"fetchesPending\":");
        try optInt(w, r.fetches_pending);
        try w.writeAll(",\"bodyTruncated\":");
        try optBool(w, r.body_truncated);
        try w.writeByte('}');
    } else try w.writeAll("null");
    try w.writeAll(",\"warnings\":[");
    for (opts.warnings, 0..) |warning, i| {
        if (i != 0) try w.writeByte(',');
        try jsonStr(w, warning);
    }
    try w.writeByte(']');
    try w.writeAll(",\"fn\":");
    try jsonStr(w, opts.export_name);
    try w.writeAll(",\"kind\":");
    try jsonStr(w, opts.activation);
    try w.writeAll(",\"captured\":");
    try w.writeAll(if (opts.captured) "true" else "false");
    try w.writeAll("};\n");

    // ── the fixed reconstruction + invoke + side-channel capture ──
    // The shared pure-JS UTF-8 codec first (installs TextEncoder/TextDecoder;
    // idempotent) — the same file the browser replay prelude evals, so the
    // sim and the browser arena can't drift codec-wise.
    try w.writeAll(TEXTCODEC_PURE);
    // The interaction digest's JS mirror, installing `globalThis.__interactionDigest`
    // for the fold below. AFTER the codec, not in the base prelude: the mirror
    // builds a `TextEncoder` at eval time (it folds UTF-8 BYTES, since the Zig
    // side does) and the base has no codec — evaluating it earlier dies with
    // "TextEncoder is not defined" before any handler runs.
    //
    // The SAME file the browser replay arena's prelude embeds
    // (scripts/ops/gen_replay_prelude.py), so the two offline engines fold one
    // implementation rather than two. Neither JS copy is authoritative —
    // `src/tape/testdata/digest_vectors.json` is, and `zig build
    // replay-digest-vectors` holds both to it.
    try w.writeAll(JS_INTERACTION_DIGEST);
    try w.writeAll(EPILOGUE_BODY);
    try w.writeAll("  __rove_park_output(__out);\n})();\n");

    // The real middleware, imported as a namespace so the async IIFE can run its
    // `before`. A static import (hoisted, loaded before the module body) — only
    // when it's resolvable AND this is an inbound-family activation, so a handler
    // without `_middlewares` never triggers a load divergence. The specifier is
    // the caller-RESOLVED spelling (`.mjs` or `.js`).
    if (opts.middleware_path) |mp| {
        try w.writeAll("import * as __rove_mw from ");
        try jsonStr(w, mp);
        try w.writeAll(";\n");
    }
    // Each registered trigger module, imported as a namespace (like the
    // middleware) so its before/after exports run synchronously from the kv
    // wrapper. Hoisted, so the `__rove_triggers` table above resolves them.
    for (opts.triggers, 0..) |t, i| {
        try w.print("import * as __rove_trig_{d} from ", .{i});
        try jsonStr(w, t.module);
        try w.writeAll(";\n");
    }

    buf = aw.toArrayList();
    return buf.toOwnedSlice(a);
}


/// The pure-JS UTF-8 TextEncoder/TextDecoder (prod-byte-exact, WTF-8 lone
/// surrogates included). One file shared with the browser replay prelude
/// (scripts/ops/gen_replay_prelude.py reads the same source).
const TEXTCODEC_PURE = @embedFile("js/textcodec_pure.js");
/// The interaction digest's JS mirror (`src/tape/js_interaction_digest.js`),
/// wired in through build.zig's `addSimGlobalEmbeds` since it lives outside this
/// module's package. Shared verbatim with the browser replay arena.
const JS_INTERACTION_DIGEST = @embedFile("js_interaction_digest");

const EPILOGUE_BODY = EPILOGUE_BODY_HEAD ++ "\n" ++ CAPS_DECL ++ "\n" ++ EPILOGUE_BODY_TAIL;

/// `__CAPS` — the capability names the activation object carries, generated
/// from `rove-reserved`'s `CAPABILITY_NAMES` rather than restated here.
///
/// The worker builds its template from the same constant
/// (`globals.zig`'s `_caps.js`). A hand-copied second list is how one
/// engine ends up able to pass a capability the others cannot, which
/// surfaces as a handler that works offline and not in prod — the exact
/// divergence `scripts/conformance/` exists to catch, found the slow way.
const CAPS_DECL = blk: {
    var out: []const u8 = "  const __CAPS = [";
    for (reserved.CAPABILITY_NAMES) |n| out = out ++ "\"" ++ n ++ "\", ";
    break :blk out ++ "];";
};

const EPILOGUE_BODY_HEAD =
    \\  // An off-tape read POISONS the run and returns absent — it does not
    \\  // throw. Nothing thrown means nothing a handler can `catch` to keep
    \\  // running on fiction invisibly: the verdict lives on the HOST
    \\  // (__rove_poison → host.zig poisonActive), the uncatchable interrupt
    \\  // brakes the run, and the driver reports the divergence post-run
    \\  // from the flag. Each call site falls through to its authored-absent
    \\  // shape (undefined header, empty payload, null ip, false isRoot), so
    \\  // the JS contract of a read is identical in the authored-miss and
    \\  // captured-divergence cases.
    \\  const miss = (what) => { if (globalThis.__rove_poison) __rove_poison(what); return undefined; };
    \\  // One ordered effect log for the whole activation (reads/writes/cmds — see
    \\  // the shims below). console.* lands here too, as {kind:"log"}, so the
    \\  // developer's own log lines stay INTERLEAVED with the effects they annotate.
    \\  // The effect sink is a per-run global array so BASE-installed globals
    \\  // (the sim_globals `_system.*` recorders) push to the SAME ordered log
    \\  // as these per-request shims. `__effects` is a local alias to it.
    \\  const __effects = (globalThis.__rove_effects = []);
    \\  // ── the interaction digest ──
    \\  // The ordered sequence of reads served and effects emitted, folded into
    \\  // a rolling hash as entries ARRIVE. Order is the point and cannot be
    \\  // recovered by walking the array afterwards (a later push could be
    \\  // reordered by a filter), so `push` is patched rather than the log
    \\  // walked at the end — the same shape the browser replay arena uses, so
    \\  // the two offline engines fold at the same points.
    \\  //
    \\  // Only the worker's grammar folds (src/tape/interaction_digest.zig):
    \\  // kv reads/writes/deletes/prefixes, fetches, wake arms, stream writes,
    \\  // and the three privileged LIFECYCLE ops the worker folds
    \\  // (globals_platform.zig foldPlatformOp). Logs, tags, blob calls and
    \\  // platform.scope are recorded for the timeline but NOT folded, because
    \\  // the worker does not fold those — a digest is only useful if every
    \\  // engine hashes the same set.
    \\  const __DG = globalThis.__interactionDigest;
    \\  const __dg = __DG ? new __DG.Digest() : null;
    \\  // A cross-store element's digest key is the NAMESPACED one
    \\  // (`__rove_store/<tag>/<key>`): the worker gives cross-store ops no
    \\  // verb of their own, so the store is data in the key
    \\  // (globals_platform.zig namespacedKey). Folding the bare key both
    \\  // disagrees with capture AND erases the store, so scope("a").kv.get(k)
    \\  // and root.get(k) would hash alike — a false agreement.
    \\  const __dgKey = (e) => (e.store === undefined || e.store === null)
    \\    ? e.key
    \\    : "__rove_store/" + e.store + "/" + e.key;
    \\  const __foldEffect = (e) => {
    \\    if (!__dg || !e) return;
    \\    // The harness's own scope-resolution marker. It exists so a resume can
    \\    // rebuild kv from the folded effect log; the worker records instance
    \\    // creation in the ROOT WRITESET (raft), never in the digest. Folding
    \\    // it would add an element capture has no counterpart for.
    \\    if (e.store === "exists") return;
    \\    switch (e.kind) {
    \\      case "read":
    \\        if (e.op === "prefix") __dg.kvPrefix(__dgKey(e), true, e.count ?? 0, BigInt("0x" + (e.rowsFold ?? "0")));
    \\        else __dg.kvRead(__dgKey(e), !!e.present, e.value ?? "");
    \\        break;
    \\      case "write":  __dg.kvWrite(__dgKey(e), e.value ?? ""); break;
    \\      case "delete": __dg.kvDelete(__dgKey(e)); break;
    \\      // Exactly the ops globals_platform.zig folds, with the same
    \\      // arguments. `scope` is deliberately absent: the worker resolves a
    \\      // scope handle without folding anything.
    \\      case "platform":
    \\        if (e.op === "instances.create") __dg.platformOp(e.op, e.name ?? "", "");
    \\        else if (e.op === "instances.deployStarter") __dg.platformOp(e.op, e.name ?? "", "");
    \\        else if (e.op === "releases.publish") __dg.platformOp(e.op, e.tenant ?? "", e.depId ?? "");
    \\        break;
    \\      case "fetch":  __dg.fetch(e.method || "GET", e.url || "", e.body ?? ""); break;
    \\      case "timer":  __dg.wakeArm("t", String(e.ms), e.on ?? ""); break;
    \\      case "kv-wake": __dg.wakeArm("k", e.prefix, e.on ?? ""); break;
    \\      case "stream": __dg.streamWrite(e.data ?? ""); break;
    \\      default: break;
    \\    }
    \\  };
    \\  { const __rawPush = __effects.push.bind(__effects);
    \\    __effects.push = (e) => { __foldEffect(e); return __rawPush(e); }; }
    \\  // Per-run fetch/subscribe id counter (the sim_globals recorders mint
    \\  // `ftch_<seq>`/`sub_<seq>` from it) — reset here so ids are deterministic
    \\  // per activation, like prod's per-request derived ids.
    \\  globalThis.__rove_fetch_seq = 0;
    \\  // Per-activation recorder state for the prod-parity argument checks
    \\  // (sim_globals): stream.write's 4 MiB cumulative cap, blob.receive's
    \\  // once-per-request gate, and the activation kind (blob.receive is
    \\  // onHeaders-only).
    \\  globalThis.__rove_stream_bytes = 0;
    \\  globalThis.__rove_blob_receive_used = false;
    \\  globalThis.__rove_activation_kind = D.kind;
    \\  // Captured tapes replay trust-the-tape: recorder checks that depend on
    \\  // harness-seeded state (platform.scope's exists marker) stand down.
    \\  globalThis.__rove_captured = D.captured;
    \\  globalThis.__rove_email_sends = 0;
    \\  // Prod's console formatter (globals/console.js `fmt`) — byte-identical
    \\  // here so a log assertion transfers between a bundle and a live request
    \\  // log: the message text INCLUDES the level prefix exactly as the worker
    \\  // writes the line ("[warn] retrying 2"); the `level` field is
    \\  // bundle-internal filtering sugar. Change one formatter, change both.
    \\  const __fmtLog = (x) => { if (typeof x === "string") return x; try { const s = JSON.stringify(x); return s === undefined ? String(x) : s; } catch (_) { return String(x); } };
    \\  const __mklog = (level, prefix) => (...a) => { const parts = a.map(__fmtLog); if (prefix) parts.unshift(prefix); __effects.push({ kind: "log", level, message: parts.join(" ") }); };
    \\  globalThis.console = { log: __mklog("info", ""), warn: __mklog("warn", "[warn]"), error: __mklog("error", "[error]"), info: __mklog("info", "[info]"), debug: __mklog("debug", "[debug]") };
    \\  // World-build warnings (dropped authored headers, …) lead the effect
    \\  // log so the author sees them before the handler's own output.
    \\  for (const m of D.warnings) __effects.push({ kind: "log", level: "warn", message: m });
    \\  const __b2s = (c) => { if (typeof c === "string") return c; let s = ""; for (let i = 0; i < c.length; i++) s += String.fromCharCode(c[i]); return s; };
    \\  // Real UTF-8 codec — the shared js/textcodec_pure.js spliced just above
    \\  // this body (prod-byte-exact incl. WTF-8 lone surrogates; a latin1 hack
    \\  // here silently corrupts every hash/JWT/base64url over non-ASCII). These
    \\  // aliases keep the epilogue's internal byte math on the one codec.
    \\  const __utf8Encode = (s) => new TextEncoder().encode(s);
    \\  const __utf8Decode = (bytes, fatal) => new TextDecoder("utf-8", { fatal: !!fatal }).decode(bytes);
    \\  const headers = {};
    \\  for (const n of D.names) Object.defineProperty(headers, n, {
    \\    enumerable: true, configurable: true,
    \\    get() { if (!(n in D.values)) miss("header '" + n + "'"); return D.values[n]; },
    \\  });
    \\  const request = { method: D.method, path: D.path, host: D.host, query: D.query, headers };
    \\  // The uniform payload surface (handler-shape §7): bytes/text/json
    \\  // derive from the ONE recorded payload; reading any of them is the
    \\  // same recorded fact the original run's body-read flag captured.
    \\  // `request.body` stays available on the DRIVER (only) so records
    \\  // from pre-retirement deployments still replay their pinned code.
    \\  // Payload-carrying kinds (prod installRequest / globals/request.js):
    \\  // every OTHER kind (wakes, durable targets, disconnect,
    \\  // subscription_fire) has no `bytes` live, so its accessors read
    \\  // undefined. A CAPTURED world keeps the read-your-tape miss() instead —
    \\  // an unread payload surfacing on replay is a divergence, not a value.
    \\  const __PAYLOAD_KINDS = ["inbound", "inbound_headers", "inbound_chunk", "fetch_chunk", "ws_message", "send_callback"];
    \\  const __rawPayload = () => {
    \\    if (!D.bodyRead) {
    \\      if (D.captured) miss("request payload (bytes/text/json/body)");
    \\      // Authored: a payload kind with no declared body reads EMPTY (prod's
    \\      // buffered inbound / terminal fetch event always has bytes); a
    \\      // payload-less kind reads undefined.
    \\      if (!__PAYLOAD_KINDS.includes(D.kind)) return undefined;
    \\      return new Uint8Array(0);
    \\    }
    \\    if (D.bodyB64 != null) {
    \\      const bin = atob(D.bodyB64);
    \\      const u = new Uint8Array(bin.length);
    \\      for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
    \\      return u;
    \\    }
    \\    // D.body is the DECODED request text — the appended `.js` source is read
    \\    // as UTF-8, so a multibyte body (`jsonStr` embedded its wire bytes raw)
    \\    // arrives here as characters, not bytes. Its wire bytes are the UTF-8
    \\    // re-encoding; `unescape(encodeURIComponent(...))` yields those bytes as a
    \\    // latin1 string. (A binary body rides D.bodyB64 above, never this path.)
    \\    const st = unescape(encodeURIComponent(D.body ?? ""));
    \\    const u = new Uint8Array(st.length);
    \\    for (let i = 0; i < st.length; i++) u[i] = st.charCodeAt(i) & 0xff;
    \\    return u;
    \\  };
    \\  const __defPayload = (name, compute) => Object.defineProperty(request, name, {
    \\    enumerable: true, configurable: true,
    \\    get() {
    \\      const v = compute();
    \\      Object.defineProperty(request, name, { enumerable: true, configurable: true, writable: true, value: v });
    \\      return v;
    \\    } });
    \\  __defPayload("bytes", () => __rawPayload());
    \\  __defPayload("text", () => { const b = __rawPayload(); return b === undefined ? undefined : __utf8Decode(b); });
    \\  __defPayload("json", () => { const t = request.text; return t === undefined ? undefined : JSON.parse(t); });
    \\  // `request.body` is RETIRED live (globals/request.js) — it exists only
    \\  // on the captured driver so pre-retirement deployments replay their
    \\  // pinned code.
    \\  if (D.captured) __defPayload("body", () => (D.bodyB64 != null) ? __rawPayload() : (D.body ?? ""));
    \\  Object.defineProperty(request, "cookies", { enumerable: true, configurable: true,
    \\    get() {
    \\      const out = {};
    \\      if (D.names.includes("cookie")) {
    \\        const cv = headers.cookie;
    \\        for (const part of cv.split(";")) {
    \\          const eq = part.indexOf("=");
    \\          if (eq < 0) continue;
    \\          const name = part.slice(0, eq).trim();
    \\          if (name) out[name] = part.slice(eq + 1).trim();
    \\        }
    \\      }
    \\      Object.defineProperty(request, "cookies", { enumerable: true, configurable: true, writable: true, value: out });
    \\      return out;
    \\    } });
    \\  // The ip channels: prod returns null when no edge proxy reported a
    \\  // client IP — an authored world without `ip` reads null the same way;
    \\  // a captured world misses (the original run never read the channel).
    \\  Object.defineProperty(request, "ip", { enumerable: true, configurable: true,
    \\    get() { if (!D.ipMasked) { if (D.captured) miss("request.ip"); return null; } return D.ipMasked.value || null; } });
    \\  request.unmaskedIp = function () { if (!D.ipRaw) { if (D.captured) miss("request.unmaskedIp()"); return null; } return D.ipRaw.value || null; };
    \\  // `request.rewind` — the platform-metadata namespace, installed ONLY for
    \\  // a platform-bound activation, exactly as prod gates it on
    \\  // `state.platform != null`. A recorded root_verdict entry IS that proof;
    \\  // a captured world installs it regardless so a read the original run
    \\  // never made surfaces as a divergence rather than a bare TypeError.
    \\  // `isRoot` is the whole surface: the bearer that produced the verdict is
    \\  // unreachable live (stripped from request.headers) and untaped, so there
    \\  // is nothing else to reconstruct.
    \\  if (D.rootVerdict || D.captured) {
    \\    request.rewind = {};
    \\    Object.defineProperty(request.rewind, "isRoot", { enumerable: true, configurable: true,
    \\      get() { if (!D.rootVerdict) { if (D.captured) miss("request.rewind.isRoot"); return false; } return D.rootVerdict.value === "1"; } });
    \\  }
    \\  // Non-inbound activation surface (null for inbound → no-ops):
    \\  // the threaded ctx, the request.activation metadata bag, and the
    \\  // flattened fetch/callback result (request.status/.done/...; the
    \\  // single success signal is `status`, 2xx = ok — no request.ok, #7).
    \\  if (D.ctx !== null) request.ctx = D.ctx;
    \\  // Engine-pinned identity (worker-set — no code to run): prod ALWAYS
    \\  // sets these on every activation (globals.zig installRequest) —
    \\  // `session` null when no cookie resolved, `sagaId` "" when no
    \\  // saga context, `tenant` = the instance id ("sim" is the
    \\  // authored-world placeholder). A captured world sets only what its
    \\  // tape carries.
    \\  if (D.captured) {
    \\    if (D.session !== null) request.session = D.session;
    \\    if (D.tenant !== null) request.tenant = D.tenant;
    \\    if (D.sagaId !== null) request.sagaId = D.sagaId;
    \\  } else {
    \\    request.session = D.session;
    \\    request.tenant = D.tenant !== null ? D.tenant : "sim";
    \\    request.sagaId = D.sagaId !== null ? D.sagaId : "";
    \\  }
    \\  // request.activation = { kind, ...payload }: prod installs the bag on
    \\  // EVERY activation, so the sim does too — the authored bag (if any)
    \\  // wins field-by-field over the synthesized defaults. The world's
    \\  // `kv_wake` kind surfaces as prod's `"kv"`.
    \\  {
    \\    const __a = D.activation !== null ? D.activation : {};
    \\    // A binary WS frame carries its bytes as base64 → rebuild the
    \\    // Uint8Array on request.activation.data (a text frame keeps its string).
    \\    if (__a.dataB64 != null) {
    \\      const bin = atob(__a.dataB64);
    \\      const u = new Uint8Array(bin.length);
    \\      for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
    \\      __a.data = u; delete __a.dataB64;
    \\    }
    \\    // An UNBOUND fetch/subscription continuation (http.fetch/http.subscribe
    \\    // `on_chunk` → a separate module chain) carries the chunk payload as
    \\    // base64 on the activation bag — there is no top-level flatten, so the
    \\    // handler reads `request.activation.bytes`. Rebuild the Uint8Array
    \\    // (parallel to `dataB64`; the JSON-serialized world can't carry raw
    \\    // bytes otherwise).
    \\    if (__a.bytesB64 != null) {
    \\      const bin = atob(__a.bytesB64);
    \\      const u = new Uint8Array(bin.length);
    \\      for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
    \\      __a.bytes = u; delete __a.bytesB64;
    \\    }
    \\    if (__a.kind == null) __a.kind = D.kind === "kv_wake" ? "kv" : D.kind;
    \\    // Bound-fetch resumes: fill prod's per-event bag (globals.zig
    \\    // fetch_chunk arm — fetchId/seq/byteOffset/bytes/final, + terminal
    \\    // status/bodyTruncated) from the flattened result where the authored
    \\    // bag left gaps. Authored worlds only — a captured bag is the tape.
    \\    if (!D.captured && D.kind === "fetch_chunk") {
    \\      const r = D.result !== null ? D.result : {};
    \\      if (__a.fetchId === undefined && r.fetchId != null) __a.fetchId = r.fetchId;
    \\      if (__a.seq === undefined) __a.seq = r.chunkSeq != null ? r.chunkSeq : 0;
    \\      if (__a.byteOffset === undefined) __a.byteOffset = 0;
    \\      if (__a.final === undefined) __a.final = r.done != null ? r.done : true;
    \\      if (__a.bytes === undefined) { const b = request.bytes; __a.bytes = b === undefined ? new Uint8Array(0) : b; }
    \\      if (__a.final) {
    \\        if (__a.status === undefined && r.status != null) __a.status = r.status;
    \\        if (__a.bodyTruncated === undefined) __a.bodyTruncated = r.bodyTruncated != null ? r.bodyTruncated : false;
    \\      }
    \\    }
    \\    request.activation = __a;
    \\  }
    \\  if (D.result !== null) {
    \\    if (D.result.status !== null) request.status = D.result.status;
    \\    if (D.result.done !== null) request.done = D.result.done;
    \\    if (D.result.fetchId !== null) request.fetchId = D.result.fetchId;
    \\    if (D.result.chunkSeq !== null) request.chunkSeq = D.result.chunkSeq;
    \\    if (D.result.fetchesPending !== null) request.fetchesPending = D.result.fetchesPending;
    \\    if (D.result.bodyTruncated !== null) request.bodyTruncated = D.result.bodyTruncated;
    \\  }
    \\  // ── effect shims ──
    \\  // The connection/continuation + durable-effect globals ALL come from the sim
    \\  // BASE (sim_globals.zig), over `_system.*` recorders that push into the same
    \\  // shared __effects log (globalThis.__rove_effects) as this epilogue: `after`/
    \\  // `stream`/`next` are faithful recorders and `cron`/`schedule`/`webhook`/
    \\  // `email` are the REAL shims, so those verbs decompose to primitives
    \\  // (`_send/owed` + `_sched/*` kv writes + `http.fetch`) in the effect log.
    \\  // Outputs are CAPTURED (not fired) so re-execution stays deterministic. Still
    \\  // epilogue-local: TextDecoder/TextEncoder (js/textcodec_pure.js, spliced
    \\  // above this body), the `on.*` pre-rename alias, and the kv recorder
    \\  // wrapper below.
    \\  // Pre-rename `on.*` — the captured driver only, so records from
    \\  // pre-rename deployments still replay their pinned code. Aliases the
    \\  // base `after`. Authored worlds never see it (retired live).
    \\  if (D.captured) globalThis.on = { fetch: globalThis.after.fetch, kv: globalThis.after.kv, timer: globalThis.after.ms };
    \\  // kv is the NATIVE common binding (rove-binding, installed at reactor
    \\  // base setup) for the whole run — no per-request JS wrapper. The
    \\  // binding owns coercion + guards + shaping (one implementation with
    \\  // the worker); the offline delegate (kv_binding.zig) records the
    \\  // effect entries, injects the `_sub/dirty/` subscription markers, and
    \\  // dispatches the kv-trigger chains to `__rove_run_triggers` below.
;

const EPILOGUE_BODY_TAIL =
    \\  // kv triggers (issue #38): `_triggers/<prefix>/index` modules whose
    \\  // before/after chains run on a matching customer write. The DISPATCH
    \\  // comes from the native kv delegate (kv_binding.zig), which calls
    \\  // `__rove_run_triggers(op, timing, key, value, prev)` in the worker's
    \\  // order — after the guard, around the store — and supplies
    \\  // `previousValue` from a raw, effect-invisible read (exactly the
    \\  // worker's slow-path prev fetch). The table + imported module
    \\  // namespaces are per-request, so the chain itself stays here. A
    \\  // before-put that returns a STRING mutates the written value (the
    \\  // final value is this function's return); a handler that THROWS
    \\  // rejects the write as Error{code:"trigger_rejected"}
    \\  // ("<module>: <message>"). Platform-owned key prefixes never fire
    \\  // (matches prod isPlatformKey); a depth cap guards
    \\  // trigger-writes-that-re-fire recursion. Subscription markers
    \\  // (`_sub/dirty/{name}`) are the delegate's too — injected below the
    \\  // binding like the worker's markSubscriptionsDirty, from the
    \\  // scenario's `__rove_store/subscriptions` registration.
    \\  const __TRIG_PLATFORM = ["_audit/", "_deploy/", "_callback/", "_magic/", "_triggers/", "_sessions/"];
    \\  const __triggerHandler = (ns, op, timing) => { const nm = op === "put" ? (timing === "before" ? "beforePut" : "afterPut") : (timing === "before" ? "beforeDelete" : "afterDelete"); if (typeof ns[nm] === "function") return ns[nm]; if (typeof ns.default === "function") return ns.default; return null; };
    \\  let __triggerDepth = 0;
    \\  const __runTriggers = (op, timing, key, value, prev) => {
    \\    const trigs = globalThis.__rove_triggers;
    \\    if (!trigs || trigs.length === 0 || __triggerDepth >= 16) return value;
    \\    for (const p of __TRIG_PLATFORM) if (key.startsWith(p)) return value;
    \\    const matched = trigs.filter((t) => key.startsWith(t.prefix));
    \\    if (matched.length === 0) return value;
    \\    // BEFORE: broad→narrow (shortest prefix first); AFTER: narrow→broad.
    \\    matched.sort((a, b) => a.prefix.length - b.prefix.length);
    \\    if (timing === "after") matched.reverse();
    \\    let evValue = value == null ? null : String(value);
    \\    prev = (prev === undefined || prev === null) ? null : String(prev);
    \\    __triggerDepth++;
    \\    try {
    \\      for (const t of matched) {
    \\        const handler = __triggerHandler(t.ns, op, timing);
    \\        if (!handler) continue;
    \\        const event = { key, value: evValue, previousValue: prev, op, timing, timestamp: (D.now_ms || 0), actor: null, depth: __triggerDepth - 1 };
    \\        let ret;
    \\        try { ret = handler(event); }
    \\        catch (e) { const err = new Error(t.module + ": " + ((e && e.message) || String(e))); err.code = "trigger_rejected"; throw err; }
    \\        if (op === "put" && timing === "before" && typeof ret === "string") { value = ret; evValue = ret; }
    \\      }
    \\    } finally { __triggerDepth--; }
    \\    return value;
    \\  };
    \\  // Installed only when this run registered triggers, so the delegate
    \\  // skips the prev fetch + dispatch entirely otherwise.
    \\  if (globalThis.__rove_triggers && globalThis.__rove_triggers.length) globalThis.__rove_run_triggers = __runTriggers;
    \\  // request.tag — the common native binding (rove-binding.Tag over the
    \\  // offline delegate): arity gate, pair rules, capacity and refusal
    \\  // shapes are ONE implementation with the worker. Each accepted call
    \\  // lands in the effect log as {kind:"tag"} (the delegate pushes it) so
    \\  // tests can assert what would index the record.
    \\  request.tag = __rove_request_tag;
    \\  // request.shredKey — the same common binding (rove-binding.ShredKey).
    \\  // A FUNCTION on every engine, so a handler that scopes its
    \\  // activation to an identity behaves the same offline as in prod.
    \\  request.shredKey = __rove_request_shred_key;
    \\  globalThis.request = request;
    \\  globalThis.response = { status: 200, headers: {}, cookies: [] };
    \\  // The activation object — the single argument every export receives
    \\  // (docs/architecture/package-isolation.md, the received-not-ambient
    \\  // model). Built HERE, before middleware, because that is where the
    \\  // worker builds it (globals.installRequest runs ahead of
    \\  // module_execution.runMiddleware), and `request`/`response` are the
    \\  // same objects the globals name — so a middleware that mutates
    \\  // `request` is seen through either spelling. Capability names absent
    \\  // from this arena are skipped rather than set undefined: the arena
    \\  // installs a subset of the worker's shims, and an own property
    \\  // holding `undefined` reads differently from an absent one.
    \\  const __act = {};
    \\  for (const __k of __CAPS) if (__k in globalThis) __act[__k] = globalThis[__k];
    \\  __act.request = request;
    \\  __act.response = globalThis.response;
    \\  let __result = null, __err = null, __short = false;
    \\  // Await like the worker's pumpJobs: drain microtasks, and if the promise
    \\  // is STILL pending treat it as a plain value (prod ships its JSON — "{}")
    \\  // rather than awaiting forever (response_building.unwrapPromise). Returns
    \\  // a {v, pending?} wrapper — returning the pending promise bare from an
    \\  // async fn would chain-adopt it and never resolve.
    \\  const __settle = async (p) => {
    \\    if (!p || typeof p.then !== "function") return { v: p };
    \\    let done = false, ok = false, val;
    \\    p.then((x) => { done = true; ok = true; val = x; }, (x) => { done = true; val = x; });
    \\    // Each turn yields one microtask tick. Prod pumps until the queue is
    \\    // quiet; the queue isn't visible from JS, so approximate with a budget
    \\    // generous beyond any real await chain. A handler needing more turns
    \\    // than this is reported as pending (the warn log below flags it).
    \\    for (let i = 0; i < 4096 && !done; i++) await null;
    \\    if (!done) return { v: p, pending: true };
    \\    if (!ok) throw val;
    \\    return { v: val };
    \\  };
    \\  // NOTE: returns the {v, pending?} WRAPPER — callers read `.v`. Returning
    \\  // a still-pending `v` bare from an async fn would make the caller's
    \\  // `await` re-adopt it and hang the epilogue forever.
    \\  const __settled = async (p) => {
    \\    const r = await __settle(p);
    \\    if (r.pending) __effects.push({ kind: "log", level: "warn", message: "handler returned a still-pending promise — prod treats it as a plain value (body \"{}\")" });
    \\    return r;
    \\  };
    \\  try {
    \\    const ns = __arena_entry_ns();
    \\    // Real middleware (inbound trust boundary): run `_middlewares`' `before`
    \\    // first — it sees globalThis.request/response and may MUTATE the request
    \\    // (e.g. request.auth = {...}) or SHORT-CIRCUIT by returning a response.
    \\    // `__rove_mw` is imported only when middleware_path resolved (build()
    \\    // appends the import at the caller's spelling — .mjs or .js);
    \\    // `typeof` is safe when it isn't declared.
    \\    if (typeof __rove_mw !== "undefined" && __rove_mw) {
    \\      if (typeof __rove_mw.before !== "function") {
    \\        // A malformed middleware is loud (module_execution.runMiddleware):
    \\        // 500 short-circuit, the handler never runs.
    \\        globalThis.response = { status: 500, headers: {}, cookies: [] };
    \\        __result = "_middlewares/index.mjs must export a `before` function\n";
    \\        __short = true;
    \\      } else {
    \\        const __mwr = (await __settled(__rove_mw.before())).v;
    \\        if (__mwr !== undefined && __mwr !== null) { __result = __mwr; __short = true; }
    \\      }
    \\    }
    \\    if (!__short) {
    \\      const __fn = ns[D.fn];
    \\      if (typeof __fn === "function") {
    \\        __result = (await __settled(__fn(__act))).v;
    \\      } else if (D.kind === "disconnect") {
    \\        // Prod: a missing onDisconnect is a no-op, not a 404 — the held
    \\        // stream closes regardless (module_execution).
    \\      } else if ((D.kind === "inbound_headers" || D.kind === "inbound_chunk") && typeof ns["default"] === "function") {
    \\        // Prod: no onHeaders/onChunk probe hit → fall back to the classic
    \\        // buffered dispatch at the default export (worker_dispatch §3.5).
    \\        __result = (await __settled(ns["default"](__act))).v;
    \\      } else {
    \\        // Prod 404s any other missing export (module_execution).
    \\        globalThis.response = { status: 404, headers: {}, cookies: [] };
    \\        __result = 'module export "' + D.fn + '" not found or not a function\n';
    \\      }
    \\    }
    \\    globalThis.__replay_result = __result;
    \\  } catch (e) {
    \\    // `message` is the exception's ToString, not its `.message` — prod's
    \\    // spelling. `takeExceptionMessage` (qjs/root.zig) is `toOwnedString`,
    \\    // so the worker records `Error: boom` on the log record and in the
    \\    // wire body; reporting a bare `boom` offline dropped the error CLASS,
    \\    // which is often the whole diagnosis (SyntaxError vs TypeError vs a
    \\    // thrown string). No information is lost — the ToString contains the
    \\    // message. The body below already used `String(e)`, so this only makes
    \\    // the structured field agree with the text beside it.
    \\    __err = { message: String(e), stack: String((e && e.stack) || "") };
    \\    // Prod parity (worker_dispatch): a JS exception → 500 with
    \\    // "handler threw: {ToString}\n" as the body, the handler-set response
    \\    // head DISCARDED, and the txn rolled back. Mark this activation's
    \\    // outputs rolled back so kv folds and matchers exclude them — reads and
    \\    // console lines are not outputs, and stream frames may already be on
    \\    // the wire (prod flushes them eagerly), so those stay.
    \\    globalThis.response = { status: 500, headers: {}, cookies: [] };
    \\    __result = "handler threw: " + String(e) + "\n";
    \\    for (const __e of __effects) {
    \\      if (__e.kind !== "read" && __e.kind !== "log" && __e.kind !== "stream") __e.rolledBack = true;
    \\    }
    \\  }
    \\  // The one held/terminal disposition read: the handler parked with
    \\  // `next()` (a thrown handler's __result is the 500 body string, so it
    \\  // reads terminal). Shared by the drop-tagging pass below and the
    \\  // terminal-body derivation — one bind-or-drop decision, like the worker.
    \\  const __held = __result !== null && typeof __result === "object" && __result.__rove_disposition === "next";
    \\  // ── connection-scoped effect disposition (prod parity) ──
    \\  // `after.ms`/`after.kv` arm — and a connection-scoped `after.fetch`
    \\  // binds — only at the handler-success seam, and only when the activation
    \\  // ends HELD (returns `next()`); a terminal return discards them
    \\  // (on.zig / worker_dispatch's bind-or-drop). A connectionless activation
    \\  // (durable_wake / send_callback / disconnect) has no socket at all, which
    \\  // also drops stream frames (stream.zig's `pending_stream_chunks orelse
    \\  // return`). The unbound `http.fetch` primitive (bound:false — what
    \\  // webhook.send/blob compose on) fires regardless. Tag the discarded
    \\  // entries `dropped` — excluded from matchers/kv-folds like `rolledBack`,
    \\  // kept on the log for debugging — and warn, so a test can't green on an
    \\  // effect prod never ships. Rolled-back entries are already excluded.
    \\  // Authored worlds only: a captured tape is the record of what prod
    \\  // actually did (including resume shapes whose accumulators differ from
    \\  // the authored kinds, e.g. a held send_callback hop that binds fetches)
    \\  // — replay must not re-litigate it. Same posture as the authored-header
    \\  // hygiene warnings.
    \\  if (!D.captured) {
    \\    const __connless = D.kind === "durable_wake" || D.kind === "send_callback" || D.kind === "disconnect" || D.kind === "subscription_fire";
    \\    const __dropWakes = __connless || !__held;
    \\    // Warns append to __effects mid-iteration: for..of visits the new tail,
    \\    // but a {kind:"log"} entry matches no branch below, so this terminates.
    \\    for (const __e of __effects) {
    \\      if (__e.rolledBack) continue;
    \\      let __what = null;
    \\      if (__e.kind === "timer" && __dropWakes) __what = "after.ms(" + __e.ms + ")";
    \\      else if (__e.kind === "kv-wake" && __dropWakes) __what = "after.kv(" + JSON.stringify(__e.prefix) + ")";
    \\      else if (__e.kind === "fetch" && __e.bound && __dropWakes) __what = "after.fetch(" + JSON.stringify(__e.url) + ")";
    \\      else if (__e.kind === "stream" && __connless) __what = "stream.write";
    \\      if (__what === null) continue;
    \\      __e.dropped = true;
    \\      __effects.push({ kind: "log", level: "warn", message: "dropped connection-scoped effect: " + __what + " — " + (__connless ? "a " + D.kind + " activation has no connection" : "the handler returned a terminal response instead of next(), so the socket was not held") + "; prod discards it and it never fires" });
    \\    }
    \\  }
    \\  // ── response vetting (prod parity) — the emit-side rules the worker
    \\  // applies to everything the handler set on `response`, mirrored from
    \\  // src/js/response_building.zig (extractResponseMetadata /
    \\  // isEmittableHeaderName / isCleanHeaderValue / sanitizeSetCookie) and
    \\  // worker_dispatch's status clamp. Drops are silent — handler bugs
    \\  // don't 500 the request — exactly as live.
    \\  const __vetResponse = () => {
    \\    const raw = globalThis.response || {};
    \\    // status: ToInt32 coercion (x|0) then clamp 100..599.
    \\    let st = raw.status;
    \\    st = (st === undefined || st === null) ? 200 : (st | 0);
    \\    if (st < 100) st = 100; else if (st > 599) st = 599;
    \\    // headers: the first 32 own enumerable props, then filter — pseudo
    \\    // (:*), token-invalid, hop-by-hop, platform-managed (set-cookie /
    \\    // content-length), and x-rewind-*/x-rove-internal-* names dropped;
    \\    // non-string or CR/LF/NUL values dropped; names lowercased (HTTP/2).
    \\    const RESERVED = ["connection", "transfer-encoding", "upgrade", "keep-alive", "te", "trailer", "proxy-authenticate", "proxy-authorization", "set-cookie", "content-length"];
    \\    const emittable = (n) => {
    \\      if (!n.length || n[0] === ":") return false;
    \\      for (let i = 0; i < n.length; i++) { const c = n.charCodeAt(i); if (c <= 0x20 || c === 0x7f) return false; }
    \\      const l = n.toLowerCase();
    \\      if (RESERVED.includes(l)) return false;
    \\      if (l.startsWith("x-rewind-") || l.startsWith("x-rove-internal-")) return false;
    \\      return true;
    \\    };
    \\    const cleanVal = (v) => { for (let i = 0; i < v.length; i++) { const c = v.charCodeAt(i); if (c === 13 || c === 10 || c === 0) return false; } return true; };
    \\    const hdrs = {};
    \\    const hsrc = (raw.headers && typeof raw.headers === "object") ? raw.headers : {};
    \\    for (const k of Object.keys(hsrc).slice(0, 32)) {
    \\      if (!emittable(k)) continue;
    \\      const v = hsrc[k];
    \\      if (typeof v !== "string" || !cleanVal(v)) continue;
    \\      hdrs[k.toLowerCase()] = v;
    \\    }
    \\    // cookies: strings only, first 32, `Domain=` stripped (a handler must
    \\    // not push a cookie onto the parent domain — sanitizeSetCookie).
    \\    const cookies = [];
    \\    const csrc = Array.isArray(raw.cookies) ? raw.cookies : [];
    \\    for (let i = 0; i < Math.min(csrc.length, 32); i++) {
    \\      const c0 = csrc[i];
    \\      if (typeof c0 !== "string" || !c0.length) continue;
    \\      const segs = c0.split(";");
    \\      let cout = segs[0].trim();
    \\      for (let j = 1; j < segs.length; j++) {
    \\        const seg = segs[j].trim();
    \\        if (!seg.length) continue;
    \\        const eq = seg.indexOf("=");
    \\        const an = (eq < 0 ? seg : seg.slice(0, eq)).trim().toLowerCase();
    \\        if (an === "domain") continue;
    \\        cout += "; " + seg;
    \\      }
    \\      if (cout.length) cookies.push(cout);
    \\    }
    \\    return { status: st, headers: hdrs, cookies };
    \\  };
    \\  const __vet = __vetResponse();
    \\  // ── terminal body derivation (response_building.bodyFromReturn +
    \\  // dispatcher.prependStreamChunks): a returned Uint8Array is RAW BYTES
    \\  // (base64 through the bundle — `bodyB64` + `binary`); a non-string
    \\  // non-bytes return is JSON and auto-stamps `content-type:
    \\  // application/json` unless the handler set its own; a first-hop
    \\  // terminal after `stream.write` ships the buffered chunks AHEAD of the
    \\  // body. `__bodyOverride` rides the bundle only when prod's wire body
    \\  // differs from the plain return value.
    \\  let __bodyOverride = null;
    \\  // The bytes prod puts ON THE WIRE — what the worker folds into the
    \\  // digest's closing element (dispatcher.zig folds `pending.body`, not the
    \\  // return value). They differ whenever `__bodyOverride` exists, so the
    \\  // digest has to follow the override rather than the plain result.
    \\  let __wireBody = "";
    \\  {
    \\    if (!__held && !__err) {
    \\      const isBytes = __result instanceof Uint8Array;
    \\      let isJson = false, text = null;
    \\      if (typeof __result === "string") text = __result;
    \\      else if (__result === undefined || __result === null || isBytes) text = null;
    \\      else { const j = JSON.stringify(__result); if (j !== undefined) { text = j; isJson = true; } }
    \\      if (isJson && !("content-type" in __vet.headers)) __vet.headers["content-type"] = "application/json";
    \\      // First-hop HTTP terminals only — a WS frame goes to the socket and
    \\      // a resume's chunks are already on the open stream.
    \\      const frames = (D.kind === "inbound" || D.kind === "inbound_headers")
    \\        ? __effects.filter((e) => e.kind === "stream" && !e.rolledBack).map((e) => e.data)
    \\        : [];
    \\      const b64 = (u) => { const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; let s = ""; for (let i = 0; i < u.length; i += 3) { const b0 = u[i], b1 = i + 1 < u.length ? u[i + 1] : 0, b2 = i + 2 < u.length ? u[i + 2] : 0; s += A[b0 >> 2] + A[((b0 & 3) << 4) | (b1 >> 4)] + (i + 1 < u.length ? A[((b1 & 15) << 2) | (b2 >> 6)] : "=") + (i + 2 < u.length ? A[b2 & 63] : "="); } return s; };
    \\      if (isBytes && frames.length) {
    \\        const head = __utf8Encode(frames.join(""));
    \\        const all = new Uint8Array(head.length + __result.length);
    \\        all.set(head, 0); all.set(__result, head.length);
    \\        __bodyOverride = { b64: b64(all) };
    \\        __wireBody = all;
    \\      } else if (isBytes) {
    \\        __bodyOverride = { b64: b64(__result) };
    \\        __wireBody = __result;
    \\      } else if (frames.length) {
    \\        __bodyOverride = { text: frames.join("") + (text === null ? "" : text) };
    \\        __wireBody = __bodyOverride.text;
    \\      } else {
    \\        __wireBody = text === null ? "" : text;
    \\      }
    \\    }
    \\  }
    \\  // Closed LAST, after every effect has folded — the element that makes the
    \\  // digest a superset of a status comparison. Status is clamped exactly as
    \\  // the worker clamps it (dispatcher.zig), so an out-of-range status folds
    \\  // to the same element on both.
    \\  if (__dg) {
    \\    const __st = __held ? 0 : Math.max(100, Math.min(599, __vet && __vet.status !== undefined ? __vet.status : 200));
    \\    // A THROWN handler's wire body is the "handler threw: …" text set in
    \\    // the catch above — prod folds `pending.body`, which is that same
    \\    // text. The body-derivation block below only runs on the success path,
    \\    // so reading `__wireBody` alone folded an empty body here and made a
    \\    // throwing activation digest differently from prod's.
    \\    if (!__held) __dg.response(__st, __err ? String(__result) : __wireBody);
    \\  }
    \\  let __out;
    \\  try {
    \\    __out = JSON.stringify({ response: __vet, result: __result, body_override: __bodyOverride, error: __err, effects: __effects, digest: __dg ? __dg.hex() : null });
    \\  } catch (e) {
    \\    __out = JSON.stringify({ response: __vet, result: null, body_override: __bodyOverride, effects: __effects, digest: __dg ? __dg.hex() : null,
    \\      error: { message: "replay result not JSON-serialisable: " + String((e && e.message) || e), stack: "" } });
    \\  }
    \\
;

fn optInt(w: *std.Io.Writer, v: ?i64) !void {
    if (v) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
}
fn optBool(w: *std.Io.Writer, v: ?bool) !void {
    try w.writeAll(if (v) |b| (if (b) "true" else "false") else "null");
}

/// `{"value": "<s>"}` or `null` — the ipMasked / ipRaw shape the getters read.
fn optValue(w: *std.Io.Writer, v: ?[]const u8) !void {
    if (v) |s| {
        try w.writeAll("{\"value\":");
        try jsonStr(w, s);
        try w.writeByte('}');
    } else {
        try w.writeAll("null");
    }
}

fn jsonB64(a: std.mem.Allocator, w: *std.Io.Writer, bytes: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(bytes.len));
    defer a.free(out);
    _ = enc.encode(out, bytes);
    try jsonStr(w, out);
}

fn jsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        // U+2028 / U+2029 can't appear in a single UTF-8 byte, so byte-level
        // escaping of the C0 controls + quote + backslash is sufficient here.
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{b}),
        else => try w.writeByte(b),
    };
    try w.writeByte('"');
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "exportForActivation maps activation kinds" {
    try testing.expectEqualStrings("default", exportForActivation("inbound"));
    try testing.expectEqualStrings("onWake", exportForActivation("kv_wake"));
    try testing.expectEqualStrings("onMessage", exportForActivation("ws_message"));
    try testing.expectEqualStrings("onChunk", exportForActivation("inbound_chunk"));
    // A fired schedule/cron target invokes the target module's default export
    // (mirrors `rpc_dispatch.defaultExportForKind`); a `module.method` target
    // names its export explicitly on the world.
    try testing.expectEqualStrings("default", exportForActivation("durable_wake"));
}

test "build: GET embeds request meta + parks output under sentinel" {
    // The driver always builds under a per-replay arena (root.zig `run`); the
    // intermediate fold allocations are reclaimed wholesale, so mirror that.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reads = [_]decode.RequestReadEntry{
        .{ .kind = .header_names, .name = "", .value = "[\"content-type\"]" },
        .{ .kind = .header_value, .name = "content-type", .value = "application/json" },
    };
    const src = try build(a, .{
        .method = "GET",
        .path = "/hello?x=1",
        .host = "ex.test",
        .request_reads = &reads,
        .export_name = "default",
    });

    try testing.expect(std.mem.indexOf(u8, src, "\"path\":\"/hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, "\"query\":\"x=1\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, "[\"content-type\"]") != null);
    try testing.expect(std.mem.indexOf(u8, src, "\"content-type\":\"application/json\"") != null);
    try testing.expect(std.mem.indexOf(u8, src, "__arena_entry_ns()") != null);
    try testing.expect(std.mem.indexOf(u8, src, "__rove_park_output(__out)") != null);
}


test "the driver passes the activation object, built from the shared list" {
    // Both halves, because either alone passes while the engines disagree:
    // the object has to be BUILT from `rove-reserved`'s list (so the worker
    // and this driver carry the same names), and it has to be PASSED at the
    // export call (so a handler that destructures its capabilities gets
    // them). A driver that builds it and calls `__fn()` looks correct in
    // review and hands every handler `undefined`.
    for (reserved.CAPABILITY_NAMES) |n| {
        try std.testing.expect(std.mem.indexOf(u8, EPILOGUE_BODY, n) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, EPILOGUE_BODY, "const __CAPS = [") != null);
    try std.testing.expect(std.mem.indexOf(u8, EPILOGUE_BODY, "__fn(__act)") != null);
    try std.testing.expect(std.mem.indexOf(u8, EPILOGUE_BODY, "ns[\"default\"](__act)") != null);
    // Middleware keeps zero arguments: the worker's runMiddleware was not
    // changed, and parity is the point.
    try std.testing.expect(std.mem.indexOf(u8, EPILOGUE_BODY, "__rove_mw.before()") != null);
}

test "no guard evaluation is left in the epilogue" {
    // The inverse of the old splice assertion: the native engines' checks
    // run inside the common binding, so a guard CALL reappearing in this
    // per-request JS would be a second evaluator sneaking back in.
    try std.testing.expect(std.mem.indexOf(u8, EPILOGUE_BODY, "__kvGuardWrite(") == null);
    try std.testing.expect(std.mem.indexOf(u8, EPILOGUE_BODY, "__tagGuardPair(") == null);
    try std.testing.expect(std.mem.indexOf(u8, EPILOGUE_BODY, "__tagGuardCapacity(") == null);
}
