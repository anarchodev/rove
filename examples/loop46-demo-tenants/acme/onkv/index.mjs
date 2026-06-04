// on.kv connection-wake exerciser (handler-surface Phase 1 Task 3 — the
// kv half, sibling of `ontimer`).
//
// The inbound hop READS the watched key first (so the §8.4 read_version
// baseline is captured AFTER the read), arms `on.kv(prefix)`, and HOLDS
// the socket via `__rove_next` with NO webhook.send. The ONLY thing that
// can resume this parked continuation is a kv write under the watched
// prefix landing at a write_version strictly greater than the baseline.
//
// Proves the on.kv path end to end:
//   kv.get (baseline) + on.kv -> StreamWakes{read_version,kv_prefixes}
//   -> broadcastKvWake(write_version)
//   -> matchEventsToWakes (write_version > read_version) -> pending_wakes
//   -> sweepParkedContinuations (kv-due) -> resumeContinuation(wake)
//   -> onWake -> resolveParked flushes to the still-open socket.
//
// The held client request blocks until a SECOND request writes
// `<prefix>flag`, then returns "woke:<value>".
export default function () {
    const req = request.body ? JSON.parse(request.body) : {};
    const prefix = req.prefix || "onkv/";
    // Read the watched key so read_version baselines AFTER this read —
    // only a write newer than what we just saw should wake us.
    kv.get(prefix + "flag");
    on.kv(prefix, { to: "onWake" });
    return next({ prefix });
}

// Resumed by a kv match. An `on.*` wake carries no callee outcome, so
// `onWake(ctx)` runs with just the parked ctx; it re-reads authoritative
// kv state ("go look" edge wake) and returns a terminal flushed to the
// held socket, completing the one synchronous request.
export function onWake(ctx) {
    const v = kv.get(ctx.prefix + "flag");
    return "woke:" + (v ?? "none");
}
