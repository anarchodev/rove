// `stream.write` back-pressure + overrun exerciser (the handler `stream.*`
// surface). Drives BOTH sides of the lossless-write contract from one held
// SSE stream; pairs with `scripts/smoke/streaming_write_pressure_smoke_v2.py`.
//
// The contract (`StreamChunks` in src/js/components.zig):
//   - SOFT cap (256 KB) is BACK-PRESSURE, not truncation. A burst past it is
//     absorbed and delivered in full; the producer is throttled, not clipped.
//   - HARD cap (4 MB in ONE activation) THROWS. `stream.write` is lossless —
//     the runtime never silently drops, so an activation that cannot buffer
//     what it was handed says so instead of shipping a short stream.
//
// `?overrun=1` picks the second case; the default drives the first.
//
// Each activation writes a small `burst` marker FIRST — always the head of
// that activation's output, so the smoke can count activations by counting
// markers — then the burst itself.
const FAT_CHUNK = "data: " + "X".repeat(3950) + "\n\n"; // ~3.96 KB

// 80 × ~3.96 KB ≈ 317 KB — past the 256 KB soft cap, nowhere near the hard
// one, so every byte must arrive.
const ABSORB_CHUNKS = 80;
// 1200 × ~3.96 KB ≈ 4.75 MB — past the 4 MB hard cap, so the write throws.
const OVERRUN_CHUNKS = 1200;

function overrunRequested() {
    return (request.query || "").indexOf("overrun=1") !== -1;
}

function emit() {
    stream.write("event: burst\ndata: start\n\n");
    const n = overrunRequested() ? OVERRUN_CHUNKS : ABSORB_CHUNKS;
    for (let i = 0; i < n; i++) stream.write(FAT_CHUNK);
}

export default function () {
    response.status = 200;
    response.headers = {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
    };
    stream.start();
    emit();
    after.ms(100);
    return next();
}

// Timer wake — same burst again, so the smoke can watch several activations
// stream losslessly rather than judging from one.
export function onWake() {
    stream.start();
    emit();
    after.ms(100);
    return next();
}
