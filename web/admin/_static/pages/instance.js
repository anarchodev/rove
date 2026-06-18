// Per-instance dashboard. M3 slice 1: log viewer only. KV + code
// tabs are stubbed and light up in later slices.

import { ApiError } from "../api.js";

const TABS = [
  { id: "logs", label: "Logs" },
  { id: "kv", label: "KV" },
  { id: "code", label: "Code" },
];

export function render(root, { goto, api, params }) {
  const instanceId = params.id;

  const wrap = document.createElement("div");
  wrap.className = "instance";
  wrap.innerHTML = `
    <header class="page-header">
      <div>
        <a class="back-link" href="#/instances">← Instances</a>
        <h1>${escapeHtml(instanceId)}</h1>
      </div>
      <button type="button" class="logout">Sign out</button>
    </header>
    <p class="error" hidden></p>

    <nav class="tabs"></nav>
    <section class="tab-body"></section>
  `;

  const errorBox = wrap.querySelector(".error");
  const tabsNav = wrap.querySelector(".tabs");
  const tabBody = wrap.querySelector(".tab-body");
  const logoutBtn = wrap.querySelector(".logout");

  function showError(msg) {
    errorBox.textContent = msg;
    errorBox.hidden = false;
  }
  function clearError() {
    errorBox.hidden = true;
    errorBox.textContent = "";
  }

  const tabButtons = new Map();
  let activeTab = "logs";
  let activeTeardown = null;

  function selectTab(tabId) {
    if (activeTab === tabId && tabBody.childElementCount > 0) return;
    activeTab = tabId;
    for (const [id, btn] of tabButtons.entries()) {
      btn.classList.toggle("active", id === tabId);
    }
    if (typeof activeTeardown === "function") {
      try { activeTeardown(); } catch {}
    }
    activeTeardown = null;
    tabBody.replaceChildren();
    clearError();

    const ctx = { instanceId, api, showError, clearError };
    if (tabId === "logs") activeTeardown = renderLogs(tabBody, ctx) || null;
    else if (tabId === "kv") activeTeardown = renderKv(tabBody, ctx) || null;
    else if (tabId === "code") activeTeardown = renderCode(tabBody, ctx) || null;
  }

  for (const t of TABS) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "tab";
    btn.textContent = t.label;
    btn.addEventListener("click", () => selectTab(t.id));
    tabsNav.appendChild(btn);
    tabButtons.set(t.id, btn);
  }

  logoutBtn.addEventListener("click", async () => {
    try { await api.logout(); } catch {}
    goto("#/login");
  });

  root.appendChild(wrap);
  selectTab("logs");

  return () => {
    if (typeof activeTeardown === "function") {
      try { activeTeardown(); } catch {}
    }
    activeTeardown = null;
  };
}

// ── Logs panel ─────────────────────────────────────────────────────

