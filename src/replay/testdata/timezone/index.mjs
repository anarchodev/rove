// Handler time is UTC, matching production (issue #53). Date.now()/new Date()
// are pinned on both substrates, but LOCAL-time methods (getHours,
// getTimezoneOffset, toString) go through libc localtime_r, which reads the
// process TZ. The CLI pins TZ=UTC so these agree with prod (UTC servers)
// regardless of the developer's host timezone.
export default function () {
  const ms = Date.UTC(2026, 6, 1, 3, 30, 0); // 2026-07-01T03:30:00Z
  const d = new Date(ms);
  return {
    hours: d.getHours(),               // UTC → 3 (host-TZ would shift this)
    minutes: d.getMinutes(),           // 30
    offset: d.getTimezoneOffset(),     // UTC → 0
    iso: d.toISOString(),              // always UTC (Z), a control
  };
}
