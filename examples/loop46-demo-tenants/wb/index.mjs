// Target tenant for the http.send fast-path smoke. Receives the call
// from acme via in-process dispatch (or libcurl fallback if the worker
// phase declines), records the request body in its own kv to prove
// writes round-trip atomically with the schedule_complete envelope,
// and returns a string body the caller's on_result can assert on.
export default function () {
    let payload = null;
    try { payload = JSON.parse(request.body); } catch (_) {}
    const tag = (payload && payload.tag) || "<no-tag>";
    kv.set("wb/last_tag", tag);
    response.status = 200;
    return "echoed:" + tag;
}
