// Gap 2.2 §9.4 overflow exerciser. Subscribes to `overflow/`;
// on every wake_batch activation emits ONE status frame echoing
// `wakes.length` + `overflow.lost_oldest` so the smoke can
// assert against them without parsing many frames.
//
// Pairs with `acme/overflow_burst` (writes N keys in one txn → all
// N events broadcast → ring overflows when N > CAP=32).
export default function () {
    const a = request.activation;
    if (a.kind === "inbound") {
        return __rove_stream({
            status: 200,
            headers: {
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
            },
            write: ["event: open\ndata: ok\n\n"],
            waitFor: [{ kv: { prefix: "overflow/" } }],
        });
    }
    if (a.kind === "wake_batch") {
        const wakes_count = a.wakes.length;
        const lost = a.overflow.lost_oldest;
        return __rove_stream({
            write: [
                `event: batch\ndata: wakes=${wakes_count} lost=${lost}\n\n`,
            ],
            waitFor: [{ kv: { prefix: "overflow/" } }],
        });
    }
    return { status: 200 };
}
