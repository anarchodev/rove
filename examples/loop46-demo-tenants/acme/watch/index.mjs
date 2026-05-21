// Streaming-handlers — kv-write wake exerciser.
// The handler subscribes to a kv prefix (`watch/`) on the inbound
// hop and emits a frame on every put/delete under that prefix. The
// chain `__rove_stream`s indefinitely until the client disconnects.
//
// Frame shape (text/event-stream):
//   - initial snapshot:            `event: snapshot\ndata: initial\n\n`
//   - kv update:                   `event: update\ndata: <key>=<value> (<op>)\n\n`
//   - terminal disconnect cleanup: no frame; just records a tape entry.
//
// `request.activation.kind` discriminates: `"inbound"` (first hop),
// `"wake_batch"` (one or more kv/timer events fired — §9.4
// accumulator drains them in temporal order; `wakes[i]` carries
// `{kind:"kv",key,op,firedAt}` or `{kind:"timer",firedAt}`;
// `overflow.lost_oldest` reports any ring-overflow), or
// `"disconnect"` (client closed; tape recorded, no frame ships).
export default function () {
    const a = request.activation;
    if (a.kind === "inbound") {
        return __rove_stream({
            status: 200,
            headers: {
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
            },
            write: ["event: snapshot\ndata: initial\n\n"],
            waitFor: [{ kv: { prefix: "watch/" } }],
        });
    }
    if (a.kind === "wake_batch") {
        // Emit one frame per kv entry in the batch (preserving
        // temporal order). Timer entries are ignored — this handler
        // only registered kv wakes. `overflow.lost_oldest > 0`
        // would mean we missed writes; the customer-recommended
        // response is to re-snapshot, but for this exerciser we
        // just continue.
        const frames = [];
        for (const w of a.wakes) {
            if (w.kind !== "kv") continue;
            const value = kv.get(w.key) ?? "(deleted)";
            frames.push(`event: update\ndata: ${w.key}=${value} (${w.op})\n\n`);
        }
        return __rove_stream({
            write: frames,
            waitFor: [{ kv: { prefix: "watch/" } }],
        });
    }
    // Disconnect (or anything else): record + close.
    return { status: 200 };
}
