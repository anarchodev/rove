// Offline cross-check of ws_wake_smoke_v2.py: a WS onMessage arms an after.kv /
// after.ms wake and parks; the wake resumes onWake / onTimer over the same
// socket. The WS fold composed with the wake folds. Agreement proves it faithful.
import { scenario, expect } from "rewind:test";

const s = scenario({ entry: "index.mjs" });
const ws = s.ws({ path: "/" });

// watch:<prefix> → arm after.kv, reply "watching:<prefix>", hold.
const w = ws.receive("watch:feed/");
expect(w.disposition).toBe("held");
expect(w).toHaveSentFrame("watching:feed/");

// A kv write under the prefix fires onWake. The resume surfaces the FIRED
// PREFIX on request.activation.wakes[] (issue #8 — never the matched key);
// the handler re-scans kv under it and replies with the last value.
const woke = w.wakeKv({ "feed/1": "hello" });
expect(woke).toHaveSentFrame("woke:hello|fired:feed/");

// timer → arm after.ms, reply "armed"; the timer elapsing resumes onTimer.
const t = ws.receive("timer");
expect(t).toHaveSentFrame("armed");
const ticked = t.clock.advance("500ms").fire();
expect(ticked).toHaveSentFrame("tick");
