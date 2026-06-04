// Streaming-handlers — kv-write wake exerciser (handler-surface Phase 2
// `stream.*` surface). The inbound hop arms `on.kv("watch/")` and emits
// a snapshot frame; on every put/delete under that prefix it emits a
// frame. The chain streams indefinitely until the client disconnects.
//
// Frame shape (text/event-stream):
//   - initial snapshot:  `event: snapshot\ndata: initial\n\n`
//   - kv update:         `event: update\ndata: <key>=<value> (<op>)\n\n`
//   - disconnect:        no frame; just records a tape entry.
//
// `request.activation.kind` discriminates: `"inbound"` (first hop),
// `"wake_batch"` (one or more kv/timer events fired — §9.4 accumulator
// drains them in temporal order; `wakes[i]` carries
// `{kind:"kv",key,op,firedAt}` or `{kind:"timer",firedAt}`;
// `overflow.lost_oldest` reports any ring-overflow), or `"disconnect"`.
// Inbound (the default export): open the stream + arm the kv wake.
// The kv-write wake lands in onWake (Phase 4 named-export dispatch);
// disconnect / anything else closes.
export default function () {
    if (request.activation.kind === "inbound") {
        response.status = 200;
        response.headers = {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
        };
        stream.start();
        stream.write("event: snapshot\ndata: initial\n\n");
        on.kv("watch/");
        return __rove_next("watch/index", {});
    }
    // Disconnect (or anything else): record + close.
    return "";
}

// One frame per kv entry in the batch (temporal order). Timer entries
// are ignored — this handler only registered kv wakes.
// `request.activation.overflow.lost_oldest > 0` would mean we missed
// writes; the recommended response is to re-snapshot, but here we
// continue.
export function onWake() {
    stream.start(); // keep the stream alive even on a zero-frame wake
    for (const w of request.activation.wakes) {
        if (w.kind !== "kv") continue;
        const value = kv.get(w.key) ?? "(deleted)";
        stream.write(`event: update\ndata: ${w.key}=${value} (${w.op})\n\n`);
    }
    on.kv("watch/");
    return __rove_next("watch/index", {});
}
