// Local-time Date methods run in UTC, matching production (#53). The assertions
// hold regardless of the host machine's TZ — verify by running the suite under
// `TZ=Asia/Tokyo zig build rewind-test-smoke` (getHours would be 12, not 3,
// without the pin).
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });
const r = s.inbound({ method: "GET", path: "/" });

expect(r.body.hours).toBe(3);    // 03:30 UTC — a host TZ would shift the hour
expect(r.body.minutes).toBe(30);
expect(r.body.offset).toBe(0);   // UTC has no offset
expect(r.body.iso).toBe("2026-07-01T03:30:00.000Z");
