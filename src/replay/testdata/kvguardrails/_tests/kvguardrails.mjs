// kv guardrails ≡ prod (issue #12). Prod enforces these at the kv.* binding
// (globals.zig / reserved.zig); offline they must fire identically so a
// handler that throws instantly in prod also throws — and with the SAME
// `err.code`/`err.name` — under `rewind test`:
//   object/array/null/undefined value or key → TypeError (no code)
//   leading-`_` write outside the shim allowlist → Error{code:"reserved_key"}
//   key > 256 B → Error{code:"key_too_large"}; value > 1 MiB → "value_too_large"
//   kv.prefix pages: omitted/≤0 limit → 100, any request capped at 1000
import { scenario, expect } from "rewind:test";

// ── (a)-(c) type / reserved / size guards ──
const g = scenario({}).inbound({ path: "/guards" });
expect(g.status).toBe(200);
const b = g.body;

// (a) value coercion — objects/arrays/null/undefined throw TypeError, not store.
for (const c of [b.objVal, b.arrVal, b.nullVal, b.undefVal, b.objKey]) {
  expect(c.name).toBe("TypeError");
  expect(c.code).toBe(null); // a plain TypeError carries no `code`
  expect(c.message).toMatch(/must be a string/);
}
// Primitives coerce and store — no throw.
expect(b.numOk.ok).toBe(true);
expect(b.boolOk.ok).toBe(true);

// (b) reserved-prefix guard — set and delete both reject, with the branchable code.
expect(b.reservedSet.code).toBe("reserved_key");
expect(b.reservedSet.message).toMatch(/platform-reserved prefix/);
expect(b.reservedDel.code).toBe("reserved_key");
// Shim-writable `_send/` and ordinary customer keys are allowed through.
expect(b.shimOk.ok).toBe(true);
expect(b.custOk.ok).toBe(true);

// (c) size caps — over the cap throws with the right code; the boundary passes.
expect(b.bigKey.code).toBe("key_too_large");
expect(b.bigVal.code).toBe("value_too_large");
expect(b.maxKeyOk.ok).toBe(true);

// ── (d) kv.prefix paging (100 default / 1000 cap) ──
const seed = {};
for (let i = 0; i < 1100; i++) seed["orders/" + String(i).padStart(4, "0")] = "v";
const s = scenario({ kv: seed });
expect(s.inbound({ path: "/page-default" }).body.n).toBe(100); // omitted → default
expect(s.inbound({ path: "/page-explicit" }).body.n).toBe(5); // honored under cap
expect(s.inbound({ path: "/page-over" }).body.n).toBe(1000); // 5000 clamped to 1000
