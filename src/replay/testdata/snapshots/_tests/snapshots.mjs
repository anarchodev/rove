// Snapshot sidecars: an unnamed toMatchSnapshot is keyed by its CALL SITE
// (file:line), stable under reordering; stale entries are pruned under --update
// and warned about otherwise (#55).
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });
const r = s.inbound({ method: "POST", path: "/x", body: { n: 7 } });

expect(r).toMatchSnapshot();             // auto-named: snapshots.mjs:<thisline>
expect(r).toMatchSnapshot("named-echo"); // explicit name
