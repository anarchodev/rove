// Cross-module fetch continuations (docs/plans/sim-test-framework.md). A fetch
// whose `on` names a DIFFERENT module file must resume in THAT module, and a bare
// continuation module must be drivable in isolation. Both were impossible before
// `FetchHandle.resolve` learned to switch entry on a module-path `on` and
// `scenario.fetchResult` was added.
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });

// ── folded: the fetch's `on` is a SEPARATE module (hooks/onFetched.mjs) ──
const req = s.inbound({ method: "GET", path: "/?k=alpha" });
expect(req.disposition).toBe("held");
expect(req).toHaveFetched(/api\.example\.com/);

const done = req.fetch(/api\.example\.com/).resolve({ status: 200, body: "payload" });
// the continuation ran the OTHER module at its default export (not the parent) —
// only hooks/onFetched.mjs writes `result/*`, so the write proves it dispatched.
expect(done.bundle.export).toBe("default");
expect(done).toHaveWritten("result/alpha", { ok: true, status: 200, body: "payload" });
expect(done.body).toEqual({ done: true, key: "alpha" });

// ── standalone: drive the continuation module in isolation, given a failure ──
const solo = s.fetchResult({
  on: "hooks/onFetched.mjs",
  ctx: { key: "beta" },
  status: 502, ok: false, body: "nope",
});
expect(solo).toHaveWritten("result/beta", { ok: false, status: 502, body: "nope" });
expect(solo.body).toEqual({ done: true, key: "beta" });
