import { scenario, expect } from "rewind:test";
const s = scenario({ now: "2026-07-01T00:00:00Z" });
const r = s.inbound({ method: "GET", path: "/" });
expect(r.body.tag).toBe("clamped-to-app-root");
