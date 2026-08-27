// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The conformance suite's replay adapter, engine side: run one AUTHORED world
// on the browser WASM arena, headless, and print its outcome as JSON.
//
//     node replay_driver.mjs <job.json>
//
// This is the third engine. It is not the sim with a different front end: it is
// a separate build (qjs_arena_wasm) with a separate shim set (the generated
// `arena-prelude.js` + `request-replay.mjs` epilogue), which is exactly why it
// has diverged from prod five independent times — missing global shims, an
// unpinned timezone, no effect verbs, a narrower request surface, no
// `_middlewares` — each found by a human replaying a record and hitting the
// next wall.
//
// ── Authored worlds on a replay engine ──
//
// Replay normally re-executes a CAPTURED world: tapes carry the reads the
// original run made, and a read the tape lacks is a divergence that kills the
// run. A conformance case is authored, not captured, so there are no tapes.
//
// The seam that makes it work anyway is the host kv OVERLAY. `_arena_host_kv_get`
// (arenajs `qjs-arena-replay-bindings.c`) consults `Module._kvOverlay` BEFORE
// the tape, so seeding the world's closed-world kv map into the overlay means
// declared reads resolve and never reach the tape at all. The epilogue already
// relies on this to seed its own `__rove_store/*` bookkeeping.
//
// What this does NOT give us is the sim's closed-world default: a read of a key
// the world does not declare falls through to an empty tape and returns -4, a
// REPLAY DIVERGENCE, where the sim would answer `not_found`. That is a genuine
// engine difference rather than a driver limitation, and it is reported as such
// (see `undeclared kv read` below) instead of being papered over — a case whose
// handler reads an undeclared key is a case that cannot run on this engine yet
// (rove#436).
//
// The porcelain (rtap / request-replay / qjs_arena_wasm) lives in the private
// rewind-apps repo; resolve it from $REWIND_APPS_DIR, the same convention the
// smoke harness uses.

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { Buffer } from "node:buffer";

function fail(msg, code = 2) {
    console.error("replay-driver: " + msg);
    process.exit(code);
}

const jobPath = process.argv[2];
if (!jobPath) fail("usage: replay_driver.mjs <job.json>");
const job = JSON.parse(fs.readFileSync(jobPath, "utf-8"));

const appsDir = job.apps_dir || process.env.REWIND_APPS_DIR;
if (!appsDir) fail("REWIND_APPS_DIR is not set — the replay porcelain lives in rewind-apps", 3);
const staticDir = path.join(appsDir, "replay", "_static");
if (!fs.existsSync(path.join(staticDir, "qjs_arena_wasm.js")))
    fail(`no replay porcelain at ${staticDir}`, 3);

const imp = (f) => import(pathToFileURL(path.join(staticDir, f)).href);
const { buildRequestEpilogue, resolveMiddleware } = await imp("request-replay.mjs");
const {
    READ_KIND_HEADER_NAMES,
    READ_KIND_HEADER_VALUE,
    READ_KIND_BODY_READ,
    READ_KIND_IP_MASKED,
    READ_KIND_IP_RAW,
} = await imp("rtap.mjs");
// The baked `__system/*` entry modules. Without them every send_callback-shaped
// record is unloadable — the gap #236 closed.
const { SYSTEM_MODULES } = await imp("arena-system-modules.js");
const getArenaJs = (await imp("qjs_arena_wasm.js")).default;

// The key the epilogue parks `{status, result, effects, digest}` under, in the
// kv overlay. Same side channel as the native driver's OUTPUT_KEY
// (`src/replay/host.zig`).
const REPLAY_OUTPUT_KEY = "__replay_output__";

const world = job.world || {};
const req = world.request || {};

const Module = await getArenaJs({ locateFile: (n) => path.join(staticDir, n) });

const arena_init_open = Module.cwrap("arena_init_open", "number", ["number", "number"]);
const arena_eval_base = Module.cwrap("arena_eval_base", "number", ["string"]);
const arena_freeze = Module.cwrap("arena_freeze", null, []);
const arena_run_module = Module.cwrap("arena_run_module", "number", ["string", "string"]);
const arena_set_random_seed = Module.cwrap("arena_set_random_seed", null, ["number", "number"]);
const arena_set_date_now = Module.cwrap("arena_set_date_now", null, ["number", "number"]);
const arena_oom_hit = Module.cwrap("arena_oom_hit", "number", []);
const arena_destroy = Module.cwrap("arena_destroy", null, []);

