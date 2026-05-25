// Entry handler for the curl-multi-plan Phase 0 fetch-concurrency
// baseline bench. Same shape as fetchchunks/index.mjs but routes
// `on_chunk` to a sibling that writes a per-fetch-id done marker
// (the bench needs to distinguish N concurrent fetches; the original
// fetchchunk.mjs overwrites a single `fetch/done` key, fine for the
// smoke that fires one fetch but useless for a concurrency bench).
//
//   GET /benchfetch?url=<upstream>
//
// Streams chunks at max_response_chunk_bytes=4096 (bigger than the
// smoke's 64 so a small upstream body collapses to one chunk +
// terminal — keeps the per-fetch event count low for the bench).
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
    const id = http.fetch({
        url: url,
        method: "GET",
        on_chunk: "benchfetch_oc",
        stream: true,
        max_response_chunk_bytes: 4096,
        ctx: { tag: "benchfetch" },
    });
    response.status = 200;
    return id;
}
