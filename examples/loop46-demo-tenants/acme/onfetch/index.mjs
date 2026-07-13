// on.fetch exerciser (handler-surface Phase 3 slice 3a). The
// connection-scoped outbound surface: `after.fetch(url, { …, on })` binds
// the fetch to the held chain — each upstream chunk wakes the `{on}`
// export ("onUpstream" here) while the chain holds the socket. Proves
// the bind + the `{on}` export override + chunk resume end to end,
// WITHOUT stream.* output (the bound-fetch stream.* path is slice 3d):
// each chunk appends to kv, and the terminal chunk returns the
// reconstructed body to the held client.
//
//   GET /onfetch?url=<upstream>
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
    kv.set("onfetch/acc", ""); // fresh accumulator per run
    // Connection-scoped: binds to THIS held chain; chunks wake onUpstream.
    after.fetch(url, { stream: true, maxChunkBytes: 64, on: "onUpstream" });
    return next();
}

// Per upstream chunk (bound via after.fetch's {on}). Accumulate in kv; on
// the terminal chunk, return the reconstructed body to the held client.
export function onUpstream() {
    if (request.done) {
        response.status = 200;
        return kv.get("onfetch/acc") || "";
    }
    const text = request.text;
    kv.set("onfetch/acc", (kv.get("onfetch/acc") || "") + text);
    return next();
}
