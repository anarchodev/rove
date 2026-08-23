// blob verbs offline. `blob.put` (one-shot), the `write`→`seal` recipe (which
// accumulates over the streaming sha256 midstate), and `blob.url` (presign) all
// run their real shims from the sim base. The handler self-verifies that the
// streamed recipe hash equals a one-shot sha256 over the concatenation — the
// invariant the whole recipe substrate rests on.
//
// The test drives one case per activation (a recipe is one-seal-per-chain), so
// the cases live here as an array selected by an ASCII index rather than being
// threaded through the request body.
const CASES = [
  { one: "one-shot", parts: ["hello ", "world"] },                 // ASCII, sub-block
  { one: "A".repeat(100), parts: ["A".repeat(70), "B".repeat(50)] }, // >64B, block-cross
  { one: "héllo", parts: ["héllo wörld ✓ ".repeat(3), "✓✓✓"] },    // UTF-8 + multi-block
  { one: "z", parts: [] },                                          // empty recipe
];

export default function ({ blob }) {
  const c = CASES[request.json.i];
  const putHash = blob.put(c.one, { contentType: "text/plain" });
  for (const p of c.parts) blob.write(p);
  const sealHash = blob.seal({ on: "media/onStored", ctx: { id: "r" } });
  const concat = c.parts.join("");
  return {
    putOk: putHash === crypto.sha256(c.one),
    sealOk: sealHash === crypto.sha256(concat),
    sealHash,
    url: blob.url(putHash, { ttl: 60 }),
  };
}
