// Gap 2.2 §9.4 overflow exerciser (handler-surface Phase 2 `stream.*`
// surface). Arms `on.kv("overflow/")`; on every wake_batch activation
// emits ONE status frame echoing `wakes.length` + `overflow.lost_oldest`
// so the smoke can assert against them without parsing many frames.
//
// Pairs with `acme/overflow_burst` (writes N keys in one txn → all N
// events broadcast → ring overflows when N > CAP=32).
export default function () {
    const a = request.activation;
    if (a.kind === "inbound") {
        response.status = 200;
        response.headers = {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
        };
        stream.start();
        stream.write("event: open\ndata: ok\n\n");
        on.kv("overflow/");
        return __rove_next("overflow_watch/index", {});
    }
    if (a.kind === "wake_batch") {
        const wakes_count = a.wakes.length;
        const lost = a.overflow.lost_oldest;
        stream.start();
        stream.write(`event: batch\ndata: wakes=${wakes_count} lost=${lost}\n\n`);
        on.kv("overflow/");
        return __rove_next("overflow_watch/index", {});
    }
    return "";
}