function renderLogs(root, { instanceId, api, showError, clearError }) {
  const el = document.createElement("div");
  el.className = "logs-panel";
  el.innerHTML = `
    <div class="toolbar">
      <button type="button" class="refresh">Refresh</button>
      <span class="count muted"></span>
    </div>
    <div class="table-wrap">
      <table class="log-table">
        <thead>
          <tr>
            <th>Time</th>
            <th>Deploy</th>
            <th>Method</th>
            <th>Path</th>
            <th>Status</th>
            <th>Duration</th>
            <th>Outcome</th>
            <th></th>
          </tr>
        </thead>
        <tbody></tbody>
      </table>
    </div>
    <div class="load-more-wrap" hidden>
      <button type="button" class="load-more">Load older</button>
    </div>
    <aside class="drawer" hidden>
      <div class="drawer-header">
        <h3></h3>
        <button type="button" class="drawer-close" aria-label="Close">×</button>
      </div>
      <div class="drawer-body"></div>
    </aside>
  `;
  root.appendChild(el);

  const tbody = el.querySelector("tbody");
  const refreshBtn = el.querySelector(".refresh");
  const countLabel = el.querySelector(".count");
  const loadMoreWrap = el.querySelector(".load-more-wrap");
  const loadMoreBtn = el.querySelector(".load-more");
  const drawer = el.querySelector(".drawer");
  const drawerTitle = drawer.querySelector("h3");
  const drawerBody = drawer.querySelector(".drawer-body");
  const drawerClose = drawer.querySelector(".drawer-close");

  const PAGE_SIZE = 50;
  let rendering = false;
  let cursor = null; // null = no more pages, set to next_cursor after a page
  let totalLoaded = 0;
  const recordsById = new Map();

  async function load({ append } = { append: false }) {
    if (rendering) return;
    rendering = true;
    refreshBtn.disabled = true;
    loadMoreBtn.disabled = true;
    clearError();
    try {
      const res = await api.listLogs(instanceId, {
        limit: PAGE_SIZE,
        after: append ? cursor : null,
      });
      const records = res.records ?? [];
      cursor = res.next_cursor || null;

      if (!append) {
        recordsById.clear();
        tbody.replaceChildren();
        totalLoaded = 0;
      }

      for (const r of records) recordsById.set(r.request_id, r);

      if (!append && records.length === 0) {
        const tr = document.createElement("tr");
        tr.className = "empty";
        tr.innerHTML = `<td colspan="8"><em>no requests logged yet</em></td>`;
        tbody.appendChild(tr);
      } else {
        for (const r of records) tbody.appendChild(buildRow(r));
      }

      totalLoaded += records.length;
      const more = cursor !== null && records.length > 0;
      countLabel.textContent =
        `${totalLoaded} record${totalLoaded === 1 ? "" : "s"}${more ? " (more available)" : ""}`;
      loadMoreWrap.hidden = !more;
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        location.hash = "#/login";
        return;
      }
      showError(`Load logs failed: ${err.message}`);
    } finally {
      refreshBtn.disabled = false;
      loadMoreBtn.disabled = false;
      rendering = false;
    }
  }

  function buildRow(r) {
    const tr = document.createElement("tr");
    tr.className = "log-row";
    tr.dataset.id = r.request_id;
    tr.tabIndex = 0;
    tr.innerHTML = `
      <td class="time" title="${escapeHtml(absTime(r.received_ns))}">${escapeHtml(relTime(r.received_ns))}</td>
      <td class="deploy" title="deployment ${r.deployment_id}">#${r.deployment_id}</td>
      <td class="method">${escapeHtml(r.method)}</td>
      <td class="path">${escapeHtml(r.path)}</td>
      <td class="status status-${statusClass(r.status)}">${r.status}</td>
      <td class="duration">${formatDuration(r.duration_ns)}</td>
      <td class="outcome outcome-${escapeHtml(r.outcome)}">${escapeHtml(r.outcome)}</td>
      <td class="actions">
        <button type="button" class="row-act replay" title="Open this request in the replay shell (scrubber, source view, variables)">Replay</button>
        <button type="button" class="row-act copy-id" title="Copy request ID">⎘</button>
      </td>
    `;
    tr.addEventListener("click", (ev) => {
      // Don't open the drawer when clicking row-action buttons.
      if (ev.target.closest(".row-act")) return;
      openDrawer(r.request_id);
    });
    tr.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter" || ev.key === " ") {
        ev.preventDefault();
        openDrawer(r.request_id);
      }
    });
    tr.querySelector(".replay").addEventListener("click", (ev) => {
      ev.stopPropagation();
      void replayRequest(r.request_id, ev.currentTarget);
    });
    tr.querySelector(".copy-id").addEventListener("click", async (ev) => {
      ev.stopPropagation();
      const btn = ev.currentTarget;
      try {
        await navigator.clipboard.writeText(r.request_id);
        const orig = btn.textContent;
        btn.textContent = "✓";
        setTimeout(() => { btn.textContent = orig; }, 1200);
      } catch (err) {
        showError("copy failed: " + err.message);
      }
    });
    return tr;
  }

  async function replayRequest(requestId, btn) {
    btn.disabled = true;
    const orig = btn.textContent;
    btn.textContent = "…";
    clearError();
    try {
      const bundle = await api.composeReplayBundle(instanceId, requestId);
      api.replayOpen(bundle);
    } catch (err) {
      showError(`Replay failed: ${err.message}`);
    } finally {
      btn.disabled = false;
      btn.textContent = orig;
    }
  }

  async function openDrawer(requestId) {
    drawer.hidden = false;
    drawerTitle.textContent = requestId;
    drawerBody.textContent = "Loading…";
    try {
      const full = await api.showLog(instanceId, requestId);
      drawerBody.replaceChildren();
      drawerBody.appendChild(renderRecordDetail(full));
    } catch (err) {
      drawerBody.textContent = `Failed to load: ${err.message}`;
    }
  }

  function closeDrawer() {
    drawer.hidden = true;
    drawerBody.replaceChildren();
  }

  refreshBtn.addEventListener("click", () => load({ append: false }));
  loadMoreBtn.addEventListener("click", () => load({ append: true }));
  drawerClose.addEventListener("click", closeDrawer);

  load({ append: false });
  return () => {};
}

