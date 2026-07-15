// scenario({ emailBudget: N }) arms prod's email rate limit offline:
// the N+1-th email.send in an activation throws prod's exact
// Error{code:"rate_limited"} shape, so the catch branch is testable; unset,
// offline sends stay unmetered (the default).
import { scenario, expect } from "rewind:test";

// Budget 2: two sends land, the third trips the limiter.
const limited = scenario({ emailBudget: 2 }).inbound({ method: "POST", path: "/" });
expect(limited.status).toBe(200);
expect(limited.body.results[0]).toBe("sent");
expect(limited.body.results[1]).toBe("sent");
expect(limited.body.results[2].code).toBe("rate_limited");
expect(limited.body.results[2].message).toMatch("email rate limit exceeded");
// Only the two allowed sends produced durable _send/owed markers.
expect(limited).toHaveSent("email", { subject: "hello 0" });
expect(limited).toHaveSent("email", { subject: "hello 1" });
expect(limited).not.toHaveSent("email", { subject: "hello 2" });

// Unset ⇒ unmetered: all three sends land.
const open = scenario({}).inbound({ method: "POST", path: "/" });
expect(open.body.results).toEqual(["sent", "sent", "sent"]);
expect(open).toHaveSent("email", { subject: "hello 2" });
