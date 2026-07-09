// The tenant's real _middlewares/index.mjs runs before the handler: it can
// mutate request (request.auth) or short-circuit. request.session is injected.
import { scenario, expect } from "rewind:test";
const s = scenario({});

// Authed: middleware sets request.auth; the handler sees it.
const ok = s.inbound({ path: "/", headers: { authorization: "Bearer good" }, session: { id: "sess1" } });
expect(ok.status).toBe(200);
expect(ok.body).toEqual({ user: "jess", scopes: ["read"], sid: "sess1" });

// Denied: middleware short-circuits — the handler never runs.
const no = s.inbound({ path: "/", headers: { authorization: "Bearer bad" } });
expect(no.status).toBe(401);
expect(no.body).toBe("denied");
