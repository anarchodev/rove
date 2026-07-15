// platform.* per-store kv isolation (docs/architecture/replay-and-sim.md). Seeds a
// tenant store + two instance stores + the root store, then asserts the admin
// handler's writes stayed isolated per store and the seeds read back through the
// matching facade.
import { scenario, expect } from "rewind:test";

const s = scenario({
  admin: true, // platform.* is admin-only
  kv: { "seed-own": "own-seed" },
  instances: { acme: { kv: { profile: "acme-old" } }, beta: {} },
  root: { kv: { cfg: "root-old" } },
});
const r = s.inbound({ method: "POST", path: "/admin" });

// The same key "shared" written to four stores — each holds its own value.
expect(r.body.ownShared).toBe("own");
expect(r.kv("shared")).toBe("own");                  // tenant store post-state
expect(r.instanceKv("acme", "shared")).toBe("acme");
expect(r.instanceKv("beta", "shared")).toBe("beta");
expect(r.rootKv("shared")).toBe("root");

// Seeds read back through the right facade.
expect(r.body.ownSeed).toBe("own-seed");
expect(r.body.acmeSeed).toBe("acme-old");
expect(r.body.rootSeed).toBe("root-old");

// Writes landed in the correct store; read-your-write within acme's store.
expect(r.instanceKv("acme", "profile")).toBe("acme-new");
expect(r.rootKv("cfg")).toBe("root-new");
expect(r.body.acmeShared).toBe("acme");

// A tenant `toHaveWritten` matches only the tenant write, not the scoped ones.
expect(r).toHaveWritten("shared", "own");
// Scoped/root writes surface in the effect log with a store tag.
expect(r.effects.some((e) => e.kind === "write" && e.store === "i/acme" && e.key === "profile")).toBe(true);
expect(r.effects.some((e) => e.kind === "write" && e.store === "r" && e.key === "cfg")).toBe(true);
