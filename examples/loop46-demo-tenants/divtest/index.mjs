// Divergence fault-injection target (scripts/divergence_faultinj_smoke.py,
// docs/unified-effect-gating.md idiom-1 regression gate).
//
//   GET  /?fn=arm&args=[selfUrl, delayMs]  — schedule a delayed
//        internal http.send back to this tenant's default route. The
//        upsert commits while all nodes are alive (quorum).
//   POST /                                  — the delayed dispatch
//        lands here via the internal-schedule fast path
//        (tenant_batch). It `events.emit`s. With the idiom-1 fix the
//        emit is PARKED on worker.pending_units and released only at
//        commit; if the proposing leader dies pre-quorum the emit is
//        discarded (never escapes). Pre-fix it fired at accept.

export function arm(selfUrl, delayMs) {
    // Same fire_at_ns computation as acme/httpfire.fireDelayed; Date
    // is tape-captured (deterministic on replay), allowed in handlers.
    const now_ms = Date.now();
    const fire_at_ns = BigInt(now_ms) * 1_000_000n + BigInt(delayMs | 0) * 1_000_000n;
    const id = http.send({
        url: selfUrl,
        method: "POST",
        body: "{}",
        headers: { "content-type": "application/json" },
        fire_at_ns: fire_at_ns,
    });
    return JSON.stringify({ id: id });
}

export default function () {
    events.emit({ type: "diverge", data: 1 });
    kv.set("diverge/fired", "1");
    return JSON.stringify({ emitted: true });
}
