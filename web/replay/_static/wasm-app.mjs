// rewind.js replay shell — WASM-driven.
//
// Runs at `replay.{public_suffix}/`. The dashboard's Replay button
// opens this URL in a popup and posts a `replay:bundle` message
// once we send back `replay:ready`.
//
// Pipeline:
//   1. Receive `replay:bundle` from the dashboard.
//   2. Parse captured tape blobs via rtap.mjs (mirrors
//      src/tape/root.zig encoding rule-for-rule).
//   3. Boot arenajs-WASM once.
//   4. Drive the run through CursorEngine.materialise() (one drill
//      pass, caches events + sidecar indexes).
//   5. Render the shell from `mat` + `playhead`. Re-rendering is
//      cheap; everything we need is O(1) addressable in `mat`.
//
// What's wired this pass:
//   ✓ appbar identity + outcome badge
//   ✓ modules rail with path-prefix + basename
//   ✓ source viewport (entry by default; click switches; current line
//     tracks the playhead)
//   ✓ event stream (past/current/future styling based on playhead)
//   ✓ scrubber ticks for scan events; playhead chip
//   ✓ stack breadcrumb derived from events up to playhead
//   ✓ next-error count
//
// Still stubbed (controls disabled — coming next pass):
//   ✗ step buttons / play
//   ✗ scrubber drag
//   ✗ variables drawer (needs engine.inspectAt — wired in phase C)

import { buildTapesFromBlobs } from "./rtap.mjs";
import { CursorEngine } from "./cursor.mjs";
import getArenaJs from "./qjs_arena_wasm.js";

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
// Per-line regex tokenizer for source highlighting. Maps to the
// canonical `tok-*` classes in rewind.css: tok-kw / tok-str /
// tok-num / tok-comm. Identifiers and punctuation render neutrally.

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

function splitPath(p) {
    const i = p.lastIndexOf("/");
    return i < 0 ? { dir: "", base: p } : { dir: p.slice(0, i + 1), base: p.slice(i + 1) };
}

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

// ── Derived helpers over materialised data ───────────────────────────
//
// `mat.events` is the full drill stream (FUNC_ENTER / FUNC_EXIT /
// LINE / THROW). Most rendering is parameterised on a `playhead`
// index into this array.

// Stack snapshot at the moment the playhead event fired. Cheap to
// recompute (one O(events) walk) — and once we have mat.stackSnapshots
// from materialise() this becomes O(stackSnapshotStep). For now we
// walk linearly, which is fine for handler-scale traces.
function stackAtPlayhead(mat, playhead) {
    const stack = [];
    let throwInfo = null;
    for (let i = 0; i <= playhead && i < mat.events.length; i++) {
        const e = mat.events[i];
        if (e.kind === "FUNC_ENTER") {
            stack.push({ name: e.name, file: e.file, line: e.line });
        } else if (e.kind === "FUNC_EXIT") {
            stack.pop();
        } else if (e.kind === "LINE" && stack.length > 0) {
            stack[stack.length - 1].line = e.line;
        } else if (e.kind === "THROW") {
            throwInfo = { file: e.file, line: e.line, message: e.message };
            // Throws don't pop frames on their own.
        }
    }
    return { stack, throwInfo };
}

// (file, line) for the source viewport based on the current playhead.
function currentSourceForPlayhead(mat, playhead) {
    const { stack, throwInfo } = stackAtPlayhead(mat, playhead);
    if (throwInfo && playhead === mat.events.length - 1) {
        return { file: throwInfo.file, line: throwInfo.line };
    }
    if (stack.length > 0) {
        const top = stack[stack.length - 1];
        return { file: top.file, line: top.line };
    }
    // Outside any frame: fall back to the last seen event's file/line.
    for (let i = Math.min(playhead, mat.events.length - 1); i >= 0; i--) {
        const e = mat.events[i];
        if (e.file) return { file: e.file, line: e.line };
    }
    return { file: null, line: null };
}

// Scan-grain events only — for the event stream + scrubber.
function scanEventsOf(mat) {
    return mat.events.filter(e => e.kind !== "FUNC_EXIT" && e.kind !== "LINE");
}

// ── Rendering ────────────────────────────────────────────────────────

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

