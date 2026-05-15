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

// Transport buttons by aria-label. The HTML names them via aria-label
// instead of ids because the natural reading is "the button labelled
// Step over" — these JS-side bindings are the implementation of that
// affordance.
function btn(label) {
    return document.querySelector(`.transport__controls button[aria-label="${label}"]`);
}
const T = {
    jumpStart: btn("Jump to start"),
    stepBack:  btn("Step back"),
    play:      btn("Play"),
    stepOver:  btn("Step over"),
    stepIn:    btn("Step into"),
    stepOut:   btn("Step out"),
    stepLine:  btn("Step line"),
    jumpEnd:   btn("Jump to end"),
};
const $scrubber = document.querySelector(".scrubber");

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

// "Visible scan" events — the events we show on the scrubber and as
// cards in the event stream. cursor.mjs's `scanOrdinal` counts every
// engine-side scan record (ENTER + EXIT + THROW), but FUNC_EXIT
// doesn't earn a tick or a card in the UI per the scrub-vs-step rule
// (function boundaries are walkable but not scrubber-jumpable). So we
// maintain our own derived index over (ENTER + THROW) and use it
// consistently for tick positions, the chip, the transport time, and
// the past/current/future styling on the stream.
//
// Returns { items, current }:
//   items[i] = { event, eventIdx } — i-th visible event in document order
//   current  = index in items of the most recent visible event at or
//              before `playhead` (-1 if playhead is before any
//              visible event)
function visibleScans(mat, playhead) {
    const items = [];
    let current = -1;
    for (let i = 0; i < mat.events.length; i++) {
        const e = mat.events[i];
        if (e.kind !== "FUNC_ENTER" && e.kind !== "THROW") continue;
        if (i <= playhead) current = items.length;
        items.push({ event: e, eventIdx: i });
    }
    return { items, current };
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

// Event stream: render visible-scan events as cards, mark past /
// current / future based on the playhead's visible index.
function renderEventStream(mat, playhead) {
    $.stream.replaceChildren();
    if (mat.events.length === 0) {
        $.stream.appendChild(el("li", {
            className: "stream__empty t-meta t-dim",
            text: "(no events captured — handler exited at module load?)",
        }));
        return;
    }
    const { items, current } = visibleScans(mat, playhead);
    if (items.length === 0) {
        $.stream.appendChild(el("li", {
            className: "stream__empty t-meta t-dim",
            text: "(no function calls or throws — handler had no observable scan events)",
        }));
        return;
    }

    items.forEach((item, i) => {
        const e = item.event;
        const cls = i === current ? "ev--current"
                  : i <  current ? "ev--past"
                  :                "ev--future";
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
            text: String(i + 1),
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
    });
}

// Scrubber rail in EVENT-INDEX space: the rail represents
// [0, mat.events.length - 1]. Each visible-scan event renders as a
// tick at its true event-index position, so ticks are irregularly
// spaced (clusters during tight loops, gaps across function-body
// runs). The playhead can drag continuously across the rail.
//
// The chip + transport time stay in visible-scan grain — the
// rail-position is "where am I in the recording," the chip is
// "which named scan event am I past."
function pctForEventIdx(mat, eventIdx) {
    const total = mat.events.length;
    if (total <= 1) return 50;
    const e = Math.max(0, Math.min(total - 1, eventIdx));
    return (e / (total - 1)) * 100;
}

function renderScrubber(mat, playhead) {
    $.scrubberTicks.replaceChildren();
    const { items, current } = visibleScans(mat, playhead);

    items.forEach(({ event: e, eventIdx }, i) => {
        const pct = pctForEventIdx(mat, eventIdx);
        const tick = el("span", {
            className: "scrubber__tick" + (e.kind === "THROW" ? " scrubber__tick--big" : ""),
            style: {
                left: pct.toFixed(3) + "%",
                background: e.kind === "THROW" ? "var(--c-error)" : "var(--c-info)",
            },
            title: `${i + 1} · ${e.kind === "THROW" ? "throw" : "fn enter " + (e.name ?? "")}`,
        });
        $.scrubberTicks.appendChild(tick);
    });

    const pct = pctForEventIdx(mat, playhead);
    $.scrubberPlayed.style.width = pct.toFixed(3) + "%";
    $.scrubberPlayhead.style.display = "";
    $.scrubberPlayhead.style.left = pct.toFixed(3) + "%";

    const shown = current < 0 ? 0 : current;
    const n = items.length || 1;
    const chip = $.scrubberPlayhead.querySelector(".scrubber__playhead-chip");
    if (chip) chip.textContent = `${shown + 1} / ${n}`;

    $.transportTime.replaceChildren(
        el("span", { className: "c-brand", text: "event " + (shown + 1) }),
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

// ── Stepping actions ─────────────────────────────────────────────────
//
// All step verbs converge on setPlayhead(); rendering is a function of
// (mat, playhead), so a single setter is enough. Granularity falls out
// of which verb the user invoked (per the scrub-vs-step memory rule).

function setPlayhead(idx) {
    if (!state.mat) return;
    const n = state.mat.events.length;
    if (n === 0) return;
    const clamped = Math.max(0, Math.min(n - 1, idx));
    if (clamped === state.playhead) return;
    state.playhead = clamped;
    renderAll();
    inspectAndRenderVars(clamped);
}

function jumpStart() { setPlayhead(0); }
function jumpEnd()   { if (state.mat) setPlayhead(state.mat.events.length - 1); }
function stepLine()  { setPlayhead(state.playhead + 1); }
function stepBack()  { setPlayhead(state.playhead - 1); }

// step-over: advance to the next event in the playhead's OWN frame,
// skipping over (descending into and emerging from) any nested
// function calls that happen in between. Stops on whichever comes
// first: the next LINE / THROW back in the original frame, or the
// FUNC_EXIT that ends the original frame.
//
// Walks events tracking a depth offset (0 at start). FUNC_ENTERs in
// between drive it positive; FUNC_EXITs bring it back. depth < 0
// signals "we just exited the original frame" — that's our stop.
// depth === 0 LINE/THROW means "back in the original frame, this is
// the next thing that happens here" — also a stop.
function stepOver() {
    if (!state.mat) return;
    const events = state.mat.events;
    const n = events.length;
    let depth = 0;
    for (let i = state.playhead + 1; i < n; i++) {
        const e = events[i];
        if (e.kind === "FUNC_ENTER") {
            depth++;
        } else if (e.kind === "FUNC_EXIT") {
            depth--;
            if (depth < 0) {
                setPlayhead(i);
                return;
            }
        } else if (depth === 0) {
            setPlayhead(i);
            return;
        }
    }
    setPlayhead(n - 1);
}

// step-in: jump to the next FUNC_ENTER after the playhead.
function stepIn() {
    if (!state.mat) return;
    const events = state.mat.events;
    for (let i = state.playhead + 1; i < events.length; i++) {
        if (events[i].kind === "FUNC_ENTER") return setPlayhead(i);
    }
    setPlayhead(events.length - 1);
}

// step-out: jump to the matching FUNC_EXIT of the frame containing the
// playhead. If we're not inside a frame, advance to end.
function stepOut() {
    if (!state.mat) return;
    const events = state.mat.events;
    // Walk back to find the most recent unmatched FUNC_ENTER.
    let depth = 0;
    let enterIdx = -1;
    for (let i = state.playhead; i >= 0; i--) {
        const e = events[i];
        if (e.kind === "FUNC_EXIT") depth++;
        else if (e.kind === "FUNC_ENTER") {
            if (depth === 0) { enterIdx = i; break; }
            depth--;
        }
    }
    if (enterIdx < 0) return setPlayhead(events.length - 1);
    const exitIdx = state.mat.matchingExit[enterIdx];
    if (exitIdx > 0) setPlayhead(exitIdx);
    else             setPlayhead(events.length - 1);
}

// next-error: jump to the next THROW after the playhead; wrap to the
// first throw if past all of them.
function nextError() {
    if (!state.mat) return;
    const events = state.mat.events;
    for (let i = state.playhead + 1; i < events.length; i++) {
        if (events[i].kind === "THROW") return setPlayhead(i);
    }
    for (let i = 0; i < events.length; i++) {
        if (events[i].kind === "THROW") return setPlayhead(i);
    }
}

// Play / pause — autoplay through events at ~300ms each (no wall-clock
// "speed" concept; the model is keyframes).
let playInterval = null;
const PLAY_INTERVAL_MS = 300;
function isPlaying() { return playInterval !== null; }
function pause() {
    if (playInterval) clearInterval(playInterval);
    playInterval = null;
    if (T.play) T.play.textContent = "▶";
}
function playPause() {
    if (!state.mat) return;
    if (isPlaying()) return pause();
    if (state.playhead >= state.mat.events.length - 1) {
        setPlayhead(0);
    }
    playInterval = setInterval(() => {
        if (!state.mat || state.playhead >= state.mat.events.length - 1) {
            pause();
            return;
        }
        setPlayhead(state.playhead + 1);
    }, PLAY_INTERVAL_MS);
    if (T.play) T.play.textContent = "❚❚";
}

// Wire transport button clicks + a click on the scrubber track that
// snaps to the nearest scan event.
function wireTransport() {
    if (T.jumpStart) T.jumpStart.addEventListener("click", jumpStart);
    if (T.stepBack)  T.stepBack .addEventListener("click", stepBack);
    if (T.play)      T.play     .addEventListener("click", playPause);
    if (T.stepOver)  T.stepOver .addEventListener("click", stepOver);
    if (T.stepIn)    T.stepIn   .addEventListener("click", stepIn);
    if (T.stepOut)   T.stepOut  .addEventListener("click", stepOut);
    if (T.stepLine)  T.stepLine .addEventListener("click", stepLine);
    if (T.jumpEnd)   T.jumpEnd  .addEventListener("click", jumpEnd);
    if ($.nextErrorBtn) $.nextErrorBtn.addEventListener("click", nextError);

    // Scrubber drag — mousedown anywhere on the rail, drag continuously
    // through event-index space. Each pixel maps to an event index,
    // not a visible-scan tick. The variables drawer + source viewport
    // follow live; the playhead chip text (visible-scan grain) ticks
    // only when crossing a tick.
    if ($scrubber) {
        let dragging = false;

        const eventIdxAt = (clientX) => {
            const rect = $scrubber.getBoundingClientRect();
            const frac = Math.max(0, Math.min(1, (clientX - rect.left) / rect.width));
            const total = state.mat.events.length;
            if (total <= 1) return 0;
            return Math.round(frac * (total - 1));
        };

        $scrubber.addEventListener("mousedown", (ev) => {
            if (!state.mat) return;
            dragging = true;
            pause();  // bail out of autoplay so we don't fight the user
            ev.preventDefault();
            setPlayhead(eventIdxAt(ev.clientX));
        });
        window.addEventListener("mousemove", (ev) => {
            if (!dragging || !state.mat) return;
            setPlayhead(eventIdxAt(ev.clientX));
        });
        window.addEventListener("mouseup", () => { dragging = false; });
    }

    // Keyboard. Skip when typing in inputs.
    window.addEventListener("keydown", (ev) => {
        const tag = ev.target.tagName;
        if (tag === "INPUT" || tag === "TEXTAREA") return;
        if (ev.metaKey || ev.ctrlKey) return;
        switch (ev.key) {
            case " ":          ev.preventDefault(); playPause(); break;
            case "ArrowRight": ev.preventDefault(); stepLine();  break;
            case "ArrowLeft":  ev.preventDefault(); stepBack();  break;
            case "Home":       ev.preventDefault(); jumpStart(); break;
            case "End":        ev.preventDefault(); jumpEnd();   break;
            case "F10":        ev.preventDefault(); stepOver();  break;
            case "F11":        ev.preventDefault();
                                ev.shiftKey ? stepOut() : stepIn();
                                break;
            case "b": case "B": stepBack(); break;
            case "e": case "E": nextError(); break;
        }
    });
}

// Enable / disable transport based on whether the playhead can go
// further in each direction. Called from renderAll().
function renderTransport(mat, playhead) {
    const last = mat.events.length - 1;
    const atStart = playhead <= 0;
    const atEnd   = playhead >= last;
    if (T.jumpStart) T.jumpStart.disabled = atStart;
    if (T.stepBack)  T.stepBack .disabled = atStart;
    if (T.play)      T.play     .disabled = mat.events.length === 0;
    if (T.stepOver)  T.stepOver .disabled = atEnd;
    if (T.stepIn)    T.stepIn   .disabled = atEnd;
    if (T.stepOut)   T.stepOut  .disabled = atEnd;
    if (T.stepLine)  T.stepLine .disabled = atEnd;
    if (T.jumpEnd)   T.jumpEnd  .disabled = atEnd;
}

// ── Variables drawer ─────────────────────────────────────────────────
//
// engine.inspectAt(mat, playhead, { cluster: 0 }) re-runs the replay
// bounded to one event and snapshots the live stack via the v0.1.0
// `_arena_host_state` reactor. Result shape per frame:
//
//   [{ func, file, line, vars: { name: <json>, ... } }, ...]
//
// Top-of-stack last. We render the deepest frame's vars by default —
// that's the "where am I" inspection the user almost always wants.
// Switching to ancestor frames via the stack-breadcrumb buttons is a
// follow-up.

const $vars         = document.querySelector(".vars");
const $varsBody     = document.querySelector(".vars__body");
const $bottomResize = document.querySelector(".bottom-resize");
let inspectSeq = 0;  // serialise rapid stepping; drop stale results

// ── Bottom-region resize ─────────────────────────────────────────────
//
// The .bottom-resize handle sits in its own row of the page grid,
// just above the transport bar. Dragging it adjusts the
// .vars__body height — the transport is fixed and rides along, the
// 1fr main grid absorbs the change. Height persists in localStorage
// so the preference sticks across reloads.

const VARS_HEIGHT_STORAGE_KEY = "rewind.replay.varsHeight";
const VARS_MIN_HEIGHT = 80;
function varsMaxHeight() { return Math.floor(window.innerHeight * 0.7); }

function setVarsHeight(px, { persist = true } = {}) {
    if (!$varsBody) return;
    const clamped = Math.max(VARS_MIN_HEIGHT, Math.min(varsMaxHeight(), Math.round(px)));
    $varsBody.style.height = clamped + "px";
    if (persist) {
        try { localStorage.setItem(VARS_HEIGHT_STORAGE_KEY, String(clamped)); }
        catch { /* private mode etc — fine */ }
    }
}

// Restore saved height on load.
try {
    const saved = parseInt(localStorage.getItem(VARS_HEIGHT_STORAGE_KEY) ?? "", 10);
    if (!Number.isNaN(saved) && saved >= VARS_MIN_HEIGHT) {
        setVarsHeight(saved, { persist: false });
    }
} catch { /* localStorage blocked — keep CSS default */ }

// Restore + persist the drawer's open/closed state. HTML default is
// open; the toggle event fires whenever the user clicks the summary
// to open or close.
const VARS_OPEN_STORAGE_KEY = "rewind.replay.varsOpen";
try {
    const saved = localStorage.getItem(VARS_OPEN_STORAGE_KEY);
    if (saved === "0") $vars.open = false;
    else if (saved === "1") $vars.open = true;
    // null/undefined → leave HTML default (open)
} catch { /* localStorage blocked — keep HTML default */ }
if ($vars) {
    $vars.addEventListener("toggle", () => {
        try { localStorage.setItem(VARS_OPEN_STORAGE_KEY, $vars.open ? "1" : "0"); }
        catch { /* fine */ }
    });
}

if ($bottomResize) {
    let dragging = false;
    let startY = 0;
    let startHeight = 0;

    $bottomResize.addEventListener("mousedown", (e) => {
        dragging = true;
        startY = e.clientY;
        startHeight = $varsBody.getBoundingClientRect().height;
        $bottomResize.classList.add("is-dragging");
        e.preventDefault();
    });
    window.addEventListener("mousemove", (e) => {
        if (!dragging) return;
        // Drag UP (clientY decreases) grows the bottom region.
        setVarsHeight(startHeight + (startY - e.clientY));
    });
    window.addEventListener("mouseup", () => {
        if (!dragging) return;
        dragging = false;
        $bottomResize.classList.remove("is-dragging");
    });
}

// ── Modules / events column width resizes ──────────────────────────
//
// Two horizontal handles flanking the source viewport. Both drive a
// CSS custom property on .replay__main so the grid columns respond
// instantly. Persisted under rewind.replay.{modulesWidth,eventsWidth}.

const $replayMain    = document.querySelector(".replay__main");
const $modulesResize = document.querySelector(".modules-resize");
const $eventsResize  = document.querySelector(".events-resize");

function clampColWidth(px, min, max) {
    return Math.max(min, Math.min(max, Math.round(px)));
}

// `cfg` describes one resizable column. `direction` is "right" for
// columns that grow when the mouse drags RIGHT (modules rail, on the
// left of the source), or "left" for columns that grow when the
// mouse drags LEFT (events stream, on the right of the source).
function wireColResize({
    handle,
    measureEl,            // DOM element whose current width is the start
    cssVar,               // custom property name on .replay__main
    storageKey,
    min,
    maxFrac,              // fraction of window.innerWidth
    direction,            // "right" | "left"
}) {
    if (!handle || !$replayMain || !measureEl) return;

    const apply = (px, { persist = true } = {}) => {
        const max = Math.floor(window.innerWidth * maxFrac);
        const clamped = clampColWidth(px, min, max);
        $replayMain.style.setProperty(cssVar, clamped + "px");
        if (persist) {
            try { localStorage.setItem(storageKey, String(clamped)); }
            catch { /* fine */ }
        }
    };

    try {
        const saved = parseInt(localStorage.getItem(storageKey) ?? "", 10);
        if (!Number.isNaN(saved) && saved >= min) apply(saved, { persist: false });
    } catch { /* fine */ }

    let dragging = false;
    let startX = 0;
    let startWidth = 0;

    handle.addEventListener("mousedown", (e) => {
        dragging = true;
        startX = e.clientX;
        startWidth = measureEl.getBoundingClientRect().width;
        handle.classList.add("is-dragging");
        e.preventDefault();
    });
    window.addEventListener("mousemove", (e) => {
        if (!dragging) return;
        const delta = direction === "right" ? (e.clientX - startX) : (startX - e.clientX);
        apply(startWidth + delta);
    });
    window.addEventListener("mouseup", () => {
        if (!dragging) return;
        dragging = false;
        handle.classList.remove("is-dragging");
    });
}

wireColResize({
    handle:    $modulesResize,
    measureEl: document.querySelector(".replay__modules"),
    cssVar:    "--modules-width",
    storageKey: "rewind.replay.modulesWidth",
    min:       140,
    maxFrac:   0.4,
    direction: "right",
});
wireColResize({
    handle:    $eventsResize,
    measureEl: document.querySelector(".stream"),
    cssVar:    "--events-width",
    storageKey: "rewind.replay.eventsWidth",
    min:       200,
    maxFrac:   0.6,
    direction: "left",
});

// Find the nearest varSnapshot at or before `eventIdx`. Binary search
// since varSnapshots is sorted by eventOrdinal.
function nearestVarSnapshot(mat, eventIdx) {
    const snaps = mat.varSnapshots;
    if (!snaps || snaps.length === 0) return null;
    let lo = 0, hi = snaps.length;
    while (lo < hi) {
        const mid = (lo + hi) >> 1;
        if (snaps[mid].eventOrdinal <= eventIdx) lo = mid + 1;
        else hi = mid;
    }
    return lo > 0 ? snaps[lo - 1] : null;
}

async function inspectAndRenderVars(eventOrdinal) {
    if (!state.engine || !state.mat) return;
    const ev = state.mat.events[eventOrdinal];
    // No frame is alive at the trailing FUNC_EXIT. Show an empty-state
    // and skip the engine round-trip.
    if (!ev || (ev.kind === "FUNC_EXIT" && eventOrdinal === state.mat.events.length - 1)) {
        renderVariablesEmpty("(no frame alive)");
        return;
    }

    const seq = ++inspectSeq;

    // Layer 1: exact hit in the inspectCache (a previous inspectAt
    // landed on this event). O(1), no round-trip, exact values.
    const cached = state.mat.inspectCache.get(eventOrdinal);
    if (cached && cached.frames && cached.frames.length > 0) {
        renderVariablesFrames(cached.frames);
        return;
    }

    // Layer 2: nearest varSnapshot from materialise's pre-computed
    // pass. With targetSnapshots ≈ rail width, the nearest snapshot
    // is at most a few events away and renders instantly. If we hit
    // the exact event, no need to follow up. Otherwise queue an
    // inspectAt below to refine.
    const snap = nearestVarSnapshot(state.mat, eventOrdinal);
    if (snap && snap.frames && snap.frames.length > 0) {
        renderVariablesFrames(snap.frames);
        if (snap.eventOrdinal === eventOrdinal) return;  // exact hit
    } else {
        renderVariablesLoading();
    }

    // Layer 3: engine round-trip for the exact answer. Fires async;
    // result replaces the snapshot render when it lands. Stale calls
    // (newer step fired) drop via the seq counter.
    let snapshots;
    try {
        snapshots = await state.engine.inspectAt(state.mat, eventOrdinal, { cluster: 0 });
    } catch (err) {
        if (seq !== inspectSeq) return;
        if (!snap) renderVariablesEmpty("(inspect failed: " + (err.message || err) + ")");
        return;
    }
    if (seq !== inspectSeq) return;
    const exact = snapshots.find(s => s.eventOrdinal === eventOrdinal) || snapshots[0];
    if (exact && exact.frames && exact.frames.length > 0) {
        renderVariablesFrames(exact.frames);
    } else if (!snap) {
        renderVariablesEmpty("(no frames)");
    }
}

function renderVariablesLoading() {
    $varsBody.replaceChildren(el("div", {
        className: "t-meta t-dim",
        text: "loading…",
    }));
}

function renderVariablesEmpty(msg) {
    $varsBody.replaceChildren(el("div", {
        className: "t-meta t-dim",
        text: msg,
    }));
}

// Render one frame's vars as a kv block. The snapshot's `frames`
// array runs top-of-stack first (deepest frame at index 0, root
// caller at the end) — that's the order qjs-arena-trace.c walks
// via top_frame() + prev_frame(). The deepest frame is the
// "current" frame the user is inspecting.
function renderVariablesFrames(frames) {
    const top = frames[0];
    $varsBody.replaceChildren();

    const section = el("div", { className: "vars__section" });
    section.appendChild(el("span", {
        className: "t-eyebrow vars__section-title",
        text: (top.func || "<frame>") + " · " + (top.file || "?") + ":" + (top.line || "?"),
    }));
    const kv = el("div", { className: "kv" });
    const vars = top.vars || {};
    const names = Object.keys(vars);
    if (names.length === 0) {
        kv.appendChild(el("span", {
            className: "t-meta t-dim",
            text: "(no locals at this point)",
            style: { gridColumn: "1 / -1" },
        }));
    } else {
        for (const name of names) {
            kv.appendChild(el("span", { className: "kv__k", text: name }));
            kv.appendChild(el("span", {
                className: "kv__v " + varValueClass(vars[name]),
                text: formatValue(vars[name]),
            }));
        }
    }
    section.appendChild(kv);
    $varsBody.appendChild(section);

    // If there are deeper frames, append a hint row pointing at the
    // stack breadcrumb. Switching which frame's vars are shown
    // (clicking a non-current breadcrumb frame) is a follow-up.
    if (frames.length > 1) {
        $varsBody.appendChild(el("div", {
            className: "t-meta t-dim",
            text: `(${frames.length - 1} ancestor frame${frames.length === 2 ? "" : "s"} above — click in the stack breadcrumb to inspect them, coming next)`,
            style: { marginTop: "var(--sp-4)" },
        }));
    }
}

// Classify a JSON-decoded var value for color hinting. The snapshot
// JSON uses bracketed-string placeholders for non-serialisable values
// (`[undefined]`, `[uninitialized]`, `[function]`, …). Plain strings
// from the source render as c-read, numbers as c-write — matches the
// design system's semantic color cues.
function varValueClass(v) {
    if (v === null) return "t-dim";
    const t = typeof v;
    if (t === "string") {
        if (v.startsWith("[") && v.endsWith("]")) return "t-dimmer";
        return "c-read";
    }
    if (t === "number" || t === "bigint" || t === "boolean") return "c-write";
    return "";
}

function formatValue(v) {
    if (v === null) return "null";
    const t = typeof v;
    if (t === "string") return v;  // includes the [placeholder] forms
    if (t === "number" || t === "boolean") return String(v);
    if (t === "object") {
        if (Array.isArray(v)) return `Array(${v.length})`;
        return "Object";
    }
    return String(v);
}

// ── App state + entry ────────────────────────────────────────────────

const state = {
    bundle: null,
    mat: null,
    engine: null,
    playhead: 0,
    currentModule: null,
};

function renderAll() {
    if (!state.mat) return;
    const src = currentSourceForPlayhead(state.mat, state.playhead);
    // Auto-follow source: when the playhead lands in a module other
    // than the one the user is browsing, switch to it. Click in the
    // modules rail to break auto-follow for the current module (we
    // re-follow on the next step that lands in a different file).
    if (src.file && src.file !== state.currentModule) {
        state.currentModule = src.file;
        renderModulesRail(state.bundle, state.currentModule, selectModule);
    }
    renderSourceView(state.bundle, state.currentModule, src.line);
    renderStackBreadcrumb(state.mat, state.playhead);
    renderEventStream(state.mat, state.playhead);
    renderScrubber(state.mat, state.playhead);
    renderNextError(state.mat, state.playhead);
    renderTransport(state.mat, state.playhead);
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
    state.engine = new CursorEngine(Module);

    // Pick varSnapshot density to roughly match the scrubber's pixel
    // width, so drag-scrubbing has near-snapshot-per-pixel resolution
    // and the variables drawer can render instantly from
    // mat.varSnapshots without an inspectAt round-trip mid-drag. Cap
    // at 800 to bound the pathological deep-stack × many-events case;
    // small recordings end up with one snapshot per event (cheap).
    const railWidth = Math.max(200, Math.floor($scrubber?.getBoundingClientRect().width ?? 800));
    const targetSnapshots = Math.min(railWidth, 800);

    let mat;
    try {
        mat = await state.engine.materialise(
            { entry: { name: entryPath, src: entrySrc }, tapes, module_sources: moduleSources },
            { targetSnapshots },
        );
    } catch (err) {
        renderError(new Error("materialise failed: " + err.message));
        arena_destroy();
        return;
    }

    state.mat = mat;
    // Diagnostic hook for the playwright smoke (and anyone poking
    // around in DevTools): the smoke can assert that varSnapshots
    // was actually populated by materialise() without us having to
    // expose `state.mat` itself on window.
    window.__mat_varSnapshots_count__ = mat.varSnapshots ? mat.varSnapshots.length : 0;

    // Park the playhead at the throw if there is one, else at the
    // end. The user can step / scrub from anywhere.
    const throwIdx = mat.events.findIndex(e => e.kind === "THROW");
    state.playhead = throwIdx >= 0 ? throwIdx : Math.max(0, mat.events.length - 1);
    wireTransport();
    renderAll();
    inspectAndRenderVars(state.playhead);

    $.sourceState.textContent = `completed · ${mat.events.length} event(s)`;
}

main();
