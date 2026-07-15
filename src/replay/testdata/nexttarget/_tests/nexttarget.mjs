// Cross-module `next(target, ctx)` (docs/handler-shape.md §2.1): the held
// chain parks the TARGET module, so every resume fold — timer wake, kv wake,
// bound fetch result, disconnect — re-enters flows/step2.mjs, not the module
// that held. Both modules write distinct keys (`step2/*` vs the decoy
// `index/*`), so the write proves which module ran; the decoys' absence
// proves the parent did NOT.
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });

const held = s.inbound({ method: "POST", path: "/start" });
expect(held.disposition).toBe("held");
// The cross ctx is the parked next() state every resume observes…
expect(held.ctx).toEqual({ job: "j1" });
// …and the target rides the bundle (the parked module).
expect(held.bundle.target).toBe("flows/step2.mjs");

// ── timer wake → the target's onWake ──
const timer = held.clock.advance("30s").fire();
expect(timer).toHaveWritten("step2/woke-timer", { ctx: { job: "j1" } });
expect(timer).not.toHaveWritten("index/woke");
expect(timer.body).toEqual({ done: "timer" });

// ── kv wake → the same target ──
const kvw = held.wakeKv({ "job/1": { state: "ready" } });
expect(kvw).toHaveWritten("step2/woke-kv", { ctx: { job: "j1" } });
expect(kvw).not.toHaveWritten("index/woke");
expect(kvw.body).toEqual({ done: "kv" });

// ── bound fetch armed by the HOLDING activation → the target's onFetchResult ──
const fr = held.fetch(/api\.example\.com/).resolve({ status: 200, body: "pong" });
expect(fr).toHaveWritten("step2/fetched", { status: 200, body: "pong", ctx: { job: "j1" } });
expect(fr).not.toHaveWritten("index/fetched");
expect(fr.body).toEqual({ done: "fetch" });

// ── disconnect → the target's onDisconnect ──
const bye = held.disconnect();
expect(bye).toHaveWritten("step2/bye", { ctx: { job: "j1" } });
expect(bye).not.toHaveWritten("index/bye");
expect(bye.body).toEqual({ done: "bye" });
