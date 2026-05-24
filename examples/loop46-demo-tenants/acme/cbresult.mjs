// on_result handler for the cbfire/webhook.send (JS-shim) pipeline.
// Post-Phase-5-PR-3 the event arrives wrapped in the chained
// `__rove_next` envelope the baked `__system/webhook_onresult`
// module emits: `request.body.ctx.result` is the result event
// ({id, ok, status, body, headers, attempts, error?}), and
// `request.body.ctx.context` is the customer's opaque context.
export default function () {
    const wrap = JSON.parse(request.body);
    const result = (wrap && wrap.ctx && wrap.ctx.result) || {};
    const context = (wrap && wrap.ctx && wrap.ctx.context) || null;
    const record = {
        ok: result.ok,
        status: result.status,
        body: result.body,
        context: context,
        error: result.error || null,
    };
    kv.set("cb/result/" + result.id, JSON.stringify(record));
}
