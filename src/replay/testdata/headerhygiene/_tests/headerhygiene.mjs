// Authored-header hygiene: the world build normalizes authored request
// headers to prod's wire — names lowercase (HTTP/2), pseudo / IP-transport /
// platform-reserved names dropped (src/js/globals.zig installHeaders strips
// them before any handler runs, so they can't exist offline either). Each
// drop leaves a warn entry in the effect log so the author learns why.
import { scenario, expect } from "rewind:test";

const s = scenario({});
const r = s.inbound({
  method: "GET",
  path: "/x",
  headers: {
    "Content-Type": "application/json",
    "Cookie": "sid=abc; theme=dark",
    "X-Forwarded-For": "203.0.113.9",
    "x-rewind-tenant": "spoof",
  },
});
expect(r.error).toBe(null);
const out = JSON.parse(r.body);

// authored mixed-case names read back lowercase, values intact
expect(out.ct).toBe("application/json");
expect(out.names).toEqual(["content-type", "cookie"]);

// the lowercased cookie header parses into request.cookies
expect(out.sid).toBe("abc");

// prod-stripped names are gone from the surface entirely
expect(out.hasXff).toBe(false);
expect(out.hasRewind).toBe(false);

// each dropped header leaves a warn log entry naming the authored spelling
const warns = r.effects.filter((e) => e.kind === "log" && e.level === "warn");
expect(warns.some((w) => w.message.includes("X-Forwarded-For"))).toBe(true);
expect(warns.some((w) => w.message.includes("x-rewind-tenant"))).toBe(true);
