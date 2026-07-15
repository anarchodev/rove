// Connection-scoped effects on a terminal or connectionless activation are
// DROPPED, exactly as prod drops them: `after.ms`/`after.kv` arm —
// and `after.fetch` binds — only when the activation ends held; `stream.write`
// needs a live socket. The sim tags the discarded entries `dropped`, excludes
// them from matchers/folds, and warns — while the durable verbs
// (`webhook.send`, ordinary kv writes) survive untouched.
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });

// ── terminal return: every connection-scoped effect is discarded ──
const t = s.inbound({ method: "POST", path: "/", body: { mode: "reply" } });
expect(t.status).toBe(200);
expect(t.disposition).toBe("terminal");
expect(t).not.toHaveFetched(/api\.example\.test/); // bound fetch never issued
expect(t).not.toHaveScheduled("onTick"); // after.ms wake never armed
expect(t).not.toHaveScheduled("onJob"); // after.kv wake never armed
expect(t).toHaveWritten("visited", "1"); // the ordinary write commits
// …and each drop is called out with a warn entry naming the effect.
const warns = t.effects
  .filter((e) => e.kind === "log" && e.level === "warn")
  .map((e) => e.message);
expect(warns.some((m) => m.includes("after.fetch") && m.includes("api.example.test"))).toBe(true);
expect(warns.some((m) => m.includes("after.ms(5000)"))).toBe(true);
expect(warns.some((m) => m.includes("after.kv") && m.includes("jobs/"))).toBe(true);
// The discarded entries stay on the log for debugging, tagged.
expect(t.effects.some((e) => e.kind === "fetch" && e.dropped === true)).toBe(true);

// ── the same handler holding the socket keeps everything armed ──
const h = s.inbound({ method: "POST", path: "/", body: { mode: "hold" } });
expect(h.disposition).toBe("held");
expect(h).toHaveFetched(/api\.example\.test/);
expect(h).toHaveScheduled("onTick");
expect(h).toHaveScheduled("onJob");
// The resume fold still works on the held chain.
const r = h.fetch(/poll/).resolve({ status: 200, body: "{}" });
expect(r.body).toEqual({ polled: 200 });

// ── connectionless (durable_wake): after.* and stream.write are inert,
//    the durable verbs fire ──
const w = s.wake({ on: "jobs/wake.mjs" });
expect(w).not.toHaveScheduled("onTick"); // after.ms: no connection
expect(w.frames.length).toBe(0); // stream.write: no socket
expect(w).toHaveSent("webhook", { url: "https://hooks.example.test/notify" });
expect(w).toHaveFetched(/hooks\.example\.test/); // webhook's UNBOUND fetch fires
expect(w).toHaveWritten("woke", "1");
const wWarns = w.effects
  .filter((e) => e.kind === "log" && e.level === "warn")
  .map((e) => e.message);
expect(wWarns.some((m) => m.includes("stream.write") && m.includes("durable_wake"))).toBe(true);
expect(wWarns.some((m) => m.includes("after.ms(1000)"))).toBe(true);
