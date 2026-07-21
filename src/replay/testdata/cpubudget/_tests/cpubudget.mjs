// A runaway handler completes in BOUNDED time with prod's 504 outcome (#48).
import { scenario, expect } from "rewind:test";
const r = scenario({ now: "2026-07-01T00:00:00Z" }).inbound({ method: "GET", path: "/" });
expect(r.status).toBe(504);
expect(r.body).toBe("handler exceeded cpu budget");
expect(r.ok).toBe(false);
expect(r.disposition).toBe("terminal");
