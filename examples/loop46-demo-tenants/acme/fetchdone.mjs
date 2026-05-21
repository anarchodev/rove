// on_done handler for the Gap 2.3 http.fetch (Pattern A) smoke.
//
// Fires exactly once, after the last `fetch_chunk`, when the
// upstream response completes. Records the terminal `ok` +
// `status` so the smoke can assert the fetch chain closed
// cleanly with the upstream's real status code.
export default function () {
    const a = request.activation;
    if (a.kind !== "fetch_done") {
        return { status: 500, body: "unexpected activation " + a.kind };
    }
    kv.set("fetch/done", JSON.stringify({
        fetch_id: a.fetch_id,
        ok: a.ok,
        status: a.status,
    }));
    return { status: 200 };
}
