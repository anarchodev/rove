// Entry handler for the Gap 2.3 / Phase 5 PR-1 http.fetch smokes.
//
//   GET /fetchchunks?url=<upstream>[&timeout_ms=<n>]
//
// Issues an http.fetch with stream:true so the response splits
// into several `fetch_chunk` activations (all routed to the same
// `fetchchunk.mjs` module — Phase 5 PR-1 collapsed the prior
// `on_done` separate-terminal hook into a `final: true` flag on
// the last `on_chunk` activation). A small `max_response_chunk_bytes`
// forces the upstream body into several chunks; `ctx` is threaded
// forward so the chunk handler can prove ctx round-trip.
// `timeout_ms` is optional — the streaming smoke sets it short so
// an infinite-drip upstream times out promptly. Returns the fetch
// id as the response body.
export default function () {
    const q = request.query || "";
    let url = null;
    let timeout_ms = null;
    for (const pair of q.split("&")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        const k = decodeURIComponent(pair.slice(0, eq));
        const v = decodeURIComponent(pair.slice(eq + 1));
        if (k === "url") url = v;
        else if (k === "timeout_ms") timeout_ms = parseInt(v, 10);
    }
    if (!url) {
        response.status = 400;
        return "missing ?url=";
    }
    const opts = {
        url: url,
        method: "GET",
        on_chunk: "fetchchunk",
        stream: true,
        max_response_chunk_bytes: 64,
        ctx: { tag: "fetchsmoke" },
    };
    if (timeout_ms != null && !isNaN(timeout_ms)) opts.timeout_ms = timeout_ms;
    const id = http.fetch(opts);
    response.status = 200;
    return id;
}
