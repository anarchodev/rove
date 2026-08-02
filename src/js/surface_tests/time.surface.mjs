// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// time — the pure time-coercion helpers shared by cron / schedule /
// webhook.send. Fully computable; pin real values.
export default function () {
  check("time.toNs", () => {
    ok(time.toNs(null) === 0n, "null → 0n (fire ASAP)");
    ok(time.toNs(123n) === 123n, "bigint passthrough");
    ok(time.toNs(1000) === 1000000000n, "number is ms-since-epoch");
    ok(time.toNs(new Date(2000)) === 2000000000n, "Date");
    ok(
      time.toNs("2026-06-01T03:00:00Z") === BigInt(Date.parse("2026-06-01T03:00:00Z")) * 1000000n,
      "ISO-8601",
    );
    const before = BigInt(Date.now()) * 1000000n;
    ok(time.toNs("2h") >= before + 7200000n * 1000000n, "duration is relative to now");
    throws(() => time.toNs({}), /unrecognized time input/);
    throws(() => time.toNs(Infinity), /must be finite/);
  });

  check("time.parseDuration", () => {
    eq(time.parseDuration("30s"), 30000);
    eq(time.parseDuration("5m"), 300000);
    eq(time.parseDuration("2h"), 7200000);
    eq(time.parseDuration("1d"), 86400000);
    eq(time.parseDuration("1w"), 604800000);
    eq(time.parseDuration("soon"), null); // not a duration → null (callers fall back to ISO)
    eq(time.parseDuration(90), null);
  });

  check("time.inToNs", () => {
    const before = BigInt(Date.now()) * 1000000n;
    const at = time.inToNs("30m");
    ok(at >= before + 1800000n * 1000000n && at < before + 1801000n * 1000000n, "duration delay: now + 30m");
    const at2 = time.inToNs(5000);
    ok(at2 >= before + 5000n * 1000000n && at2 < before + 6000n * 1000000n, "number is a ms delay from now");
    throws(() => time.inToNs("later"), /not a duration: later/);
    throws(() => time.inToNs({}), /number \(ms delay\) or a duration string/);
    throws(() => time.inToNs(Infinity), /must be finite/);
  });

  return done();
}
