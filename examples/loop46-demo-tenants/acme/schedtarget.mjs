// §2.6 durable-wake smoke helper — the durable_wake target. A FLAT
// module (not `schedtarget/index.mjs`): the chain resolver
// (`resolveDeployment`) that dispatches a durable_wake target tries
// `<target>` / `<target>.mjs` / `<target>.js`, not directory-index
// resolution — same as webhook's `cbresult.mjs` on_result target.
//
// Records each fire to kv so the smoke can observe it via /readkey:
//   sched-fire-count            total fires (string int)
//   sched-last-id               id of the most recent fire
//   sched-last-msg              JSON of the most recent activation.msg
//   sched-last-scheduled-at-ns  scheduled_at_ns of the most recent fire
//   sched-fires/{id}            per-id fire count (idempotency observation)
export default function () {
    const a = request.activation;
    // Defensive: only act on durable_wake activations.
    if (a.kind !== "durable_wake") return { status: 200 };

    const n = parseInt(kv.get("sched-fire-count") || "0", 10) + 1;
    kv.set("sched-fire-count", String(n));
    kv.set("sched-last-id", a.id);
    kv.set("sched-last-msg", JSON.stringify(a.msg));
    kv.set("sched-last-scheduled-at-ns", String(a.scheduled_at_ns));

    const perId = "sched-fires/" + a.id;
    const m = parseInt(kv.get(perId) || "0", 10) + 1;
    kv.set(perId, String(m));

    return { status: 200 };
}
