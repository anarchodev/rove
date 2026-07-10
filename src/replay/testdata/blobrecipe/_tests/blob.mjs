// blob recipe correctness offline (docs/architecture/replay-and-sim.md). The
// pure-JS streaming sha256 driving blob.write/seal must agree bit-for-bit with
// one-shot crypto.sha256 over the concatenation — across block boundaries and
// UTF-8 — and the durable primitives (owed marker + recipe rows + the PUT/compose
// fetches) must land in the effect log. The handler self-verifies (it has
// `crypto`); each case is one activation (one seal per chain), selected by index.
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });

function run(i) {
  return s.inbound({ method: "POST", path: "/", body: { i } });
}

// case 0 ASCII sub-block, 1 >64B block-cross, 2 UTF-8 + multi-block.
for (const i of [0, 1, 2]) {
  const r = run(i);
  expect(r.body.putOk).toBe(true);   // put hash === sha256(one)
  expect(r.body.sealOk).toBe(true);  // streamed seal hash === sha256(concat)
}

// case 3 empty recipe seals to sha256("") — the well-known digest.
const empty = run(3);
expect(empty.body.sealOk).toBe(true);
expect(empty.body.sealHash).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

// Durable primitives + presign in the effect log (case 0).
const r0 = run(0);
expect(r0.body.url).toMatch(/sim\.invalid\/blob\/[0-9a-f]{64}/);
const writes = r0.effects.filter((e) => e.kind === "write");
expect(writes.some((e) => e.key.startsWith("_blob/owed/"))).toBe(true);   // put's owed marker
expect(writes.some((e) => e.key.startsWith("_blob/recipe/"))).toBe(true); // recipe rows + meta
expect(r0).toHaveFetched(/rove-blob\.internal/);                          // the put PUT
expect(r0).toHaveFetched(/rove-compose\.internal/);                       // the seal compose
