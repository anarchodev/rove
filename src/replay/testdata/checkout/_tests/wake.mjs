// The DETACHED durable-wake family: a schedule/cron `target` fires as its own
// `durable_wake` activation, authored standalone via scenario().wake() (the
// durable_wake analogue of sendCallback) — NOT folded from a schedule() emitter,
// which would drag the whole scheduler queue/idempotency ladder into the test.
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });

// A one-shot schedule fires its target with the payload on request.ctx and the
// delivery metadata on request.activation. No `key` was armed → key reads null.
const fired = s.wake({ on: "jobs/reminder.mjs", ctx: { user: "ada" } });
expect(fired.ok).toBe(true);
expect(fired.body).toEqual({ ok: true, count: 1 });
expect(fired).toHaveWritten("reminder/ada", { count: 1, key: null, firedFrom: "sched_test" });
// It re-armed itself for the next occurrence (the recurring-reminder recipe).
expect(fired).toHaveScheduled("jobs/reminder");

// An idempotency key surfaces on request.activation.key; a custom id + fire
// time thread through too (scheduledAtNs on the metadata bag).
const keyed = s.wake({
  on: "jobs/reminder.mjs",
  ctx: { user: "bob", count: 2 },
  id: "sched_bob",
  key: "reminder/bob",
  scheduledAtNs: 1782000000000000000,
});
expect(keyed).toHaveWritten("reminder/bob", {
  count: 3, key: "reminder/bob", firedFrom: "sched_bob", scheduledAtNs: 1782000000000000000,
});
// count reached 3 → no re-arm this time.
expect(keyed).not.toHaveScheduled("jobs/reminder");

// A cron occurrence is delivered to the customer target the SAME way (the baked
// cron_tick is a __system re-dispatcher the customer never sees), so one
// wake(...) models one occurrence.
const occurrence = s.wake({ on: "jobs/reminder.mjs", ctx: { user: "cron", count: 0 }, key: "cron/reminder" });
expect(occurrence.body).toEqual({ ok: true, count: 1 });
expect(occurrence).toHaveWritten("reminder/cron", { key: "cron/reminder" });
