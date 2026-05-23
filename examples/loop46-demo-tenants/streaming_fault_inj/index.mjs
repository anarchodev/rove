// effect-reification Phase 4.0.b regression gate — streaming-model.md
// §2 ("a chunk reaches the wire only after the activation that
// produced it has committed") is enforced by the parked_units
// commit-arm chunk-transfer. The fault gate freezes followers BEFORE
// the timer wake fires, so the wake_batch hop's propose can't
// quorum; the staged chunk must NOT leak.
//
// Pre-fix the wake_batch handler's chunk was queued into StreamChunks
// IMMEDIATELY (eager-fire) and h2 shipped it ~one tick later — long
// before the writes durably committed. Post-fix the chunk stages on
// the parked unit and the §9.4 service tick sees an empty chunk
// queue; the customer reads nothing during the commit-wait window;
// the fault arm discards the chunk.
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
            // 1.5s timer — wide enough that the smoke can SIGSTOP
            // followers before the wake fires, narrow enough to
            // exercise the gate within a smoke's deadline.
            waitFor: { timer: { intervalMs: 1500 } },
        });
    }
    if (a.kind === "wake_batch") {
        // wake_batch + writes: the arm Phase 4.0.b gates. A raft
        // fault during the commit-wait window must discard the
        // staged "tick" chunk; the customer must NOT see this
        // frame on the wire until the kv.set durably commits.
        const ctr = parseInt(kv.get("counter") ?? "0") + 1;
        kv.set("counter", String(ctr));
        return __rove_stream({
            write: [`event: tick\ndata: ${ctr}\n\n`],
            waitFor: { timer: { intervalMs: 1500 } },
        });
    }
    return { status: 200 };
}
