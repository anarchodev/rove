// Streaming-handlers — kv-write wake exerciser (handler-surface Phase 2
// `stream.*` surface). The inbound hop arms `after.kv("watch/")` and emits
// a snapshot frame; on every put/delete under that prefix it emits a
// frame. The chain streams indefinitely until the client disconnects.
//
// Frame shape (text/event-stream):
//   - initial snapshot:  `event: snapshot\ndata: initial\n\n`
//   - kv update:         `event: update\ndata: <key>=<value>\n\n`
//   - disconnect:        no frame; just records a tape entry.
//
// Named-export dispatch (handler-surface Phase 4): the inbound hop runs
// the `default` export; each kv wake runs `onWake`. A wake is an edge
// ("go look") — `request.activation.wakes` names the FIRED PREFIX
// (`{kind:"kv",prefix,firedAt}` / `{kind:"timer",firedAt}`, issue #8),
// never the matched keys, so onWake drains the prefix past a `ctx`
// cursor (handler-shape §5.7) to find what changed.
// A disconnect needs no cleanup here, so there's no `onDisconnect`.
// Inbound (the default export): open the stream + arm the kv wake. The
// kv-write wake lands in onWake (Phase 4 named-export dispatch).
export default function () {
    response.status = 200;
    response.headers = {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
    };
    stream.start();
    stream.write("event: snapshot\ndata: initial\n\n");
    after.kv("watch/");
    return next({ cursor: null });
}

// Go-look drain: the wake fired for "watch/"; emit one frame per key
// past the cursor. Coalesced wakes lose nothing — the drain always
// starts where the last one stopped. Timer entries are ignored — this
// handler only registered kv wakes.
export function onWake() {
    stream.start(); // keep the stream alive even on a zero-frame wake
    const cursor = request.ctx ? request.ctx.cursor : null;
    const rows = kv.prefix("watch/", cursor);
    for (const r of rows) {
        stream.write(`event: update\ndata: ${r.key}=${r.value}\n\n`);
    }
    after.kv("watch/");
    return next({ cursor: rows.length ? rows.at(-1).key : cursor });
}
