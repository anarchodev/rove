// Offline cross-check of ws_fetch_smoke_v2.py: a WS onMessage issues after.fetch
// and the result resumes onUpstream over the SAME socket — the WS fold composed
// with the fetch fold. Agreement with the smoke proves the composition faithful.
import { scenario, expect } from "rewind:test";

const s = scenario({ entry: "index.mjs" });
const ws = s.ws({ path: "/" });

// Control: a plain frame echoes.
const m1 = ws.receive("hello");
expect(m1).toHaveSentFrame("echo:hello");

// A "fetch:<url>" frame: onMessage binds after.fetch to the held chain and parks.
const fm = ws.receive("fetch:http://stub/data");
expect(fm.disposition).toBe("held");
expect(fm).toHaveFetched(/stub/);

// The fetch result resumes onUpstream over the same socket → a "fetched:…" frame.
const up = fm.fetch(/stub/).resolve({ status: 200, body: "hello-upstream" });
expect(up).toHaveSentFrame("fetched:200:hello-upstream");
