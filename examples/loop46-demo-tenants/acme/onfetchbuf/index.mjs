// on.fetch NON-streaming exerciser — proves the onFetchResult
// convention (handler-shape.md §3 + §8 finer conventions).
//
//   GET /onfetchbuf?url=<upstream>
//
// A connection-scoped on.fetch WITHOUT `stream: true` and WITHOUT a
// `{to}` override: the whole upstream body is buffered and delivered in
// ONE terminal event that dispatches to the conventional `onFetchResult`
// export (not onFetchChunk / onFetchDone — those are the streaming
// split). No stream.* output; the held client gets the buffered body.
export default function () {
    const q = request.query || "";
    let url = null;
    for (const pair of q.split("&")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        const k = decodeURIComponent(pair.slice(0, eq));
        const v = decodeURIComponent(pair.slice(eq + 1));
        if (k === "url") url = v;
    }
    if (!url) {
        response.status = 400;
        return "missing ?url=";
    }
    // Buffered (no stream:true) + conventional export (no {to}).
    on.fetch(url);
    return next();
}

// The whole upstream body arrives here in one activation.
export function onFetchResult() {
    response.status = 200;
    return new TextDecoder().decode(request.body);
}
