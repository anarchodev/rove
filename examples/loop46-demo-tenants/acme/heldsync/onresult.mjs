// §6.4 held-synchronous third-party call — resume hop.
//
// Invoked by the resume engine when the bound http.send completes (or
// the §6.4 deadline fires), RPC-style: `onResult(ctx, outcome)`.
// `ctx` is what the open hop passed to __rove_next; `outcome` is the
// call event: {id, ok, status, body, error, context} on completion,
// or {ok:false, reason:"deadline"} when the mandatory timeout fired.
//
// Returning a value is TERMINAL — flushed to the still-open client
// socket, completing the one synchronous request. Returning another
// __rove_next RE-PARKS (recipe-1: customer-composed retry, exercised
// via `ctx.retry_to`).
export function onResult(ctx, outcome) {
    if (!outcome.ok) {
        // Recipe-1: compose a retry yourself. One re-issue to a
        // known-good target, then re-park (allow_repark=true).
        if (ctx.retry_to && ctx.tries < 1) {
            http.send({
                url: ctx.retry_to,
                method: "POST",
                body: JSON.stringify({ from: "heldsync-retry", tag: ctx.tag }),
                headers: { "content-type": "application/json" },
            });
            return __rove_next("heldsync/onresult", {
                fn: "onResult",
                ctx: { tag: ctx.tag, tries: ctx.tries + 1, retry_to: null },
            });
        }
        response.status = 502;
        return "heldsync upstream failed: " + (outcome.error || outcome.reason || outcome.status);
    }
    return "heldsync:" + ctx.tag + ":" + outcome.body;
}
