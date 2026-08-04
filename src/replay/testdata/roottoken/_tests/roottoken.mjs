// `request.rewind.isRoot` — the operator-root verdict
// (docs/architecture/replay-and-sim.md). A scenario declares the ANSWER, not a
// token to compare: prod computes the verdict in the engine and the bearer is
// unreachable from the handler, so there is no token for a test to supply.
import { scenario, expect } from "rewind:test";

// Root-credentialed request → admitted. `admin: true` is what installs
// `request.rewind` at all (platform-bound); `isRoot` is the verdict on it.
const good = scenario({ admin: true, isRoot: true })
  .inbound({ method: "GET", path: "/admin" });
expect(good.status).toBe(200);
expect(good.body).toEqual({ ok: true, admin: true });

// Same handler, no root credential → rejected. An admin run always declares
// the verdict, so the unauthenticated branch needs no extra knob.
const bad = scenario({ admin: true, isRoot: false })
  .inbound({ method: "GET", path: "/admin" });
expect(bad.status).toBe(403);
expect(bad.body.ok).toBe(false);

// Omitting `isRoot` on an admin run defaults to false — nothing authenticates
// as root unless the scenario says so.
const unset = scenario({ admin: true }).inbound({ method: "GET", path: "/admin" });
expect(unset.status).toBe(403);
