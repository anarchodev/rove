// Caller side of the http.send fast-path smoke.
// `fn=fire&args=[targetUrl, tag]` invokes http.send at the given URL
// with a tagged context the on_result handler echoes back into kv so
// the smoke can assert end-to-end shape. Returns { id } so the smoke
// can correlate the receipt.
export function fire(target_url, tag) {
    const id = http.send({
        url: target_url,
        method: "POST",
        body: JSON.stringify({ from: "acme", tag: tag }),
        headers: { "content-type": "application/json" },
        on_result: { module: "httpresult" },
        context: { tag: tag },
    });
    kv.set("http/last_fire", id);
    return { id: id };
}