// The engine-shim prelude — the pure-compute globals prod compiles into the
// worker (TextEncoder / URLSearchParams / base64url / crypto / the interaction
// digest). GENERATED from the engine's own shim sources by
// `scripts/ops/gen_replay_prelude.py`, and evaled into the OPEN arena base
// before freeze, so a replayed handler sees the compute surface the live run
// had. Fail LOUD if it is missing: a bare arena replays a faithful world with a
// spurious ReferenceError, which is precisely the class #227 closed and would
// read here as a conformance divergence in the handler rather than in the boot.
const preludePath = path.join(staticDir, "arena-prelude.js");
if (!fs.existsSync(preludePath))
    fail(`no arena-prelude.js at ${preludePath} — run scripts/ops/gen_replay_prelude.py`, 3);
const preludeSrc = fs.readFileSync(preludePath, "utf-8");

if (arena_init_open(8192, 8192) !== 0) fail("arena_init_open failed");
if (arena_eval_base(preludeSrc) !== 0) fail("arena_eval_base(prelude) failed");
arena_freeze();

// Empty tapes: an authored world has no capture. Every channel must still be
// present — the bindings index `Module.tapes.kv` / `.module` unconditionally.
Module.tapes = {
    kv: [],
    module: [],
    request_reads: [],
    fetch_responses: [],
    trigger_payload: [],
};

// The root a handler's kv capability resolves under — `reserved.USER_KEY_ROOT`
// (`src/reserved/root.zig`), which the arena's compiled binding applies to every
// key before it reaches this overlay. The overlay IS the arena's store, so it is
// keyed the way the store is; a world is authored in the handler's spelling, so
// seeding resolves and the write-back un-resolves.
//
// Getting this wrong does not fail loudly: the world seeds, every read misses,
// and the case reports a divergence that reads like a behaviour change.
const USER_KEY_ROOT = "_user/";
// The harness's cross-store facade addresses OTHER stores, so it is exempt from
// the rooting on both sides — same carve-out the binding makes.
const isExemptKey = (k) =>
    k.startsWith("__rove_store/") || k === REPLAY_OUTPUT_KEY ||
    // `_config/` lives outside the handler root by design: the `config.get`
    // door (authored scope 0) reads it at the visible spelling, and a
    // handler's literal `kv.get("_config/…")` reroots into its own keyspace
    // — same exemption the native seeding makes (`kv_binding.storeKey`).
    k.startsWith("_config/");
const storeKey = (k) => (isExemptKey(k) ? k : USER_KEY_ROOT + k);
const namedKey = (k) =>
    !isExemptKey(k) && k.startsWith(USER_KEY_ROOT) ? k.slice(USER_KEY_ROOT.length) : k;

// The world's closed-world kv map, seeded into the overlay so declared reads
// resolve before the (empty) tape is consulted. A JSON-shaped value is
// stringified, matching `world.zig`: kv holds byte strings the handler parses
// itself, so an author may write an object and mean its serialization.
const overlay = new Map();
for (const [k, v] of Object.entries(world.kv || {})) {
    overlay.set(storeKey(k), typeof v === "string" ? v : JSON.stringify(v));
}
Module._kvOverlay = overlay;

Module.module_sources = { ...SYSTEM_MODULES, ...(job.sources || {}) };

const seed = BigInt(world.seed ?? 0);
arena_set_random_seed(Number(seed & 0xffffffffn), Number((seed >> 32n) & 0xffffffffn));
// The sim pins the clock from `now_ms`; the replay engine takes ms directly.
const nowMs = BigInt(world.now_ms ?? 0);
arena_set_date_now(Number(nowMs & 0xffffffffn), Number((nowMs >> 32n) & 0xffffffffn));

// Request reads: the replay engine rebuilds `request` from the request_reads
// TAPE, not from a world document, so a world's headers/ip/body have to be
// expressed as tape entries or the handler's getters throw. Synthesizing them
// here is what lets one case drive both engines from one document.
const requestReads = [];
const headers = req.headers || {};
const headerNames = Object.keys(headers).map((h) => h.toLowerCase());
if (headerNames.length) {
    requestReads.push({
        kind: READ_KIND_HEADER_NAMES,
        name: "",
        value: JSON.stringify(headerNames),
    });
    for (const [name, value] of Object.entries(headers)) {
        requestReads.push({
            kind: READ_KIND_HEADER_VALUE,
            name: String(name).toLowerCase(),
            value: typeof value === "string" ? value : JSON.stringify(value),
        });
    }
}
// Unconditional, for the same reason as the body-read marker below: on a
// capture, an absent ip entry means "the original run never read `request.ip`"
// and reading it is a divergence — but an authored world has no original run,
// and prod/the sim let the handler read it and hand back null when no ip was
// declared. An empty value is precisely how the channel spells "null was
// returned" (`RequestReadKind.ip_masked`, src/tape/root.zig).
for (const kind of [READ_KIND_IP_MASKED, READ_KIND_IP_RAW]) {
    // Both channels: `request.ip` (masked) and `unmaskedIp()` (the
    // deliberate escalation). A world declares one address; which of the two a
    // handler reads is the handler's business, and gating either on the world
    // makes an authored world throw where prod returns a value or null.
    requestReads.push({ kind, name: "", value: req.ip != null ? String(req.ip) : "" });
}

