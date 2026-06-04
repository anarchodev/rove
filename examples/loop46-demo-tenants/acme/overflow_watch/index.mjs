// Gap 2.2 §9.4 overflow exerciser (handler-surface Phase 2 `stream.*`
// surface). Arms `on.kv("overflow/")`; on every wake_batch activation
// emits ONE status frame echoing `wakes.length` + `overflow.lost_oldest`
// so the smoke can assert against them without parsing many frames.
//
// Pairs with `acme/overflow_burst` (writes N keys in one txn → all N
// events broadcast → ring overflows when N > CAP=32).
export default function () {
    response.status = 200;
    response.headers = {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
    };
    stream.start();
    stream.write("event: open\ndata: ok\n\n");
    on.kv("overflow/");
    return next();
}

// One status frame per wake echoing wakes.length + overflow.lost_oldest.
export function onWake() {
    const a = request.activation;
    stream.start();
    stream.write(`event: batch\ndata: wakes=${a.wakes.length} lost=${a.overflow.lost_oldest}\n\n`);
    on.kv("overflow/");
    return next();
}
