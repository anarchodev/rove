// Streaming-handlers Phase 3 helper — POST a kv write under the
// `watch/` prefix the `/watch` handler subscribes to. Body shape:
//   `{ "id": "<short>", "value": "<text>" }`
// Returns "ok"; the kv write fires the §4.6 kv-wake on every node
// that holds a `/watch` stream for this tenant. (Status set via
// the global `response.status` — the handler's return value
// becomes the response body when it's not a Response object.)
export default function () {
    const body = JSON.parse(request.body || "{}");
    const id = body.id ?? "x";
    const value = body.value ?? "";
    kv.set("watch/" + id, value);
    response.status = 204;
    return "";
}
