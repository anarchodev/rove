// Entry handler for the curl-multi-plan Phase 3 (gap 2.5)
// subscription smoke. Opens a held outbound subscription against
// the URL passed in `?url=...`, returns the subscription id, and
// the per-chunk handler (`subscribe_oc.mjs`) records each chunk
// under `sub/chunk/<id>/<seq>`.
//
//   GET /subscribe?url=<upstream>
//
// The smoke later issues `POST /cancel_subscribe?id=<id>` to stop
// the subscription cleanly.
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
    const id = http.subscribe({
        url: url,
        on_chunk: "subscribe_oc",
        max_response_chunk_bytes: 256,
        ctx: { tag: "subscribesmoke" },
    });
    response.status = 200;
    return id;
}
