// Upstream for the Gap 2.3 streaming-transport smoke. An infinite
// SSE-style drip: emits one short frame every ~120 ms, forever,
// until the client (the fetching node's libcurl) disconnects.
//
// A buffered transport fetching this would see NOTHING until the
// connection closed — so it proves the FetchPool's libcurl path
// is genuinely streaming (CURLOPT_WRITEFUNCTION): chunks must
// arrive incrementally, well before the fetch's timeout fires.
export default function () {
    const a = request.activation;
    if (a.kind === "inbound") {
        return __rove_stream({
            status: 200,
            headers: { "Content-Type": "text/plain" },
            write: ["drip\n"],
            waitFor: { timer: { intervalMs: 120 } },
        });
    }
    if (a.kind === "wake_batch") {
        // One frame per timer tick — never returns terminal, so the
        // stream runs until the fetch times out + libcurl FINs.
        return __rove_stream({
            write: ["drip\n"],
            waitFor: { timer: { intervalMs: 120 } },
        });
    }
    // disconnect (client gone): close.
    return { status: 200 };
}
