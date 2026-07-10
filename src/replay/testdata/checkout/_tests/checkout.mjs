// The saga test surface (docs/architecture/replay-and-sim.md). Eager by default —
// `expect` forces its node and fails locally; the tree combinators (fetch
// resolve / branch / cases) are opt-in. Run by `rewind test` on a harness
// reactor; each `simulate` runs on a separate sim reactor.
import { scenario, expect } from "rewind:test";

const s = scenario({
  kv: { "cart/jess": JSON.stringify({ item: "book", price: 1200 }) },
  now: "2026-07-01T00:00:00Z",
  seed: 42,
});

// The inbound activation runs once (memoized) and is asserted on directly.
const req = s.inbound({ method: "POST", path: "/checkout", body: { user: "jess" } });
expect(req.status).toBe(202);
expect(req.disposition).toBe("held");
expect(req).toHaveWritten("order/jess", { status: "pending" });
expect(req).toHaveFetched(/stripe/);

// Resolve the emitted fetch → the dependent charge-callback activation, with
// the parent's writes/ctx/clock folded forward.
const charged = req.fetch(/stripe/).resolve({ status: 200, body: { id: "ch_1" } });
expect(charged).toHaveWritten("order/jess", { status: "paid" });
expect(charged).toHaveSent("email", { to: ["jess@example.com"], subject: "Your order is paid" });
expect(charged.kv("order/jess")).toEqual({ status: "paid" });

// Fork the shared prefix over two upstream outcomes.
const [paid, declined] = req.fetch(/stripe/).branch([
  { status: 200, body: { id: "ch_1" } },
  { status: 402 },
]);
expect(paid).toHaveWritten("order/jess", { status: "paid" });
expect(declined).toHaveWritten("order/jess", { status: "failed" });

// An invariant that must hold across every future, without naming them.
req.fetch(/stripe/).cases([{ status: 200 }, { status: 402 }, { status: 500 }]).forEachPath((node) =>
  expect(node.kv("order/jess").status).toMatch(/paid|failed/)
);
