// on_result handler for the webhook.send (JS-shim) fast-path smoke.
// Captures the event into kv keyed by the schedule id so the smoke
// script can assert end-to-end shape via the admin API. The result
// arrives on the unified flattened surface (handler-shape §7): the
// response on `request.body`/`.status` (2xx = delivered; `status === 0`
// = never reached; no `request.ok`, issue #7), the echoed customer
// `context` IS `request.ctx`, and the delivery metadata ({id, attempts,
// error}) is on `request.activation.*` (Endpoint A).
export default function () {
    const a = request.activation || {};
    const record = {
        id: a.id,
        ok: request.status >= 200 && request.status < 300,
        status: request.status,
        version: a.attempts, // attempts ~ legacy `version`
        context: request.ctx ?? null,
        body: request.text,
        error: a.error || null,
    };
    kv.set("http/result/" + a.id, JSON.stringify(record));
}
