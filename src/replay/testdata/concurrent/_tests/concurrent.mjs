// Concurrent-effect interleavings (docs/architecture/replay-and-sim.md). Two
// after.fetches race on one held chain; `whenConcurrent` folds BOTH arrival
// orders, threading each leg's writes into the next resume's overlay, and checks
// the cross-order invariant. Before this combinator, "leg B resolves into an
// activation that observes leg A's write" was inexpressible (each resolve folded
// the parent only).
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });

const req = s.inbound({ method: "GET", path: "/" });
expect(req.disposition).toBe("held");
expect(req).toHaveFetched(/a\.example/);
expect(req).toHaveFetched(/b\.example/);

const inter = req.whenConcurrent([
  { match: /a\.example/, resolve: { status: 200 }, label: "A" },
  { match: /b\.example/, resolve: { status: 200 }, label: "B" },
]);

// Under EVERY arrival order the chain terminates with the same total (each leg
// observed exactly once — read-your-writes across the race).
inter.forEachOrder((terminal, order) => {
  expect(terminal.disposition).toBe("terminal");
  expect(terminal.body).toEqual({ total: 30 });
  // the running total was folded across the two resumes (leg 2 saw leg 1's write)
  expect(terminal.kv("total")).toBe("30");
});

// The invariant helper: one streamed pass iff all orders agree on the projection.
inter.invariant((terminal) => terminal.body.total, "final total");

// Explicit-order form (the escape hatch for large factorials): drive B-then-A.
const [ba] = inter.orders([["B", "A"]]);
expect(ba.body).toEqual({ total: 30 });
