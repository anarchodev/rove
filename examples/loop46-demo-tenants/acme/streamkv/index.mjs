// stream.* + on.kv + next() exerciser (handler-surface Phase 2 slice
// 2b/2c) — the NEW streaming surface, sibling of the old-surface `watch`
// handler. Output is the `stream.start()` / `stream.write()` effects;
// the wait is `on.kv`; the disposition is `next()` (keep the
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
    after.kv("streamkv/in/");                        // wait for writes
    return next({ cursor: null });     // hold the socket
}

// A kv write under the watched prefix landed (§8.4-gated) — the wake
// names the FIRED PREFIX (issue #8); drain past the ctx cursor and emit
// one frame per new entry, then re-arm. A zero-frame wake (woke, nothing
// new past the cursor) re-holds via the plain `next()` below — no
// `stream.start()` ritual needed to stay parked.
export function onWake() {
    const cursor = request.ctx ? request.ctx.cursor : null;
    const rows = kv.prefix("streamkv/in/", cursor);
    for (const r of rows) {
        stream.write("event: update\ndata: " + r.key + "=" + r.value + "\n\n");
    }
    after.kv("streamkv/in/");                        // re-arm
    return next({ cursor: rows.length ? rows.at(-1).key : cursor });
}
