// Phase 4d exerciser — stream-first-hop writes kv as part of open
// (handler-surface Phase 2 `stream.*` surface). The "open a session"
// pattern: register the connection in kv (so other endpoints can see
// who's online) AND stream live events. The first-hop writes propose
// through raft via the normal write-batch path; `drainRaftPending`
// registers the chain cell + moves the entity into `stream_response_in`
// once the writes commit.
// Resume hops receive ctx via the synthesized request body shape
// `{ctx:<json>}` — parse it back out.
function resumeCtx() {
    return JSON.parse(request.body || "{}").ctx || {};
}

export default function () {
    const a = request.activation;
    if (a.kind === "inbound") {
        const id = (request.query || "").split("&")
            .map(p => p.split("="))
            .find(p => decodeURIComponent(p[0]) === "id");
        const session_id = id ? decodeURIComponent(id[1]) : "anon";
        // The first-hop side effect: register the session.
        kv.set("sessions/" + session_id, "online");
        response.status = 200;
        response.headers = {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
        };
        stream.start();
        stream.write(`event: hello\ndata: ${session_id}\n\n`);
        on.timer(100);
        return __rove_next("sessions_sse/index", { ctx: { session_id } });
    }
    if (a.kind === "disconnect") {
        // Mirror the open: deregister the session. (`onDisconnect` is
        // Phase 4's follow-up; disconnect still lands on default.)
        kv.set("sessions/" + resumeCtx().session_id, "offline");
        return "";
    }
    return "";
}

// Timer-driven tick; one frame per fire.
export function onWake() {
    const ctx = resumeCtx();
    stream.start();
    for (const w of request.activation.wakes) {
        if (w.kind === "timer") stream.write(`event: tick\ndata: ${ctx.session_id}\n\n`);
    }
    on.timer(100);
    return __rove_next("sessions_sse/index", { ctx });
}
