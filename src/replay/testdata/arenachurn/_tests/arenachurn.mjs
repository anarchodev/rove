// GC arena ≡ prod's effective ceiling (issue #70). A churny-but-legal handler
// whose cumulative allocation dwarfs the 16 MiB request arena, but whose peak
// live set is tiny, completes offline because the sim runs GC always — the
// same outcome prod produces via its bump→GC retry. Before #70 the sim ran a
// bump arena and this OOM'd offline while passing in production (a false fail).
import { scenario, expect } from "rewind:test";

const r = scenario({}).inbound({ path: "/" });
expect(r.status).toBe(200);
expect(r.ok).toBe(true);
expect(r.body).toEqual({ len: 524290 }); // 524288 + the 2-digit loop tail
