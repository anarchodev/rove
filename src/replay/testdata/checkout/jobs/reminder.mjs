import schedule from "@rewind/schedule";
// A DURABLE scheduled target — fires as its own connectionless `durable_wake`
// activation (no held socket, survives crashes/leader change), NOT folded from
// a `schedule()` emitter. Tested standalone via scenario().wake(), the same way
// hooks/onDelivered.mjs is tested via sendCallback().
//
// It reads its payload from `request.ctx` (the one-ctx rule — a schedule target
// reads its threaded value in the same slot every callback does) and delivery
// metadata from `request.activation.{id, key, scheduledAtNs}`; then re-arms
// itself under a stable idempotency key — the self-rescheduling recurring
// reminder recipe.
export default function ({ kv }) {
  const a = request.activation;
  const { user, count = 0 } = request.ctx || {};
  const n = count + 1;
  kv.set("reminder/" + user, JSON.stringify({
    count: n,
    key: a.key || null,
    firedFrom: a.id,
    scheduledAtNs: a.scheduledAtNs,
  }));
  // Re-arm for the next reminder under a stable key (last-write-wins keeps
  // exactly one outstanding entry) until three have fired.
  if (n < 3) {
    schedule({ in: "1d" }, "jobs/reminder", { user, count: n }, { key: "reminder/" + user });
  }
  return { ok: true, count: n };
}

// A NAMED export — the target of a `schedule(..., "jobs/reminder.mjs.weekly")`.
// Writes a distinct marker so a test can prove the method ran
// rather than `default`.
export function weekly({ kv }) {
  const a = request.activation;
  const { user } = request.ctx || {};
  kv.set("weekly/" + user, JSON.stringify({ export: "weekly", firedFrom: a.id }));
  return { ok: true, export: "weekly" };
}
