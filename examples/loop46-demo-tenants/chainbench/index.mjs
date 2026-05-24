// Continuation-chain workload for scripts/chain_fusion_bench.py.
//
// Each chain link is a *pure same-tenant immediate self-schedule*:
// one kv.set (progress) + exactly one webhook.send back to this tenant's
// own URL with depth-1, NO on_result, NO fire_at_ns, NO entropy
// (no Date.now / Math.random / crypto) — the shape the internal-
// schedule fast path (and the fusion predicate) consume.
//
// Instrument discipline (why `start` + a single counter): the bench
// must NOT poll per-chain status on this tenant — that floods the
// hot path with H2 GETs and contends on chainbench's per-tenant
// txn lock against the internal-schedule writer, swamping the
// measurement. Instead: ONE `start` call kicks every chain; each
// terminal link bumps ONE shared counter; the bench reads that
// counter once per slow poll. ~1 GET/s instead of ~N GETs/50ms.

// GET `/?fn=start&args=[count,depth,url]`: kick `count` chains of
// `depth` from a single client request (one writeset / one propose).
export function start(count, depth, url) {
    const n = count | 0;
    for (let i = 0; i < n; i++) {
        const cid = "c" + i;
        kv.set("chain/progress/" + cid, String(depth | 0));
        webhook.send({
            url: url,
            method: "POST",
            body: JSON.stringify({ id: cid, depth: depth | 0, url: url }),
            headers: { "content-type": "application/json" },
        });
    }
    return JSON.stringify({ started: n });
}

// POST `/` body {id, depth, url}: one chain link.
export default function () {
    const step = JSON.parse(request.body);
    const id = step.id;
    const depth = step.depth | 0;

    kv.set("chain/progress/" + id, String(depth));

    if (depth > 0) {
        webhook.send({
            url: step.url,
            method: "POST",
            body: JSON.stringify({ id: id, depth: depth - 1, url: step.url }),
            headers: { "content-type": "application/json" },
        });
        return JSON.stringify({ id: id, depth: depth, more: true });
    }

    // Terminal link. Bump the single shared completion counter (the
    // read+write is correct under the per-tenant batch txn: runOne
    // is sequential within the txn, so each terminal link sees the
    // prior link's increment).
    const c = (kv.get("chain/donecount") | 0);
    kv.set("chain/donecount", String(c + 1));
    kv.set("chain/done/" + id, "1");
    return JSON.stringify({ id: id, depth: 0, more: false });
}

// GET `/?fn=status`: ONE aggregate read — the only thing the bench
// polls during the measured window. No entropy, no webhook.send.
export function status() {
    return JSON.stringify({ count: (kv.get("chain/donecount") | 0) });
}
