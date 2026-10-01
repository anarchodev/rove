// Offline eager dispatch resolution: the result row and the marker delete
// land in the store the handler reads, `__root__` always resolves, and the
// root models read absence as absence.
import { scenario, expect } from "rewind:test";

const r = scenario({
  admin: true,
  instances: { acme: {} },
  root: { kv: { "instance/acme": "" } },
}).inbound({ method: "GET", path: "/" });

// Resolved in the same activation: marker gone, result row readable.
expect(r.body.scopeKv.owed).toBe(null);
expect(r.body.scopeKv.status).toBe(200);
expect(r.instanceKv("acme", "k")).toBe("v");

// `__root__` is always resolvable — no scenario has to declare it.
expect(r.body.rootQuery.instances).toEqual(["acme"]);
expect(r.body.rootQuery.instance_exists).toBe(false);
expect(r.body.rootQuery.domain_owner).toBe(null);

// A `requires` naming a missing root row fails the install.
expect(r.body.rootRequires).toBe(409);

// Each resolution op is recorded exactly once — the result write, the marker
// delete and both watchdog deletes. A second recording path would double
// them and shift the interaction digest.
const resolveOps = r.effects.filter((e) =>
  (e.kind === "write" && String(e.key).startsWith("_dispatch/result/")) ||
  (e.kind === "delete" && /^_(dispatch\/owed|sched\/by_id|sched\/by_time)\//.test(String(e.key))));
const seen = new Set(resolveOps.map((e) => e.kind + " " + e.key));
expect(resolveOps.length).toBe(seen.size);
// Three dispatches: three result rows, three marker deletes, six watchdog deletes.
expect(resolveOps.length).toBe(12);
