// UTF-8 request-body round-trip (docs/plans/sim-test-framework.md). Before the
// fix the sim rebuilt the body as a latin1 byte string, so any multibyte body
// made request.json throw; now request.bytes carries the UTF-8 wire bytes and
// text/json decode correctly. Covers 2-, 3- and 4-byte sequences.
import { scenario, expect } from "rewind:test";

const body = { name: "Ådám ✓", emoji: "🚀", nested: { tag: "café—naïve" } };
const r = scenario({ now: "2026-07-01T00:00:00Z" })
  .inbound({ method: "POST", path: "/submit", body });

expect(r.body.name).toBe("Ådám ✓");
expect(r.body.emoji).toBe("🚀");
expect(r.body.nested).toBe("café—naïve");
expect(r.body.textParses).toBe(true);
// The wire is UTF-8: byte length exceeds the character length (multibyte present).
expect(r.body.byteLen > r.body.charLen).toBe(true);
