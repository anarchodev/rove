// cron — recurring durable schedule + the pure time/expr helpers it
// carries as statics. The helpers are fully computable; pin real values.
export default function () {
  check("cron.parseDuration", () => {
    eq(cron.parseDuration("30s"), 30000);
    eq(cron.parseDuration("5m"), 300000);
    eq(cron.parseDuration("2h"), 7200000);
    eq(cron.parseDuration("1d"), 86400000);
    eq(cron.parseDuration("1w"), 604800000);
    eq(cron.parseDuration("soon"), null);   // not a duration → null (callers fall back to ISO)
    eq(cron.parseDuration(90), null);
  });

  check("cron.toFireAtNs", () => {
    ok(cron.toFireAtNs(null) === 0n, "null → 0n (fire ASAP)");
    ok(cron.toFireAtNs(123n) === 123n, "bigint passthrough");
    ok(cron.toFireAtNs(1000) === 1000000000n, "number is ms-since-epoch");
    ok(cron.toFireAtNs(new Date(2000)) === 2000000000n, "Date");
    ok(cron.toFireAtNs("2026-06-01T03:00:00Z") === BigInt(Date.parse("2026-06-01T03:00:00Z")) * 1000000n, "ISO-8601");
    const before = BigInt(Date.now()) * 1000000n;
    ok(cron.toFireAtNs("2h") >= before + 7200000n * 1000000n, "duration is relative to now");
    throws(() => cron.toFireAtNs({}), /unrecognized time input/);
  });

  check("cron.fromNow", () => {
    const before = BigInt(Date.now()) * 1000000n;
    const at = cron.fromNow("30m");
    ok(at >= before + 1800000n * 1000000n && at < before + 1801000n * 1000000n, "now + 30m");
    throws(() => cron.fromNow("later"), /not a duration: later/);
  });

  check("cron.next", () => {
    // Pinned base: 2026-01-01 04:30 UTC (a Thursday).
    const base = Date.parse("2026-01-01T04:30:00Z");
    ok(cron.next("0 3 * * *", base) === BigInt(Date.parse("2026-01-02T03:00:00Z")) * 1000000n,
       "daily 03:00 → tomorrow (today's slot passed)");
    ok(cron.next("*/15 * * * *", base) === BigInt(Date.parse("2026-01-01T04:45:00Z")) * 1000000n,
       "every 15 min → next quarter-hour");
    ok(cron.next("0 9 * * 1-5", base) === BigInt(Date.parse("2026-01-01T09:00:00Z")) * 1000000n,
       "weekday 09:00 → same day (Thursday)");
    ok(cron.next("30 4 * * *", base) === BigInt(Date.parse("2026-01-02T04:30:00Z")) * 1000000n,
       "exact-now slot rounds to the NEXT minute, so next day");
    throws(() => cron.next("0 3 * *"), /expected 5 fields/);
    throws(() => cron.next("61 * * * *"), /bad range in field/);
    throws(() => cron.next("*/0 * * * *"), /bad step in field/);
  });

  check("cron.dailyAt", () => {
    const ns = cron.dailyAt(3, 0);
    const d = new Date(Number(ns / 1000000n));
    ok(d.getUTCHours() === 3 && d.getUTCMinutes() === 0, "slot is 03:00 UTC");
    ok(ns > BigInt(Date.now()) * 1000000n, "in the future");
    throws(() => cron.dailyAt(24, 0), /hour must be 0\.\.23/);
    throws(() => cron.dailyAt(3, 60), /minute must be 0\.\.59/);
  });

  check("cron.weeklyAt", () => {
    const ns = cron.weeklyAt(1, 9, 0);
    const d = new Date(Number(ns / 1000000n));
    ok(d.getUTCDay() === 1 && d.getUTCHours() === 9, "next Monday 09:00 UTC");
    ok(ns > BigInt(Date.now()) * 1000000n, "in the future");
    throws(() => cron.weeklyAt(7, 0, 0), /dayOfWeek must be 0\.\.6/);
  });

  check("cron.hourly", () => {
    const ns = cron.hourly();
    const d = new Date(Number(ns / 1000000n));
    ok(d.getUTCMinutes() === 0 && d.getUTCSeconds() === 0, "top of the hour");
    ok(ns > BigInt(Date.now()) * 1000000n, "in the future");
  });

  check("cron()", () => {
    // Registers ONE durable wake keyed on (spec, target) → idempotent.
    const id = cron("0 3 * * *", "jobs/cleanup", { keep: 30 });
    eq(id, base64url.encode(hex.decode(crypto.sha256("cron/0 3 * * * jobs/cleanup"))));
    const s = schedule.get(id);
    eq(s.target, "__system/cron_tick");
    eq(s.key, "cron/0 3 * * * jobs/cleanup");
    const rec = JSON.parse(kv.get("_sched/by_id/" + id));
    eq(rec.msg, { spec: "0 3 * * *", target: "jobs/cleanup", ctx: { keep: 30 } });
    eq(cron("0 3 * * *", "jobs/cleanup"), id); // re-register: same id
    throws(() => cron(7, "jobs/x"), /spec must be a crontab string/);
    throws(() => cron("0 3 * * *", ""), /target must be a non-empty module specifier/);
    throws(() => cron("bad spec", "jobs/x"), /expected 5 fields/); // validated at registration
  });

  return done();
}
