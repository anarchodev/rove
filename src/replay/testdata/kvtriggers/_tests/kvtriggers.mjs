// kv triggers run offline (#38): beforePut mutates or rejects a matching write.
import { scenario, expect } from "rewind:test";
const withTrig = () => scenario({ now: "2026-07-01T00:00:00Z", triggers: [{ prefix: "users/" }] });

// A valid write is NORMALIZED by beforePut (the returned string is stored).
const good = withTrig().inbound({ method: "POST", path: "/good" });
expect(JSON.parse(good.body.stored)).toEqual({ name: "ada", normalized: true });
expect(good).toHaveWritten("users/1", { name: "ada", normalized: true }); // the MUTATED value is recorded

// An invalid write is REJECTED as trigger_rejected.
const bad = withTrig().inbound({ method: "POST", path: "/bad" });
expect(bad.body.rejected).toBe(true);
expect(bad.body.code).toBe("trigger_rejected");
expect(bad.body.message).toMatch(/name required/);

// beforeDelete rejects a delete.
const del = withTrig().inbound({ method: "POST", path: "/del" });
expect(del.body.rejected).toBe(true);
expect(del.body.code).toBe("trigger_rejected");

// No trigger registered ⇒ writes succeed unmutated (no _triggers module imported).
const notrig = scenario({}).inbound({ method: "POST", path: "/bad" });
expect(notrig.body.rejected).toBe(false);
