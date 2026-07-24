// Streaming-sha256 midstate tokens are wire-compatible with the worker (#47):
// the sim decodes the worker's `s2:` format (so a prod-captured world whose kv
// carries an s2: token replays offline) and emits `s2:` too (so sim-produced
// worlds round-trip into prod-shaped fixtures), while still reading legacy `js2:`.
export default function () {
  const out = {};
  // (1) A PROD-format s2: token the sim did NOT emit — state=IV, buffered "hello " —
  // continues correctly offline.
  const prodTok = "s2:agnmZ7tnroU8bvNypU_1OlEOUn-bBWiMH4PZq1vgzRkAAAAAAAAABgZoZWxsbyA";
  out.crossBoundary = crypto.sha256Final(crypto.sha256Update(prodTok, "world"));
  // (2) The sim EMITS the worker's s2: format — prod-exact for the empty init.
  const init = crypto.sha256Init();
  out.initIsS2 = init.indexOf("s2:") === 0;
  out.initMatchesProd = init === "s2:agnmZ7tnroU8bvNypU_1OlEOUn-bBWiMH4PZq1vgzRkAAAAAAAAAAAA";
  // (3) Streaming across a 64-byte block boundary matches the one-shot digest.
  let t = crypto.sha256Init();
  t = crypto.sha256Update(t, "a".repeat(40));
  t = crypto.sha256Update(t, "b".repeat(40)); // 80 bytes → one block processed + 16 buffered
  out.midIsS2 = t.indexOf("s2:") === 0;
  out.streamed = crypto.sha256Final(t);
  out.oneshot = crypto.sha256("a".repeat(40) + "b".repeat(40));
  // (4) A legacy js2: token (old captured world) still parses.
  const legacy = "js2:6a09e667bb67ae853c6ef372a54ff53a510e527f9b05688c1f83d9ab5be0cd19:0:";
  out.legacy = crypto.sha256Final(crypto.sha256Update(legacy, "abc"));
  return out;
}
