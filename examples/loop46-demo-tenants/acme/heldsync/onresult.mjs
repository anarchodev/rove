// §6.4 held-synchronous third-party call — resume hop.
//
// Invoked by the resume engine when the bound webhook.send completes
// (or the §6.4 deadline fires), on the Endpoint-A flattened surface
// (handler-shape §7): the threaded ctx on `request.ctx`, the outcome
// on `request.ok`/`.status`/`.text` (+ `request.activation.error` —
// ONE failure-cause field: the webhook classifier's
// transport_failed/upstream_5xx, or the platform's "deadline").
//
// Returning a value is TERMINAL — flushed to the still-open client
// socket, completing the one synchronous request. Returning another
// __rove_next RE-PARKS (recipe-1: customer-composed retry, exercised
// via `ctx.retry_to`).
export function onResult() {
    const ctx = request.ctx || {};
    if (!request.ok) {
        // Recipe-1: compose a retry yourself. One re-issue to a
        // known-good target, then re-park (allow_repark=true).
        if (ctx.retry_to && ctx.tries < 1) {
            webhook.send(ctx.retry_to, {
                method: "POST",
                body: JSON.stringify({ from: "heldsync-retry", tag: ctx.tag }),
                headers: { "content-type": "application/json" },
                max_attempts: 1,
            });
            return __rove_next("heldsync/onresult", {
                fn: "onResult",
                ctx: { tag: ctx.tag, tries: ctx.tries + 1, retry_to: null },
            });
        }
        response.status = 502;
        return "heldsync upstream failed: " + request.activation.error;
    }
    return "heldsync:" + ctx.tag + ":" + request.text;
}
