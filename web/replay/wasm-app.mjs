// Loop46 replay — WASM-driven path (PLAN §10.12, beta scope).
//
// Runs at `replay.{public_suffix}/wasm`. Same opener/postMessage
// handshake as the existing iframe replay (web/replay/app.js) so the
// dashboard's Replay button can target either URL — what differs is
// what we do with the bundle once we have it.
//
// Pipeline:
//   1. Receive `replay:bundle` from the dashboard
//   2. Parse the captured tape blobs via rtap.mjs (mirrors
//      src/tape/root.zig encoding rule-for-rule)
//   3. Install parsed tapes + per-path module sources on the
//      Emscripten Module object
//   4. Install Module.host_trace to collect FUNC_ENTER / FUNC_EXIT /
//      THROW events as the handler runs
//   5. Boot arenajs-WASM, set trace mode to SCAN, call
//      arena_run_module(entry, source)
//   6. Render the captured event stream as a call-tree timeline
//
// V1 stops here — no scrubbing controls, no source view, no variable
// panel. The DRILL-mode + host_state (stack-walker) hooks the arenajs
// runtime already exposes are what those features will hang off in
// follow-ups; this file just doesn't drive them yet.

import { buildTapesFromBlobs } from "./rtap.mjs";
import getArenaJs from "./qjs_arena_wasm.js";

const $status    = document.getElementById("status");
const $runStatus = document.getElementById("run-status");
const $meta      = document.getElementById("meta");
const $output    = document.getElementById("output");
const $timeline  = document.getElementById("timeline");

function setStatus(el, text, kind) {
    el.textContent = text;
    el.className = "status " + (kind || "info");
}

// ── Trace mode constants ─────────────────────────────────────────────
const TRACE_OFF   = 0;
const TRACE_SCAN  = 1;
const TRACE_DRILL = 2;

// Event kinds (binary wire format — see qjs-arena-trace.c).
const K_NAME       = 0;
const K_FUNC_ENTER = 1;
const K_FUNC_EXIT  = 2;
const K_LINE       = 3;
const K_THROW      = 4;

// ── postMessage handshake ────────────────────────────────────────────
//
// Mirrors web/replay/app.js: opener is the dashboard at `app.<suffix>`,
// we're at `replay.<suffix>`. Origin check derives the expected origin
// from our own so it works across loop46.me / loop46.localhost / any
// future suffix.
function expectedDashboardOrigin() {
    return window.location.origin.replace("://replay.", "://app.");
}

function awaitBundle() {
    if (!window.opener) {
        setStatus($status,
            "error: open this page from the dashboard's Replay button",
            "error");
        return Promise.reject(new Error("no opener"));
    }
    const expectedOrigin = expectedDashboardOrigin();
    setStatus($status, "waiting for bundle from dashboard…", "info");
    window.opener.postMessage({ kind: "replay:ready" }, expectedOrigin);
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            window.removeEventListener("message", onMsg);
            reject(new Error("bundle timeout (10s)"));
        }, 10_000);
        function onMsg(e) {
            if (e.origin !== expectedOrigin) return;
            if (e.source !== window.opener) return;
            if (e.data?.kind !== "replay:bundle") return;
            clearTimeout(timer);
            window.removeEventListener("message", onMsg);
            resolve(e.data.bundle);
        }
        window.addEventListener("message", onMsg);
    });
}

// ── Metadata rendering ───────────────────────────────────────────────
function renderMeta(bundle) {
    const r = bundle.request || {};
    const w = bundle.response || {};
    $meta.innerHTML = "";
    const row = (k, v) => {
        const dt = document.createElement("dt"); dt.textContent = k;
        const dd = document.createElement("dd"); dd.textContent = v;
        $meta.appendChild(dt);
        $meta.appendChild(dd);
    };
    row("method", r.method || "?");
    row("path",   r.path || "?");
    row("host",   r.host || "?");
    row("status (original)", String(w.status ?? "?"));
    row("outcome",           w.outcome || "?");
    row("deployment",        String(bundle.deployment_id ?? "?"));
    if (w.exception) row("exception (original)", w.exception);
}