function renderRecordDetail(r) {
  const wrap = document.createElement("dl");
  wrap.className = "record-detail";
  const rows = [
    ["Request ID", r.request_id],
    ["Deployment", String(r.deployment_id)],
    ["Host", r.host],
    ["Method", r.method],
    ["Path", r.path],
    ["Status", String(r.status)],
    ["Outcome", r.outcome],
    ["Received", absTime(r.received_ns)],
    ["Duration", formatDuration(r.duration_ns)],
  ];
  for (const [label, value] of rows) {
    const dt = document.createElement("dt");
    dt.textContent = label;
    const dd = document.createElement("dd");
    dd.textContent = value;
    wrap.appendChild(dt);
    wrap.appendChild(dd);
  }
  if (r.console && r.console.length > 0) {
    const dt = document.createElement("dt");
    dt.textContent = "Console";
    const dd = document.createElement("dd");
    const pre = document.createElement("pre");
    pre.textContent = r.console;
    dd.appendChild(pre);
    wrap.appendChild(dt);
    wrap.appendChild(dd);
  }
  if (r.exception && r.exception.length > 0) {
    const dt = document.createElement("dt");
    dt.textContent = "Exception";
    const dd = document.createElement("dd");
    const pre = document.createElement("pre");
    pre.className = "error";
    pre.textContent = r.exception;
    dd.appendChild(pre);
    wrap.appendChild(dt);
    wrap.appendChild(dd);
  }
  return wrap;
}

// ── KV panel ───────────────────────────────────────────────────────

function renderKv(root, { instanceId, api, showError, clearError }) {
  const el = document.createElement("div");
  el.className = "kv-panel";
  el.innerHTML = `
    <div class="toolbar">
      <label class="prefix-label">
        <span>Prefix</span>
        <input class="prefix-input" type="text" placeholder="(any)">
      </label>
      <button type="button" class="refresh">Refresh</button>
      <span class="count muted"></span>
    </div>
    <form class="kv-create">
      <input name="key" placeholder="key" autocomplete="off" required>
      <input name="value" placeholder="value" autocomplete="off">
      <button type="submit">Set</button>
    </form>
    <div class="table-wrap">
      <table class="kv-table">
        <thead>
          <tr><th>Key</th><th>Value</th><th></th></tr>
        </thead>
        <tbody></tbody>
      </table>
    </div>
  `;
  root.appendChild(el);

  const tbody = el.querySelector("tbody");
  const prefixInput = el.querySelector(".prefix-input");
  const refreshBtn = el.querySelector(".refresh");
  const countLabel = el.querySelector(".count");
  const createForm = el.querySelector(".kv-create");

  async function load() {
    refreshBtn.disabled = true;
    clearError();
    try {
      const res = await api.listKv(instanceId, {
        prefix: prefixInput.value,
        limit: 200,
      });
      const entries = res.entries ?? [];
      tbody.replaceChildren();
      if (entries.length === 0) {
        const tr = document.createElement("tr");
        tr.className = "empty";
        tr.innerHTML = `<td colspan="3"><em>no matching keys</em></td>`;
        tbody.appendChild(tr);
      } else {
        for (const e of entries) tbody.appendChild(kvRow(e));
      }
      countLabel.textContent = `${entries.length} entr${entries.length === 1 ? "y" : "ies"}`;
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        location.hash = "#/login";
        return;
      }
      showError(`Load failed: ${err.message}`);
    } finally {
      refreshBtn.disabled = false;
    }
  }

  function kvRow(entry) {
    const tr = document.createElement("tr");
    tr.dataset.key = entry.key;

    const keyCell = document.createElement("td");
    keyCell.className = "kv-key";
    keyCell.textContent = entry.key;
    tr.appendChild(keyCell);

    const valCell = document.createElement("td");
    valCell.className = "kv-value";
    const valInput = document.createElement("input");
    valInput.type = "text";
    valInput.className = "kv-value-input";
    valInput.value = entry.value;
    valInput.dataset.original = entry.value;
    valCell.appendChild(valInput);
    tr.appendChild(valCell);

    const actionCell = document.createElement("td");
    actionCell.className = "kv-actions";
    const saveBtn = document.createElement("button");
    saveBtn.type = "button";
    saveBtn.textContent = "Save";
    saveBtn.disabled = true;
    const delBtn = document.createElement("button");
    delBtn.type = "button";
    delBtn.className = "danger";
    delBtn.textContent = "Delete";
    actionCell.appendChild(saveBtn);
    actionCell.appendChild(delBtn);
    tr.appendChild(actionCell);

    valInput.addEventListener("input", () => {
      saveBtn.disabled = valInput.value === valInput.dataset.original;
    });

    saveBtn.addEventListener("click", async () => {
      saveBtn.disabled = true;
      try {
        await api.setKv(instanceId, entry.key, valInput.value);
        valInput.dataset.original = valInput.value;
      } catch (err) {
        showError(`Save failed: ${err.message}`);
        saveBtn.disabled = false;
      }
    });

    delBtn.addEventListener("click", async () => {
      if (!confirm(`Delete "${entry.key}"?`)) return;
      try {
        await api.deleteKv(instanceId, entry.key);
        tr.remove();
      } catch (err) {
        showError(`Delete failed: ${err.message}`);
      }
    });

    return tr;
  }

  async function onCreate(ev) {
    ev.preventDefault();
    clearError();
    const data = new FormData(createForm);
    const key = String(data.get("key") ?? "").trim();
    const value = String(data.get("value") ?? "");
    if (!key) return;
    try {
      await api.setKv(instanceId, key, value);
      createForm.reset();
      await load();
    } catch (err) {
      showError(`Set failed: ${err.message}`);
    }
  }

  refreshBtn.addEventListener("click", load);
  createForm.addEventListener("submit", onCreate);
  prefixInput.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter") {
      ev.preventDefault();
      load();
    }
  });

  load();
  return () => {};
}

