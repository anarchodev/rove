// Wake-coalescing exerciser (issue #8 fired-prefix contract,
// decisions.md §3.10). Arms `after.kv("burst/")`; on every wake_batch
// activation emits ONE status frame echoing `wakes.length` + the fired
// prefixes + whether the retired `overflow` object is present, so the
// smoke can assert a burst of N writes coalesces into ONE `{kind:"kv",
// prefix}` entry (a bit-per-arm can't overflow — there is no
// lost_oldest to report).
//
// Pairs with `acme/coalesce_burst` (writes N keys under `burst/` in one
// txn → all N events broadcast → ONE fired-arm stamp on the watcher).
export default function () {
    response.status = 200;
    response.headers = {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
    };
    stream.start();
    stream.write("event: open\ndata: ok\n\n");
    after.kv("burst/");
    return next();
}

// One status frame per wake echoing the batch shape.
export function onWake() {
    const a = request.activation;
    stream.start();
    const prefixes = a.wakes.filter((w) => w.kind === "kv").map((w) => w.prefix).join(",");
    const overflow = a.overflow === undefined ? "absent" : "present";
    stream.write(`event: batch\ndata: wakes=${a.wakes.length} prefix=${prefixes} overflow=${overflow}\n\n`);
    after.kv("burst/");
    return next();
}