// ── Trace event collection + decode ──────────────────────────────────
//
// Binary layouts (see qjs-arena-trace.c):
//   NAME       [u32 atom][u16 len][len bytes]
//   FUNC_ENTER [u32 name_atom][u32 file_atom][u32 line]
//   FUNC_EXIT  (empty)
//   LINE       [u32 file_atom][u32 line]
//   THROW      [u32 file_atom][u32 line][u16 msg_len][msg bytes]

class TraceCollector {
    constructor(Module) {
        this.Module = Module;
        this.events = [];
        this.names = new Map();  // atom u32 → string
        this.decoder = new TextDecoder();
    }

    install() {
        // Module.host_trace runs synchronously inside arena_run_module.
        // Return 0 to continue; we never stop in v1.
        this.Module.host_trace = (kind, ptr, len) => {
            this._handle(kind, ptr, len);
            return 0;
        };
    }

    _handle(kind, ptr, len) {
        const M = this.Module;
        switch (kind) {
            case K_NAME: {
                const atom = M.HEAPU32[ptr >> 2];
                const slen = M.HEAPU16[(ptr + 4) >> 1];
                const s = this.decoder.decode(M.HEAPU8.subarray(ptr + 6, ptr + 6 + slen));
                this.names.set(atom, s);
                return;  // NAME is out-of-band, not appended to events
            }
            case K_FUNC_ENTER:
                this.events.push({
                    kind: "enter",
                    name_atom: M.HEAPU32[ptr >> 2],
                    file_atom: M.HEAPU32[(ptr + 4) >> 2],
                    line:      M.HEAPU32[(ptr + 8) >> 2],
                });
                return;
            case K_FUNC_EXIT:
                this.events.push({ kind: "exit" });
                return;
            case K_LINE:
                this.events.push({
                    kind: "line",
                    file_atom: M.HEAPU32[ptr >> 2],
                    line:      M.HEAPU32[(ptr + 4) >> 2],
                });
                return;
            case K_THROW: {
                const fileAtom = M.HEAPU32[ptr >> 2];
                const line     = M.HEAPU32[(ptr + 4) >> 2];
                const mlen     = M.HEAPU16[(ptr + 8) >> 1];
                const msg = this.decoder.decode(M.HEAPU8.subarray(ptr + 10, ptr + 10 + mlen));
                this.events.push({ kind: "throw", file_atom: fileAtom, line, message: msg });
                return;
            }
        }
    }

    resolveName(atom) { return this.names.get(atom) || `<atom:${atom}>`; }
}

// ── Timeline rendering ───────────────────────────────────────────────
//
// One <li> per FUNC_ENTER and THROW, indented by the call depth at
// that moment. FUNC_EXIT is implicit — used only to track depth so
// the next enter renders at the right indent. Each row carries its
// event index in a data attribute so future drill-into-state can
// re-run with stopAtEvent = idx.

function renderTimeline(collector) {
    $timeline.innerHTML = "";
    if (collector.events.length === 0) {
        const li = document.createElement("li");
        li.className = "timeline-empty";
        li.textContent = "(no events — try running in DRILL mode for line-level detail)";
        $timeline.appendChild(li);
        return;
    }

    let depth = 0;
    let eventIdx = 0;
    for (const e of collector.events) {
        eventIdx++;
        if (e.kind === "exit") { depth--; continue; }

        const li = document.createElement("li");
        li.dataset.eventIndex = String(eventIdx);

        const idx = document.createElement("span");
        idx.className = "idx";
        idx.textContent = String(eventIdx);
        li.appendChild(idx);

        if (depth > 0) {
            const nest = document.createElement("span");
            nest.className = "nest";
            nest.textContent = "│ ".repeat(depth);
            li.appendChild(nest);
        }

        if (e.kind === "enter") {
            const fn = document.createElement("span");
            fn.className = "fn";
            fn.textContent = "▸ " + collector.resolveName(e.name_atom);
            li.appendChild(fn);

            const loc = document.createElement("span");
            loc.className = "loc";
            loc.textContent = collector.resolveName(e.file_atom) + ":" + e.line;
            li.appendChild(loc);

            depth++;
        } else if (e.kind === "throw") {
            li.classList.add("throw");
            const fn = document.createElement("span");
            fn.className = "fn";
            fn.textContent = "⚠ throw";
            li.appendChild(fn);

            const loc = document.createElement("span");
            loc.className = "loc";
            loc.textContent = collector.resolveName(e.file_atom) + ":" + e.line;
            li.appendChild(loc);

            const msg = document.createElement("span");
            msg.className = "msg";
            msg.textContent = e.message || "";
            li.appendChild(msg);
        } else if (e.kind === "line") {
            // DRILL-mode only — not visible in default v1 scan mode,
            // but render compactly when present so toggling drill is
            // useful as soon as we expose a control.
            const fn = document.createElement("span");
            fn.className = "fn";
            fn.textContent = "·";
            li.appendChild(fn);
            const loc = document.createElement("span");
            loc.className = "loc";
            loc.textContent = collector.resolveName(e.file_atom) + ":" + e.line;
            li.appendChild(loc);
        }

        $timeline.appendChild(li);
    }
}

