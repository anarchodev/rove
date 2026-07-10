// platform.auth.checkRootToken (docs/architecture/replay-and-sim.md). The sim now
// validates the token against the configured operator root token rather than
// always succeeding, so an admin gate can actually be tested for rejection.
import { scenario, expect } from "rewind:test";

const s = scenario({ admin: true, rootToken: "s3cret" }); // platform.* is admin-only

// Correct token → admitted.
const good = s.inbound({ method: "GET", path: "/admin", headers: { "x-root-token": "s3cret" } });
expect(good.status).toBe(200);
expect(good.body).toEqual({ ok: true, admin: true });

// Wrong token → rejected.
const bad = s.inbound({ method: "GET", path: "/admin", headers: { "x-root-token": "nope" } });
expect(bad.status).toBe(403);
expect(bad.body.ok).toBe(false);

// Missing token → rejected.
const none = s.inbound({ method: "GET", path: "/admin", headers: {} });
expect(none.status).toBe(403);

// Admin handler but no root token configured → nothing authenticates, even the
// "right" string.
const unconf = scenario({ admin: true }).inbound({ method: "GET", path: "/admin", headers: { "x-root-token": "s3cret" } });
expect(unconf.status).toBe(403);

// The check surfaces its result in the effect log.
expect(good.effects.some((e) => e.op === "auth.checkRootToken" && e.ok === true)).toBe(true);
expect(bad.effects.some((e) => e.op === "auth.checkRootToken" && e.ok === false)).toBe(true);
