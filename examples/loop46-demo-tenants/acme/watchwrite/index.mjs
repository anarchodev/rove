// Phase 4b exerciser — stream-resume (kv-wake) writes kv (handler-
// surface Phase 2 `stream.*` surface). On inbound, arms
// `on.kv("watchwrite/in/")`. On every kv match, reads the incoming
// value, writes to `watchwrite/out/<key>` = `processed:<value>` (the
// customer's "react to writes" pattern), then emits a frame echoing
// both keys.
//
// The stream-resume hop's writes propose asynchronously via
// `proposeForgetfulWrites`; the frame ships live and the kv state lands
// durably via `drainRaftPending` (chunks gated on commit per
// streaming-model §2).
export default function () {
    response.status = 200;
    response.headers = {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
    };
    stream.start();
    stream.write("event: ready\ndata: 1\n\n");
    on.kv("watchwrite/in/");
    return __rove_next("watchwrite/index", {});
}

// §9.4: relay every kv entry in the wake batch in temporal order,
// writing a processed marker per key.
export function onWake() {
    stream.start(); // keep the stream alive even on a zero-frame wake
    for (const w of request.activation.wakes) {
        if (w.kind !== "kv") continue;
        const value = kv.get(w.key) ?? "(absent)";
        const out_key = "watchwrite/out/" + w.key.slice("watchwrite/in/".length);
        kv.set(out_key, "processed:" + value);
        stream.write(`event: relayed\ndata: ${w.key}->${out_key}\n\n`);
    }
    on.kv("watchwrite/in/");
    return __rove_next("watchwrite/index", {});
}
