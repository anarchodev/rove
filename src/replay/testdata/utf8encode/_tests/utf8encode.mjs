// Offline cross-check of utf8_encode_smoke_v2.py (issue #11): TextEncoder now
// emits real UTF-8, so every non-ASCII byte / hash / base64url matches prod.
// The expected values are the authoritative UTF-8 of "héllo €🚀" (and the
// U+FFFD replacement for a lone surrogate) — identical in the worker.
import { scenario, expect } from "rewind:test";

const s = scenario({ entry: "index.mjs" });
const r = s.inbound({ method: "GET", path: "/" });

// Values are the worker's actual output (captured by utf8_encode_smoke_v2.py):
// prod encodes a lone surrogate as 3-byte WTF-8 (eda080) but DECODES malformed
// input to U+FFFD (65533) per byte — the sim must match both.
expect(r.body).toEqual({
  hex: "68c3a96c6c6f20e282acf09f9a80",
  b64: "aMOpbGxvIOKCrPCfmoA",
  sha: "2033a60daf08c0f4d1c096929cbc3b340e8f45ce1211cf38582570e7c67c417c",
  text: "héllo €🚀",
  loneHex: "eda080",
  decInvalidLead: [65, 65533, 66],
  decIncomplete: [65, 65533],
  decOverlong: [65533, 65533],
  decSurrogate: [65533, 65533, 65533],
});
