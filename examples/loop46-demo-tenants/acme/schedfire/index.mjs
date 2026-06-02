// §2.6 durable-wake smoke helper — schedule a durable wake.
//
// Query params (all optional):
//   delay=<ms>   delay from now (default 2000)
//   tag=<str>    payload tag, surfaces as activation.msg.tag (default "smoke")
//   key=<str>    idempotency key (deterministic id; re-arm on repeat)
//   big=<n>      build an n-byte tag — used to trip SCHED_MAX_MSG_BYTES
//                (the throw surfaces as a 500, the fail-loud cap check)
//
// Returns JSON `{ id }`. The wake fires the `schedtarget` handler with
// msg `{ tag }`.
export default function () {
    const q = request.query || "";
    const params = {};
    for (const pair of q.split("&")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        params[decodeURIComponent(pair.slice(0, eq))] = decodeURIComponent(pair.slice(eq + 1));
    }
    const delay = parseInt(params.delay || "2000", 10);
    const big = parseInt(params.big || "0", 10);
    const tag = big > 0 ? "x".repeat(big) : (params.tag || "smoke");
    const opts = params.key ? { key: params.key } : undefined;
    const id = scheduler.after(delay, "schedtarget", { tag }, opts);
    return { id };
}
