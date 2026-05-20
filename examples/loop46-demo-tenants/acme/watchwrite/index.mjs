// Phase 4b exerciser — stream-resume (kv-wake / timer) writes kv.
// On inbound, subscribes to `watchwrite/in/`. On every kv match,
// reads the incoming value, writes to `watchwrite/out/<key>` =
// `processed:<value>` (the customer's "react to writes" pattern),
// then emits a frame echoing both keys.
//
// Pre-Phase-4b this would have closed the stream with a defined
// 500 (kv_error in the tape) the moment a kv-wake hop wrote.
// Phase 4b lifts that: writes propose asynchronously via
// `proposeForgetfulWrites` (the same eager-fire path the §4.4
// disconnect activation uses), the frame ships live, and the
// kv state lands durably via `drainRaftPending`.
export default function () {
    const a = request.activation;
    if (a.kind === "inbound") {
        return __rove_stream({
            status: 200,
            headers: {
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
            },
            write: ["event: ready\ndata: 1\n\n"],
            waitFor: [{ kv: { prefix: "watchwrite/in/" } }],
        });
    }
    if (a.kind === "kv") {
        const value = kv.get(a.key) ?? "(absent)";
        const out_key = "watchwrite/out/" + a.key.slice("watchwrite/in/".length);
        kv.set(out_key, "processed:" + value);
        return __rove_stream({
            write: [`event: relayed\ndata: ${a.key}->${out_key}\n\n`],
            waitFor: [{ kv: { prefix: "watchwrite/in/" } }],
        });
    }
    return { status: 200 };
}
