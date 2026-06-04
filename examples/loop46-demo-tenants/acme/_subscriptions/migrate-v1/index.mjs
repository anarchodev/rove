// Gap 2.1 Phase D exerciser — a boot subscription that fires once
// per deployment activation. The handler reads
// `request.activation.source.deployment_id`, increments a
// "boot-fire-count" counter and writes a "boot-fired-marker"
// confirming the activation. The smoke
// (scripts/streaming_subscription_boot_smoke.py) reads the marker
// to verify the chain origin fired without an inbound HTTP request.
//
// Idempotency: the runtime writes `_boot_fired/<dep_id>` post-fire
// to gate re-fires, so this handler shouldn't see the same
// deployment_id twice across normal restarts. But the customer
// handler must STILL be idempotent for the rare
// fire-then-crash-before-marker-write window (per the documented
// contract).
export function onBoot() {
    const a = request.activation;
    const dep_id = a.source.deployment_id;
    const count_str = kv.get("boot-fire-count") ?? "0";
    const count = parseInt(count_str, 10) + 1;
    kv.set("boot-fire-count", String(count));
    kv.set("boot-fired-marker", `dep=${dep_id} count=${count}`);
    return { status: 200 };
}
