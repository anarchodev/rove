// on_chunk for the http.subscribe smoke. Records each chunk under
// `sub/chunk/<fetch_id>/<seq>` so the smoke can poll for arrival.
// On the terminal event (`final: true`) records `sub/done/<fetch_id>`
// with the reason ok=false + status. Phase 3 (gap 2.5) held
// subscriptions ALWAYS terminate with ok=false ("subscription
// ended") — whether the upstream closed cleanly or the customer
// cancelled.
export default function () {
    const a = request.activation;
    if (a.kind !== "fetch_chunk") {
        return { status: 500, body: "unexpected activation " + a.kind };
    }
    if (a.final) {
        kv.set("sub/done/" + a.fetch_id, JSON.stringify({
            ok: a.ok,
            status: a.status,
            body_truncated: a.body_truncated,
        }));
        return { status: 200 };
    }
    const bytes = a.bytes;
    let text = "";
    for (let i = 0; i < bytes.length; i++) text += String.fromCharCode(bytes[i]);
    kv.set("sub/chunk/" + a.fetch_id + "/" + a.seq, JSON.stringify({
        seq: a.seq,
        text: text,
        len: bytes.length,
    }));
    return { status: 200 };
}
