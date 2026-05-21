// on_chunk handler for the Gap 2.3 http.fetch (Pattern A) smoke.
//
// Each upstream chunk fires a `fetch_chunk` activation here. The
// chunk payload arrives as `request.activation.bytes` (a
// Uint8Array). We record each chunk under its own unique key
// (`fetch/chunk/<seq>`) — NOT a read-modify-write counter, since
// sibling chunk activations dispatch back-to-back and a later
// one's txn may begin before an earlier one's forgetful write
// has applied. The smoke counts the keys instead.
export default function () {
    const a = request.activation;
    if (a.kind !== "fetch_chunk") {
        return { status: 500, body: "unexpected activation " + a.kind };
    }
    // Decode the ASCII chunk. The upstream body is pure ASCII so
    // String.fromCharCode over the Uint8Array is exact.
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
