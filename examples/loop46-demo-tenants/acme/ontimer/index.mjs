// on.timer connection-wake exerciser (handler-surface Phase 1).
//
// The inbound hop arms a connection timer with `on.timer(ms)` and
// HOLDS the socket via `__rove_next` (no response). It does NO
// webhook.send — so there is no send-callback binding; the ONLY thing
// that can resume this parked continuation is the timer wake.
// `sweepParkedContinuations` fires `onWake` after the interval and the
// terminal it returns flushes to the still-open client socket.
//
// Proves the on.timer path end to end:
//   on.timer -> StreamWakes -> sweepParkedContinuations(timer-due)
//   -> resumeContinuation(wake) -> onWake -> resolveParked.
//
// The single client request blocks for ~ms, then returns "woke:<tag>".
export default function () {
    const req = request.body ? JSON.parse(request.body) : {};
    on.timer(req.ms || 150);
    return next({ tag: req.tag || "t" });
}

// Resumed by the timer wake. The parked `next({ctx})` rides
// `request.ctx` (Endpoint A). Returning a value is terminal — flushed to
// the held socket, completing the one synchronous request.
export function onWake() {
    const ctx = request.ctx || {};
    return "woke:" + ctx.tag;
}
