// docs/architecture/blob-write-recipes.md §4–5: the flip + customer handoff.
// Arrives as the send_callback of blob_compose's PUT (via
// __system/blob_onresult): request.status hoisted top-level (2xx = ok),
// request.ctx = {sid, hash, on, ctx, totalBytes}.
//
// Success: delete the recipe (rows + meta + the _blob/pending row —
// the object owns its bytes now; absence of meta IS "materialized"),
// then chain to the customer's `on` with the standard result surface:
// request.ctx = the seal-time ctx, request.activation.hash, and
// {hash, totalBytes} as the JSON body.
//
// Failure: leave everything (the owed marker already carries
// failed:true) — the materializer re-fires the compose. The customer
// is NEVER told ok:false; the completion contract has no failure arm.

export default function () {
    const c = request.ctx || {};
    const sid = c.sid;
    const hash = c.hash;
    if (!sid || !hash) return { status: 400 };

    // 2xx = stored; anything else (incl. status 0 transport failure) is
    // a failed PUT. `status` is the single result truth (no
    // `request.ok`).
    if (request.status < 200 || request.status >= 300) {
        console.error("blob_compose_onresult: PUT for " + hash + " failed (status " +
            request.status + ") — recipe " + sid + " left for the materializer");
        return { status: 200 };
    }

    const metaKey = "_blob/recipe/" + sid + "/meta";
    const raw = kv.get(metaKey);
    if (raw == null) return { status: 200 }; // duplicate fire — already flipped
    const meta = JSON.parse(raw);
    for (let i = 0; i < meta.rows; i++) {
        kv.delete("_blob/recipe/" + sid + "/r/" + String(i).padStart(4, "0"));
    }
    kv.delete(metaKey);
    kv.delete("_blob/pending/" + hash);

    const userCtx = c.ctx !== undefined ? c.ctx : null;
    // Cross-module continuation into the customer's `on` handler — the
    // widened public `next(target, ctx)` (no bare `__rove_next`).
    return next(c.on, {
        result: {
            hash: hash,
            ok: true,
            status: 200,
            body_b64: base64url.encode(new TextEncoder().encode(
                JSON.stringify({ hash: hash, totalBytes: c.totalBytes }))),
        },
        context: userCtx,
    });
}