// Event stream: render scan-grain events as cards, mark past / current
// / future based on the playhead's scan ordinal.
function renderEventStream(mat, playhead) {
    $.stream.replaceChildren();
    const events = mat.events;
    if (events.length === 0) {
        $.stream.appendChild(el("li", {
            className: "stream__empty t-meta t-dim",
            text: "(no events captured — handler exited at module load?)",
        }));
        return;
    }
    // Map each scan event's idx-in-events to past/current/future.
    let scanOrd = 0;
    const playheadEvent = events[playhead];
    const playheadScanOrd = playheadEvent && playheadEvent.scanOrdinal != null
        ? playheadEvent.scanOrdinal
        : -1;

    for (let i = 0; i < events.length; i++) {
        const e = events[i];
        if (e.kind === "FUNC_EXIT" || e.kind === "LINE") continue;
        // FUNC_ENTER + THROW = scan events.

        const cls = (e.scanOrdinal === playheadScanOrd) ? "ev--current"
                  : (e.scanOrdinal <  playheadScanOrd) ? "ev--past"
                  :                                      "ev--future";
        const li = el("li", { className: "ev " + cls });

        const rail = el("div", { className: "ev__rail" });
        rail.appendChild(el("span", {
            className: "ev__dot " + (e.kind === "THROW" ? "c-error" : "c-info"),
            attrs: { "aria-hidden": "true" },
        }));
        if (cls === "ev--current") {
            rail.appendChild(el("span", {
                className: "ev__playhead",
                attrs: { "aria-hidden": "true" },
            }));
        }
        li.appendChild(rail);

        const body = el("div", { className: "ev__body" });
        const head = el("div", { className: "ev__head" });
        head.appendChild(el("span", {
            className: "t-mono-sm " + (e.kind === "THROW" ? "c-error" : "c-info"),
            text: e.kind === "THROW" ? "throw" : "fn enter",
        }));
        head.appendChild(el("span", {
            className: "ev__t t-mono-sm "
                + (cls === "ev--current" ? "c-brand" : "t-dimmer"),
            text: String(e.scanOrdinal + 1),
        }));
        body.appendChild(head);

        if (e.kind === "FUNC_ENTER") {
            body.appendChild(el("div", {
                className: "t-mono-sm t-dim",
                text: e.name,
            }));
            body.appendChild(el("div", {
                className: "ev__detail t-mono-sm t-dimmer",
                text: e.file + ":" + e.line,
            }));
        } else if (e.kind === "THROW") {
            body.appendChild(el("div", {
                className: "t-mono-sm c-error",
                text: e.message || "(no message)",
            }));
            body.appendChild(el("div", {
                className: "ev__detail t-mono-sm t-dimmer",
                text: e.file + ":" + e.line,
            }));
        }
        li.appendChild(body);
        $.stream.appendChild(li);
        scanOrd++;
    }
}

// Scrubber ticks: one per scan event, evenly spaced. Throws get the
// big-tick treatment. Playhead chip + played-gradient track the
// playhead's scan ordinal.
function renderScrubber(mat, playhead) {
    $.scrubberTicks.replaceChildren();
    const scans = scanEventsOf(mat);
    if (scans.length === 0) return;

    const n = scans.length;
    scans.forEach((e, i) => {
        const pct = ((i + 0.5) / n) * 100;
        const tick = el("span", {
            className: "scrubber__tick" + (e.kind === "THROW" ? " scrubber__tick--big" : ""),
            style: {
                left: pct.toFixed(2) + "%",
                background: e.kind === "THROW" ? "var(--c-error)" : "var(--c-info)",
            },
            title: `${i + 1} · ${e.kind === "THROW" ? "throw" : "fn enter " + (e.name ?? "")}`,
        });
        $.scrubberTicks.appendChild(tick);
    });

    const ev = mat.events[playhead];
    const scanOrd = ev?.scanOrdinal ?? 0;
    const pct = ((scanOrd + 0.5) / n) * 100;

    $.scrubberPlayed.style.width = pct.toFixed(2) + "%";
    $.scrubberPlayhead.style.display = "";
    $.scrubberPlayhead.style.left = pct.toFixed(2) + "%";
    const chip = $.scrubberPlayhead.querySelector(".scrubber__playhead-chip");
    if (chip) chip.textContent = `${scanOrd + 1} / ${n}`;

    $.transportTime.replaceChildren(
        el("span", { className: "c-brand", text: "event " + (scanOrd + 1) }),
        el("span", { className: "t-dim", text: " of " + n }),
    );
}

