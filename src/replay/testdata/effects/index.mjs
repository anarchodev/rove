// Effect-global unification prototype fixture. Exercises the two durable verbs
// the unification converts — `webhook.send` and `schedule` — DIRECTLY, so the
// `_tests/effects.mjs` test sees them decompose
// into primitives (`_send/owed/*` + `_sched/*` kv writes + an `http.fetch`)
// instead of one high-level `{kind:"webhook"|"schedule"}` effect each.
export default function () {
  const user = request.json.user;

  // Durable outbound HTTP. Real shim: writes the _send/owed/{id} marker, arms a
  // crash-recovery watchdog schedule (__system/webhook_fire), and fires the
  // fetch. `key` makes the id deterministic (base64url(sha256(key))).
  webhook.send("https://hooks.example.com/notify", {
    body: JSON.stringify({ event: "signup", user }),
    key: "notify/" + user,
    on: "hooks/onNotified",
    ctx: { user },
  });

  // Durable one-shot timer. Real shim: writes _sched/by_id/{id} + the
  // _sched/by_time/{when} index row (two more kv writes).
  schedule({ in: "1h" }, "jobs/followup", { user }, { key: "followup/" + user });

  kv.set("signup/" + user, "1");
  return { ok: true };
}
