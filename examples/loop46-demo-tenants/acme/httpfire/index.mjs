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

// Same as `fire` but schedules the http.send for `delay_ms`
// milliseconds in the future. Used by the leader-failover smoke
// (production.md #7) — schedules a fire, kills the leader during
// the delay window, then asserts the new leader picked up the row
// and the on_result handler still ran.
export function fireDelayed(target_url, tag, delay_ms) {
    const now_ms = Date.now();
    const fire_at_ns = BigInt(now_ms) * 1_000_000n + BigInt(delay_ms) * 1_000_000n;
    const id = http.send({
        url: target_url,
        method: "POST",
        body: JSON.stringify({ from: "acme", tag: tag }),
        headers: { "content-type": "application/json" },
        on_result: { module: "httpresult" },
        context: { tag: tag },
        fire_at_ns: fire_at_ns,
    });
    kv.set("http/last_fire", id);
    // Return the computed fire_at_ns so the smoke can verify it's
    // set correctly (BigInt serializes as a string in JSON.stringify).
    return { id: id, fire_at_ns: String(fire_at_ns), now_ms: now_ms };
}
