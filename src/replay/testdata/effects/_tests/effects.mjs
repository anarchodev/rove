// Effect-global unification prototype (docs/plans/sim-test-framework.md
// "what's left" → the clean effect-global unification). With realEffects: true
// the sim runs the REAL webhook.send / schedule shims from its base, so those
// verbs decompose to primitives in the effect log. This test proves TWO things:
//   1. the readable matchers (toHaveSent/toHaveScheduled/toHaveFetched) read the
//      SAME as in stub mode — the customer-facing API is unchanged; and
//   2. under the hood the durable primitives that actually replicate through
//      raft (the _send/owed marker + the _sched rows + the fetch) are really
//      what the verbs produced.
import { scenario, expect } from "rewind:test";

const s = scenario({ realEffects: true, now: "2026-07-01T00:00:00Z" });
const r = s.inbound({ method: "POST", path: "/signup", body: { user: "ada" } });

expect(r.ok).toBe(true);

// ── the readable matchers still read the same, now over the primitive log ──
expect(r).toHaveSent("webhook", { url: "https://hooks.example.com/notify" });
expect(r).toHaveScheduled("jobs/followup");            // the explicit one-shot
expect(r).toHaveFetched(/hooks\.example\.com/);        // webhook fired the fetch
expect(r).toHaveWritten("signup/ada", "1");            // the handler's own write

// ── the decomposition really happened: the durable primitives are in the log ──
const writes = r.effects.filter((e) => e.kind === "write");
const sendMarkers = writes.filter((e) => e.key.startsWith("_send/owed/"));
const schedRows = writes.filter((e) => e.key.startsWith("_sched/by_id/"));
expect(sendMarkers.length).toBe(1);   // webhook.send wrote exactly one marker
// two _sched/by_id rows: the webhook watchdog + the explicit schedule().
expect(schedRows.length).toBe(2);

// The marker carries the real durable send state (url/method/on_result/context).
const marker = JSON.parse(sendMarkers[0].value);
expect(marker.on_result).toBe("hooks/onNotified");
expect(marker.context).toEqual({ user: "ada" });
