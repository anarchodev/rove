// effect-reification Phase 4.0.b regression gate — streaming-model.md
// §2 ("a chunk reaches the wire only after the activation that produced
// it has committed") is enforced by the parked_units commit-arm
// chunk-transfer. The fault gate freezes followers BEFORE the timer wake
// fires, so the wake_batch hop's propose can't quorum; the staged chunk
// must NOT leak. (Handler-surface Phase 2 `stream.*` surface.)
export default function () {
    response.status = 200;
    response.headers = {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
    };
    stream.start();
    stream.write("event: ready\ndata: 1\n\n");
    // 1.5s timer — wide enough that the smoke can SIGSTOP followers
    // before the wake fires, narrow enough to exercise the gate within a
    // smoke's deadline.
    on.timer(1500);
    return __rove_next("index", {});
}

// wake_batch + writes: the arm Phase 4.0.b gates. A raft fault during
// the commit-wait window must discard the staged "tick" chunk; the
// customer must NOT see this frame until the kv.set durably commits.
export function onWake() {
    const ctr = parseInt(kv.get("counter") ?? "0") + 1;
    kv.set("counter", String(ctr));
    stream.start();
    stream.write(`event: tick\ndata: ${ctr}\n\n`);
    on.timer(1500);
    return __rove_next("index", {});
}
