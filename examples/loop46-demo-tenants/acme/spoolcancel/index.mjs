// Chunk-spool Phase 4 cancel-mid-stream handler —
// `docs/chunk-spool-plan.md`.
//
//   GET /spoolcancel?url=<upstream>
//
// Bound, streaming fetch consumed writes-per-chunk (raft round-trip
// per chunk → the spool backs up behind the consumer). After a couple
// of chunks the handler calls `http.cancelFetch(request.fetchId)` on
// its OWN in-flight fetch and returns a terminal response. The spool
// still holds the unconsumed tail chunks; the cancel path
// (`cancelFetchTrampoline` → `dropSpool`) must discard them — counted
// by `bound_fetch_spool_dropped_total`. Exercises the "handler cancels
// its own fetch mid-dispatch" reentrancy (the spool must survive its
// own key being freed during the resume).
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
    kv.set("sc/count", "0");
    on.fetch(url, { stream: true, max_response_chunk_bytes: 64 });
    return next();
}

export function onFetchChunk() {
    const seq = request.chunkSeq;
    if (seq >= 2) {
        // Cancel our own fetch mid-stream + terminate the held chain.
        // No kv write → wrote=false → ships immediately via resolveParked.
        http.cancelFetch({ id: request.fetchId });
        response.status = 200;
        return "cancelled@" + seq;
    }
    const c = parseInt(kv.get("sc/count") || "0", 10) + 1;
    kv.set("sc/count", String(c));
    return next();
}

// Terminal event (handler-shape.md §3). Shouldn't normally reach here —
// we cancel mid-stream — but a tiny body could complete before seq>=2.
export function onFetchDone() {
    response.status = 200;
    return "done-uncancelled@" + request.chunkSeq;
}
