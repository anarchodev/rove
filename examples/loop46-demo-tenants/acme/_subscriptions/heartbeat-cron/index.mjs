// Gap 2.1 Phase F exerciser — a cron subscription that fires
// every 1000ms. The handler increments a counter and stamps the
// last-fired-at timestamp. The smoke
// (scripts/streaming_subscription_cron_smoke.py) waits ~3 seconds
// and verifies the counter incremented at least 2 times.
//
// Cron state is in-memory on NodeState (next_fire_at_ns keyed by
// `<tenant>|<name>`); leader change resets the cron clock, which
// can pause cron for up to one interval. Customer-side
// idempotency / missed-tick tolerance is the documented contract.
export function onCron() {
    const a = request.activation;
    const count_str = kv.get("cron-fire-count") ?? "0";
    const count = parseInt(count_str, 10) + 1;
    kv.set("cron-fire-count", String(count));
    kv.set("cron-last-fired-at-ns", String(a.source.firedAt));
    return { status: 200 };
}
