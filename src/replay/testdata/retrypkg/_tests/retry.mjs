import { scenario, expect } from "rewind:test";

// retry.send wraps webhook.send: pins maxAttempts to 1, threads the retry
// chain state under ctx._retry, keeps the customer's own ctx keys.
const s = scenario({ now: "2026-07-01T00:00:00Z", seed: 1 })
  .inbound({ method: "POST", path: "/send", host: "r.localhost" });
expect(s.status).toBe(200);
expect(s).toHaveSent("webhook", {
  url: "https://api.stripe.com/v1/charges",
  on: "stripe_done",
  maxAttempts: 1,
});
expect(s).toHaveSent("webhook", {
  context: { charge_id: 42, _retry: { attempt: 1, max_attempts: 3, on_result_module: "stripe_done" } },
});

// shouldRetry: false on success, true on failure with attempts left, false when
// exhausted or with no _retry meta. (ctx() strips _retry — exercised in-handler.)
const l = scenario({ now: "2026-07-01T00:00:00Z", seed: 1 })
  .inbound({ method: "POST", path: "/logic", host: "r.localhost" });
expect(l.status).toBe(200);
expect(l.body.verdicts).toEqual([false, true, false, false]);
