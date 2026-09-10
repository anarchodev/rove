// platform.* admin-only gating, fail-closed (docs/architecture/replay-and-sim.md).
// A non-admin run has every sync platform method throw; an admin run has them
// all succeed. `platform.compile` is ungated in both (door-side check in prod).
import { scenario, expect } from "rewind:test";

// `root` is not in this list: `platform.root` is GONE (rove#852), and an
// absent name is not a gate — root reads are dispatched queries against
// `__root__`, gated through `dispatch` like every other platform verb.
const GATED = ["scope", "dispatch"];
const NOT_ADMIN = /only available on the admin handler/;

// Non-admin (default): the gated methods throw, compile still emits.
const denied = scenario({}).inbound({ method: "GET", path: "/" });
for (const k of GATED) expect(denied.body[k]).toMatch(NOT_ADMIN);
expect(denied.body.compile).toBe("ok");
// `request.rewind` isn't gated — it is absent entirely off a platform-bound
// handler, so there is no operator-root verdict to read and no verb that would
// take a bearer.
expect(denied.body.rewind).toBe("absent");
// A rejected call logs no platform effect (it throws before recording).
expect(denied.effects.some((e) => e.kind === "platform")).toBe(false);

// Admin run: every method is allowed. The scoped instance must be declared —
// platform.scope resolves eagerly (ghost id ⇒ InstanceNotFound, like prod).
const ok = scenario({ admin: true, instances: { acme: {} } }).inbound({ method: "GET", path: "/" });
for (const k of GATED) expect(ok.body[k]).toBe("ok");
expect(ok.body.compile).toBe("ok");
// Platform-bound ⇒ `request.rewind` exists; an admin run that doesn't declare
// `isRoot` reads false (nothing authenticates as root by default).
expect(ok.body.rewind).toBe("false");
expect(ok.effects.some((e) => e.kind === "platform" && e.op === "scope")).toBe(true);
// The dispatched write LANDED in the target's isolated store — the offline
// model resolves a dispatch eagerly (marker never observably stands), same
// semantics as the live round-trip, one activation sooner.
expect(ok.instanceKv("acme", "pd/x")).toBe("1");
// The recorders carry their real arguments — the effect log names which
// module was dispatched against which tenant.
expect(ok.effects.some((e) => e.op === "dispatch" && e.tenant === "acme" && e.module === "__system/scope_kv")).toBe(true);
