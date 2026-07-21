import { scenario, expect } from "rewind:test";
const r = scenario({}).inbound({ method: "POST", path: "/token", body: { sub: "jess" } }).body;

// A generated key signs an id_token that verifies against its own JWK.
expect(r.kty).toBe("RSA");
expect(r.valid).toBe(true);
expect(r.sub).toBe("jess");
// A tampered token is rejected.
expect(r.badValid).toBe(false);
// The kid is deterministic (same run → same key → same signatures, replay-exact).
expect(r.kid).toMatch(/^sim-rsa-/);

// Determinism: a second identical run mints the SAME token surface.
const r2 = scenario({}).inbound({ method: "POST", path: "/token", body: { sub: "jess" } }).body;
expect(r2.kid).toBe(r.kid);
