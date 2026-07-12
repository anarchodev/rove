// A `.js`-spelled `_middlewares/index.js` runs offline exactly like prod
// (which probes `.mjs` THEN `.js` — dispatcher.zig): before runs, its
// request mutation is visible, it short-circuits, and the missing-`before`
// 500 fires for the `.js` spelling too (issue #51).
import { scenario, expect } from "rewind:test";
const s = scenario({});

// Authed: the .js middleware sets request.auth; the handler sees it.
const ok = s.inbound({ path: "/", headers: { authorization: "Bearer good" } });
expect(ok.status).toBe(200);
expect(ok.body).toEqual({ user: "jess", scopes: ["read"] });

// Denied: the .js middleware short-circuits — the handler never runs.
const no = s.inbound({ path: "/", headers: { authorization: "Bearer bad" } });
expect(no.status).toBe(401);
expect(no.body).toBe("denied");

// A `.js` middleware without `before`: the same loud 500 as the .mjs
// spelling (prod's message names the .mjs path for both — module_execution).
const bm = scenario({
  sources: {
    "index.mjs": "export default function () { kv.set(\"reached\", \"1\"); return \"never\"; }",
    "_middlewares/index.js": "export const notBefore = 1;",
  },
});
const rm = bm.inbound({ path: "/" });
expect(rm.status).toBe(500);
expect(rm.body).toMatch(/_middlewares\/index\.mjs must export a `before` function/);
expect(rm.kv("reached")).toBe(null); // short-circuited before the handler

// Prod prefers .mjs when BOTH spellings exist — the .js twin must not win.
const both = scenario({
  sources: {
    "index.mjs": "export default function () { return { via: request.auth }; }",
    "_middlewares/index.mjs": "export function before() { request.auth = \"mjs\"; }",
    "_middlewares/index.js": "export function before() { request.auth = \"js\"; }",
  },
});
const rb = both.inbound({ path: "/" });
expect(rb.status).toBe(200);
expect(rb.body).toEqual({ via: "mjs" });
