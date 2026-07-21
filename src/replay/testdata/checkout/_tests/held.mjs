// The held-connection resume family (after.ms / after.kv / disconnect) + a
// detached delivery callback (sendCallback). Each held resume threads the held
// continuation's next({ctx}) forward; the detached one is authored standalone.
import { scenario, expect } from "rewind:test";

const s = scenario({ entry: "stream.mjs", now: "2026-07-01T00:00:00Z" });

const held = s.inbound({ method: "POST", path: "/room", body: { room: "r1" } });
expect(held.disposition).toBe("held");
expect(held.ctx).toEqual({ room: "r1", seen: 0 });

// after.ms timer wake → onTimeout, resumed with the held ctx.
const timedOut = held.clock.advance("30s").fire();
expect(timedOut).toHaveWritten("room/r1/closed", "timeout");

// after.kv wake → onMsg; the FIRED PREFIX shows on request.activation.wakes
// (never the matched key); re-holds.
const woke = held.wakeKv({ "msg/r1/1": { text: "hi" } });
expect(woke.disposition).toBe("held");
expect(woke).toHaveWritten("room/r1/lastwake", { count: 1, prefix: "msg/r1/" });
expect(woke.ctx).toEqual({ room: "r1", seen: 1 });

// client disconnect → onDisconnect, held ctx threaded.
const gone = held.disconnect();
expect(gone).toHaveWritten("room/r1/closed", "disconnect");

// A resume fold on a NON-held node must throw (after.* is inert without a hold).
let threw = false;
try { timedOut.wakeKv({ x: 1 }); } catch (_) { threw = true; }
expect(threw).toBe(true);

// Detached delivery callback — authored standalone, not folded from webhook.send.
const delivered = s.sendCallback({
  on: "hooks/onDelivered.mjs",
  result: { status: 200, attempts: 2 },
  ctx: { order: "o9" },
});
expect(delivered).toHaveWritten("delivery/o9", { ok: true, status: 200, attempts: 2 });
