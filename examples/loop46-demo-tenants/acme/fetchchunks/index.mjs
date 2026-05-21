// Entry handler for the Gap 2.3 http.fetch (Pattern A) smoke.
//
//   GET /fetchchunks?url=<upstream>
//
// Issues an http.fetch against the upstream with a small
// `max_response_chunk_bytes` so the response splits into several
// `fetch_chunk` activations (routed to `fetchchunk.mjs`); the
// terminal `fetch_done` routes to `fetchdone.mjs`. `ctx` is
// threaded forward so the chunk handler can prove ctx round-trip.
// Returns the fetch id as the response body.
export default function () {
    const q = request.query || "";
    let url = null;
    for (const pair of q.split("&")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        if (decodeURIComponent(pair.slice(0, eq)) === "url") {
            url = decodeURIComponent(pair.slice(eq + 1));
        }
    }
    if (!url) {
        response.status = 400;
        return "missing ?url=";
    }
    const id = http.fetch({
        url: url,
        method: "GET",
        on_chunk: "fetchchunk",
        on_done: "fetchdone",
        max_response_chunk_bytes: 64,
        ctx: { tag: "fetchsmoke" },
    });
    response.status = 200;
    return id;
}
