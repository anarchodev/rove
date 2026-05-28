// Bound-fetch smoke handler — `docs/handler-shape.md` §5.5 +
// `docs/streaming-model.md` §7 item 1.
//
//   GET /boundproxy?url=<upstream>
//
// Issues an http.fetch with `bind: true` so upstream chunks resume
// THIS chain (instead of firing a separate `fetch-<id>` chain) via
// the module's `onFetchChunk` named export. The default returns
// `__rove_next("boundproxy")` to park the held client; the first
// upstream chunk fires `onFetchChunk` on the same entity, and the
// resume builds a JSON response from the chunk and terminates the
// chain.
//
// V1 scope: returns Response on the first chunk (terminates).
// Multi-chunk stream({write}) per upstream chunk needs the stream-
// chain wake-on-fetch path (a follow-up).
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
    http.fetch({
        url: url,
        method: "GET",
        bind: true,
        // For the smoke we want a single chunk delivery: stream=false
        // collapses the upstream body to one fetch_chunk event with
        // final=true.
        stream: false,
        // on_chunk is still required by the binding even when
        // bind=true (the field is the module-path resolver; for
        // bound fetches the resume engine ignores it and dispatches
        // the held chain's onFetchChunk instead).
        on_chunk: "boundproxy",
        ctx: { tag: "boundsmoke" },
    });
    return __rove_next("boundproxy/index", { ctx: { tag: "boundsmoke" } });
}

// Per upstream chunk on a bound fetch. V1 always responds (terminal)
// with the chunk wrapped in JSON — the smoke gates on receiving this.
export function onFetchChunk() {
    const body = new TextDecoder().decode(request.body);
    response.status = 200;
    response.headers["content-type"] = "application/json";
    return JSON.stringify({
        fetchId: request.fetchId,
        chunkSeq: request.chunkSeq,
        done: request.done,
        body: body,
    });
}
