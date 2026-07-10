// email.send decomposition (docs/plans/sim-test-framework.md). The readable
// matcher surfaces recipient + subject; under the hood email IS a webhook at the
// primitive level (one _send/owed marker pointed at the Resend API).
import { scenario, expect } from "rewind:test";

const s = scenario({ now: "2026-07-01T00:00:00Z" });
const r = s.inbound({ method: "POST", path: "/signup", body: { user: "ada" } });

expect(r.ok).toBe(true);
expect(r).toHaveWritten("emailed/ada", "1");

// ── readable: the email view surfaces recipient + subject (the Resend `to` is
// always an array), reading the decomposed marker under the hood ──
expect(r).toHaveSent("email", { to: ["ada@example.com"], subject: "Welcome, ada" });

// ── the decomposition really happened: exactly one durable send marker,
// pointed at Resend, carrying the built request body + the callback wiring ──
const markers = r.effects.filter((e) => e.kind === "write" && e.key.startsWith("_send/owed/"));
expect(markers.length).toBe(1);
const m = JSON.parse(markers[0].value);
expect(m.url).toBe("https://api.resend.com/emails");
expect(m.method).toBe("POST");
expect(m.on_result).toBe("hooks/onEmailed");
expect(m.context).toEqual({ user: "ada" });
const body = JSON.parse(m.body);
expect(body.from).toBe("noreply@acme.dev");
expect(body.subject).toBe("Welcome, ada");
expect(body.to).toEqual(["ada@example.com"]);

// email is a webhook at the primitive level — the webhook view sees it too.
expect(r).toHaveSent("webhook", { url: "https://api.resend.com/emails" });
