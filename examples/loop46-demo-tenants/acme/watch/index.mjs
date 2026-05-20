// Streaming-handlers Phase 3 — kv-write wake exerciser.
// The handler subscribes to a kv prefix (`watch/`) on the inbound
// hop and emits a frame on every put/delete under that prefix. The
// chain `__rove_stream`s indefinitely until the client disconnects.
//
// Frame shape (text/event-stream):
//   - initial snapshot:           `event: snapshot\ndata: initial\n\n`
//   - kv update:                  `event: update\ndata: <key>=<value> (<op>)\n\n`
//   - terminal disconnect cleanup: no frame; just records a tape entry.
//
// `request.activation.kind` discriminates: `"inbound"` (first hop),
// `"kv"` (a prefix match fired — `.key` + `.op` carry payload), or
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
    if (a.kind === "kv") {
        const value = kv.get(a.key) ?? "(deleted)";
        return __rove_stream({
            write: [`event: update\ndata: ${a.key}=${value} (${a.op})\n\n`],
            waitFor: [{ kv: { prefix: "watch/" } }],
        });
    }
    // Disconnect (or anything else): record + close.
    return { status: 200 };
}
