// Loop46 replay — WASM-driven path (PLAN §10.12, beta scope).
//
// Runs at `replay.{public_suffix}/wasm`. Same opener/postMessage
// handshake as the existing iframe replay (web/replay/app.js) so the
// dashboard's Replay button can target either by URL — what differs
// is what we DO with the bundle once we have it.
//
// Pipeline:
//   1. Receive `replay:bundle` from the dashboard
//   2. Parse the captured tape blobs via rtap.mjs (mirrors
//      src/tape/root.zig encoding rule-for-rule)
//   3. Install the parsed tapes + per-path module sources on the
//      Emscripten Module object
//   4. Boot arenajs-WASM and call arena_run_module(entry, source)
//   5. Display whether the handler ran to completion and what (if
//      anything) it threw
//
// V1 stops here — no timeline / scrubber / variable panel yet. Those
// layer on top of the same Module.host_trace + Module.host_state hooks
// the arenajs trace emitter already provides; this file just doesn't
// install them yet.

import { buildTapesFromBlobs } from "./rtap.mjs";
import getArenaJs from "./qjs_arena_wasm.js";

const $status    = document.getElementById("status");
const $runStatus = document.getElementById("run-status");
const $meta      = document.getElementById("meta");
const $output    = document.getElementById("output");

function setStatus(el, text, kind) {
    el.textContent = text;
    el.className = "status " + (kind || "info");
}

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

// ── Entry path resolution ────────────────────────────────────────────
//
// Same fallback the existing iframe replay uses: explicit entry_path
// in the bundle wins; otherwise look for index.mjs in the module set.
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

    // Boot the WASM module. Pre-allocate 8 MiB per arena for now —
    // matches the rove worker default; we can tighten or expose later.
    let Module;
    try {
        Module = await getArenaJs();
    } catch (err) {
        setStatus($status, "error loading WASM: " + err.message, "error");
        return;
    }
    const arena_init       = Module.cwrap("arena_init",       "number", ["number","number"]);
    const arena_run_module = Module.cwrap("arena_run_module", "number", ["string","string"]);
    const arena_destroy    = Module.cwrap("arena_destroy",    null,     []);

    if (arena_init(8192, 8192) !== 0) {
        setStatus($status, "error: arena_init failed", "error");
        return;
    }

    // Capture printf/fprintf output so we can show what the handler
    // logged or what exception text the reactor surfaced. Emscripten
    // routes stdout/stderr to console.* by default — hook print and
    // printErr on the Module before any execution.
    const captured = [];
    const origPrint = Module.print, origErr = Module.printErr;
    Module.print    = (s) => { captured.push(s); origPrint?.(s); };
    Module.printErr = (s) => { captured.push("[stderr] " + s); origErr?.(s); };

    // Install tapes + sources from the bundle.
    try {
        Module.tapes = buildTapesFromBlobs(bundle.tape_blobs || {});
    } catch (err) {
        setStatus($status, "error parsing tape blobs: " + err.message, "error");
        arena_destroy();
        return;
    }
    Module.module_sources = buildModuleSources(bundle);

    // Find the entry module + its source.
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
    const rc = arena_run_module(entryPath, entrySrc);
    arena_destroy();

    if (rc === 0) {
        setStatus($status, "handler completed", "ok");
        setStatus($runStatus, "ran to completion (rc=0)", "ok");
    } else {
        setStatus($status, "handler error (see output)", "error");
        setStatus($runStatus, "exited with rc=" + rc, "error");
    }
    $output.textContent = captured.length ? captured.join("\n") : "(no output)";
}

main();
