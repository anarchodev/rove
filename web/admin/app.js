// rove admin entry point. Hash-based router — no build step required.
//
// Routes:
//   #/login       → token entry
//   #/instances   → list + create + delete + assign-domain
//   #/instance/:id → per-instance dashboard
//
// Auth: cookie-based. Every route except #/login calls `api.whoami()`
// before rendering. On 401, we bounce to #/login. On success, the
// cookie carries auth for every subsequent fetch in the session.

import { api, ApiError } from "./api.js";
import * as login from "./pages/login.js";
import * as instances from "./pages/instances.js";
import * as instance from "./pages/instance.js";

// Route resolver. Static routes map exactly; `#/instance/:id` is a
// parameterized route so we match its prefix.
function resolveRoute(hash) {
  if (hash === "#/login") return { page: login, params: {} };
  if (hash === "#/instances") return { page: instances, params: {} };
  if (hash.startsWith("#/instance/")) {
    const id = decodeURIComponent(hash.slice("#/instance/".length));
    if (id.length > 0) return { page: instance, params: { id } };
  }
  return { page: instances, params: {} };
}

let currentTeardown = null;

async function route() {
  const hash = location.hash || "#/instances";
  const { page, params } = resolveRoute(hash);

  // Auth gate: every page except login requires a live session.
  // /v1/session 401 → redirect to login; 200 → proceed.
  if (page !== login) {
    const who = await api.whoami();
    if (!who) {
      location.hash = "#/login";
      return;
    }
  } else {
    // Don't strand already-authed users on the login page.
    const who = await api.whoami();
    if (who) {
      location.hash = "#/instances";
      return;
    }
  }

  if (typeof currentTeardown === "function") {
    try { currentTeardown(); } catch {}
  }
  currentTeardown = null;

  const root = document.getElementById("app");
  root.replaceChildren();

  try {
    const result = page.render(root, { goto, api, ApiError, params });
    if (typeof result === "function") currentTeardown = result;
  } catch (err) {
    root.textContent = `render failed: ${err.message}`;
    console.error(err);
  }
}

export function goto(hash) {
  if (location.hash === hash) route();
  else location.hash = hash;
}

window.addEventListener("hashchange", route);
window.addEventListener("DOMContentLoaded", route);

// Handy for console debugging.
window.__rove_api = api;
