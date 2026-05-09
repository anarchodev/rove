// on_result handler for the cbfire/webhook.send → polyfill →
// http.send → schedule_complete pipeline. The receipt event shape
// is the http-send schedule shape (id/ok/status/version/body/...);
// the legacy webhook event shape (outcome/attempts/response/...)
// went away with the C webhook.send binding.
export default function (event) {
    const record = {
        ok: event.ok,
        status: event.status,
        body: event.body,
        context: event.context,
        error: event.error || null,
    };
    kv.set("cb/result/" + event.id, JSON.stringify(record));
}
