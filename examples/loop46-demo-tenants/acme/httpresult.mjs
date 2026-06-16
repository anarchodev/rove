// on_result handler for the webhook.send (JS-shim) fast-path smoke.
// Captures the event into kv keyed by the schedule id so the smoke
// script can assert end-to-end shape via the admin API. The result
// arrives on the unified flattened surface (handler-shape §7): the
// response on `request.body`/`.status`/`.ok`, the echoed customer
// `context` IS `request.ctx`, and the delivery metadata ({id, attempts,
// error}) is on `request.activation.*` (Endpoint A).
export default function () {
    const a = request.activation || {};
    const record = {
        id: a.id,
        ok: request.ok,
        status: request.status,
        version: a.attempts, // attempts ~ legacy `version`
        context: request.ctx ?? null,
        body: request.body,
        error: a.error || null,
    };
    kv.set("http/result/" + a.id, JSON.stringify(record));
}
