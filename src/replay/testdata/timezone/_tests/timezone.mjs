// Local-time Date methods run in UTC, matching production (#53). The build
// runs this fixture under `TZ=Asia/Tokyo` (build.zig, the test_dirs loop) —
// on a UTC host these assertions pass with or without the pin, so the
// non-UTC host IS the test. Without the pin getHours reads 12, not 3.
//
// Two mechanisms hold the invariant and either alone suffices: the CLI pins
// the process (`setenv TZ=UTC` + tzset, src/cli/rewind.zig) and arenajs pins
// the engine (JS_SetTimezoneUTC at reactor construction, which also covers
// the browser replay arena where the env route is a no-op).
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });
const r = s.inbound({ method: "GET", path: "/" });

expect(r.body.hours).toBe(3);    // 03:30 UTC — a host TZ would shift the hour
expect(r.body.minutes).toBe(30);
expect(r.body.offset).toBe(0);   // UTC has no offset
expect(r.body.iso).toBe("2026-07-01T03:30:00.000Z");
