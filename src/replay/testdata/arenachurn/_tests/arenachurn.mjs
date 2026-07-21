// GC arena ≡ prod's effective ceiling. A churny-but-legal handler
// whose cumulative allocation (~256 MiB) dwarfs the 100 MiB request arena, but
// whose peak live set is ~1 MiB, completes offline because the sim runs GC
// always — the same outcome prod produces via its bump→GC retry. Before the
// switch to GC-always the sim ran a bump arena and this OOM'd offline while
// passing in production.
import { scenario, expect } from "rewind:test";

const r = scenario({}).inbound({ path: "/" });
expect(r.status).toBe(200);
expect(r.ok).toBe(true);
expect(r.body).toEqual({ len: 1048579 }); // 1048576 + the 3-digit loop tail
