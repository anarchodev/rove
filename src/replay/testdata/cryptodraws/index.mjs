// crypto.* replays the draws a capture recorded, not values derived from the
// seed: the conformance case `cryptodraws` gives every engine the same
// recorded run and expects byte-identical output.
export default function () {
  const id = crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(4));
  const r = crypto.randomBytes(2);
  return { id, b: Array.from(b).join(","), r: Array.from(r).join(",") };
}
