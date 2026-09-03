// The promise flow's settle verbs over the chain fold (rove#929 S4):
// hold → settle → terminal, all on one folded request arena.
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });

// (1) await after.ms: hold with a pending timer; the settle advances the
// clock to the armed interval; the terminal carries the post-await head,
// the kept local, and the same request.
const held = s.hold({ method: "POST", path: "/p", body: { ms: 250, tag: "a" } });
expect(held.disposition).toBe("held");
expect(held.pending.length).toBe(1);
expect(held.pending[0].kind).toBe("timer");
expect(held).toHaveWritten("before/a");
const done = held.timer();
expect(done.disposition).toBe("terminal");
expect(done.status).toBe(201);
expect(done.body).toBe("woke:a:kept:/p");
expect(done).toHaveWritten("after/a");
expect(done.kv("before/a")).not.toBe(null); // the chain-wide kv fold

// (2) two awaits re-hold the same chain: settle → held again → settle → done.
const h2 = s.hold({ method: "POST", path: "/p", body: { ms: 100, tag: "b", twice: true } });
const mid = h2.timer();
expect(mid.disposition).toBe("held");
expect(mid.pending[0].kind).toBe("timer");
const end = mid.timer();
expect(end.status).toBe(201);
expect(end.body).toBe("woke:b:kept:/p");

// (3) a throw after the await: the outer rejects → 500, that hop's writes
// rolled back (prod's handler-threw semantics on a resume).
const h3 = s.hold({ method: "POST", path: "/p", body: { ms: 50, tag: "c", throwAfter: true } });
const boom = h3.timer();
expect(boom.status).toBe(500);
expect(boom.ok).toBe(false);
expect(boom.body).toMatch(/boom:c/);
expect(boom.kv("after/c")).toBe(null); // rolled back with the throw

// (4) the fork rule: settle consumes, a fork re-folds its prefix — two
// children of ONE held node both fold clean.
const p = s.hold({ method: "POST", path: "/p", body: { ms: 40, tag: "f" } });
const leg1 = p.timer();
const leg2 = p.timer();
expect(leg1.status).toBe(201);
expect(leg2.status).toBe(201);

// (5) await after.kv: kvWrite applies the change BEFORE the settle; the
// wake delivers the fired prefix, the handler re-reads the new value.
const sw = scenario({ entry: "watch.mjs", now: "2026-07-01T00:00:00Z" });
const watch = sw.hold({ method: "POST", path: "/w" });
expect(watch.disposition).toBe("held");
expect(watch.pending[0].kind).toBe("kv");
const fired = watch.kvWrite({ "watch/flag": "lit" });
expect(fired.status).toBe(201);
expect(JSON.parse(fired.body)).toEqual({ kind: "kv", prefix: "watch/", seen: "lit" });

// (6) await after.fetch — the Fetch-API shape (rove#930): the whole-body
// resolve hands the handle; `await r.text()` is a microtask (one hop).
const sf = scenario({ entry: "fetcher.mjs", now: "2026-07-01T00:00:00Z" });
const f = sf.hold({ method: "POST", path: "/f?url=" + encodeURIComponent("https://up.test/data") });
expect(f.disposition).toBe("held");
expect(f.pending[0].kind).toBe("fetch");
const got = f.fetch(/up\.test/).resolve({ status: 200, body: "0123456789" });
expect(got.status).toBe(201);
expect(JSON.parse(got.body)).toEqual({ status: 200, text: "0123456789", form: "function" });

// …and reject: the awaited promise rejects, the handler has no catch → 500.
const f2 = sf.hold({ method: "POST", path: "/f?url=" + encodeURIComponent("https://up.test/data") });
const rej = f2.fetch(/up\.test/).reject("upstream unreachable");
expect(rej.status).toBe(500);
expect(rej.body).toMatch(/upstream unreachable/);

// (7) the STREAMED path: settle at headers, then chunk hops, then done —
// `for await (const c of r.chunks)` consumes them in place.
const ss = scenario({ entry: "streamer.mjs", now: "2026-07-01T00:00:00Z" });
const s0 = ss.hold({ method: "POST", path: "/s?url=" + encodeURIComponent("https://up.test/stream") });
expect(s0.pending[0].kind).toBe("fetch");
const h = s0.fetch(/up\.test/).headers({ status: 200, headers: { "content-type": "text/event-stream" } });
expect(h.disposition).toBe("held"); // awaiting the first chunk pull
expect(h.pending.some((c) => c.kind === "fetch_chunk")).toBe(true);
const c1 = h.chunk("hello ");
expect(c1.disposition).toBe("held");
const c2 = c1.chunk("world");
const fin = c2.done();
expect(fin.disposition).toBe("terminal");
expect(fin.status).toBe(201);
expect(fin.body).toBe("hello world");
expect(fin.kv("chunks")).toBe("2");
expect(fin.kv("head")).toBe("200:text/event-stream");
