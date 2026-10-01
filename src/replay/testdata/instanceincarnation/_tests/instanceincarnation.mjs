// platform.instances.incarnation offline: the declared token, a fixed default,
// the legacy sentinel, InstanceNotFound for an undeclared name, and the
// name-reuse sequence a stale ownership row has to fail.
import { scenario, expect } from "rewind:test";

// A declared instance with no token reports the fixed default — minted-token
// shaped, never the legacy sentinel.
const dflt = scenario({ admin: true, instances: { acme: {} } }).inbound({ method: "GET", path: "/" });
expect(dflt.body.current).toBe("0000000000000000");

// The scenario's token is what the handler reads.
const legacy = scenario({ admin: true, instances: { acme: { incarnation: "legacy" } } })
  .inbound({ method: "GET", path: "/" });
expect(legacy.body.current).toBe("legacy");

// An undeclared name is prod's InstanceNotFound.
const ghost = scenario({ admin: true, instances: { acme: {} } })
  .inbound({ method: "GET", path: "/?name=ghost" });
expect(ghost.status).toBe(404);
expect(ghost.body.code).toBe("InstanceNotFound");

// Ownership recorded under one lifetime holds for that lifetime...
const first = scenario({ admin: true, instances: { acme: { incarnation: "aaaa1111aaaa1111" } } });
const rec = first.inbound({ method: "POST", path: "/" });
expect(rec.body.recorded).toBe("aaaa1111aaaa1111");
const stored = rec.kv("instance/acme/incarnation");
expect(stored).toBe("aaaa1111aaaa1111");
const same = scenario({
  admin: true,
  kv: { "instance/acme/incarnation": stored },
  instances: { acme: { incarnation: "aaaa1111aaaa1111" } },
}).inbound({ method: "GET", path: "/" });
expect(same.body.owned).toBe(true);

// ...and stops holding once the name is deprovisioned and provisioned again:
// the same kv row, a different incarnation.
const reborn = scenario({
  admin: true,
  kv: { "instance/acme/incarnation": "aaaa1111aaaa1111" },
  instances: { acme: { incarnation: "bbbb2222bbbb2222" } },
}).inbound({ method: "GET", path: "/" });
expect(reborn.body.current).toBe("bbbb2222bbbb2222");
expect(reborn.body.owned).toBe(false);

// platform.instances.usage offline: the declared figures, zeros by default,
// InstanceNotFound for an undeclared name.
const usage = scenario({
  admin: true,
  instances: { acme: { usage: { usedBytes: 300, durableBytes: 200, overlayBytes: 100, entries: 7, capBytes: 1000 } }, bare: {} },
}).inbound({ method: "GET", path: "/usage" });
expect(usage.body.acme).toEqual({ usedBytes: 300, durableBytes: 200, overlayBytes: 100, entries: 7, capBytes: 1000 });
expect(usage.body.bare).toEqual({ usedBytes: 0, durableBytes: 0, overlayBytes: 0, entries: 0, capBytes: null });
expect(usage.body.ghost).toBe("InstanceNotFound");
