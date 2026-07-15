// platform.* admin-only gating, fail-closed (docs/architecture/replay-and-sim.md).
// A non-admin run has every sync platform method throw; an admin run has them
// all succeed. `platform.compile` is ungated in both (door-side check in prod).
import { scenario, expect } from "rewind:test";

const GATED = ["scope", "root", "instances", "releases", "auth"];
const NOT_ADMIN = /only available on the admin handler/;

// Non-admin (default): the gated methods throw, compile still emits.
const denied = scenario({}).inbound({ method: "GET", path: "/" });
for (const k of GATED) expect(denied.body[k]).toMatch(NOT_ADMIN);
expect(denied.body.compile).toBe("ok");
// A rejected call logs no platform effect (it throws before recording).
expect(denied.effects.some((e) => e.kind === "platform")).toBe(false);

// Admin run: every method is allowed. The scoped instance must be declared —
// platform.scope resolves eagerly (ghost id ⇒ InstanceNotFound, like prod).
const ok = scenario({ admin: true, instances: { acme: {} } }).inbound({ method: "GET", path: "/" });
for (const k of GATED) expect(ok.body[k]).toBe("ok");
expect(ok.body.compile).toBe("ok");
expect(ok.effects.some((e) => e.kind === "platform" && e.op === "scope")).toBe(true);
