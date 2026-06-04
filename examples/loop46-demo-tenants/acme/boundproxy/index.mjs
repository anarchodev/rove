// Bound-fetch smoke handler — `docs/handler-shape.md` §5.5 +
// `docs/streaming-model.md` §7 item 1.
//
//   GET /boundproxy?url=<upstream>
//
// Issues an http.fetch from a handler that returns next()/stream(), so
// the fetch AUTO-BINDS (docs/auto-bind-plan.md) — upstream chunks
// resume THIS chain via the module's `onFetchChunk` export instead of
// firing a separate `fetch-<id>` chain. No `bind` keyword needed. The
// default returns `next()` to park the held
// client; each upstream chunk fires `onFetchChunk`, which streams a
// transformed "chunk:<text>" frame back to the held socket via
// __rove_stream. On the terminal chunk (done=true) it returns "".
//
// Tests the full auto-bind + Gap #1 path: first chunk arrives with
// the entity in parked_continuations (cont→stream transition fires);
// subsequent chunks arrive with the entity in stream_data_out
// (stream wake via resumeBoundFetchStream).
export default function () {
    const q = request.query || "";
    let url = null;
    for (const pair of q.split("&")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        const k = decodeURIComponent(pair.slice(0, eq));
        const v = decodeURIComponent(pair.slice(eq + 1));
        if (k === "url") url = v;
    }
    if (!url) {
        response.status = 400;
        return "missing ?url=";
    }
    // on.fetch is connection-scoped: this held handler returns next(),
    // so the fetch binds and chunks resume onFetchChunk. stream:true
    // splits the upstream body into multiple fetch_chunk events at
    // max_response_chunk_bytes granularity — the multi-chunk Gap #1 path.
    on.fetch(url, { stream: true, max_response_chunk_bytes: 64 });
    return next({ tag: "boundsmoke" });
}

// Per upstream chunk on a bound fetch. Streams "chunk:<text>" back to
// the held client via stream.write; closes on the terminal (done=true)
// chunk.
export function onFetchChunk() {
    if (request.done) {
        // Terminal chunk — close the stream.
        return "";
    }
    const text = new TextDecoder().decode(request.body);
    // Headers ride only on the first activation (ignored once the head
    // is committed).
    response.headers = { "content-type": "text/plain" };
    stream.start();
    stream.write("chunk:" + text);
    return next({ tag: "boundsmoke" });
}
