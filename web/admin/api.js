// Typed wrapper around /_system/* — fleshed out in M2.
// Bearer token lives in localStorage under "rove.admin.token".

const TOKEN_KEY = "rove.admin.token";

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
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}`);
  const ct = res.headers.get("content-type") ?? "";
  return ct.includes("application/json") ? res.json() : res.text();
}

export const api = {
  setToken(t) { localStorage.setItem(TOKEN_KEY, t); },
  clearToken() { localStorage.removeItem(TOKEN_KEY); },
  hasToken() { return getToken().length > 0; },
  // Endpoints get added as M1 lands them.
};
