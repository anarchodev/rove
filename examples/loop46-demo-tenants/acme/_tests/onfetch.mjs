// Offline cross-check of on_fetch_smoke_v2.py: the same acme on.fetch handlers,
// the same wb/bulk body, the same byte-exact reconstruction assertions — but as
// a pure `rewind test` (no cluster). If this agrees with the smoke's
// through-the-stack result, the fetch fold is faithful for streaming-bind +
// buffered fetch resumes.
import { scenario, expect } from "rewind:test";

// The exact deterministic body wb/bulk serves (10 lines × 17B = 170B), which
// on_fetch_smoke_v2 asserts is reconstructed byte-exact.
const EXPECTED = Array.from({ length: 10 }, (_, i) => `bulk-line-${String(i).padStart(2, "0")}-zzz\n`).join("");

// ── streaming on.fetch: bind + {on:onUpstream} + per-chunk resume ──
// Mirrors the smoke's "/onfetch" — the handler accumulates each chunk in kv and
// returns the reconstructed body on the terminal chunk.
{
  const s = scenario({ entry: "onfetch/index.mjs" });
  const req = s.inbound({ method: "GET", path: "/onfetch?url=http://wb/bulk" });
  expect(req.disposition).toBe("held");
  expect(req).toHaveFetched(/bulk/);
  // Deliver the body in ≤64B chunks, as the engine would under maxChunkBytes:64.
  const chunks = [EXPECTED.slice(0, 64), EXPECTED.slice(64, 128), EXPECTED.slice(128)];
  const done = req.fetch(/bulk/).stream(chunks);
  expect(done.status).toBe(200);
  expect(done.body).toBe(EXPECTED); // the smoke's core assertion, offline
}

// ── non-streaming on.fetch → conventional onFetchResult ──
// Mirrors the smoke's "/onfetchbuf" — whole body in one result activation.
{
  const s = scenario({ entry: "onfetchbuf/index.mjs" });
  const req = s.inbound({ method: "GET", path: "/onfetchbuf?url=http://wb/bulk" });
  expect(req.disposition).toBe("held");
  const res = req.fetch(/bulk/).resolve({ status: 200, body: EXPECTED });
  expect(res.status).toBe(200);
  expect(res.body).toBe(EXPECTED);
}
