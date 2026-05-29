// Upstream for the chunk-spool large-body smoke
// (`docs/chunk-spool-plan.md` Phase 3). Returns a deterministic,
// pure-ASCII body of `?n=` fixed-width lines (default 200). At the
// caller's `max_response_chunk_bytes` of 64 this splits into many
// chunks (200 lines × 20 bytes = 4000 bytes ≈ 63 chunks), enough to
// overflow the K-deep RAM window so the spool evicts inline bytes +
// reads them back from the coordinator. Pure ASCII so the on_chunk
// handler can `TextDecoder().decode` without surprises.
//
// Each line is exactly 20 bytes: "bigbody-line-NNNNN\n" → 19 visible
// + newline = 20. Zero-padded index keeps every line identical width
// so the reconstructed body is trivial to verify.
export default function () {
    const q = request.query || "";
    let n = 200;
    for (const pair of q.split("&")) {
        const eq = pair.indexOf("=");
        if (eq < 0) continue;
        if (decodeURIComponent(pair.slice(0, eq)) === "n") {
            const v = parseInt(decodeURIComponent(pair.slice(eq + 1)), 10);
            if (Number.isFinite(v) && v > 0 && v <= 100000) n = v;
        }
    }
    let body = "";
    for (let i = 0; i < n; i++) {
        body += "bigbody-line-" + String(i).padStart(5, "0") + "\n"; // 20 bytes
    }
    response.status = 200;
    response.headers = { "content-type": "text/plain", "x-bigbody": "yes" };
    return body;
}