// ── Code panel ─────────────────────────────────────────────────────

// The Code tab builds a deploy bundle IN THE BROWSER (a "draft") and ships it
// in one shot via POST /v1/deploy + release (api.deployAndRelease) — the
// files-server's per-file upload/edit API was dissolved (rewind-cli-plan §4).
// Loading the CURRENTLY-deployed files back into the editor needs a
// cross-tenant blob/manifest READ door (the write twin exists; the read door
// does not yet) — until it lands this tab edits a fresh draft rather than the
// live deployment.
function renderCode(root, { instanceId, api, showError, clearError }) {
  const el = document.createElement("div");
  el.className = "code-panel";
  el.innerHTML = `
    <div class="code-layout">
      <aside class="file-list">
        <div class="toolbar">
          <button type="button" class="new-file">New</button>
          <button type="button" class="deploy" disabled>Deploy</button>
        </div>
        <p class="draft-note muted">Current handlers loaded for editing. Deploy
          ships the whole bundle at once (you'll be warned before any current
          static is dropped).</p>
        <ul></ul>
      </aside>
      <section class="editor">
        <div class="editor-header">
          <span class="current-path muted">(no file selected)</span>
          <span class="editor-meta muted"></span>
        </div>
        <div class="editor-body" tabindex="-1"></div>
      </section>
    </div>
  `;
  root.appendChild(el);

  const list = el.querySelector(".file-list ul");
  const deployBtn = el.querySelector(".deploy");
  const newBtn = el.querySelector(".new-file");
  const pathLabel = el.querySelector(".current-path");
  const metaLabel = el.querySelector(".editor-meta");
  const editorMount = el.querySelector(".editor-body");

  // Draft bundle: path → { kind, content_type, source }. Editing updates
  // `source` live; Deploy ships the whole map.
  const draft = {};
  // Static paths in the CURRENTLY-deployed bundle (loaded via the read door
  // for reference). They're not editable here (binary-safe), and Deploy ships
  // only the draft — so if any of these aren't re-added, Deploy would drop
  // them. We warn before that happens.
  let currentStatics = [];
  let selected = null; // { path, kind, content_type }
  let cm = null;       // { view, langCompartment, EditorView, EditorState, ... }
  let cmLoading = null; // in-flight import promise

  // Lazy-load + mount the CodeMirror editor on first use. Returns
  // the resolved `cm` handle. The vendored bundle is ~450 KB; only
  // pulled when the user actually opens the Code tab.
  function ensureEditor() {
    if (cm) return Promise.resolve(cm);
    if (cmLoading) return cmLoading;
    cmLoading = import("/codemirror.mjs").then((CM) => {
      const langCompartment = new CM.Compartment();
      const editableCompartment = new CM.Compartment();
      const docChanged = CM.EditorView.updateListener.of((u) => {
        if (!u.docChanged || !selected) return;
        // Live-write the edit into the draft; Deploy ships the whole map.
        draft[selected.path].source = u.state.doc.toString();
        deployBtn.disabled = Object.keys(draft).length === 0;
      });
      const state = CM.EditorState.create({
        doc: "",
        extensions: [
          CM.lineNumbers(),
          CM.highlightActiveLine(),
          CM.history(),
          CM.bracketMatching(),
          CM.indentOnInput(),
          CM.syntaxHighlighting(CM.defaultHighlightStyle, { fallback: true }),
          CM.keymap.of([...CM.defaultKeymap, ...CM.historyKeymap, CM.indentWithTab]),
          langCompartment.of([]),
          editableCompartment.of(CM.EditorView.editable.of(false)),
          docChanged,
        ],
      });
      const view = new CM.EditorView({ state, parent: editorMount });
      cm = { CM, view, langCompartment, editableCompartment };
      return cm;
    }).catch((err) => {
      cmLoading = null;
      showError(`Code editor failed to load: ${err.message}`);
      throw err;
    });
    return cmLoading;
  }

  function renderDraft() {
    list.replaceChildren();
    const paths = Object.keys(draft).sort();
    deployBtn.disabled = paths.length === 0;
    if (paths.length === 0) {
      const li = document.createElement("li");
      li.className = "empty";
      li.innerHTML = `<em>empty draft — add a file with New</em>`;
      list.appendChild(li);
      return;
    }
    for (const p of paths) list.appendChild(buildFileLi(p, draft[p]));
  }

  function buildFileLi(path, entry) {
    const li = document.createElement("li");
    li.className = `file file-${entry.kind}`;
    li.dataset.path = path;
    li.innerHTML = `
      <span class="file-kind">${entry.kind === "handler" ? "JS" : "—"}</span>
      <span class="file-path">${escapeHtml(path)}</span>
    `;
    li.addEventListener("click", () => openFile(path));
    return li;
  }

  /// Pick a CodeMirror language extension based on the file path.
  /// `.mjs` / `.js` → JavaScript (with optional JSX flag off);
  /// `.html` / `.htm` → HTML; `.css` → CSS; otherwise plain text.
  function langFor(CM, path) {
    if (path.endsWith(".mjs") || path.endsWith(".js")) return CM.javascript();
    if (path.endsWith(".html") || path.endsWith(".htm")) return CM.html();
    if (path.endsWith(".css")) return CM.css();
    return [];
  }

  async function openFile(path) {
    clearError();
    const entry = draft[path];
    if (!entry) return;
    for (const node of list.querySelectorAll("li")) {
      node.classList.toggle("active", node.dataset.path === path);
    }
    pathLabel.textContent = path;
    metaLabel.textContent = "Loading editor…";

    let editor;
    try {
      editor = await ensureEditor();
    } catch {
      return; // showError already invoked inside ensureEditor
    }
    selected = { path, kind: entry.kind, content_type: entry.content_type };
    editor.view.dispatch({
      changes: { from: 0, to: editor.view.state.doc.length, insert: entry.source },
      effects: [
        editor.langCompartment.reconfigure(langFor(editor.CM, path)),
        editor.editableCompartment.reconfigure(
          editor.CM.EditorView.editable.of(true),
        ),
      ],
    });
    metaLabel.textContent =
      `${entry.kind} · ${entry.content_type || "(no content-type)"} · draft`;
  }

  deployBtn.addEventListener("click", async () => {
    if (Object.keys(draft).length === 0) return;
    // Deploy ships ONLY the draft. If the live deployment has statics that
    // aren't in the draft, deploying would drop them — confirm first.
    const dropping = currentStatics.filter((p) => !(p in draft));
    if (dropping.length > 0 &&
        !window.confirm(
          "Deploying replaces the live deployment. These static assets are " +
          "not in your draft and will be DROPPED:\n\n  " + dropping.join("\n  ") +
          "\n\nContinue?")) {
      return;
    }
    deployBtn.disabled = true;
    const orig = deployBtn.textContent;
    deployBtn.textContent = "Deploying…";
    clearError();
    try {
      // draft entries → api.deploy's {path: {source}|{bytes,content_type}} map.
      const files = {};
      for (const [p, e] of Object.entries(draft)) {
        files[p] = e.kind === "handler"
          ? { source: e.source }
          : { source: e.source, content_type: e.content_type };
      }
      const result = await api.deployAndRelease(instanceId, files);
      metaLabel.textContent = `deployed + released · dep ${result.dep_id}`;
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        location.hash = "#/login";
        return;
      }
      showError(`Deploy failed: ${err.message}`);
    } finally {
      deployBtn.textContent = orig;
      deployBtn.disabled = Object.keys(draft).length === 0;
    }
  });

  newBtn.addEventListener("click", async () => {
    const raw = prompt(
      "New file path. Either a handler ending in `.mjs` / `.js`, or a static asset under `_static/`.\n\nExamples:\n  index.mjs\n  api/users.mjs\n  _static/about.html",
      "",
    );
    if (raw == null) return;
    const path = raw.trim();
    if (!path) return;

    const kind =
      path.startsWith("_static/") ? "static"
      : (path.endsWith(".mjs") || path.endsWith(".js")) ? "handler"
      : null;
    if (!kind) {
      showError("Path must end in `.mjs` / `.js` or live under `_static/`.");
      return;
    }

    const contentType = kind === "handler"
      ? "application/javascript"
      : inferContentType(path);
    const starter = kind === "handler"
      ? `export default function (req) {\n  return "hello from ${path}\\n";\n}\n`
      : "";

    draft[path] = { kind, content_type: contentType, source: starter };
    renderDraft();
    await openFile(path);
  });

  // Load the CURRENT deployment's handler sources into the draft (edit-existing
  // via the cross-tenant read door). Handlers become editable; statics are
  // recorded in `currentStatics` so Deploy can warn before dropping them (their
  // bytes aren't pulled into the text editor). No deployment yet → empty draft.
  async function loadCurrent() {
    try {
      const res = await api.readSources(instanceId, "current");
      const entries = res.entries || [];
      for (const e of entries) {
        if (e.kind === "handler" && e.source != null) {
          draft[e.path] = {
            kind: "handler",
            content_type: e.content_type || "application/javascript",
            source: e.source,
          };
        } else if (e.kind === "static") {
          currentStatics.push(e.path);
        }
      }
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) { location.hash = "#/login"; return; }
      // 404 (no current deployment) or read failure → start from an empty draft.
    }
    renderDraft();
  }

  loadCurrent();
  return () => {
    if (cm) {
      cm.view.destroy();
      cm = null;
    }
  };
}

