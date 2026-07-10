// Continuing a WS conversation past a fetch resume (docs/plans/sim-test-framework.md).
// A held WS handler issues an after.fetch mid-chain; resolving it once returned a
// plain Node, so `.receive(nextFrame)` hit the blob.receive driver and threw
// ("armed no blob.receive"). The fetch resume off a WS frame is now a WsNode bound
// to the same connection, so the conversation continues — the agent-loop shape.
import { scenario, expect } from "rewind:test";

const s = scenario({});
const ws = s.ws({ path: "/agent" });

// frame 1: "start" → issues the LLM fetch and holds
const f1 = ws.receive(JSON.stringify({ t: "start" }));
expect(f1.disposition).toBe("held");
expect(f1).toHaveFetched(/llm\.example/);

// resolve the fetch → onResult writes + re-holds, bumping the connection ctx
const r = f1.fetch(/llm\.example/).resolve({ status: 200, body: "{}" });
expect(r.disposition).toBe("held");
expect(r).toHaveWritten("ws/llm", { turn: 0, ok: true });
expect(r).toHaveSentFrame(/llm-done/);

// KEY: continue the conversation — the next frame runs onMessage on the SAME
// connection, seeing the resume's bumped ctx (turn 1) and its writes
const f2 = r.receive(JSON.stringify({ t: "next" }));
expect(f2).toHaveWritten("ws/frame2", { sawTurn: 1, t: "next" });
expect(f2).toHaveSentFrame(/frame2:turn1/);
expect(f2.kv("ws/llm")).toEqual({ turn: 0, ok: true }); // frame1+resume writes folded through

// and it can keep going — a third frame threads turn forward again
const f3 = f2.receive(JSON.stringify({ t: "again" }));
expect(f3).toHaveWritten("ws/frame2", { sawTurn: 1, t: "again" });