// The body-read marker is unconditional on payload-carrying activations, not
// gated on the world declaring a body. On a capture the marker means "the
// original run read the payload", and its absence is a divergence — but an
// AUTHORED world has no original run, and prod reads a bodyless inbound as `""`
// rather than throwing. Gating the marker on a declared body made a bodyless
// world throw REPLAY DIVERGENCE where the sim (and prod) return empty.
const PAYLOAD_KINDS = new Set(["inbound", "inbound_chunk", "fetch_chunk", "ws_message"]);
if (PAYLOAD_KINDS.has(world.activation || "inbound"))
    requestReads.push({ kind: READ_KIND_BODY_READ, name: "", value: "" });

const binaryBody = req.bodyB64 != null;
const bodyBytes = binaryBody
    ? new Uint8Array(Buffer.from(req.bodyB64, "base64"))
    : req.body == null
      ? null
      : typeof req.body === "string"
        ? req.body
        : JSON.stringify(req.body);

const entry = world.entry || "index.mjs";
const entrySource = Module.module_sources[entry];
if (entrySource === undefined) fail(`no source for entry module '${entry}'`, 4);

// `arena_run_module` only EVALUATES the module body. The shared epilogue —
// the same one the browser shell uses, so the engine under test is the one
// customers replay against — rebuilds `request` and invokes the export.
// `_middlewares/index.mjs` runs for real when the app tree has one — the sim
// runs it too, so omitting it here would manufacture a divergence in the driver
// rather than surface one in the engines (the gap #230 closed).
const middlewarePath = resolveMiddleware(
    Module.module_sources,
    world.activation || "inbound",
);

const epilogue = buildRequestEpilogue({
    record: { method: req.method || "GET", path: req.path || "/", host: req.host || "" },
    requestReads,
    bodyBytes,
    binaryBody,
    exportName: world.export || "default",
    activation: world.activation || "inbound",
    // A conformance case is AUTHORED, not captured. The distinction is the
    // engine's, not this driver's: `world.zig` carries the same flag and
    // `export_fixture` stamps it. Declaring it turns off the postures that only
    // make sense for a world that actually happened — strict read-your-tape,
    // the admin grant, the retired `request.body` alias (rove#436).
    captured: world.captured === true,
    ctx: world.ctx,
    middlewarePath,
    tenant: req.tenant ?? null,
    sagaId: req.sagaId ?? req.correlationId ?? null,
});

const logs = [];
Module.print = (s) => logs.push(s);
Module.printErr = (s) => logs.push("[stderr] " + s);

const rc = arena_run_module(entry, entrySource + epilogue);
const oom = arena_oom_hit ? arena_oom_hit() === 1 : false;

let parked = null;
const rawOut = overlay.get(REPLAY_OUTPUT_KEY);
if (rawOut != null) {
    try {
        parked = JSON.parse(rawOut);
    } catch (e) {
        parked = { __parse_error: String(e) };
    }
}

// The writes the handler performed, read straight out of the overlay: every
// `kv.set` lands there. The epilogue's own bookkeeping keys and the output key
// are excluded — they are host scaffolding the worker never wrote, and folding
// them in would report writes no other engine can have.
const writes = [];
for (const [sk, v] of overlay) {
    if (sk === REPLAY_OUTPUT_KEY || sk.startsWith("__rove_store/")) continue;
    // Reported in the spelling the handler used, so `writes` compares against
    // the other engines' — they record what was named, not where it landed.
    const k = namedKey(sk);
    if (Object.prototype.hasOwnProperty.call(world.kv || {}, k) && v === overlay.get(sk)) {
        // Unchanged seed value — a read, not a write. A genuine rewrite to the
        // same value is indistinguishable here and is reported through
        // `effects` instead, which records the operation rather than the state.
        continue;
    }
    writes.push(v === null ? { key: k, deleted: true } : { key: k, value: v });
}

arena_destroy();

process.stdout.write(
    JSON.stringify({
        rc,
        oom,
        // -4 from the kv binding surfaces as a thrown REPLAY DIVERGENCE inside
        // the run, so a non-zero rc with no parked output is the signature of an
        // undeclared read. The adapter turns that into a legible error.
        parked,
        writes,
        logs: logs.slice(0, 32),
    }),
);
process.exit(0);
