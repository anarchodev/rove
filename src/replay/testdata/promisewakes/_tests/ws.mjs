// The iterable WS flow: default runs once at open, frames settle the
// request.messages pulls, close ends the loop (rove#929 S4).
import { scenario, expect } from "rewind:test";

const s = scenario({ entry: "ws.mjs", now: "2026-07-01T00:00:00Z" });

const open = s.ws({ path: "/live" }).open();
expect(open.disposition).toBe("held");
expect(open.pending[0].kind).toBe("input");

const f1 = open.frame("alpha");
expect(f1.disposition).toBe("held");
expect(f1.frames).toEqual(["echo:1:alpha"]); // the loop's local survived
const f2 = f1.frame("beta");
expect(f2.frames).toEqual(["echo:2:beta"]);

const closed = f2.close();
expect(closed.disposition).toBe("terminal");
expect(closed.kv("ws/count")).toBe("2");
