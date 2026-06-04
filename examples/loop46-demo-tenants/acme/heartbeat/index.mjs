// Streaming-handlers — multi-frame timer-wake exerciser (handler-
// surface Phase 2 `stream.*` surface). The inbound hop (`default`
// export) opens the stream with a single SSE `:heartbeat\n\n` frame and
// arms `on.timer(200)`; every 200ms the runtime runs `onWake` (Phase 4
// named-export dispatch) which emits another `:heartbeat\n\n`. The smoke
// (scripts/streaming_heartbeat_smoke.py) reads at least three heartbeats
// over ~700ms, then closes — verifying the chunked-DATA + timer-wake
// lifecycle end to end.
//
// The connection has NO held handle — the chain IS the connection by
// construction (project-connection-actor-unified-trigger). The platform
// decides when the stream ends: client disconnect, or the per-stream
// activation cap (MAX_STREAM_ACTIVATIONS).
export default function () {
    response.status = 200;
    response.headers = {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
    };
    stream.start();
    stream.write(":heartbeat\n\n");
    on.timer(200);
    return __rove_next("heartbeat/index", {});
}

// Timer wake — emit a heartbeat per timer entry, re-arm.
export function onWake() {
    stream.start(); // keep the stream alive even if zero frames this wake
    for (const w of request.activation.wakes) {
        if (w.kind === "timer") stream.write(":heartbeat\n\n");
    }
    on.timer(200);
    return __rove_next("heartbeat/index", {});
}
