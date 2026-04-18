// Typed wrapper around the rove admin API.
//
// Auth is cookie-based: the server mints a `rove_session` cookie after
// POST /v1/login, and every subsequent fetch replays it automatically
// (we send `credentials: "include"`). No tokens in localStorage.
//
// Every RPC call is still a named function on the `__admin__` handler:
// `?fn=<name>` (GET, URL-encoded JSON args) or `POST {fn, args}`.
//
// Two scopes for the admin handler:
// 1. Bare admin host (`app.loop46.me`) → `kv` = root store (tenant /
//    domain CRUD + session store).
// 2. `{id}.app.loop46.me`              → `kv` = {id}'s app.db
//    (per-tenant KV browsing).
//
// Out-of-band (still the native Zig proxies): logs + code via
// `/_system/log/*` and `/_system/files/*`.

const BASE_KEY = "rove.admin.api_base";

export class ApiError extends Error {
  constructor(status, statusText, body) {
    super(`${status} ${statusText}`);
    this.status = status;
    this.body = body;
  }
}

/// The admin API base. Defaults to this page's origin (prod shape:
/// same-origin as the UI bundle). Override via `?api=` once and it
/// sticks in localStorage — useful for dev against a remote worker.
function adminBase() {
  const override = window.__rove_api_base ?? localStorage.getItem(BASE_KEY);
  if (override && override.length > 0) return override.replace(/\/+$/, "");
  return window.location.origin;
}

/// Per-tenant API base: `{id}.<admin host>`.
function scopeBase(instance_id) {
  const base = adminBase();
  try {
    const u = new URL(base);
    u.hostname = `${instance_id}.${u.hostname}`;
    return u.toString().replace(/\/+$/, "");
  } catch {
    return base;
  }
}

/// Call a named export on the admin handler. `?fn=<name>&args=...` for
/// GET, JSON body for POST. Sends cookies.
async function rpc(base, fn, args, { method = "GET" } = {}) {
  const argsArr = args ?? [];
  let url, init;
  if (method === "POST") {
    url = base + "/";
    init = {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "include",
      body: JSON.stringify({ fn, args: argsArr }),
    };
  } else {
    const qs = new URLSearchParams({ fn });
    if (argsArr.length > 0) qs.set("args", JSON.stringify(argsArr));
    url = `${base}/?${qs.toString()}`;
    init = { method: "GET", credentials: "include" };
  }
  const res = await fetch(url, init);
  const ct = res.headers.get("content-type") ?? "";
  const parsed = ct.includes("application/json")
    ? await res.json().catch(() => null)
    : await res.text();
  if (!res.ok) throw new ApiError(res.status, res.statusText, parsed);
  return parsed;
}

/// Minimal JSON POST used by /v1/login, /v1/logout. Returns the parsed
/// body or throws on non-2xx.
async function postJson(url, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    credentials: "include",
    body: JSON.stringify(body),
  });
  const ct = res.headers.get("content-type") ?? "";
  const parsed = ct.includes("application/json")
    ? await res.json().catch(() => null)
    : await res.text();
  if (!res.ok) throw new ApiError(res.status, res.statusText, parsed);
  return parsed;
}

async function rawGet(base, path) {
  const res = await fetch(base + path, { credentials: "include" });
  if (!res.ok) {
    const txt = await res.text().catch(() => "");
    throw new ApiError(res.status, res.statusText, txt);
  }
  return res;
}

/// URL-encode a file path that may contain `/` separators. Slashes are
/// preserved; each segment gets `encodeURIComponent`'d.
function encodePath(path) {
  return path.split("/").map(encodeURIComponent).join("/");
}

export const api = {
  // ── Auth ─────────────────────────────────────────────────────────
  login(token) {
    return postJson(adminBase() + "/v1/login", { token });
  },
  logout() {
    return postJson(adminBase() + "/v1/logout", {});
  },
  /// Returns `{is_root}` on a valid session, null on 401.
  async whoami() {
    try {
      const res = await fetch(adminBase() + "/v1/session", {
        method: "GET",
        credentials: "include",
      });
      if (res.status === 401) return null;
      if (!res.ok) throw new ApiError(res.status, res.statusText, null);
      return await res.json();
    } catch (err) {
      if (err instanceof ApiError) throw err;
      return null;
    }
  },

  // ── Admin scope: tenant CRUD + domains (kv = root) ──────────────
  listInstances() {
    return rpc(adminBase(), "listInstance");
  },
  createInstance(id) {
    return rpc(adminBase(), "createInstance", [id], { method: "POST" });
  },
  getInstance(id) {
    return rpc(adminBase(), "getInstance", [id]);
  },
  deleteInstance(id) {
    return rpc(adminBase(), "deleteInstance", [id], { method: "POST" });
  },
  listDomains() {
    return rpc(adminBase(), "listDomain");
  },
  assignDomain(host, instance_id) {
    return rpc(adminBase(), "assignDomain", [host, instance_id], { method: "POST" });
  },

  // ── Tenant scope: KV (kv={instance_id}.app.db) ───────────────────
  listKv(instance_id, { prefix = "", cursor = "", limit = 100 } = {}) {
    return rpc(scopeBase(instance_id), "listKv", [prefix, cursor, limit]);
  },
  getKv(instance_id, key) {
    return rpc(scopeBase(instance_id), "getKv", [key]);
  },

  // ── Out-of-band: files (native Zig proxy) ────────────────────────
  async listFiles(instance_id) {
    const res = await rawGet(adminBase(),
      `/_system/files/${encodeURIComponent(instance_id)}/list`);
    return res.json();
  },
  async getFile(instance_id, path) {
    const res = await rawGet(adminBase(),
      `/_system/files/${encodeURIComponent(instance_id)}/file/${encodePath(path)}`);
    return res.json();
  },
  async putFile(instance_id, path, content, contentType) {
    const res = await fetch(
      adminBase() + `/_system/files/${encodeURIComponent(instance_id)}/file/${encodePath(path)}`,
      {
        method: "PUT",
        credentials: "include",
        headers: { "Content-Type": contentType || "application/octet-stream" },
        body: content,
      },
    );
    if (!res.ok) {
      const txt = await res.text().catch(() => "");
      throw new ApiError(res.status, res.statusText, txt);
    }
    return res.text();
  },

  // ── Out-of-band: logs (native Zig proxy) ────────────────────────
  async listLogs(instance_id, { limit = 100 } = {}) {
    const qs = new URLSearchParams({ limit: String(limit) }).toString();
    const res = await rawGet(adminBase(),
      `/_system/log/${encodeURIComponent(instance_id)}/list?${qs}`);
    return res.json();
  },
  async showLog(instance_id, request_id_hex) {
    const res = await rawGet(adminBase(),
      `/_system/log/${encodeURIComponent(instance_id)}/show/${encodeURIComponent(request_id_hex)}`);
    return res.json();
  },
  async countLogs(instance_id) {
    const res = await rawGet(adminBase(),
      `/_system/log/${encodeURIComponent(instance_id)}/count`);
    return res.text();
  },
};
