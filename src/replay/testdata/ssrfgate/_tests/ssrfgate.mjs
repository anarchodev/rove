// Resolving a SUCCESS outcome for a fetch prod categorically blocks fails
// loud: the blocked classes (SSRF ranges, plain http, localhost)
// never leave the engine, so a scripted 200 exercises a path no handler can
// reach live. The outcome prod actually delivers — the terminal transport
// failure, status 0 — stays authorable, and public https URLs are untouched.
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });
const h = s.inbound({ method: "GET", path: "/" });
expect(h.disposition).toBe("held");

const throwsWith = (fn) => {
  try { fn(); return null; } catch (e) { return String(e.message); }
};

// Metadata endpoint + 200 → loud failure naming the prod policy.
const meta = throwsWith(() => h.fetch(/169\.254/).resolve({ status: 200, body: "{}" }));
expect(meta).toMatch("prod categorically blocks");
expect(meta).toMatch("BlockedAddress");

// Plain http + 200 → loud failure naming the scheme policy.
const plain = throwsWith(() => h.fetch(/plain/).resolve({ status: 200 }));
expect(plain).toMatch("PlaintextBlocked");

// localhost + 200 → loud failure (loopback by construction).
const local = throwsWith(() => h.fetch(/localhost/).resolve({ status: 200 }));
expect(local).toMatch("BlockedAddress");

// The outcome prod actually delivers folds normally.
const failed = h.fetch(/169\.254/).resolve({ status: 0 });
expect(failed.body).toEqual({ status: 0 });

// A public https fetch is untouched by the gate.
const ok = h.fetch(/api\.example\.test\/ok/).resolve({ status: 200, body: "{}" });
expect(ok.body).toEqual({ ok: true });
