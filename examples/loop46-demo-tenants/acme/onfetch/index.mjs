// on.fetch exerciser (handler-surface Phase 3 slice 3a). The NEW
// connection-scoped outbound surface: `on.fetch(url, opts, {to})` binds
// the fetch to the held chain — each upstream chunk wakes the `{to}`
// export ("onUpstream" here) while the chain holds the socket. Proves
// the bind + the `{to}` export override + chunk resume end to end,
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
    on.fetch(url, { stream: true, max_response_chunk_bytes: 64 }, { to: "onUpstream" });
    return __rove_next("onfetch/index", {});
}

// Per upstream chunk (bound via on.fetch's {to}). Accumulate in kv; on
// the terminal chunk, return the reconstructed body to the held client.
export function onUpstream() {
    if (request.done) {
        response.status = 200;
        return kv.get("onfetch/acc") || "";
    }
    const text = new TextDecoder().decode(request.body);
    kv.set("onfetch/acc", (kv.get("onfetch/acc") || "") + text);
    return __rove_next("onfetch/index", {});
}
