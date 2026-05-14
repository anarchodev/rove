// Node-runnable smoke driver for the WASM replay path. Reads a
// bundle JSON file (composed by the Python orchestrator from a real
// captured log record + deployment manifest), boots qjs_arena_wasm,
// installs Module.tapes / Module.module_sources / Module.host_trace
// the same way `web/replay/wasm-app.mjs` does, runs the handler in
// SCAN mode, and prints a one-line JSON summary on stdout.
//
// Exit 0 on rc=0 from arena_run_module; non-zero otherwise. The
// orchestrator parses the stdout JSON to validate counts.
//
// Usage:
//     node scripts/replay_wasm_smoke.mjs <bundle.json>

import fs from "node:fs";
import { Buffer } from "node:buffer";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { buildTapesFromBlobs } from "../web/replay/rtap.mjs";
import getArenaJs from "../web/replay/qjs_arena_wasm.js";

const __filename = fileURLToPath(import.meta.url);
const repo_root = path.resolve(path.dirname(__filename), "..");

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
const tape_blobs = {};
for (const k of ["kv", "date", "math_random", "crypto_random", "module"]) {
    const b64 = raw.tape_blobs?.[k];
    tape_blobs[k] = b64 ? new Uint8Array(Buffer.from(b64, "base64")) : null;
}

const Module = await getArenaJs({
    // Emscripten's default locateFile resolves the .wasm next to the
    // .js, but Node's module loader can leave the cwd elsewhere — be
    // explicit so the driver works from any cwd.
    locateFile: (name) => path.join(repo_root, "web/replay", name),
});

const arena_init           = Module.cwrap("arena_init",           "number", ["number","number"]);
const arena_run_module     = Module.cwrap("arena_run_module",     "number", ["string","string"]);
const arena_set_trace_mode = Module.cwrap("arena_set_trace_mode", null,     ["number"]);
const arena_destroy        = Module.cwrap("arena_destroy",        null,     []);

if (arena_init(8192, 8192) !== 0) fail("arena_init failed");

try {
    Module.tapes = buildTapesFromBlobs(tape_blobs);
} catch (err) {
    fail("buildTapesFromBlobs: " + err.message);
}

const module_sources = {};
for (const m of raw.modules || []) {
    if (m.source != null) module_sources[m.path] = m.source;
}
Module.module_sources = module_sources;

// Stash printf / stderr so we can surface what the handler logged.
const captured = [];
Module.print    = (s) => captured.push(s);
Module.printErr = (s) => captured.push("[stderr] " + s);

// Trace collection: count events by kind; record names for later
// diagnostic output. Match the wire-format decode in wasm-app.mjs.
let event_count = 0;
let func_enter_count = 0;
let func_exit_count = 0;
let line_count = 0;
let throw_count = 0;
const names = new Map();
const decoder = new TextDecoder();

Module.host_trace = (kind, ptr, len) => {
    if (kind === K_NAME) {
        const atom = Module.HEAPU32[ptr >> 2];
        const slen = Module.HEAPU16[(ptr + 4) >> 1];
        names.set(atom, decoder.decode(Module.HEAPU8.subarray(ptr + 6, ptr + 6 + slen)));
        return 0;
    }
    event_count++;
    if (kind === K_FUNC_ENTER) func_enter_count++;
    else if (kind === K_FUNC_EXIT) func_exit_count++;
    else if (kind === K_LINE) line_count++;
    else if (kind === K_THROW) throw_count++;
    return 0;
};

let entry_path = raw.entry_path;
let entry_source = raw.entry_source;
if (!entry_path) {
    const m = (raw.modules || []).find((m) => m.path === "index.mjs" || m.path === "index.js");
    if (m) { entry_path = m.path; entry_source = m.source; }
}
if (!entry_path || !entry_source) fail("no entry module in bundle");

arena_set_trace_mode(TRACE_SCAN);
const rc = arena_run_module(entry_path, entry_source);
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
};
console.log(JSON.stringify(summary));
process.exit(rc === 0 ? 0 : 1);
