// Offline cross-check of ws_worker_smoke_v2.py: the SAME deployed handler
// (wsworker/index.mjs, shared with the smoke via _src), driven through the WS
// held-socket fold. Agreement with the smoke's raw-RFC-6455 round trip proves
// the fold faithful for text/binary echo, kv read/write threading across frames,
// terminal close, and onDisconnect.
import { scenario, expect } from "rewind:test";

const s = scenario({ entry: "index.mjs" });
const ws = s.ws({ path: "/" });

// 1. text frame → echo reply, socket held.
const m1 = ws.receive("hi");
expect(m1.disposition).toBe("held");
expect(m1).toHaveSentFrame("echo:hi");

// 3. persist: durable frame → kv.set + reply (the write path).
const m2 = m1.receive("persist:v1");
expect(m2).toHaveSentFrame("persisted:v1");
expect(m2).toHaveWritten("ws/last", "v1");

// 4. read: kv round-trip inside onMessage sees the folded write.
const m3 = m2.receive("read:anything");
expect(m3).toHaveSentFrame("value:v1");

// 2. binary frame → bytes echoed back verbatim (NULs + high byte survive).
const bytes = new Uint8Array([0, 1, 2, 0, 255]);
const m4 = m3.receive(bytes, { binary: true });
expect(m4.frames[0]).toBe(String.fromCharCode(0, 1, 2, 0, 255));

// 6. tag then disconnect → onDisconnect reads the tag and stamps ws/disc_<tag>.
const tagged = m4.receive("tag:alice");
expect(tagged).toHaveSentFrame("tagged:alice");
const disc = tagged.disconnect();
expect(disc).toHaveWritten("ws/disc_alice", "1");

// 5. bye → terminal return (server sends Close), final frame ships first.
const closed = m1.receive("bye");
expect(closed).toHaveSentFrame("closing");
expect(closed.disposition).toBe("terminal");
