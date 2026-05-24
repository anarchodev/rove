// Phase 5 PR-2a: on_chunk handler for /chainfetch. On the final
// event, returns __rove_next("chainresult", {ctx}) — the runtime
// must dispatch the named module with the cont's ctx threaded as
// request.body.ctx. Pre-PR-2 this was a warn-and-drop.
export default function () {
    const a = request.activation;
    if (!a.final) return { status: 200 };  // intermediates: ignore
    // Build the chained-hop ctx with what we observed; the next
    // module will assert this round-trips correctly.
    return __rove_next("chainresult", {
        ctx: {
            seen_status: a.status,
            seen_ok: a.ok,
            seen_bytes_len: a.bytes.length,
            fetch_id: a.fetch_id,
            // Echo the originating ctx so the smoke can prove it
            // round-tripped through fetch → chained hop.
            originating_tag: JSON.parse(request.body).ctx.tag,
        },
    });
}
