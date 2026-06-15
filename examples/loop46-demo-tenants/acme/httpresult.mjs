// on_result handler for the webhook.send (JS-shim) fast-path smoke.
// Captures the event into kv keyed by the schedule id so the smoke
// script can assert end-to-end shape via the admin API. The result
// arrives on the unified flattened surface (handler-shape §7): the
// response on `request.body`/`.status`/`.ok`, the delivery metadata
// ({id, attempts, error}) + customer `context` on `request.ctx`.
export default function () {
    const ctx = request.ctx || {};
    const record = {
        id: ctx.id,
        ok: request.ok,
        status: request.status,
        version: ctx.attempts, // attempts ~ legacy `version`
        context: ctx.context || null,
        body: request.body,
        error: ctx.error || null,
    };
    kv.set("http/result/" + ctx.id, JSON.stringify(record));
}
