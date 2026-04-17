// Typed wrapper around the js-worker's /_system/* surface.
//
// Bearer token lives in localStorage under "rove.admin.token".
// The API base URL defaults to same-origin; override in dev by setting
// window.__rove_api_base before app.js runs (see index.html).
//
// Error model: every method throws an ApiError on non-2xx. The router
// intercepts 401 + clears the token so users land back on login.

const TOKEN_KEY = "rove.admin.token";

export class ApiError extends Error {
  constructor(status, statusText, body) {
    super(`${status} ${statusText}`);
    this.status = status;
    this.body = body;
  }
}

function getToken() { return localStorage.getItem(TOKEN_KEY) ?? ""; }

async function call(method, path, body) {
  const base = window.__rove_api_base ?? "";
  const res = await fetch(base + path, {
    method,
    headers: {
      "Authorization": `Bearer ${getToken()}`,
      ...(body != null ? { "Content-Type": "application/json" } : {}),
    },
    body: body != null ? JSON.stringify(body) : undefined,
  });

  const ct = res.headers.get("content-type") ?? "";
  const parsed = ct.includes("application/json")
    ? await res.json().catch(() => null)
    : await res.text();

  if (!res.ok) throw new ApiError(res.status, res.statusText, parsed);
  return parsed;
}

export const api = {
  // ── Auth ─────────────────────────────────────────────────────────
  setToken(t) { localStorage.setItem(TOKEN_KEY, t); },
  clearToken() { localStorage.removeItem(TOKEN_KEY); },
  hasToken() { return getToken().length > 0; },

  // ── Tenant: instances ────────────────────────────────────────────
  listInstances() {
    return call("GET", "/_system/tenant/instance");
  },
  createInstance(id) {
    return call("POST", "/_system/tenant/instance", { id });
  },
  getInstance(id) {
    return call("GET", `/_system/tenant/instance/${encodeURIComponent(id)}`);
  },
  deleteInstance(id) {
    return call("DELETE", `/_system/tenant/instance/${encodeURIComponent(id)}`);
  },

  // ── Tenant: domains ──────────────────────────────────────────────
  listDomains() {
    return call("GET", "/_system/tenant/domain");
  },
  assignDomain(host, instance_id) {
    return call("POST", "/_system/tenant/domain", { host, instance_id });
  },

  // ── Logs ─────────────────────────────────────────────────────────
  listLogs(instance_id, { limit = 100 } = {}) {
    const qs = new URLSearchParams({ limit: String(limit) }).toString();
    return call("GET", `/_system/log/${encodeURIComponent(instance_id)}/list?${qs}`);
  },
  showLog(instance_id, request_id_hex) {
    return call(
      "GET",
      `/_system/log/${encodeURIComponent(instance_id)}/show/${encodeURIComponent(request_id_hex)}`,
    );
  },
  countLogs(instance_id) {
    return call("GET", `/_system/log/${encodeURIComponent(instance_id)}/count`);
  },
};
