// Console formatting is ONE contract on both sides: strings pass through,
// everything else JSON-stringifies (never "[object Object]"), JSON-
// inexpressible values fall back to String(x), and the level rides as the
// worker's line prefix — so these exact strings are what a live request
// log shows (the dispatcher_test.zig console tests pin the same bytes).
import { scenario, expect } from "rewind:test";

const s = scenario({});
const r = s.inbound({ path: "/x" });
expect(r.error).toBe(null);

const msgs = r.effects.filter((e) => e.kind === "log").map((e) => e.message);
expect(msgs).toEqual([
  '{"a":1} [1,2] 42 null undefined',
  "[object Object]", // circular → String(x) fallback
  "[warn] retrying 2",
  '[warn] {"retry":true}',
  "[error]",
]);

// the bundle-internal level field still filters
expect(r.effects.filter((e) => e.kind === "log" && e.level === "warn").length).toBe(2);
