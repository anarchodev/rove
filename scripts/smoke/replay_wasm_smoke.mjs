// Node-runnable smoke driver for the WASM replay path. Reads a
// bundle JSON file (composed by the Python orchestrator from a real
// captured log record + deployment manifest), boots qjs_arena_wasm,
// installs Module.tapes / Module.module_sources / Module.host_trace
// the same way the replay shell's `wasm-app.mjs` does (resolved from
// $REWIND_APPS_DIR — the porcelain moved to the private rewind-apps repo
// when `web/` was extracted, commit fecf07b), runs the handler in SCAN
// mode, and prints a one-line JSON summary on stdout.
//
// Exit 0 on rc=0 from arena_run_module; non-zero otherwise. The
// orchestrator parses the stdout JSON to validate counts.
//
// Usage:
//     node scripts/smoke/replay_wasm_smoke.mjs <bundle.json>

import fs from "node:fs";
import { Buffer } from "node:buffer";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const __filename = fileURLToPath(import.meta.url);
// scripts/smoke/ → the repo root is two levels up.
const repo_root = path.resolve(path.dirname(__filename), "..", "..");

// The WASM replay porcelain (rtap / request-replay / qjs_arena_wasm) moved
// out of this repo when `web/` was extracted into the private rewind-apps
// repo (commit fecf07b). Resolve it from $REWIND_APPS_DIR — the smoke
// harness convention (smoke_lib_v2.APPS_DIR) — falling back to an in-repo
// ./web for an operator who keeps apps in-tree. Dynamic import so the
// path is resolved at runtime rather than hardcoded at parse time.
const apps_dir = process.env.REWIND_APPS_DIR || path.join(repo_root, "web");
const static_dir = path.join(apps_dir, "replay", "_static");

const { buildTapesFromBlobs } =
    await import(pathToFileURL(path.join(static_dir, "rtap.mjs")).href);
const { buildRequestEpilogue } =
    await import(pathToFileURL(path.join(static_dir, "request-replay.mjs")).href);
const getArenaJs =
    (await import(pathToFileURL(path.join(static_dir, "qjs_arena_wasm.js")).href)).default;

// Trace event kinds — see vendor/arenajs/qjs-arena-trace.c.
const K_NAME = 0, K_FUNC_ENTER = 1, K_FUNC_EXIT = 2, K_LINE = 3, K_THROW = 4;
const TRACE_SCAN = 1;

function fail(msg) {
    console.error("replay-wasm-smoke: " + msg);
    process.exit(2);
}

const bundlePath = process.argv[2];
if (!bundlePath) fail("usage: replay_wasm_smoke.mjs <bundle.json>");

const raw = JSON.parse(fs.readFileSync(bundlePath, "utf-8"));

// The orchestrator writes tape_blobs as base64 strings (since JSON
// can't hold raw bytes). Decode each channel to a Uint8Array; null
// when the channel had no entries in the captured record.
// `docs/primitive-gaps.md` §9 + fold-in: only kv + module remain
// on the wire. `Math.random` + `crypto.*` + `Date.now()` reseed
// from `raw.seed` + `raw.timestamp_ns`, no per-call tape entries.
const tape_blobs = {};
for (const k of ["kv", "module", "request_reads"]) {
    const b64 = raw.tape_blobs?.[k];
    tape_blobs[k] = b64 ? new Uint8Array(Buffer.from(b64, "base64")) : null;
}

const Module = await getArenaJs({
    // Emscripten's default locateFile resolves the .wasm next to the
    // .js, but Node's module loader can leave the cwd elsewhere — be
    // explicit so the driver works from any cwd.
    locateFile: (name) => path.join(static_dir, name),
});

const arena_init           = Module.cwrap("arena_init",           "number", ["number","number"]);
const arena_run_module     = Module.cwrap("arena_run_module",     "number", ["string","string"]);
const arena_set_trace_mode = Module.cwrap("arena_set_trace_mode", null,     ["number"]);
const arena_set_random_seed = Module.cwrap("arena_set_random_seed", null,   ["number","number"]);
const arena_set_date_now   = Module.cwrap("arena_set_date_now",   null,    ["number","number"]);
const arena_destroy        = Module.cwrap("arena_destroy",        null,     []);

if (arena_init(8192, 8192) !== 0) fail("arena_init failed");

try {
    Module.tapes = buildTapesFromBlobs(tape_blobs);
} catch (err) {
    fail("buildTapesFromBlobs: " + err.message);
}

// §9 seed-not-draws: reseed the per-context PRNG from the captured
// request's seed before running the handler. `Math.random` /
// `crypto.*` then reproduce the original draw sequence.
const seed_bi = BigInt(raw.seed ?? 0);
arena_set_random_seed(
    Number(seed_bi & 0xFFFFFFFFn),
    Number((seed_bi >> 32n) & 0xFFFFFFFFn),
);

// §9 fold-in: pin `Date.now()` and `new Date()` (no args) to the
// captured request's `timestamp_ns` (converted to ms). Both Date
// reads inside the replay return the same scalar — matching the
// original request's behavior.
const ts_ns = BigInt(raw.timestamp_ns ?? 0);
const ms_bi = ts_ns / 1_000_000n;
arena_set_date_now(
    Number(ms_bi & 0xFFFFFFFFn),
    Number((ms_bi >> 32n) & 0xFFFFFFFFn),
);

