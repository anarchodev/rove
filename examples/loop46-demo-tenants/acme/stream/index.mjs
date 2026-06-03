// Streaming-handlers — degenerate single-shot `stream.*` exerciser
// (handler-surface Phase 2). Writes three SSE frames via the
// `stream.write()` effect and closes with a terminal return. The frames
// ship as one concatenated body (the terminal-close path prepends the
// buffered chunks to the terminal body). The smoke verifies all three
// chunks land in the body and the header is set.
export default function () {
    response.status = 200;
    response.headers = {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
    };
    stream.write("event: tick\ndata: alpha\n\n");
    stream.write("event: tick\ndata: bravo\n\n");
    stream.write("event: tick\ndata: charlie\n\n");
    return ""; // close
}
