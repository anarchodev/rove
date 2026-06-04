// Upstream for the Gap 2.3 streaming-transport smoke (handler-surface
// Phase 2 `stream.*` surface). An infinite SSE-style drip: emits one
// short frame every ~120 ms, forever, until the client (the fetching
// node's libcurl) disconnects.
//
// A buffered transport fetching this would see NOTHING until the
// connection closed — so it proves the FetchPool's libcurl path is
// genuinely streaming (CURLOPT_WRITEFUNCTION): chunks must arrive
// incrementally, well before the fetch's timeout fires.
export default function () {
    if (request.activation.kind === "inbound") {
        response.status = 200;
        response.headers = { "Content-Type": "text/plain" };
        stream.start();
        stream.write("drip\n");
        on.timer(120);
        return __rove_next("drip/index", {});
    }
    // disconnect (client gone): close.
    return "";
}

// One frame per timer tick — never returns terminal, so the stream
// runs until the fetch times out + libcurl FINs.
export function onWake() {
    stream.start();
    stream.write("drip\n");
    on.timer(120);
    return __rove_next("drip/index", {});
}
