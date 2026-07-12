// Phase 4b exerciser — stream-resume (kv-wake) writes kv (handler-
// surface Phase 2 `stream.*` surface). On inbound, arms
// `after.kv("watchwrite/in/")`. On every kv match, reads the incoming
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
    after.kv("watchwrite/in/");
    return next();
}

// Go-look relay: the wake names the FIRED PREFIX (issue #8 — never the
// matched keys); scan under it and relay everything not yet processed
// (the out-key marker doubles as the dedupe cursor, so coalesced wakes
// relay each key exactly once).
export function onWake() {
    stream.start(); // keep the stream alive even on a zero-frame wake
    for (const w of request.activation.wakes) {
        if (w.kind !== "kv") continue;
        for (const r of kv.prefix(w.prefix)) {
            const out_key = "watchwrite/out/" + r.key.slice(w.prefix.length);
            if (kv.get(out_key) != null) continue; // already relayed
            kv.set(out_key, "processed:" + r.value);
            stream.write(`event: relayed\ndata: ${r.key}->${out_key}\n\n`);
        }
    }
    after.kv("watchwrite/in/");
    return next();
}
