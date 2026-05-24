// on_result handler for the webhook.send (JS-shim) fast-path smoke.
// Captures the event into kv keyed by the schedule id so the smoke
// script can assert end-to-end shape via the admin API. Post-PR-3:
// the event arrives wrapped — `request.body.ctx.result` is the
// result event, `request.body.ctx.context` is the customer's
// opaque context.
export default function () {
    const wrap = JSON.parse(request.body);
    const result = (wrap && wrap.ctx && wrap.ctx.result) || {};
    const context = (wrap && wrap.ctx && wrap.ctx.context) || null;
    const record = {
        id: result.id,
        ok: result.ok,
        status: result.status,
        version: result.attempts, // attempts post-PR-3 ~ legacy `version`
        context: context,
        body: result.body,
        error: result.error || null,
    };
    kv.set("http/result/" + result.id, JSON.stringify(record));
}
