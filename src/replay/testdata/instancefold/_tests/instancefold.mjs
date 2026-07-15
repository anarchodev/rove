// An instance created by `platform.instances.create` stays resolvable for
// `platform.scope` in later activations of the same chain — the exists
// marker folds forward with the effect log, so create-then-scope-in-resume
// works offline as it does live.
import { scenario, expect } from "rewind:test";

const s = scenario({ admin: true, now: "2026-07-01T00:00:00Z" });
const held = s.inbound({ method: "POST", path: "/provision" });
expect(held.disposition).toBe("held");

const done = held.fetch(/api\.example\.test/).resolve({ status: 200, body: "{}" });
expect(done.body).toEqual({ ok: true });
expect(done.instanceKv("neo", "hello")).toBe("1");
