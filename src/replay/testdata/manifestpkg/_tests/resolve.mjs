// The scenario carries NO `packages`/`app_imports` — the imports resolve purely
// from the app's manifest.json deps, proving the `rewind test` auto-resolve
// enabler (P-Lift #123 / P4a).
import { scenario, expect } from "rewind:test";

const r = scenario({ now: "2026-07-01T00:00:00Z", seed: 1 })
  .inbound({ method: "GET", path: "/", host: "mp.localhost" });
expect(r.status).toBe(200);
const b = JSON.parse(r.body);
expect(b.jwt).toBe(true);   // @rewind/jwt (direct leaf) resolved + ran
expect(b.oidc).toBe(true);  // @rewind/oidc (direct) + its transitive @rewind/jwt resolved
