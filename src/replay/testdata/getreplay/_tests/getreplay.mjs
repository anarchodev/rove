// Engine-pinned per-chain identity (docs/architecture/replay-and-sim.md). A handler
// branch keyed on request.tenant + request.correlation_id (browser.getReplay) was
// undriveable — the sim never set either, so getReplay always returned false. Now
// scenario({tenant, correlationId}) supplies them and every activation (WS frame,
// fetch resume) inherits the chain's identity, so BOTH branches are reachable.
import { scenario, expect } from "rewind:test";

// ── issued branch: tenant + correlation_id present → getReplay fetches ──
const s = scenario({ tenant: "acme", correlationId: "corr-1", now: "2026-07-01T00:00:00Z" });
const frame = s.ws({ path: "/agent" }).receive("go");
expect(frame.disposition).toBe("held"); // onMessage held for the bound replay fetch
expect(frame).toHaveFetched(/rewind-logs\.internal/);

// the bound fetch scopes to THIS tenant + correlation id (both threaded onto the
// WS frame's request from the scenario)
const fetched = frame.effects.find((e) => e.kind === "fetch");
expect(fetched.url).toContain("/v1/acme/list");
expect(fetched.url).toContain("tag._corr=corr-1");

// resolving the replay fetch bounces into onReplay (the correlation id inherited
// by the resume too) → the row is written
const replayed = frame.fetch(/rewind-logs\.internal/).resolve({ status: 200, body: '{"records":[]}' });
expect(replayed).toHaveWritten("replay/log", { ok: true });
expect(replayed).toHaveSentFrame(/replay ready/);

// ── unavailable branch: no correlation_id → getReplay can't issue ──
const s2 = scenario({ tenant: "acme", now: "2026-07-01T00:00:00Z" });
const frame2 = s2.ws({ path: "/agent" }).receive("go");
expect(frame2.disposition).toBe("terminal");   // took the unavailable path
expect(frame2).not.toHaveFetched(/rewind-logs/); // armed NO fetch
expect(frame2).toHaveSentFrame(/replay unavailable/);
