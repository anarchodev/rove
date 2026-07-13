// on_result handler for the cbfire/webhook.send (JS-shim) pipeline.
// The result arrives on the unified flattened surface (handler-shape
// §7): the response on `request.body`/`.status` (2xx = delivered;
// `status === 0` = never reached; no `request.ok`, issue #7), the
// customer's opaque `context` IS `request.ctx`, and the delivery
// metadata ({id, attempts, error, headers}) is on `request.activation.*`
// (Endpoint A).
export default function () {
    const a = request.activation || {};
    const record = {
        ok: request.status >= 200 && request.status < 300,
        status: request.status,
        body: request.text,
        context: request.ctx ?? null,
        error: a.error || null,
    };
    kv.set("cb/result/" + a.id, JSON.stringify(record));
}