// ── Entry path resolution ────────────────────────────────────────────
function resolveEntry(bundle) {
    if (bundle.entry_path) return bundle.entry_path;
    const idx = (bundle.modules || []).find(m => m.path === "index.mjs");
    if (idx) return idx.path;
    throw new Error("bundle has no entry_path and no index.mjs");
}

function buildModuleSources(bundle) {
    const out = {};
    for (const m of (bundle.modules || [])) out[m.path] = m.source;
    return out;
}

// ── Driver ───────────────────────────────────────────────────────────
async function main() {
    let bundle;
    try {
        bundle = await awaitBundle();
    } catch (err) {
        setStatus($status, "error: " + err.message, "error");
        return;
    }

    renderMeta(bundle);
    setStatus($status, "running handler in arenajs-WASM…", "info");
    setStatus($runStatus, "booting WASM module…", "info");

    let Module;
    try {
        Module = await getArenaJs();
    } catch (err) {
        setStatus($status, "error loading WASM: " + err.message, "error");
        return;
    }
    const arena_init           = Module.cwrap("arena_init",           "number", ["number","number"]);
    const arena_run_module     = Module.cwrap("arena_run_module",     "number", ["string","string"]);
    const arena_set_trace_mode = Module.cwrap("arena_set_trace_mode", null,     ["number"]);
    const arena_destroy        = Module.cwrap("arena_destroy",        null,     []);

    if (arena_init(8192, 8192) !== 0) {
        setStatus($status, "error: arena_init failed", "error");
        return;
    }

    // Capture printf/fprintf so handler logging + exception text are
    // visible in the Output panel.
    const captured = [];
    const origPrint = Module.print, origErr = Module.printErr;
    Module.print    = (s) => { captured.push(s); origPrint?.(s); };
    Module.printErr = (s) => { captured.push("[stderr] " + s); origErr?.(s); };

    // Install trace collector BEFORE setting tapes / running; the
    // trace mode is read once at each arena_run_module start.
    const trace = new TraceCollector(Module);
    trace.install();

    try {
        Module.tapes = buildTapesFromBlobs(bundle.tape_blobs || {});
    } catch (err) {
        setStatus($status, "error parsing tape blobs: " + err.message, "error");
        arena_destroy();
        return;
    }
    Module.module_sources = buildModuleSources(bundle);

    let entryPath, entrySrc;
    try {
        entryPath = resolveEntry(bundle);
        entrySrc = Module.module_sources[entryPath];
        if (!entrySrc) throw new Error("entry source not in bundle modules: " + entryPath);
    } catch (err) {
        setStatus($status, "error: " + err.message, "error");
        arena_destroy();
        return;
    }

    setStatus($runStatus, "running " + entryPath + "…", "info");
    arena_set_trace_mode(TRACE_SCAN);
    const rc = arena_run_module(entryPath, entrySrc);
    arena_set_trace_mode(TRACE_OFF);
    arena_destroy();

    renderTimeline(trace);

    if (rc === 0) {
        setStatus($status, "handler completed", "ok");
        setStatus($runStatus,
            `ran to completion — ${trace.events.length} trace event(s)`, "ok");
    } else {
        setStatus($status, "handler error (see output)", "error");
        setStatus($runStatus,
            `exited with rc=${rc} — ${trace.events.length} trace event(s)`, "error");
    }
    $output.textContent = captured.length ? captured.join("\n") : "(no output)";
}

main();
