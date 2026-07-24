// Held-connection wake-fold parity vs the per-arm-`{on}` worker (issues #28,
// #29, #30). See index.mjs for the three invariants under test.
import { scenario, expect } from "rewind:test";

const s = scenario({ entry: "index.mjs", now: "2026-07-01T00:00:00Z" });

// ── #30: multiple after.ms → the LAST-armed timer wins (one worker slot) ──
const t = s.inbound({ method: "GET", path: "/twotimers" });
expect(t.disposition).toBe("held");

// The clock gates on the LAST arm's interval (3000ms), not the first (1000ms):
// advancing only 1s — past onEarly's overwritten arm but short of onLate's —
// must throw, proving the fold uses the last-armed interval.
let under = false;
try { t.clock.advance("1s").fire(); } catch (_) { under = true; }
expect(under).toBe(true);

// Reaching the last interval fires onLate (never onEarly — its arm is gone).
const late = t.clock.advance("3s").fire();
expect(late).toHaveWritten("fired", "late");

// ── #28: per-arm {on} routing — timer→onTimeout, kv→onMsg (distinct) ──
const h = s.inbound({ method: "GET", path: "/perarm" });
expect(h.disposition).toBe("held");

const fired = h.clock.advance("1200ms").fire();
expect(fired).toHaveWritten("route", "onTimeout");

const woke = h.wakeKv({ "msg/r1/42": { text: "hi" } });
expect(woke).toHaveWritten("route", { via: "onMsg", prefix: "msg/r1/" });

// ── #29: an after.kv wake fires ONLY for a change under its prefix ──
// A change key outside every armed prefix delivers a wake prod never would —
// the fold must refuse it rather than fabricate a resume.
let outOfPrefix = false;
try { h.wakeKv({ "other/key": "x" }); } catch (_) { outOfPrefix = true; }
expect(outOfPrefix).toBe(true);
