// rewind.js replay shell — WASM-driven path.
//
// Runs at `replay.{public_suffix}/wasm`. Same opener/postMessage
// handshake as the iframe replay (web/replay/app.js) so the
// dashboard's Replay button can target either URL — what differs
// is what we do with the bundle once we have it.
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
//   6. Render the shell — appbar / modules rail / source viewport /
//      event stream / scrubber — populated from the bundle + trace.
//
// This pass renders the full mockup chrome but only drives the
// pieces the current engine supports:
//   ✓ appbar identity + outcome badge
//   ✓ modules rail with path-prefix + basename
//   ✓ source viewport (entry module by default; click a module to
//     switch); throw lines highlighted
//   ✓ event stream (function enters + throws)
//   ✓ scrubber ticks (one per scan event)
//   ✓ next-error button (jump to next throw)
//   ✗ stack breadcrumb     — needs host_state stack-walker
//   ✗ variables drawer     — needs DRILL-mode + host_state
//   ✗ step buttons / play  — needs the arenajs cursor API
//   ✗ scrubber drag        — needs cursor API for snap-to-scan
//
// The disabled controls are part of the chrome so the contract for
// future passes is visible. Wiring them up is mechanical once the
// cursor API lands.

import { buildTapesFromBlobs } from "./rtap.mjs";
import getArenaJs from "./qjs_arena_wasm.js";

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

// ── DOM refs (lookup once at module load) ────────────────────────────
const $ = {
    crumb:           document.getElementById("appbar-crumb"),
    meta:            document.getElementById("appbar-meta"),
    stack:           document.getElementById("stack-frames"),
    nextErrorBtn:    document.getElementById("next-error-btn"),
    nextErrorLabel:  document.getElementById("next-error-label"),
    modTree:         document.getElementById("mod-tree"),
    sourceHeader:    document.getElementById("source-header"),
    sourceState:     document.getElementById("source-state"),
    sourceCode:      document.getElementById("source-code"),
    stream:          document.getElementById("event-stream"),
    scrubberTicks:   document.getElementById("scrubber-ticks"),
    scrubberPlayed:  document.getElementById("scrubber-played"),
    scrubberPlayhead: document.getElementById("scrubber-playhead"),
    transportTime:   document.getElementById("transport-time"),
};

// ── JavaScript syntax tokenizer ──────────────────────────────────────
//
// Per-line regex tokenizer for source highlighting. Maps to the
// canonical `tok-*` classes in rewind.css: tok-kw / tok-str /
// tok-num / tok-comm. Identifiers and punctuation render neutrally
// (no class), which keeps the source readable without going
// rainbow-noisy.
//
// Known limitations (acceptable for replay's source viewer):
//   - Block comments that span multiple lines render the body
//     lines uncolored (the open `/*` line gets the comment tint).
//   - Regex literals and JSX aren't recognized — both are rare in
//     handler code and would need full parser context.
//   - Template-literal substitutions (`${expr}`) render as one
//     opaque string, not as nested syntax.

