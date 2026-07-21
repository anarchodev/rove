// Cross-module fetch continuations (docs/architecture/replay-and-sim.md). A
// bound `after.fetch` cannot name a different module: prod validates `{on}` as
// a bare export identifier at issue time (a `/` or `.` path throws — the
// cross-module continuation surface is `webhook.send`'s `on`), and the sim
// recorder throws the identical TypeError. A bare continuation MODULE is still
// drivable in isolation via `scenario.fetchResult`.
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });

// ── issuing: a module-path `{on}` throws at the call site, like prod ──
const req = s.inbound({ method: "GET", path: "/?k=alpha" });
expect(req.status).toBe(200);
expect(req.body.type).toBe("TypeError");
expect(req.body.threw).toMatch(/after\.fetch: `on` must be a JS identifier/);
expect(req).not.toHaveFetched(/api\.example\.com/); // nothing was issued

// ── standalone: drive the continuation module in isolation, given a failure ──
const solo = s.fetchResult({
  on: "hooks/onFetched.mjs",
  ctx: { key: "beta" },
  status: 502, body: "nope",
});
expect(solo).toHaveWritten("result/beta", { ok: false, status: 502, body: "nope" });
expect(solo.body).toEqual({ done: true, key: "beta" });
// The surface is UNBOUND: no top-level flatten; the result is on request.activation.*
expect(solo).toHaveWritten("surface/beta", { topStatus: true, activationKind: "fetch_chunk", bytesLen: 4 });

// …and given a success.
const soloOk = s.fetchResult({
  on: "hooks/onFetched.mjs",
  ctx: { key: "gamma" },
  status: 200, body: "payload",
});
expect(soloOk).toHaveWritten("result/gamma", { ok: true, status: 200, body: "payload" });
expect(soloOk.body).toEqual({ done: true, key: "gamma" });
