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

// ── WS module handoff: the join frame re-aims the chain; every later frame
// runs the TARGET module with the threaded ctx (one next() semantic — the WS
// family honors the cross-module target like every other held chain). ──
const wss = scenario({ entry: "lobby.mjs", now: "2026-07-01T00:00:00Z" });
const conn = wss.ws({ path: "/lobby" });
const join = conn.receive("join");
expect(join.disposition).toBe("held");
expect(join).toHaveWritten("lobby/joined", "1");
expect(join).toHaveSentFrame("lobby:ok");
const hello = join.receive("hello");
expect(hello).toHaveWritten("chat/got", "hello:r1");
expect(hello).toHaveSentFrame("chat:hello:r1");
expect(hello).not.toHaveWritten("lobby/decoy");
// The re-aim sticks: a third frame still runs chat, with chat's own ctx.
const again = hello.receive("again");
expect(again).toHaveWritten("chat/got", "again:r1");
expect(again).not.toHaveWritten("lobby/decoy");

// ── streaming activation: the SSE first hop parks the chain at the
// cross-module target; the kv wake runs the target's onWake. ──
const sses = scenario({ entry: "sse.mjs", now: "2026-07-01T00:00:00Z" });
const sse = sses.inbound({ method: "GET", path: "/sse" });
expect(sse.disposition).toBe("held");
expect(sse.bundle.target).toBe("flows/sink.mjs");
expect(sse).toHaveSentFrame("event: ready\n\n");
const sunk = sse.wakeKv({ "job/1": "go" });
expect(sunk).toHaveWritten("sink/woke", "sse");
expect(sunk).toHaveSentFrame("event: sink\n\n");
expect(sunk).not.toHaveWritten("sse/decoy");
expect(sunk.disposition).toBe("held"); // sink re-armed + re-held

// ── wake-less park: a next() with no possible resume source is prod's
// immediate defined 500 naming the mistake (never a silent 25 s 504) — the
// hop's writes roll back with it. ──
const orphans = scenario({
  sources: { "index.mjs": "export default function () { kv.set(\"orphan/wrote\", \"1\"); return next({ n: 1 }); }" },
});
const orphan = orphans.inbound({ path: "/" });
expect(orphan.disposition).toBe("terminal");
expect(orphan.status).toBe(500);
expect(orphan.body).toMatch(/held with no wake source/);
expect(orphan).not.toHaveWritten("orphan/wrote");
expect(orphan.kv("orphan/wrote")).toBe(null);
