// Generic kv writer. POST `{ "key": "<full path>", "value": "<text>" }`
// → kv.set(key, value); 204. Used by smokes that need to write
// arbitrary keys (the `/writekey` helper hardcodes the `watch/`
// prefix for the kv-wake smoke and can't be repurposed without
// breaking that smoke).
export default function () {
    const body = JSON.parse(request.body || "{}");
    if (!body.key || typeof body.key !== "string") {
        response.status = 400;
        return "missing key";
    }
    kv.set(body.key, body.value ?? "");
    response.status = 204;
    return "";
}
