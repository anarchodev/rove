// Chunk-spool Phase 3 back-pressure handler — `docs/chunk-spool-plan.md`.
//
//   GET /spoolsink?url=<upstream>
//
// Issues a bound, streaming http.fetch and consumes each upstream
// chunk with a kv read-modify-write THEN `next()` — i.e. the
// "writes-per-chunk" pattern. Unlike `boundproxy` (which streams
// frames back via `__rove_stream` and so pipelines without moving the
// held entity), every chunk here forces a full raft round-trip: the
// `next()` parks the cont in `raft_pending_cont` until its writeset
// commits, so chunk consumption runs at raft rate. When the upstream
// pushes a large body all at once, the per-fetch spool backs up well
// past its K-deep RAM window — exercising inline-byte eviction +
// coordinator read-back.
//
// The kv key `spoolsink/full` accumulates the byte-exact upstream body
// across activations (each chunk reads the prior value, appends its
// text, writes it back — serialized because each `next()` commits
// before the next chunk dispatches). On the terminal chunk the handler
// returns the fully reconstructed body to the held client, so the
// smoke can assert byte-exactness directly.
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
    // Fresh accumulator per run.
    kv.set("spoolsink/full", "");
    // Connection-scoped (held handler) → chunks resume onFetchChunk.
    on.fetch(url, { stream: true, max_response_chunk_bytes: 64 });
    return next({ tag: "spoolsink" });
}

export function onFetchChunk() {
    if (request.done) {
        // Terminal: hand the reconstructed body back to the held client.
        response.status = 200;
        return kv.get("spoolsink/full") || "";
    }
    const text = new TextDecoder().decode(request.body);
    const prev = kv.get("spoolsink/full") || "";
    kv.set("spoolsink/full", prev + text);
    // Stay parked as a cont — forces a raft round-trip per chunk.
    return next({ tag: "spoolsink" });
}
