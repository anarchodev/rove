// Chunk-spool Phase 3 multi-bind smoke handler —
// `docs/chunk-spool-plan.md` (the failing case the `8bd53bb` safety
// net guarded: same-tick chunks for *different* bound fetches landing
// on one held entity).
//
//   GET /multibind?u1=<upstream1>&u2=<upstream2>
//
// Issues TWO bound, streaming http.fetches on the same held chain.
// Each upstream chunk fires `onFetchChunk`; chunks for the two
// fetches interleave on the one entity. The handler keys a kv
// accumulator by `request.fetchId` and consumes every chunk with a
// read-modify-write + `__rove_next()` (writes-per-chunk → a raft
// round-trip per chunk, real back-pressure → both per-fetch spools
// back up). Per-fetch ordering must hold (each spool is FIFO);
// cross-fetch interleave is arbitrary.
//
// When BOTH fetches have delivered their terminal chunk, the handler
// returns the two reconstructed bodies joined by a marker so the
// smoke can assert each is byte-exact (no drops, in order).
const SPLIT = "@@MULTIBIND-SPLIT@@";

export default function () {
    const q = request.query || "";
    let u1 = null;
    let u2 = null;
    for (const pair of q.split("&")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        const k = decodeURIComponent(pair.slice(0, eq));
        const v = decodeURIComponent(pair.slice(eq + 1));
        if (k === "u1") u1 = v;
        else if (k === "u2") u2 = v;
    }
    if (!u1 || !u2) {
        response.status = 400;
        return "missing ?u1=&u2=";
    }
    const id1 = http.fetch({
        url: u1, method: "GET", bind: true, stream: true,
        max_response_chunk_bytes: 64, on_chunk: "multibind", ctx: {},
    });
    const id2 = http.fetch({
        url: u2, method: "GET", bind: true, stream: true,
        max_response_chunk_bytes: 64, on_chunk: "multibind", ctx: {},
    });
    // Remember the two fetch ids (in issue order) + reset state.
    kv.set("mb/id1", id1);
    kv.set("mb/id2", id2);
    kv.set("mb/acc/" + id1, "");
    kv.set("mb/acc/" + id2, "");
    kv.set("mb/ndone", "0");
    return __rove_next("multibind/index", { ctx: {} });
}

export function onFetchChunk() {
    const fid = request.fetchId;
    if (request.done) {
        const ndone = parseInt(kv.get("mb/ndone") || "0", 10) + 1;
        kv.set("mb/ndone", String(ndone));
        if (ndone < 2) {
            // First fetch finished — stay parked for the second.
            return __rove_next("multibind/index", { ctx: {} });
        }
        // Both done — return the two reconstructed bodies in issue order.
        const id1 = kv.get("mb/id1") || "";
        const id2 = kv.get("mb/id2") || "";
        response.status = 200;
        return (kv.get("mb/acc/" + id1) || "") + SPLIT + (kv.get("mb/acc/" + id2) || "");
    }
    const text = new TextDecoder().decode(request.body);
    const prev = kv.get("mb/acc/" + fid) || "";
    kv.set("mb/acc/" + fid, prev + text);
    return __rove_next("multibind/index", { ctx: {} });
}
