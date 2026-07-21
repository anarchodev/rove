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

// ── a write under a watched prefix injects the _sub/dirty marker (produce side) ──
const w = scenario({ now: "2026-07-01T00:00:00Z", subscriptions: [{ name: "orders/watch", prefix: "orders/" }] })
  .inbound({ method: "POST", path: "/order", body: { id: "123" } });
expect(w.body).toEqual({ placed: true });
expect(w).toHaveWritten("orders/123", "placed");
expect(w).toHaveWritten("_sub/dirty/orders/watch", "orders/"); // the marker that feeds onSubscription
// Coalesced: two watched writes leave exactly ONE marker (deduped per activation).
expect(w.effects.filter((e) => e.kind === "write" && e.key === "_sub/dirty/orders/watch").length).toBe(1);
// No subscriptions registered ⇒ no marker.
const w0 = scenario({ now: "2026-07-01T00:00:00Z" }).inbound({ method: "POST", path: "/order", body: { id: "9" } });
expect(w0.effects.some((e) => e.kind === "write" && e.key.startsWith("_sub/dirty/"))).toBe(false);

// ── the detached kv-react onSubscription is testable in isolation (consume side) ──
const f = s.subscriptionFire({ on: "index.mjs", name: "orders/watch" });
expect(f.disposition).toBe("terminal");
expect(f.body).toEqual({ fired: "orders/watch", kind: "subscription_fire" });
expect(f.kv("subs/orders/watch")).toBe("fired");
