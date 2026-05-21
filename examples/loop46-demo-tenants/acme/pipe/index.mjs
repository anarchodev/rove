// Entry handler for the Gap 2.3 Phase E http.fetch (Pattern B,
// `pipe_to`) smoke — transparent upstream→client proxy.
//
//   GET /pipe?url=<upstream>
//
// On the inbound hop: issue an http.fetch with `pipe_to:
// "held_response"` and return `__rove_stream` with a
// `fetch_pipe_done` waitFor. The upstream bytes are piped
// straight into this held response — they never re-enter this
// handler, so nothing about them is taped.
//
// The handler is re-entered exactly once, for `fetch_pipe_done`,
// when the upstream connection closes. It records the terminal
// accounting to kv (so the smoke can assert it) and returns a
// terminal Cmd, closing the stream.
export default function () {
    const a = request.activation;

    if (a.kind === "fetch_pipe_done") {
        kv.set("pipe/done", JSON.stringify({
            ok: a.ok,
            status: a.status,
            bytes_piped: a.bytes_piped,
            dropped_chunks: a.dropped_chunks,
        }));
        // Terminal: close the stream with no trailing body. The
        // response status line went out with the __rove_stream
        // first hop — a terminal return value here is shipped as a
        // final DATA chunk, so it must be empty.
        return "";
    }

    // inbound hop
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

    http.fetch({
        url: url,
        method: "GET",
        pipe_to: "held_response",
    });

    return __rove_stream({
        status: 200,
        headers: { "Content-Type": "text/plain" },
        waitFor: { fetch_pipe_done: "auto" },
    });
}
