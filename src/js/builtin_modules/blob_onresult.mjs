// `docs/blob-storage-plan.md` P1: blob.put's on_chunk handler. The
// shim wrote a durable `_blob/owed/{hash}` marker (riding the
// handler's writeset, envelope-0 atomic) and fired the signed PUT
// through the fetch engine's rove-blob.internal door; this module
// receives the PUT's terminal event and settles the marker:
//
//   - success (2xx): kv.delete the marker — the object is durable
//     at its content-addressed key.
//   - failure: keep the marker as durable evidence, stamped
//     `failed: true` + the status. NO re-fire from here — the
//     marker deliberately carries no bytes (effect-algebra §2.5:
//     the bytes are re-derivable from the source activation), so
//     P1 cannot retry; re-execution recovery is post-P1. A re-put
//     of the same bytes is always safe (same hash, idempotent).
//
// Then hands off to the customer's on_result module (if registered)
// via __rove_next, mirroring __system/webhook_onresult.

export default function () {
    const a = request.activation;
    if (a.kind !== "fetch_chunk" && a.kind !== "send_callback") {
        return { status: 200 };
    }
    if (a.kind === "fetch_chunk" && !a.final) return { status: 200 };

    const ctx = JSON.parse(request.body).ctx;
    const hash = ctx.hash;
    const on_result = ctx.on_result || null;
    const context = ctx.context !== undefined ? ctx.context : null;

    const key = "_blob/owed/" + hash;
    const owed_raw = kv.get(key);
    if (owed_raw == null) {
        // Duplicate fire (marker already settled) — no-op.
        return { status: 200 };
    }
    const owed = JSON.parse(owed_raw);

    const status = (a.kind === "fetch_chunk") ? a.status : 0;
    const ok = (a.kind === "fetch_chunk") ? (a.ok && status >= 200 && status < 300) : false;

    if (ok) {
        kv.delete(key);
    } else {
        owed.failed = true;
        owed.last_status = status;
        owed.failed_at_ns = String(BigInt(Date.now()) * 1_000_000n);
        kv.set(key, JSON.stringify(owed));
    }

    if (on_result) {
        return __rove_next(on_result, {
            ctx: {
                result: { hash: hash, ok: ok, status: status },
                context: context,
            },
        });
    }
    return { status: 200 };
}
