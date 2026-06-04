// Gap 2.2 §9.4 write-pressure exerciser (handler-surface Phase 2
// `stream.*` surface). Heartbeat stream that writes more chunk bytes
// per activation than `StreamChunks.QUEUE_BYTES_CAP` so the cap-overflow
// path fires, then echoes `request.activation.write_pressure
// .dropped_chunks` from the PRIOR activation on the next one. Pairs with
// `scripts/streaming_write_pressure_smoke.py`.
//
// Each activation writes:
//   1. A `pressure` status frame (small — always survives the cap)
//      reporting the dropped-chunk count from the previous run.
//   2. ~80 fat chunks (~4 KB each = ~320 KB) — exceeds the 256 KB cap so
//      ~16-20 chunks drop per activation. The status frame always
//      survives because it goes FIRST.
const FAT_CHUNK = "data: " + "X".repeat(3950) + "\n\n"; // ~3.96 KB

function emit(prior_dropped) {
    stream.write(`event: pressure\ndata: dropped=${prior_dropped}\n\n`);
    for (let i = 0; i < 80; i++) stream.write(FAT_CHUNK);
}

export default function () {
    if (request.activation.kind === "inbound") {
        response.status = 200;
        response.headers = {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
        };
        stream.start();
        emit(0);
        on.timer(100);
        return __rove_next("big_chunks/index", {});
    }
    return "";
}

// Timer wake — echo the prior activation's dropped-chunk count, then
// flood again.
export function onWake() {
    stream.start();
    emit(request.activation.write_pressure.dropped_chunks);
    on.timer(100);
    return __rove_next("big_chunks/index", {});
}
