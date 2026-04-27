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
          </tr>
        </thead>
        <tbody></tbody>
      </table>
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
  const drawer = el.querySelector(".drawer");
  const drawerTitle = drawer.querySelector("h3");
  const drawerBody = drawer.querySelector(".drawer-body");
  const drawerClose = drawer.querySelector(".drawer-close");

  let rendering = false;
  const recordsById = new Map();

  async function load() {
    if (rendering) return;
    rendering = true;
    refreshBtn.disabled = true;
    clearError();
    try {
      const res = await api.listLogs(instanceId, { limit: 100 });
      const records = res.records ?? [];
      recordsById.clear();
      for (const r of records) recordsById.set(r.request_id, r);

      tbody.replaceChildren();
      if (records.length === 0) {
        const tr = document.createElement("tr");
        tr.className = "empty";
        tr.innerHTML = `<td colspan="7"><em>no requests logged yet</em></td>`;
        tbody.appendChild(tr);
      } else {
        for (const r of records) tbody.appendChild(buildRow(r));
      }
      countLabel.textContent = `${records.length} record${records.length === 1 ? "" : "s"}`;
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        location.hash = "#/login";
        return;
      }
      showError(`Load logs failed: ${err.message}`);
    } finally {
      refreshBtn.disabled = false;
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
    `;
    tr.addEventListener("click", () => openDrawer(r.request_id));
    tr.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter" || ev.key === " ") {
        ev.preventDefault();
        openDrawer(r.request_id);
      }
    });
    return tr;
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

  refreshBtn.addEventListener("click", load);
  drawerClose.addEventListener("click", closeDrawer);

  load();
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

function renderCode(root, { instanceId, api, showError, clearError }) {
  const el = document.createElement("div");
  el.className = "code-panel";
  el.innerHTML = `
    <div class="code-layout">
      <aside class="file-list">
        <div class="toolbar">
          <button type="button" class="new-file">New</button>
          <button type="button" class="refresh">Refresh</button>
        </div>
        <ul></ul>
      </aside>
      <section class="editor">
        <div class="editor-header">
          <span class="current-path muted">(no file selected)</span>
          <span class="editor-meta muted"></span>
          <button type="button" class="save" disabled>Save</button>
        </div>
        <textarea class="editor-body" spellcheck="false" disabled></textarea>
      </section>
    </div>
  `;
  root.appendChild(el);

  const list = el.querySelector(".file-list ul");
  const refreshBtn = el.querySelector(".refresh");
  const newBtn = el.querySelector(".new-file");
  const pathLabel = el.querySelector(".current-path");
  const metaLabel = el.querySelector(".editor-meta");
  const saveBtn = el.querySelector(".save");
  const textarea = el.querySelector(".editor-body");

  let selected = null; // { path, kind, content_type, original }

  async function loadList() {
    refreshBtn.disabled = true;
    clearError();
    try {
      const res = await api.listFiles(instanceId);
      const entries = res.entries ?? [];
      list.replaceChildren();
      if (entries.length === 0) {
        const li = document.createElement("li");
        li.className = "empty";
        li.innerHTML = `<em>no deployment</em>`;
        list.appendChild(li);
      } else {
        for (const e of entries) list.appendChild(buildFileLi(e));
      }
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        location.hash = "#/login";
        return;
      }
      showError(`Load files failed: ${err.message}`);
    } finally {
      refreshBtn.disabled = false;
    }
  }

  function buildFileLi(entry) {
    const li = document.createElement("li");
    li.className = `file file-${entry.kind}`;
    li.dataset.path = entry.path;
    li.innerHTML = `
      <span class="file-kind">${entry.kind === "handler" ? "JS" : "—"}</span>
      <span class="file-path">${escapeHtml(entry.path)}</span>
    `;
    li.addEventListener("click", () => openFile(entry.path));
    return li;
  }

  async function openFile(path) {
    clearError();
    for (const node of list.querySelectorAll("li")) {
      node.classList.toggle("active", node.dataset.path === path);
    }
    pathLabel.textContent = path;
    metaLabel.textContent = "Loading…";
    textarea.disabled = true;
    saveBtn.disabled = true;
    try {
      const file = await api.getFile(instanceId, path);
      selected = {
        path,
        kind: file.kind,
        content_type: file.content_type,
        original: file.content ?? "",
      };
      textarea.value = selected.original;
      textarea.disabled = false;
      metaLabel.textContent = `${file.kind} · ${file.content_type || "(no content-type)"} · ${selected.original.length} bytes`;
      saveBtn.disabled = true; // enable only when dirty
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        location.hash = "#/login";
        return;
      }
      showError(`Open failed: ${err.message}`);
      metaLabel.textContent = "";
    }
  }

  textarea.addEventListener("input", () => {
    if (!selected) return;
    saveBtn.disabled = textarea.value === selected.original;
  });

  saveBtn.addEventListener("click", async () => {
    if (!selected) return;
    saveBtn.disabled = true;
    saveBtn.textContent = "Saving…";
    try {
      const body = textarea.value;
      const ct = selected.content_type && selected.content_type.length > 0
        ? selected.content_type
        : (selected.kind === "handler" ? "application/javascript" : "application/octet-stream");
      await api.putFile(instanceId, selected.path, body, ct);
      selected.original = body;
      metaLabel.textContent = `${selected.kind} · ${ct} · ${body.length} bytes · saved`;
    } catch (err) {
      showError(`Save failed: ${err.message}`);
      saveBtn.disabled = false;
    } finally {
      saveBtn.textContent = "Save";
    }
  });

  refreshBtn.addEventListener("click", loadList);

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

    try {
      await api.putFile(instanceId, path, starter, contentType);
    } catch (err) {
      showError(`Create failed: ${err.message}`);
      return;
    }
    await loadList();
    await openFile(path);
  });

  loadList();
  return () => {};
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
