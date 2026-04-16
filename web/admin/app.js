// rove admin entry point. Hash-based router — no build step required.
//
// Routes:
//   #/login       → token entry
//   #/instances   → list + create + delete + assign-domain
//
// Auth gate: every route except #/login bounces to #/login if
// api.hasToken() is false. The individual pages also handle 401 by
// clearing the token and calling goto("#/login"), which covers the
// "token was valid yesterday but got revoked" case.

import { api, ApiError } from "./api.js";
import * as login from "./pages/login.js";
import * as instances from "./pages/instances.js";

const routes = {
  "#/login": login,
  "#/instances": instances,
};

let currentTeardown = null;

function route() {
  const hash = location.hash || "#/instances";
  const target = routes[hash] ?? routes["#/instances"];

  // Auth gate: any route except login requires a token.
  if (target !== login && !api.hasToken()) {
    location.hash = "#/login";
    return;
  }
  // Already-logged-in users bounced off the login page land on instances.
  if (target === login && api.hasToken()) {
    location.hash = "#/instances";
    return;
  }

  if (typeof currentTeardown === "function") {
    try { currentTeardown(); } catch {}
  }
  currentTeardown = null;

  const root = document.getElementById("app");
  root.replaceChildren();

  try {
    const result = target.render(root, { goto, api, ApiError });
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
