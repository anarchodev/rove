// on_result handler for the http.send fast-path smoke. Captures the
// event into kv keyed by the schedule id so the smoke script can
// assert end-to-end shape via the admin API.
export default function (event) {
    const record = {
        id: event.id,
        ok: event.ok,
        status: event.status,
        version: event.version,
        context: event.context,
        body: event.body,
        error: event.error || null,
    };
    kv.set("http/result/" + event.id, JSON.stringify(record));
}
