// Streaming-handlers Phase 2b-ii — multi-frame timer-wake exerciser.
// The handler returns `__rove_stream({...})` with a single SSE
// `:heartbeat\n\n` chunk and a `waitFor.timer.intervalMs` of 200ms.
// The runtime ships the chunk, parks the chain, then re-invokes the
// handler every 200ms (`request.activation.kind === "timer"`) which
// emits another `:heartbeat\n\n`. The smoke (scripts/streaming_heartbeat_smoke.py)
// opens the stream, reads at least three heartbeats over ~700ms,
// then closes — verifying the chunked-DATA + timer-wake lifecycle
// end-to-end.
//
// The connection has NO held handle — the chain IS the connection
// by construction (project-connection-actor-unified-trigger). The
// platform decides when the stream ends; right now that's either:
//   - client disconnect (h2 reports the entity through to
//     `response_out`, `cleanupResponses` reaps the cell), or
//   - the per-stream activation cap (MAX_STREAM_ACTIVATIONS).
export default function () {
    return __rove_stream({
        status: 200,
        headers: {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
        },
        write: [
            ":heartbeat\n\n",
        ],
        waitFor: { timer: { intervalMs: 200 } },
    });
}