// Stack breadcrumb at the playhead. Replaces the previous "snapshot
// at throw or end" rendering — now we know the stack at any event.
function renderStackBreadcrumb(mat, playhead) {
    const { stack, throwInfo } = stackAtPlayhead(mat, playhead);
    $.stack.replaceChildren();

    if (stack.length === 0) {
        const ev = mat.events[playhead];
        let msg;
        if (throwInfo && ev?.kind === "THROW") {
            msg = "(throw at module top-level — no frames to walk)";
        } else if (playhead >= mat.events.length - 1) {
            // Playhead is at end of run, no throw, all frames exited.
            msg = "(handler exited cleanly — mid-run frames need stepping)";
        } else {
            msg = "(outside any frame)";
        }
        $.stack.appendChild(el("span", {
            className: "t-meta t-dim",
            text: msg,
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
            const errOnTop = throwInfo && mat.events[playhead]?.kind === "THROW";
            btn.appendChild(el("span", {
                className: "stack__frame-line t-mono-sm" + (errOnTop ? " c-error" : ""),
                text: ":" + (errOnTop ? throwInfo.line : frame.line),
            }));
        }
        $.stack.appendChild(btn);
    }
}

function renderNextError(mat, playhead) {
    const throwsTotal = mat.events.filter(e => e.kind === "THROW").length;
    if (throwsTotal === 0) {
        $.nextErrorBtn.disabled = true;
        $.nextErrorLabel.textContent = "No throws in this recording";
        $.nextErrorBtn.title = "No throws in this recording.";
        return;
    }
    // Always enable if there are throws in the recording. The button's
    // click handler (phase B) jumps to the next throw after the
    // playhead, wrapping to the first throw if past all of them.
    $.nextErrorBtn.disabled = false;
    $.nextErrorLabel.textContent = `Next throw · ${throwsTotal}`;
    $.nextErrorBtn.title = `${throwsTotal} throw(s) in this recording (E)`;
}

function renderError(err) {
    $.meta.replaceChildren(
        el("span", { className: "badge badge--error", text: "load error" }),
        el("span", { className: "t-mono", text: err.message || String(err) }),
    );
}

// ── App state + entry ────────────────────────────────────────────────

const state = {
    bundle: null,
    mat: null,
    playhead: 0,
    currentModule: null,
};

function renderAll() {
    if (!state.mat) return;
    const src = currentSourceForPlayhead(state.mat, state.playhead);
    // Auto-follow source: when the playhead lands in a module other
    // than the one the user is browsing, switch to it. The user can
    // override by clicking another module in the rail (we just stop
    // auto-following until a step lands somewhere else again — for
    // now we always auto-follow, the toggle is a phase-B follow-up).
    if (src.file && src.file !== state.currentModule) {
        state.currentModule = src.file;
        renderModulesRail(state.bundle, state.currentModule, selectModule);
    }
    renderSourceView(state.bundle, state.currentModule, src.line);
    renderStackBreadcrumb(state.mat, state.playhead);
    renderEventStream(state.mat, state.playhead);
    renderScrubber(state.mat, state.playhead);
    renderNextError(state.mat, state.playhead);
}

function selectModule(path) {
    state.currentModule = path;
    renderModulesRail(state.bundle, state.currentModule, selectModule);
    // Don't reach into the playhead's line when the user is browsing
    // a non-current module; show the file without a line highlight.
    const src = currentSourceForPlayhead(state.mat || { events: [] }, state.playhead);
    const lineForView = (path === src.file) ? src.line : null;
    renderSourceView(state.bundle, path, lineForView);
}

async function main() {
    let bundle;
    try {
        bundle = await awaitBundle();
    } catch (err) {
        renderError(err);
        return;
    }
    state.bundle = bundle;

    renderAppbar(bundle);

    let entryPath;
    try {
        entryPath = resolveEntry(bundle);
    } catch (err) {
        renderError(err);
        return;
    }
    state.currentModule = entryPath;
    renderModulesRail(bundle, state.currentModule, selectModule);
    renderSourceView(bundle, state.currentModule, null);

    $.sourceState.textContent = "booting WASM…";

    let Module;
    try {
        Module = await getArenaJs();
    } catch (err) {
        renderError(new Error("WASM load failed: " + err.message));
        return;
    }

    const arena_init    = Module.cwrap("arena_init",    "number", ["number","number"]);
    const arena_destroy = Module.cwrap("arena_destroy", null,     []);

    if (arena_init(8192, 8192) !== 0) {
        renderError(new Error("arena_init failed"));
        return;
    }

    let tapes;
    try {
        tapes = buildTapesFromBlobs(bundle.tape_blobs || {});
    } catch (err) {
        renderError(new Error("tape parse failed: " + err.message));
        arena_destroy();
        return;
    }

    const moduleSources = buildModuleSources(bundle);
    const entrySrc = moduleSources[entryPath];
    if (!entrySrc) {
        renderError(new Error("entry source not in bundle: " + entryPath));
        arena_destroy();
        return;
    }

    // Surface engine output in case the handler prints / errors.
    const captured = [];
    const origPrint = Module.print, origErr = Module.printErr;
    Module.print    = (s) => { captured.push(s); origPrint?.(s); };
    Module.printErr = (s) => { captured.push("[stderr] " + s); origErr?.(s); };

    $.sourceState.textContent = "running…";
    const engine = new CursorEngine(Module);
    let mat;
    try {
        mat = await engine.materialise(
            { entry: { name: entryPath, src: entrySrc }, tapes, module_sources: moduleSources },
            { targetSnapshots: 0 },  // var snapshots come in phase C
        );
    } catch (err) {
        renderError(new Error("materialise failed: " + err.message));
        arena_destroy();
        return;
    }

    state.mat = mat;
    // Park the playhead at the throw if there is one, else at the
    // end. Matches the destination the previous (non-cursor) shell
    // landed on by default. Step buttons in phase B will let the
    // user walk forward/back from anywhere.
    const throwIdx = mat.events.findIndex(e => e.kind === "THROW");
    state.playhead = throwIdx >= 0 ? throwIdx : Math.max(0, mat.events.length - 1);
    renderAll();

    $.sourceState.textContent = `completed · ${mat.events.length} event(s)`;
}

main();
