import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });

// ── a binary inbound body round-trips byte-exact on request.bytes ──
const bytes = new Uint8Array([0, 1, 2, 250, 255, 128, 7]);
let want = 0;
for (const x of bytes) want = (want + x) & 0xffff;
const r = s.inbound({ method: "POST", path: "/upload", bodyBinary: bytes });
expect(r.body.len).toBe(7);
expect(r.body.first).toBe(0);
expect(r.body.last).toBe(7);
expect(r.body.sum).toBe(want);

// ── an explicit export override drives that export directly ──
const c = s.inbound({ path: "/x", export: "onCustom" });
expect(c.body).toEqual({ via: "onCustom", path: "/x" });
