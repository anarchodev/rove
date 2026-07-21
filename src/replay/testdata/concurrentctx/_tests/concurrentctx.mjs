// whenConcurrent threads the EVOLVING next({ctx}) between legs (#35). A no-ctx
// fetch resume reads the current chain ctx, which an earlier leg replaced by
// re-holding — so the second leg to land observes the first leg's next({ctx}).
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });

const req = s.inbound({ method: "GET", path: "/" });
expect(req.disposition).toBe("held");

const inter = req.whenConcurrent([
  { match: /a\.example/, resolve: { status: 200 }, label: "A" },
  { match: /b\.example/, resolve: { status: 200 }, label: "B" },
]);

// Under EVERY arrival order the second leg reads the first leg's next({step:1}),
// so the chain terminates at step 2 with both steps recorded. (Without the
// evolving-ctx thread the second leg re-reads step 0 and the chain stays held.)
inter.forEachOrder((terminal, order) => {
  expect(terminal.disposition).toBe("terminal");
  expect(terminal.body).toEqual({ steps: 2 });
  expect(terminal.kv("step/0")).toBe("1"); // first leg saw step 0
  expect(terminal.kv("step/1")).toBe("1"); // second leg saw step 1 — the bump
});
