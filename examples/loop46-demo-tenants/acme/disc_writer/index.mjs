// Phase 4c exerciser — disconnect activation writes kv as a cleanup
// side effect. The stream emits heartbeats on a fast timer; when the
// client disconnects, the disconnect activation writes a marker key
// to kv so a follow-up GET (acme/readkey) can confirm the write
// committed through raft.
//
// Pre-Phase-4 this would have been rejected with a defined 500
// ("kv_error" in the tape) because the disconnect activation's
// write-rejection guard fired. Phase 4c lifts it: the writes
// propose via raft and `drainRaftPending` commits them
// asynchronously (no held socket to gate on — fire-and-forget).
export default function () {
    const a = request.activation;
    if (a.kind === "inbound") {
        return __rove_stream({
            status: 200,
            headers: {
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
            },
            write: [":hb\n\n"],
            waitFor: { timer: { intervalMs: 100 } },
        });
    }
    if (a.kind === "wake_batch") {
        // Timer-fired heartbeat (this stream registered no kv wakes,
        // so the batch is timer-only). One frame per fire — multiple
        // timer entries in one batch happen only if the worker ran
        // longer than the interval, which we don't expect here.
        const frames = [];
        for (const w of a.wakes) {
            if (w.kind === "timer") frames.push(":hb\n\n");
        }
        return __rove_stream({
            write: frames,
            waitFor: { timer: { intervalMs: 100 } },
        });
    }
    if (a.kind === "disconnect") {
        // The cleanup write — set a marker key whose value is the
        // current ctx (or "1" if ctx is null). The smoke reads this
        // back via /readkey after disconnect.
        const id = (request.ctx && request.ctx.id) || "1";
        kv.set("disc_marker/" + id, "fired");
        return { status: 200 };
    }
    return { status: 200 };
}
