// A consumer of @rewind/retry (P-Lift, rove#123). retry.send wraps the ambient
// webhook.send durable-send primitive: it pins webhook's built-in retry to 1
// (the customer drives the chain via retry.again) and carries the retry chain
// state under the reserved `ctx._retry`. Also exercises shouldRetry/ctx — the
// result-side helpers that read `request.status` + `request.ctx._retry`.
// (Replaces the two ambient-retry dispatcher_test cases now that retry is a
// package, not a global.)
import retry from "@rewind/retry";

export default function () {
  if (request.path === "/send") {
    return { id: retry.send({
      url: "https://api.stripe.com/v1/charges",
      body: "x",
      on: "stripe_done",
      maxAttempts: 3,
      ctx: { charge_id: 42 },
    }) };
  }
  // Result-side logic: mirror the dispatcher case (set status + _retry meta
  // in-handler, then read them back through the helpers).
  const mk = (okv, r) => { request.status = okv ? 200 : 500; request.ctx = { _retry: r }; return retry.shouldRetry(); };
  const ok = mk(true, { attempt: 1, max_attempts: 3 });
  const failed_with_attempts = mk(false, { attempt: 1, max_attempts: 3 });
  const failed_exhausted = mk(false, { attempt: 3, max_attempts: 3 });
  request.status = 500; request.ctx = { charge_id: 42 };
  const no_retry_meta = retry.shouldRetry();
  request.ctx = { charge_id: 42, _retry: { attempt: 2 } };
  const stripped = retry.ctx();
  return { verdicts: [ok, failed_with_attempts, failed_exhausted, no_retry_meta], stripped };
}
