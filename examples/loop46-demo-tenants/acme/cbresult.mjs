// on_result handler for the cbfire/webhook.send (JS-shim) pipeline.
// The result arrives on the unified flattened surface (handler-shape
// §7): the response on `request.body`/`.status`/`.ok`, and the delivery
// metadata ({id, attempts, error, headers}) + the customer's opaque
// `context` on `request.ctx`.
export default function () {
    const ctx = request.ctx || {};
    const record = {
        ok: request.ok,
        status: request.status,
        body: request.body,
        context: ctx.context || null,
        error: ctx.error || null,
    };
    kv.set("cb/result/" + ctx.id, JSON.stringify(record));
}
