// Gap 2.2 §9.4 write-pressure exerciser. Heartbeat stream that
// returns more chunk bytes per activation than `StreamChunks
// .QUEUE_BYTES_CAP` so the cap-overflow path fires, then echoes
// `request.activation.write_pressure.dropped_chunks` from the
// PRIOR activation on the next one. Pairs with
// `scripts/streaming_write_pressure_smoke.py`.
//
// Each activation appends:
//   1. A `pressure` status frame (small — always survives the cap)
//      reporting the dropped-chunk count from the previous run.
//   2. ~80 fat chunks (~4 KB each = ~320 KB) — exceeds the 256 KB
//      cap so ~16-20 chunks drop per activation. The handler can
//      always send the status frame because it goes FIRST.
//
// The frame size + count is deliberately chosen so each activation
// drains within the next 100ms timer interval (queue drains 1
// chunk per worker tick, so ~64 chunks in ~64 sub-ms ticks —
// well under 100ms).
export default function () {
    const a = request.activation;
    const chunk = "data: " + "X".repeat(3950) + "\n\n"; // ~3.96 KB

    function buildPayload(prior_dropped) {
        const frames = [`event: pressure\ndata: dropped=${prior_dropped}\n\n`];
        for (let i = 0; i < 80; i++) frames.push(chunk);
        return frames;
    }

    if (a.kind === "inbound") {
        return __rove_stream({
            status: 200,
            headers: {
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
            },
            write: buildPayload(0),
            waitFor: { timer: { intervalMs: 100 } },
        });
    }
    if (a.kind === "wake_batch") {
        return __rove_stream({
            write: buildPayload(a.write_pressure.dropped_chunks),
            waitFor: { timer: { intervalMs: 100 } },
        });
    }
    return { status: 200 };
}
