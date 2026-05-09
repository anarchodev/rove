// on_result handler for the cbfire/webhook.send → polyfill →
// http.send → schedule_complete pipeline. Same shape as a regular
// HTTP request handler — no args, event JSON arrives in
// `request.body`. The schedule envelope-9 event shape is
// {id, ok, status, body, context, error}.
export default function () {
    const event = JSON.parse(request.body);
    const record = {
        ok: event.ok,
        status: event.status,
        body: event.body,
        context: event.context,
        error: event.error || null,
    };
    kv.set("cb/result/" + event.id, JSON.stringify(record));
}
