// Upstream for the Gap 2.3 http.fetch (Pattern A) chunk smoke.
// Returns a deterministic ASCII body (10 lines, 170 bytes) large
// enough to split into several chunks when the caller sets a
// small `max_response_chunk_bytes`. Pure ASCII so the on_chunk
// handler can decode bytes with `String.fromCharCode` (no
// TextDecoder dependency).
export default function () {
    let body = "";
    for (let i = 0; i < 10; i++) {
        const n = String(i).padStart(2, "0");
        body += ("bulk-line-" + n + "-zzz\n"); // 17 bytes / line
    }
    response.status = 200;
    response.headers = { "content-type": "text/plain", "x-bulk": "yes" };
    return body;
}
