// Phase 4c exerciser — disconnect activation writes kv as a cleanup side
// effect (handler-surface Phase 2 `stream.*` surface). The stream emits
// heartbeats on a fast timer; when the client disconnects, the
// disconnect activation writes a marker key to kv so a follow-up GET
// (acme/readkey) can confirm the write committed through raft.
//
// The disconnect-activation writes propose via raft and
// `drainRaftPending` commits them asynchronously (no held socket to gate
// on — fire-and-forget).
export default function () {
    const a = request.activation;
    if (a.kind === "inbound") {
        response.status = 200;
        response.headers = {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
        };
        stream.start();
        stream.write(":hb\n\n");
        on.timer(100);
        return __rove_next("disc_writer/index", {});
    }
    if (a.kind === "disconnect") {
        // The cleanup write — set a marker key. The smoke reads it back
        // via /readkey after disconnect. (`onDisconnect` is Phase 4's
        // follow-up; disconnect still lands on the default export.)
        const id = (request.ctx && request.ctx.id) || "1";
        kv.set("disc_marker/" + id, "fired");
        return "";
    }
    return "";
}

// Timer-fired heartbeat (no kv wakes registered → timer-only batch).
// One frame per timer entry.
export function onWake() {
    stream.start();
    for (const w of request.activation.wakes) {
        if (w.kind === "timer") stream.write(":hb\n\n");
    }
    on.timer(100);
    return __rove_next("disc_writer/index", {});
}
