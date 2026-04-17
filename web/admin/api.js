// Typed wrapper around the rove admin API.
//
// Every admin call is an RPC against the `__admin__` handler. Named
// function exports are invoked via `?fn=<name>` (GET, with any args
// as a URL-encoded JSON array in `args=`) or POST body
// `{fn:"name", args:[...]}`. The return value IS the response body.
//
// Two scopes for the admin handler:
// 1. Bare admin host (`api.loop46.com`)      → `kv` = root store.
//    Use for tenant + domain CRUD.
// 2. `{id}.api.loop46.com` subdomain         → `kv` = {id}'s app.db.
//    Use for KV browsing scoped to one tenant.
//
// Out-of-band (still the native Zig proxies): logs + code via
// `/_system/log/*` and `/_system/code/*`. Path-scoped; instance
// always appears in the path.

const TOKEN_KEY = "rove.admin.token";
const BASE_KEY = "rove.admin.api_base";

export class ApiError extends Error {
  constructor(status, statusText, body) {
    super(`${status} ${statusText}`);
    this.status = status;
    this.body = body;
  }
}

function getToken() { return localStorage.getItem(TOKEN_KEY) ?? ""; }

/// The bare admin API base, e.g. `https://api.loop46.com:8443`.
function adminBase() {
  const v = window.__rove_api_base ?? localStorage.getItem(BASE_KEY) ?? "";
  return v.replace(/\/+$/, "");
}

/// The per-tenant API base: `https://{id}.api.loop46.com:8443`.
function scopeBase(instance_id) {
  const base = adminBase();
  if (base === "") return "";
  try {
    const u = new URL(base);
    u.hostname = `${instance_id}.${u.hostname}`;
    return u.toString().replace(/\/+$/, "");
  } catch {
    return base;
  }
}

/// Call a named export on the admin handler. GET with args as a
/// URL-encoded JSON array; or, if `method === "POST"`, send
/// `{fn, args}` as a JSON body. Returns the parsed response body.
async function rpc(base, fn, args, { method = "GET" } = {}) {
  const argsArr = args ?? [];
  let url, init;
  if (method === "POST") {
    url = base + "/";
    init = {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${getToken()}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ fn, args: argsArr }),
    };
  } else {
    const qs = new URLSearchParams({ fn });
    if (argsArr.length > 0) qs.set("args", JSON.stringify(argsArr));
    url = `${base}/?${qs.toString()}`;
    init = {
      method: "GET",
      headers: { "Authorization": `Bearer ${getToken()}` },
    };
  }
  const res = await fetch(url, init);
  const ct = res.headers.get("content-type") ?? "";
  const parsed = ct.includes("application/json")
    ? await res.json().catch(() => null)
    : await res.text();
  if (!res.ok) throw new ApiError(res.status, res.statusText, parsed);
  return parsed;
}

/// Raw GET for endpoints that return non-JSON bodies (mostly the
/// out-of-band log/code proxies).
async function rawGet(base, path) {
  const res = await fetch(base + path, {
    headers: { "Authorization": `Bearer ${getToken()}` },
  });
  if (!res.ok) {
    const txt = await res.text().catch(() => "");
    throw new ApiError(res.status, res.statusText, txt);
  }
  return res;
}

export const api = {
  // ── Auth ─────────────────────────────────────────────────────────
  setToken(t) { localStorage.setItem(TOKEN_KEY, t); },
  clearToken() { localStorage.removeItem(TOKEN_KEY); },
  hasToken() { return getToken().length > 0; },

  // ── Admin scope: tenant CRUD + domains (kv=root) ────────────────
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
