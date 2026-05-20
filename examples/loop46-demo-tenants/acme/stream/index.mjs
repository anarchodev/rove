// Streaming-handlers Phase 2b-i — degenerate single-DATA-frame
// `__rove_stream` exerciser. The customer's JS shape is the same one
// real iterative streams will use (write[] of chunks, headers,
// status); Phase 2b-i lands those reaching the wire as a single
// concatenated body, Phase 2b-ii adds the per-chunk DATA-frame
// lifecycle + timer-wake re-activation.
//
// Returns 200 with `Content-Type: text/event-stream`, three SSE-
// formatted chunks. The smoke verifies all three chunks land in the
// response body (concatenated) and the header is set.
export default function () {
    return __rove_stream({
        status: 200,
        headers: {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
        },
        write: [
            "event: tick\ndata: alpha\n\n",
            "event: tick\ndata: bravo\n\n",
            "event: tick\ndata: charlie\n\n",
        ],
    });
}
