// Single on_chunk handler for the Gap 2.3 / Phase 5 PR-1 http.fetch
// smoke. Each upstream event fires here; `activation.final`
// distinguishes streaming intermediates from the terminal event.
//
// Pre-Phase-5 there were TWO handlers — `fetchchunk.mjs` for
// `fetch_chunk` (per-chunk bytes) and `fetchdone.mjs` for
// `fetch_done` (terminal status + ok). PR-1 collapsed those into
// a single callback with the same name; the final event carries
// the terminal fields alongside an empty `bytes` Uint8Array.
//
// Chunks are recorded under their own unique key
// (`fetch/chunk/<seq>`) — NOT a read-modify-write counter, since
// sibling chunk activations dispatch back-to-back and a later
// one's txn may begin before an earlier one's forgetful write has
// applied. The smoke counts the keys instead. The terminal event
// writes `fetch/done` with the upstream `ok` + `status`.
export default function () {
    const a = request.activation;
    if (a.kind !== "fetch_chunk") {
        return { status: 500, body: "unexpected activation " + a.kind };
    }

    if (a.final) {
        // Terminal event — bytes is empty (the canonical "fetch
        // complete" signal). Record the upstream status.
        kv.set("fetch/done", JSON.stringify({
            fetch_id: a.fetch_id,
            ok: a.ok,
            status: a.status,
            body_truncated: a.body_truncated,
        }));
        return { status: 200 };
    }

    // Intermediate body chunk. Decode the ASCII chunk (upstream
    // body is pure ASCII).
    const bytes = a.bytes;
    let text = "";
    for (let i = 0; i < bytes.length; i++) text += String.fromCharCode(bytes[i]);

    // ctx round-trip: the entry handler passed { tag: "fetchsmoke" }.
    let tag = null;
    try { tag = JSON.parse(request.body).ctx.tag; } catch (_) {}

    kv.set("fetch/chunk/" + a.seq, JSON.stringify({
        seq: a.seq,
        byteOffset: a.byteOffset,
        len: bytes.length,
        text: text,
        has_headers: a.headers ? true : false,
        content_type: a.headers ? (a.headers["content-type"] || null) : null,
        fetch_id: a.fetch_id,
        tag: tag,
    }));
    return { status: 200 };
}
