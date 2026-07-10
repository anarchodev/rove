// A WS frame's data is readable as request.text (docs/plans/sim-test-framework.md).
// The sim once put the frame ONLY on request.activation.data and left the payload
// empty, so request.text was "" and browser.message() (which reads request.text)
// returned null — every request.text-based WS handler (the agent-SDK pattern)
// no-op'd. Now ws.receive(data) delivers the frame as the payload too.
import { scenario, expect } from "rewind:test";

const s = scenario({});

// ── text frame → request.text is the frame; browser.message() parses it ──
const m = s.ws({ path: "/agent" }).receive(JSON.stringify({ t: "hello", goal: "buy milk" }));
expect(m.disposition).toBe("held");
expect(m).toHaveWritten("ws/last", { t: "hello", goal: "buy milk", n: 1 });
// the handler echoed request.text back verbatim
expect(m).toHaveSentFrame(/"echoedText":"\{\\"t\\":\\"hello\\"/);

// ── the frame is still on activation.data too (handlers read either) ──
const m2 = s.ws({ path: "/agent" }).receive(JSON.stringify({ t: "hi" }));
expect(m2).toHaveWritten("ws/last", { t: "hi" });

// ── binary frame → request.bytes is the decoded bytes ──
const bin = s.ws({ path: "/agent" }).receive(new Uint8Array([1, 2, 3, 4, 5]), { binary: true });
expect(bin.disposition).toBe("held");
expect(bin.kv("ws/bytes")).toBe("5");   // request.bytes.length === 5
expect(bin).toHaveSentFrame(/bin:5/);
