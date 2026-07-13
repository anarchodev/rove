// Error semantics ≡ prod (issue #10). Each case asserts the outcome the
// WORKER produces (worker_dispatch.zig / module_execution.zig), so a test
// written offline predicts the live response:
//   throw          → 500 "handler threw: {ToString}\n", head discarded, txn
//                    rolled back (writes/cmds excluded from folds + matchers)
//   pending return → treated as a plain value → 200 "{}" (response_building)
//   missing export → 404 "module export …" (disconnect = no-op;
//                    inbound_headers falls back to the buffered default)
//   bad middleware → 500 "must export a `before` function"; a THROWING
//                    middleware takes the same 500+rollback path as a handler
import { scenario, expect } from "rewind:test";

const s = scenario({});

// ── thrown handler: 500 + rollback ──
const t = s.inbound({ path: "/throw" });
expect(t.status).toBe(500); // the handler's 201 is discarded
expect(t.ok).toBe(false);
expect(t.body).toMatch(/^handler threw: Error: boom/);
expect(t.error).toBeTruthy(); // the diagnostic survives on the bundle
expect(t).not.toHaveWritten("before-throw"); // rolled back with the txn
expect(t.kv("before-throw")).toBe(null); // …and excluded from the kv fold
expect(t).not.toHaveFetched(/api\.example\.com/); // pending fetch freed unfired

// ── pending-promise return: prod ships 200 "{}" ──
const p = s.inbound({ path: "/pending" });
expect(p.status).toBe(200);
expect(p.ok).toBe(true);
expect(p.error).not.toBeTruthy();
expect(p.body).toEqual({});

// ── missing onDisconnect: a no-op in prod, never an error ──
const h = s.inbound({ path: "/hold" });
expect(h.disposition).toBe("held");
const d = h.disconnect();
expect(d.ok).toBe(true);
expect(d.error).not.toBeTruthy();

// ── missing export: 404 with prod's message ──
const m = scenario({ sources: { "index.mjs": "export function onlyThis() { return 1; }" } });
const r404 = m.inbound({ path: "/" });
expect(r404.status).toBe(404);
expect(r404.body).toMatch(/module export "default" not found or not a function/);
expect(r404.ok).toBe(true); // the run executed fine; the 404 IS the response

// ── inbound_headers without onHeaders: falls back to the buffered default ──
const fb = scenario({ sources: { "index.mjs": "export default function () { return { via: \"default\" }; }" } });
const rh = fb.inboundHeaders({ path: "/up" });
expect(rh.status).toBe(200);
expect(rh.body).toEqual({ via: "default" });

// ── middleware without `before`: loud 500, handler never runs ──
const bm = scenario({
  sources: {
    "index.mjs": "export default function () { kv.set(\"reached\", \"1\"); return \"never\"; }",
    "_middlewares/index.mjs": "export const notBefore = 1;",
  },
});
const rm = bm.inbound({ path: "/" });
expect(rm.status).toBe(500);
expect(rm.body).toMatch(/_middlewares\/index\.mjs must export a `before` function/);
expect(rm.kv("reached")).toBe(null); // short-circuited before the handler

// ── throwing middleware: the same 500 "handler threw" + rollback path ──
const tm = scenario({
  sources: {
    "index.mjs": "export default function () { kv.set(\"reached\", \"1\"); return \"never\"; }",
    "_middlewares/index.mjs": "export function before() { kv.set(\"mw\", \"1\"); throw new Error(\"mw boom\"); }",
  },
});
const rt = tm.inbound({ path: "/" });
expect(rt.status).toBe(500);
expect(rt.body).toMatch(/^handler threw: Error: mw boom/);
expect(rt).not.toHaveWritten("mw");
expect(rt.kv("reached")).toBe(null);
