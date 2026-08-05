// `.mjs` is the only deployable handler source, so a `.js`-spelled middleware
// is inert offline exactly as it is in production.
import { scenario, expect } from "rewind:test";

// The `.js` middleware next to the handler does not run: no gate, no auth.
const s = scenario({});
const r = s.inbound({ path: "/", headers: { authorization: "Bearer good" } });
expect(r.status).toBe(200);
expect(r.body).toEqual({ auth: null });

// It cannot short-circuit either — a `.js` that would 401 is simply absent.
const deny = scenario({
  sources: {
    "index.mjs": "export default function () { return \"handler ran\"; }",
    "_middlewares/index.js": "export function before() { response.status = 401; return \"denied\"; }",
  },
});
const d = deny.inbound({ path: "/" });
expect(d.status).toBe(200);
expect(d.body).toBe("handler ran");

// The `.mjs` spelling still gates, so this is about the EXTENSION and not
// about middleware having been dropped wholesale.
const mjs = scenario({
  sources: {
    "index.mjs": "export default function () { return { via: request.auth }; }",
    "_middlewares/index.mjs": "export function before() { request.auth = \"mjs\"; }",
  },
});
const m = mjs.inbound({ path: "/" });
expect(m.status).toBe(200);
expect(m.body).toEqual({ via: "mjs" });

// Both spellings present: `.mjs` runs, `.js` is ignored — not merely preferred.
const both = scenario({
  sources: {
    "index.mjs": "export default function () { return { via: request.auth }; }",
    "_middlewares/index.mjs": "export function before() { request.auth = \"mjs\"; }",
    "_middlewares/index.js": "export function before() { request.auth = \"js\"; }",
  },
});
const b = both.inbound({ path: "/" });
expect(b.status).toBe(200);
expect(b.body).toEqual({ via: "mjs" });
