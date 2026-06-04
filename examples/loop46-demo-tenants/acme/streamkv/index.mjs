// stream.* + on.kv + next() exerciser (handler-surface Phase 2 slice
// 2b/2c) — the NEW streaming surface, sibling of the old-surface `watch`
// handler. Output is the `stream.start()` / `stream.write()` effects;
// the wait is `on.kv`; the disposition is `__rove_next(...)` (keep the
// socket). No `__rove_stream({write, waitFor})` — that return verb is
// retired in slice 2d. The dispatcher's `finishResponse` bridges this
// (next() + stream_started) to the same internal Stream descriptor the
// `watch` handler produces, so the h2 stream pipeline drives both.
//
// Proves: stream.start/write + on.kv + next() → finishResponse bridge →
// stream pipeline (stream_response_in → stream_data_out) →
// serviceParkedStreams → resumeStream → (re-dispatch) → bridge again.
export default function () {
    // The head is the ambient response.* (no descriptor head).
    response.status = 200;
    response.headers = {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
    };
    stream.start();                              // commit the head
    stream.write("event: ready\ndata: 1\n\n");   // first frame
    on.kv("streamkv/in/");                        // wait for writes
    return __rove_next("streamkv/index", {});     // hold the socket
}

// A kv write under the watched prefix landed (§8.4-gated) — emit one
// frame per kv entry in the §9.4 batch (temporal order), then re-arm.
export function onWake() {
    stream.start(); // keep the stream alive even on a zero-frame wake
    for (const w of request.activation.wakes) {
        if (w.kind !== "kv") continue;
        const v = kv.get(w.key) ?? "(absent)";
        stream.write("event: update\ndata: " + w.key + "=" + v + "\n\n");
    }
    on.kv("streamkv/in/");                        // re-arm
    return __rove_next("streamkv/index", {});
}
