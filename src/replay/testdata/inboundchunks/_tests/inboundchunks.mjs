// Streaming inbound body → per-chunk onChunk folds (#37): ctx threads
// chunk-to-chunk, kv accumulates, request.done ends the stream.
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });
const r = s.inboundChunks({ method: "POST", path: "/upload" }, ["Hello, ", "streaming ", "world!"]);

expect(r.disposition).toBe("terminal");
expect(r.body).toEqual({ assembled: "Hello, streaming world!", chunks: 3, offset: 17, bytes: 23 });
expect(r.kv("upload/buf")).toBe("Hello, streaming world!");
expect(r.kv("upload/lastSeq")).toBe("2");

// ── binary chunks round-trip on request.bytes (the bodyB64 world field) ──
const b = s.inboundChunks(
  { method: "POST", path: "/upload" },
  [new Uint8Array([1, 2, 3, 4]), new Uint8Array([5, 6]), new Uint8Array([7, 8, 9])],
  { binary: true },
);
expect(b.disposition).toBe("terminal");
expect(b.body.bytes).toBe(9);       // 4 + 2 + 3 raw bytes accumulated
expect(b.body.chunks).toBe(3);      // ctx threaded across the three fires
expect(b.body.offset).toBe(6);      // wire bytes before the last chunk (4 + 2)
