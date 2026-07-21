// http.subscribe recorder fidelity + the detached onSubscription activation (#36).
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });

// ── the subscribe recorder carries the full option bag ──
const r = s.inbound({ method: "GET", path: "/subscribe" });
expect(r.disposition).toBe("terminal"); // subscribe is fire-and-forget on the connection
expect(r).toHaveSent("subscribe", {
  url: "https://feed.example.com/stream",
  method: "GET",
  maxChunkBytes: 8192,
  headers: { authorization: "Bearer tok" },
});
// A cap the subscribe did NOT set must not spuriously match.
expect(r).not.toHaveSent("subscribe", { maxChunkBytes: 1 });

// ── the detached kv-react onSubscription is testable in isolation ──
const f = s.subscriptionFire({ on: "index.mjs", name: "orders/watch" });
expect(f.disposition).toBe("terminal");
expect(f.body).toEqual({ fired: "orders/watch", kind: "subscription_fire" });
expect(f.kv("subs/orders/watch")).toBe("fired");
