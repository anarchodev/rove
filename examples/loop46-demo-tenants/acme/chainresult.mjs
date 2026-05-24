// Phase 5 PR-2a: chained-dispatch terminal — fires because the
// chainfetchstep1 handler returned __rove_next("chainresult", {ctx}).
// `request.activation.kind === "send_callback"`; the cont's ctx
// rides as `request.body.ctx`. Writes a kv marker the smoke reads
// back to confirm the chained dispatch ran with the right payload.
export default function () {
    const a = request.activation;
    if (a.kind !== "send_callback") {
        return { status: 500, body: "unexpected activation " + a.kind };
    }
    const ctx = JSON.parse(request.body).ctx;
    kv.set("chain/result", JSON.stringify({
        kind: a.kind,
        seen_status: ctx.seen_status,
        seen_ok: ctx.seen_ok,
        seen_bytes_len: ctx.seen_bytes_len,
        fetch_id: ctx.fetch_id,
        originating_tag: ctx.originating_tag,
    }));
    return { status: 200 };
}