const module_sources = {};
for (const m of raw.modules || []) {
    if (m.source != null) module_sources[m.path] = m.source;
}
Module.module_sources = module_sources;

// Stash printf / stderr so we can surface what the handler logged.
const captured = [];
Module.print    = (s) => captured.push(s);
Module.printErr = (s) => captured.push("[stderr] " + s);

// Optional argv[3]: stop_at_event (1-based, non-NAME events). When
// set, host_trace returns 2 at that event index so the WASM runtime
// walks live frames and ships a JSON snapshot via host_state. Used by
// the orchestrator's second pass to validate the stack walker on a
// real captured run. Pass 0 / -1 / nothing to disable.
const stop_at_event = process.argv[3] ? parseInt(process.argv[3], 10) : -1;
// Optional argv[4]: trace mode (1 = SCAN, 2 = DRILL). DRILL adds
// per-source-line LINE events between FUNC_ENTER / FUNC_EXIT pairs;
// SCAN omits them (zero overhead per opcode tick). Defaults to SCAN.
const trace_mode_arg = process.argv[4] ? parseInt(process.argv[4], 10) : 1;

// Trace collection: count events by kind; record names for later
// diagnostic output. When stop_at_event is set, also build an
// `events` array with resolved file/name strings so the host can
// confirm which point we paused at.
let event_count = 0;
let func_enter_count = 0;
let func_exit_count = 0;
let line_count = 0;
let throw_count = 0;
let snapshot = null;
const names = new Map();
const events = [];   // resolved event log (only the first ~32 entries)
const decoder = new TextDecoder();

function resolveAtom(atom) {
    return names.get(atom) || `<atom:${atom}>`;
}

Module.host_state = (ptr, len) => {
    try {
        snapshot = JSON.parse(decoder.decode(Module.HEAPU8.subarray(ptr, ptr + len)));
    } catch (err) {
        snapshot = { __parse_error: err.message };
    }
};

Module.host_trace = (kind, ptr, len) => {
    if (kind === K_NAME) {
        const atom = Module.HEAPU32[ptr >> 2];
        const slen = Module.HEAPU16[(ptr + 4) >> 1];
        names.set(atom, decoder.decode(Module.HEAPU8.subarray(ptr + 6, ptr + 6 + slen)));
        return 0;
    }
    event_count++;
    if (kind === K_FUNC_ENTER) {
        func_enter_count++;
        if (events.length < 1024) {
            events.push({
                idx: event_count,
                kind: "enter",
                name: resolveAtom(Module.HEAPU32[ptr >> 2]),
                file: resolveAtom(Module.HEAPU32[(ptr + 4) >> 2]),
                line: Module.HEAPU32[(ptr + 8) >> 2],
            });
        }
    } else if (kind === K_FUNC_EXIT) {
        func_exit_count++;
        if (events.length < 1024) events.push({ idx: event_count, kind: "exit" });
    } else if (kind === K_LINE) {
        line_count++;
        if (events.length < 1024) {
            events.push({
                idx: event_count,
                kind: "line",
                file: resolveAtom(Module.HEAPU32[ptr >> 2]),
                line: Module.HEAPU32[(ptr + 4) >> 2],
            });
        }
    } else if (kind === K_THROW) {
        throw_count++;
        if (events.length < 1024) {
            const mlen = Module.HEAPU16[(ptr + 8) >> 1];
            events.push({
                idx: event_count,
                kind: "throw",
                file: resolveAtom(Module.HEAPU32[ptr >> 2]),
                line: Module.HEAPU32[(ptr + 4) >> 2],
                message: decoder.decode(Module.HEAPU8.subarray(ptr + 10, ptr + 10 + mlen)),
            });
        }
    }
    if (stop_at_event > 0 && event_count === stop_at_event) return 2;
    return 0;
};

let entry_path = raw.entry_path;
let entry_source = raw.entry_source;
if (!entry_path) {
    const m = (raw.modules || []).find((m) => m.path === "index.mjs" || m.path === "index.js");
    if (m) { entry_path = m.path; entry_source = m.source; }
}
if (!entry_path || !entry_source) fail("no entry module in bundle");

// arena_run_module only EVALUATES the module body — it doesn't
// invoke any export. The shared epilogue builder (request-replay.mjs,
// same one the browser shell uses) rebuilds `request` from the
// recorded `request_reads` tape — getters that throw REPLAY
// DIVERGENCE on unrecorded reads — and invokes the export through
// `__arena_entry_ns()`. The injected lines sit at module-top scope,
// so they don't confuse the call-tree timeline.
const wrapped_source =
    entry_source +
    buildRequestEpilogue({
        record: raw.request || {},
        requestReads: Module.tapes.request_reads,
        bodyBytes: raw.request?.body ?? null,
        exportName: raw.entry_fn || "default",
    });

arena_set_trace_mode(trace_mode_arg);
const rc = arena_run_module(entry_path, wrapped_source);
arena_set_trace_mode(0);
arena_destroy();

const summary = {
    ok: rc === 0,
    rc,
    entry_path,
    event_count,
    func_enter_count,
    func_exit_count,
    line_count,
    throw_count,
    name_count: names.size,
    output_lines: captured.length,
    output_sample: captured.slice(0, 8),
    events,
    stop_at_event: stop_at_event > 0 ? stop_at_event : null,
    trace_mode: trace_mode_arg,
    snapshot,
};
console.log(JSON.stringify(summary));
process.exit(rc === 0 ? 0 : 1);
