// on_chunk for the benchfetch entry handler. Writes a per-fetch-id
// done marker on the terminal event so the bench can poll for
// completion of each individual fetch (vs. fetchchunk.mjs's single
// `fetch/done` overwrite, which loses information across N
// concurrent fetches).
//
// Intermediate body chunks are no-ops here — the bench measures
// dispatch + transport + completion latency, not per-chunk content
// (the smoke at fetchchunk.mjs already covers content correctness).
export default function () {
    const a = request.activation;
    if (a.kind !== "fetch_chunk") {
        return { status: 500, body: "unexpected activation " + a.kind };
    }
    if (a.final) {
        // Per-id done marker. The bench polls `bench/done/<id>` for
        // each fetch it issued; presence === completion.
        kv.set("bench/done/" + a.fetch_id, JSON.stringify({
            ok: a.ok,
            status: a.status,
        }));
    }
    return { status: 200 };
}