const TOK_PATTERNS = [
    { type: "comment", re: /^\/\/.*/ },
    { type: "comment", re: /^\/\*[\s\S]*?\*\// },
    { type: "string",  re: /^"(?:[^"\\]|\\.)*"/ },
    { type: "string",  re: /^'(?:[^'\\]|\\.)*'/ },
    { type: "string",  re: /^`(?:[^`\\]|\\.)*`/ },
    { type: "number",  re: /^\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/ },
    { type: "keyword", re: /^(?:const|let|var|function|async|await|return|throw|new|if|else|for|while|of|in|import|export|from|class|extends|try|catch|finally|typeof|instanceof|break|continue|switch|case|default|null|true|false|undefined|this|do|delete|void|yield|static|get|set)\b/ },
    { type: "ident",   re: /^[a-zA-Z_$][a-zA-Z0-9_$]*/ },
    { type: "punc",    re: /^[+\-*/%=<>!&|^~?:.,;()[\]{}]+/ },
    { type: "space",   re: /^\s+/ },
];

const TOK_CLASS = {
    keyword: "tok-kw",
    string:  "tok-str",
    number:  "tok-num",
    comment: "tok-comm",
};

function tokenize(src) {
    const tokens = [];
    let pos = 0;
    while (pos < src.length) {
        let matched = false;
        const rest = src.slice(pos);
        for (const { type, re } of TOK_PATTERNS) {
            const m = rest.match(re);
            if (m && m.index === 0) {
                tokens.push({ type, text: m[0] });
                pos += m[0].length;
                matched = true;
                break;
            }
        }
        if (!matched) {
            tokens.push({ type: "other", text: src[pos] });
            pos++;
        }
    }
    return tokens;
}

// Append a tokenized JS line into `parent`. Token classes are
// inserted as spans; identifiers / punctuation / whitespace render
// as bare text nodes.
function appendTokenized(parent, lineSrc) {
    for (const tok of tokenize(lineSrc)) {
        const cls = TOK_CLASS[tok.type];
        if (cls) {
            const span = document.createElement("span");
            span.className = cls;
            span.textContent = tok.text;
            parent.appendChild(span);
        } else {
            parent.appendChild(document.createTextNode(tok.text));
        }
    }
}

// ── Small helpers ────────────────────────────────────────────────────

function el(tag, opts = {}) {
    const e = document.createElement(tag);
    if (opts.className) e.className = opts.className;
    if (opts.text != null) e.textContent = String(opts.text);
    if (opts.title) e.title = opts.title;
    if (opts.style) Object.assign(e.style, opts.style);
    if (opts.attrs) for (const [k, v] of Object.entries(opts.attrs)) e.setAttribute(k, v);
    return e;
}

// Split "src/lib/pricing.mjs" → { dir: "src/lib/", base: "pricing.mjs" }
// "index.mjs" → { dir: "", base: "index.mjs" }
function splitPath(p) {
    const i = p.lastIndexOf("/");
    return i < 0 ? { dir: "", base: p } : { dir: p.slice(0, i + 1), base: p.slice(i + 1) };
}

// Short content-hash for the modules rail. The bundle doesn't carry
// per-module hashes today, so derive a stable 4-char fingerprint from
// the source bytes. Same source → same fingerprint, so duplicate
// modules dedup visually.
function shortHash(s) {
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) {
        h ^= s.charCodeAt(i);
        h = (h * 0x01000193) >>> 0;
    }
    return h.toString(16).padStart(8, "0").slice(0, 4);
}

function badgeKindFor(status) {
    if (status == null) return "";
    if (status >= 200 && status < 300) return "badge--ok";
    if (status >= 300 && status < 400) return "badge--info";
    if (status >= 400 && status < 500) return "badge--warn";
    return "badge--error";
}

// ── postMessage handshake ────────────────────────────────────────────
//
// Opener is the dashboard at `app.<suffix>`, we're at `replay.<suffix>`.
// Origin check derives the expected origin from our own so it works
// across loop46.me / loop46.localhost / any future suffix.
function expectedDashboardOrigin() {
    return window.location.origin.replace("://replay.", "://app.");
}

function awaitBundle() {
    if (!window.opener) {
        return Promise.reject(new Error(
            "open this page from the dashboard's Replay button"));
    }
    const expectedOrigin = expectedDashboardOrigin();
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

// ── Trace collector ──────────────────────────────────────────────────
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
        this.names = new Map();
        this.decoder = new TextDecoder();
    }

    install() {
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
                return;
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

// ── Rendering ────────────────────────────────────────────────────────

// Appbar: tenant crumb + outcome badge + method/path. Tenant is
// derived from the request host ("acme.foo.com" → "acme"); falls
// back to the full host when host can't be parsed.
function renderAppbar(bundle) {
    const req = bundle.request || {};
    const res = bundle.response || {};

    const tenant = (req.host || "").split(".")[0] || req.host || "—";
    const recId = bundle.recording_id || bundle.deployment_id || "—";

    $.crumb.replaceChildren(
        el("span", { text: tenant }),
        el("span", { className: "crumb__sep", text: "/" }),
        el("span", { text: "recordings" }),
        el("span", { className: "crumb__sep", text: "/" }),
        el("span", { className: "c-brand t-mono", text: String(recId).slice(0, 14) }),
    );

    $.meta.replaceChildren();
    if (res.status != null) {
        $.meta.appendChild(el("span", {
            className: "badge " + badgeKindFor(res.status),
            text: String(res.status),
        }));
    }
    if (req.method || req.path) {
        $.meta.appendChild(el("span", {
            className: "t-mono",
            text: `${req.method || "?"} ${req.path || "?"}`,
        }));
    }
    if (res.outcome) {
        $.meta.appendChild(el("span", { className: "t-mute", text: "·" }));
        $.meta.appendChild(el("span", { text: res.outcome }));
    }
}

// Modules rail: one row per bundle module. Path prefix dim, basename
// bright. Entry path gets is-current. Click switches the source view.
function renderModulesRail(bundle, currentPath, onSelect) {
    const modules = bundle.modules || [];
    $.modTree.replaceChildren();
    if (modules.length === 0) {
        $.modTree.appendChild(el("li", {
            className: "t-meta t-dim",
            text: "(no modules in bundle)",
            style: { padding: "var(--sp-2) var(--sp-4)" },
        }));
        return;
    }
    for (const m of modules) {
        const li = el("li", {
            className: "mod-tree__item" + (m.path === currentPath ? " is-current" : ""),
        });
        const { dir, base } = splitPath(m.path);
        const file = el("span", { className: "mod-tree__file t-mono" });
        if (dir) file.appendChild(el("span", { className: "mod-tree__dir", text: dir }));
        file.appendChild(document.createTextNode(base));
        li.appendChild(file);
        li.appendChild(el("span", {
            className: "mod-tree__hash t-dimmer t-mono-sm",
            text: shortHash(m.source || ""),
            title: "Content fingerprint — same value means byte-identical source",
        }));
        li.addEventListener("click", () => onSelect(m.path));
        $.modTree.appendChild(li);
    }
}

// Source viewport: gutter with line numbers + code body. If a
// highlightLine is given, that line gets is-current styling.
function renderSourceView(bundle, modulePath, highlightLine) {
    const mod = (bundle.modules || []).find(m => m.path === modulePath);
    const src = mod?.source || "";

    const { dir, base } = splitPath(modulePath);
    $.sourceHeader.replaceChildren();
    if (dir) $.sourceHeader.appendChild(el("span", { className: "t-dim", text: dir }));
    $.sourceHeader.appendChild(el("span", { className: "c-info", text: base }));
    if (highlightLine != null) {
        $.sourceHeader.appendChild(el("span", { className: "t-dim", text: " · line" }));
        $.sourceHeader.appendChild(el("span", { className: "c-brand", text: " " + highlightLine }));
    }

    const lines = src.split("\n");
    $.sourceCode.replaceChildren();
    const gutter = el("div", { className: "code__gutter" });
    const body   = el("div", { className: "code__body" });
    for (let i = 0; i < lines.length; i++) {
        const lineNo = i + 1;
        gutter.appendChild(el("span", { className: "ln", text: String(lineNo) }));
        const lineSpan = el("span", {
            className: "line" + (lineNo === highlightLine ? " is-current" : ""),
        });
        appendTokenized(lineSpan, lines[i]);
        lineSpan.appendChild(document.createTextNode("\n"));
        body.appendChild(lineSpan);
    }
    $.sourceCode.appendChild(gutter);
    $.sourceCode.appendChild(body);
}

// Event stream: function enters and throws as cards. Function exits
// are skipped (they're depth-tracking only). Line events are skipped
// unless we're in DRILL mode (later pass).
function renderEventStream(collector) {
    $.stream.replaceChildren();
    const scanEvents = collector.events.filter(e => e.kind !== "exit" && e.kind !== "line");
    if (scanEvents.length === 0) {
        $.stream.appendChild(el("li", {
            className: "stream__empty t-meta t-dim",
            text: "(no events captured — handler exited at module load?)",
        }));
        return;
    }
    let idx = 0;
    for (const e of scanEvents) {
        idx++;
        const li = el("li", { className: "ev ev--past" });
        const rail = el("div", { className: "ev__rail" });
        rail.appendChild(el("span", {
            className: "ev__dot " + (e.kind === "throw" ? "c-error" : "c-info"),
            attrs: { "aria-hidden": "true" },
        }));
        li.appendChild(rail);

        const body = el("div", { className: "ev__body" });
        const head = el("div", { className: "ev__head" });
        const kindEl = el("span", {
            className: "t-mono-sm " + (e.kind === "throw" ? "c-error" : "c-info"),
            text: e.kind === "throw" ? "throw" : "fn enter",
        });
        head.appendChild(kindEl);
        head.appendChild(el("span", {
            className: "ev__t t-mono-sm t-dimmer",
            text: String(idx),
        }));
        body.appendChild(head);

        if (e.kind === "enter") {
            body.appendChild(el("div", {
                className: "t-mono-sm t-dim",
                text: collector.resolveName(e.name_atom),
            }));
            body.appendChild(el("div", {
                className: "ev__detail t-mono-sm t-dimmer",
                text: collector.resolveName(e.file_atom) + ":" + e.line,
            }));
        } else if (e.kind === "throw") {
            body.appendChild(el("div", {
                className: "t-mono-sm c-error",
                text: e.message || "(no message)",
            }));
            body.appendChild(el("div", {
                className: "ev__detail t-mono-sm t-dimmer",
                text: collector.resolveName(e.file_atom) + ":" + e.line,
            }));
        }
        li.appendChild(body);
        $.stream.appendChild(li);
    }
}

// Scrubber ticks: one per scan event, evenly spaced. Throws get the
// "big tick" treatment. Playhead is hidden in this pass (no
// stepping yet); the played-portion gradient is also hidden.
function renderScrubber(collector) {
    $.scrubberTicks.replaceChildren();
    const scanEvents = collector.events.filter(e => e.kind !== "exit" && e.kind !== "line");
    if (scanEvents.length === 0) return;

    const n = scanEvents.length;
    scanEvents.forEach((e, i) => {
        const pct = ((i + 0.5) / n) * 100;  // center each tick in its slot
        const tick = el("span", {
            className: "scrubber__tick" + (e.kind === "throw" ? " scrubber__tick--big" : ""),
            style: {
                left: pct.toFixed(2) + "%",
                background: e.kind === "throw" ? "var(--c-error)" : "var(--c-info)",
            },
            title: `${i + 1} · ${e.kind === "throw" ? "throw" : "fn enter " + collector.resolveName(e.name_atom)}`,
        });
        $.scrubberTicks.appendChild(tick);
    });

    $.transportTime.replaceChildren(
        el("span", { className: "c-brand", text: "event " + n }),
        el("span", { className: "t-dim", text: " of " + n }),
    );
}

// Stack breadcrumb: derive a call-stack snapshot from FUNC_ENTER /
// FUNC_EXIT events. Two cases we can usefully render today:
//
//   1. Recording threw → snapshot the stack AT the throw event
//      (the throw happens inside the deepest frame, no exits yet).
//      Render the throw line as the rightmost frame's `:N` suffix
//      with c-error styling.
//
//   2. Recording exited cleanly → final stack is empty. Render a
//      placeholder explaining that mid-run frames need stepping
//      (which itself needs the cursor API, not yet wired).
//
// Once stepping lands, this function gets a `currentEventIdx`
// argument that bounds the walk — the snapshot becomes "stack at
// scan record N" rather than "stack at throw" or "stack at end".

function renderStackBreadcrumb(collector) {
    const stack = [];
    let throwInfo = null;
    for (const e of collector.events) {
        if (e.kind === "enter") {
            stack.push({
                name: collector.resolveName(e.name_atom),
                file: collector.resolveName(e.file_atom),
                line: e.line,
            });
        } else if (e.kind === "exit") {
            stack.pop();
        } else if (e.kind === "throw") {
            throwInfo = {
                file: collector.resolveName(e.file_atom),
                line: e.line,
                message: e.message,
            };
            break;  // snapshot at throw; don't unwind
        }
    }

    $.stack.replaceChildren();
    if (stack.length === 0) {
        $.stack.appendChild(el("span", {
            className: "t-meta t-dim",
            text: throwInfo
                ? "(throw at module top-level — no frames to walk)"
                : "(handler exited cleanly — mid-run frames need stepping)",
            style: { padding: "0 var(--sp-2)" },
        }));
        return;
    }

    for (let i = 0; i < stack.length; i++) {
        const frame = stack[i];
        const isLast = i === stack.length - 1;
        if (i > 0) {
            $.stack.appendChild(el("span", {
                className: "stack__chev",
                text: "›",
                attrs: { "aria-hidden": "true" },
            }));
        }
        const btn = el("button", {
            className: "stack__frame" + (isLast ? " is-current" : ""),
        });
        btn.appendChild(el("span", {
            className: "stack__frame-file t-mono-sm t-dim",
            text: frame.file,
        }));
        btn.appendChild(el("span", {
            className: "stack__frame-fn t-mono",
            text: frame.name,
        }));
        if (isLast) {
            const lineText = ":" + (throwInfo ? throwInfo.line : frame.line);
            btn.appendChild(el("span", {
                className: "stack__frame-line t-mono-sm" + (throwInfo ? " c-error" : ""),
                text: lineText,
            }));
        }
        $.stack.appendChild(btn);
    }
}

// Next-error: enable if any throws exist; count throws total.
// Wiring it to actually jump comes with the cursor API; for now
// the button is decorative-but-honest.
function renderNextError(collector) {
    const throws = collector.events.filter(e => e.kind === "throw");
    if (throws.length === 0) {
        $.nextErrorBtn.disabled = true;
        $.nextErrorLabel.textContent = "No throws in this recording";
        $.nextErrorBtn.title = "No throws in this recording.";
        return;
    }
    $.nextErrorBtn.disabled = false;
    $.nextErrorLabel.textContent = `Next throw · ${throws.length}`;
    $.nextErrorBtn.title = `${throws.length} throw(s) in this recording (E)`;
}

// Surface a load/run error in the appbar meta strip and bail out
// of the normal render flow.
function renderError(err) {
    $.meta.replaceChildren(
        el("span", { className: "badge badge--error", text: "load error" }),
        el("span", { className: "t-mono", text: err.message || String(err) }),
    );
}

// ── Bundle helpers ───────────────────────────────────────────────────

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
        renderError(err);
        return;
    }

    renderAppbar(bundle);

    let currentModule;
    try {
        currentModule = resolveEntry(bundle);
    } catch (err) {
        renderError(err);
        return;
    }
    const selectModule = (path) => {
        currentModule = path;
        renderModulesRail(bundle, currentModule, selectModule);
        renderSourceView(bundle, currentModule, null);
    };
    renderModulesRail(bundle, currentModule, selectModule);
    renderSourceView(bundle, currentModule, null);

    $.sourceState.textContent = "booting WASM…";

    let Module;
    try {
        Module = await getArenaJs();
    } catch (err) {
        renderError(new Error("WASM load failed: " + err.message));
        return;
    }
    const arena_init           = Module.cwrap("arena_init",           "number", ["number","number"]);
    const arena_run_module     = Module.cwrap("arena_run_module",     "number", ["string","string"]);
    const arena_set_trace_mode = Module.cwrap("arena_set_trace_mode", null,     ["number"]);
    const arena_destroy        = Module.cwrap("arena_destroy",        null,     []);

    if (arena_init(8192, 8192) !== 0) {
        renderError(new Error("arena_init failed"));
        return;
    }

    const captured = [];
    const origPrint = Module.print, origErr = Module.printErr;
    Module.print    = (s) => { captured.push(s); origPrint?.(s); };
    Module.printErr = (s) => { captured.push("[stderr] " + s); origErr?.(s); };

    const trace = new TraceCollector(Module);
    trace.install();

    try {
        Module.tapes = buildTapesFromBlobs(bundle.tape_blobs || {});
    } catch (err) {
        renderError(new Error("tape parse failed: " + err.message));
        arena_destroy();
        return;
    }
    Module.module_sources = buildModuleSources(bundle);

    const entrySrc = Module.module_sources[currentModule];
    if (!entrySrc) {
        renderError(new Error("entry source not in bundle: " + currentModule));
        arena_destroy();
        return;
    }

    $.sourceState.textContent = "running…";
    arena_set_trace_mode(TRACE_SCAN);
    const rc = arena_run_module(currentModule, entrySrc);
    arena_set_trace_mode(TRACE_OFF);
    arena_destroy();

    // If any throw was captured, jump the source view to that line.
    const firstThrow = trace.events.find(e => e.kind === "throw");
    if (firstThrow) {
        const throwFile = trace.resolveName(firstThrow.file_atom);
        // Only swap the source if the throw is in the current module;
        // otherwise leave the user on their selected file. Future pass
        // will move the playhead and pull the view along with it.
        if (throwFile === currentModule) {
            renderSourceView(bundle, currentModule, firstThrow.line);
        } else {
            renderSourceView(bundle, currentModule, null);
        }
    }

    renderStackBreadcrumb(trace);
    renderEventStream(trace);
    renderScrubber(trace);
    renderNextError(trace);

    $.sourceState.textContent = rc === 0
        ? `completed · ${trace.events.length} trace event(s)`
        : `exited rc=${rc} · ${trace.events.length} trace event(s)`;
}

main();
