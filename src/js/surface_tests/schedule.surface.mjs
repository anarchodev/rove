// schedule — the durable one-shot timer, pure composition over kv +
// crypto (rows: _sched/by_id/{id} + _sched/by_time/{when:020}/{id}).
// Fully observable in-process.
const PAD = "00000000000000000000";
function byTimeKey(whenNs, id) {
  const d = String(whenNs);
  return "_sched/by_time/" + PAD.slice(d.length) + d + "/" + id;
}

export default function () {
  check("schedule()", () => {
    // {in: ms} — fire time rounds UP to the 1 s tick.
    const id = schedule({ in: 5000 }, "jobs/poll", { user: "ada" });
    ok(typeof id === "string" && id.length === 36, "random uuid id: " + id);
    const rec = JSON.parse(kv.get("_sched/by_id/" + id));
    eq(rec.target, "jobs/poll");
    eq(rec.msg, { user: "ada" });
    ok(BigInt(rec.when_ns) % 1000000000n === 0n, "not tick-rounded: " + rec.when_ns);
    ok(kv.get(byTimeKey(rec.when_ns, id)) !== null, "by_time index row missing");

    // {at: bigint ns} — exact composition; rounds up to the next tick.
    const at = schedule({ at: 1500000001n }, "jobs/at");
    eq(JSON.parse(kv.get("_sched/by_id/" + at)).when_ns, "2000000000");

    // Idempotency key: deterministic id == base64url(sha256(key));
    // re-arm moves the fire time and drops the stale by_time row.
    const k1 = schedule({ in: "1h" }, "jobs/expire", null, { key: "expire/7" });
    eq(k1, base64url.encode(hex.decode(crypto.sha256("expire/7"))));
    const w1 = JSON.parse(kv.get("_sched/by_id/" + k1)).when_ns;
    const k2 = schedule({ in: "2h" }, "jobs/expire", null, { key: "expire/7" });
    eq(k1, k2);
    const w2 = JSON.parse(kv.get("_sched/by_id/" + k2)).when_ns;
    ok(w1 !== w2, "re-arm did not move the fire time");
    ok(kv.get(byTimeKey(w1, k1)) === null, "stale by_time row survived re-arm");
    ok(kv.get(byTimeKey(w2, k1)) !== null, "moved by_time row missing");

    // Fail-loud contract.
    throws(() => schedule({}, "jobs/x"), /when must be \{ at \} or \{ in \}/);
    throws(() => schedule({ in: 5000 }, ""), /target must be a non-empty module specifier/);
    throws(() => schedule({ at: {} }, "jobs/x"), /unrecognized time input/);
    throws(() => schedule({ in: "sooner" }, "jobs/x"), /not a duration: sooner/);
    throws(() => schedule({ in: 0 }, "jobs/x", "y".repeat(17000)), /SCHED_MAX_MSG_BYTES/);
  });

  check("schedule.get", () => {
    const id = schedule({ in: "1h" }, "jobs/expire2", { lease: 7 }, { key: "lease/7" });
    const s = schedule.get(id);
    eq(s.id, id);
    eq(s.target, "jobs/expire2");
    eq(s.key, "lease/7");
    ok(typeof s.whenNs === "bigint" && s.whenNs > 0n, "whenNs not a bigint");
    eq(schedule.get("no-such-id"), null);
    eq(schedule.get(""), null);
    // Keyless schedule reports key: null.
    eq(schedule.get(schedule({ in: 0 }, "jobs/asap")).key, null);
  });

  check("schedule.cancel", () => {
    const id = schedule({ in: "1h" }, "jobs/expire3");
    const rec = JSON.parse(kv.get("_sched/by_id/" + id));
    eq(schedule.cancel(id), true);
    eq(schedule.get(id), null);
    ok(kv.get(byTimeKey(rec.when_ns, id)) === null, "by_time row survived cancel");
    eq(schedule.cancel(id), false); // idempotent
    eq(schedule.cancel("unknown"), false);
    eq(schedule.cancel(""), false);
  });

  return done();
}
