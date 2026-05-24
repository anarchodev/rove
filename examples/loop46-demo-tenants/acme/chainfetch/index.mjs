// Phase 5 PR-2a regression gate — proves `__rove_next` returned
// from a fetch `on_chunk` handler actually dispatches the next
// module (instead of warn-and-drop, the pre-PR-2 behavior).
//
//   GET /chainfetch?url=<upstream>
//
// Issues http.fetch with on_chunk=chainfetchstep1; that handler,
// on the final event, returns __rove_next("chainresult", {ctx}).
// The chained handler writes a kv marker the smoke reads back.
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
        on_chunk: "chainfetchstep1",
        max_response_chunk_bytes: 256 * 1024,
        ctx: { tag: "chainfetch" },
    });
    response.status = 200;
    return id;
}
