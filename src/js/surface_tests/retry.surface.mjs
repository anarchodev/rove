// retry — customer-driven retry policy over webhook.send. send() is
// observable via the marker it writes (built-in retry suppressed,
// policy riding ctx._retry); the no-arg helpers read the ambient
// result surface — on a plain inbound they take their documented
// "not a retry result" paths.
export default function () {
  check("retry.send", () => {
    const id = retry.send({
      url: "https://stripe.test/charge",
      on: "charges/handler",
      maxAttempts: 3,
      backoffMs: [1000, 5000, 30000],
      body: "amount=42",
      ctx: { charge_id: 42 },
    });
    ok(typeof id === "string" && id.length > 0, "id: " + id);
    const marker = JSON.parse(kv.get("_send/owed/" + id));
    eq(marker.max_attempts, 1);            // built-in retry suppressed
    eq(marker.on_result, "charges/handler");
    eq(marker.context.charge_id, 42);      // user ctx preserved…
    const r = marker.context._retry;       // …with the policy alongside
    eq(r.attempt, 1);
    eq(r.max_attempts, 3);
    eq(r.backoff_ms, [1000, 5000, 30000]);
    eq(r.on_result_module, "charges/handler");
    eq(r.original.url, "https://stripe.test/charge");
    eq(r.original.body, "amount=42");

    throws(() => retry.send(), /requires an options object/);
    throws(() => retry.send({ on: "x" }), /`url` must be a string/);
    throws(() => retry.send({ url: "https://x.test", max_attempts: 2 }), /`max_attempts` was renamed/);
    throws(() => retry.send({ url: "https://x.test" }), /`on` must be a non-empty string/);
    throws(() => retry.send({ url: "https://x.test", on: "x", maxAttempts: 0 }), /`maxAttempts` must be a positive integer/);
  });

  // The ambient helpers on a plain inbound (no retry ctx):
  check("retry.shouldRetry", () => eq(retry.shouldRetry(), false));
  check("retry.again", () => eq(retry.again(), null));
  check("retry.attempt", () => eq(retry.attempt(), null));
  check("retry.ctx", () => eq(retry.ctx(), null)); // inbound has no ctx at all

  return done();
}
