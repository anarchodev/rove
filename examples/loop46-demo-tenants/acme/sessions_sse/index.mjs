// Phase 4d exerciser — stream-first-hop writes kv as part of
// open. The "open a session" pattern: customer wants to register
// the connection in kv (so other endpoints can see who's online)
// AND stream live events.
//
// Pre-Phase-4d the kv write would have made the dispatch path
// reject the __rove_stream return with a defined 500 (the
// `ws_pre_len` guard). Post-Phase-4d the writes propose through
// raft via the normal write-batch path; `drainRaftPending`
// registers the chain cell + moves the entity into
// `stream_response_in` once the writes commit.
export default function () {
    const a = request.activation;
    if (a.kind === "inbound") {
        const id = (request.query || "").split("&")
            .map(p => p.split("="))
            .find(p => decodeURIComponent(p[0]) === "id");
        const session_id = id ? decodeURIComponent(id[1]) : "anon";
        // The first-hop side effect: register the session.
        kv.set("sessions/" + session_id, "online");
        return __rove_stream({
            status: 200,
            headers: {
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
            },
            write: [`event: hello\ndata: ${session_id}\n\n`],
            waitFor: { timer: { intervalMs: 100 } },
            ctx: { session_id },
        });
    }
    // Resume hops receive ctx via the synthesized request body
    // shape `{ctx:<json>}` — parse it back out. (`request.ctx`
    // isn't a first-class JS property yet — §3.3 / §6 of the
    // plan exposes it conceptually but the surface remains the
    // request body for now.)
    const ctx = JSON.parse(request.body || "{}").ctx || {};
    if (a.kind === "wake_batch") {
        // Timer-driven tick; one frame per fire.
        const frames = [];
        for (const w of a.wakes) {
            if (w.kind === "timer") frames.push(`event: tick\ndata: ${ctx.session_id}\n\n`);
        }
        return __rove_stream({
            write: frames,
            waitFor: { timer: { intervalMs: 100 } },
            ctx: ctx,
        });
    }
    if (a.kind === "disconnect") {
        // Mirror the open: deregister the session.
        kv.set("sessions/" + ctx.session_id, "offline");
        return { status: 200 };
    }
    return { status: 200 };
}
