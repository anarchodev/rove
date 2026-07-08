// Offline cross-check of on_timer_smoke_v2.py: the same acme ontimer handler,
// the same held POST resumed by the timer wake, the same "woke:<tag>" result.
// Agreement with the smoke proves the after.ms held resume faithful.
import { scenario, expect } from "rewind:test";

const s = scenario({ entry: "ontimer/index.mjs" });

// The held inbound arms after.ms(ms) and holds via next({tag}).
const held = s.inbound({ method: "POST", path: "/ontimer", body: { ms: 150, tag: "x" } });
expect(held.disposition).toBe("held");
expect(held.ctx).toEqual({ tag: "x" });
expect(held).toHaveScheduled(); // armed the after.ms timer

// Advancing past the timer fires onWake, which returns "woke:<tag>" from the
// held next({tag}) ctx.
const woke = held.clock.advance("150ms").fire();
expect(woke.status).toBe(200);
expect(woke.body).toBe("woke:x"); // the smoke's core assertion, offline

// The smoke's second request uses tag "y" — same shape, distinct ctx.
const woke2 = s.inbound({ method: "POST", path: "/ontimer", body: { ms: 150, tag: "y" } })
  .clock.advance("150ms").fire();
expect(woke2.body).toBe("woke:y");