/// Small extension → MIME table for new static files. Covers the
/// obvious cases; falls back to octet-stream for unknowns.
function inferContentType(path) {
  const i = path.lastIndexOf(".");
  const ext = i >= 0 ? path.slice(i + 1).toLowerCase() : "";
  switch (ext) {
    case "html": case "htm": return "text/html; charset=utf-8";
    case "css":  return "text/css";
    case "js":   case "mjs": return "application/javascript";
    case "json": return "application/json";
    case "svg":  return "image/svg+xml";
    case "png":  return "image/png";
    case "jpg":  case "jpeg": return "image/jpeg";
    case "gif":  return "image/gif";
    case "webp": return "image/webp";
    case "ico":  return "image/x-icon";
    case "txt":  case "md": return "text/plain; charset=utf-8";
    case "xml":  return "application/xml";
    case "wasm": return "application/wasm";
    case "woff": return "font/woff";
    case "woff2": return "font/woff2";
    default:     return "application/octet-stream";
  }
}

// ── Formatters ─────────────────────────────────────────────────────

function escapeHtml(s) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function statusClass(n) {
  if (n >= 500) return "5xx";
  if (n >= 400) return "4xx";
  if (n >= 300) return "3xx";
  if (n >= 200) return "2xx";
  return "1xx";
}

function formatDuration(ns) {
  const us = ns / 1000;
  if (us < 1000) return `${us.toFixed(0)}µs`;
  const ms = us / 1000;
  if (ms < 1000) return `${ms.toFixed(1)}ms`;
  return `${(ms / 1000).toFixed(2)}s`;
}

function relTime(nsEpoch) {
  const nowMs = Date.now();
  const thenMs = Number(BigInt(nsEpoch) / 1_000_000n);
  const diff = nowMs - thenMs;
  if (diff < 0) return "just now";
  if (diff < 1000) return "just now";
  if (diff < 60_000) return `${Math.floor(diff / 1000)}s ago`;
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
  return `${Math.floor(diff / 86_400_000)}d ago`;
}

function absTime(nsEpoch) {
  const ms = Number(BigInt(nsEpoch) / 1_000_000n);
  try {
    return new Date(ms).toISOString();
  } catch {
    return String(nsEpoch);
  }
}
