import email from "@rewind/email";
// A send loop with a rate-limit catch branch — the shape prod's per-tenant
// outbound token bucket (bindings/http.zig `outboundRateOk`) eventually trips
// (email.send composes over the metered webhook.send). Offline the bucket is
// armed by `scenario({ emailBudget })`; each iteration reports "sent" or the
// caught error surface.
export default function () {
  const results = [];
  for (let i = 0; i < 3; i++) {
    try {
      email.send({
        apiKey: "re_test_123",
        from: "ops@acme.test",
        to: "user@example.test",
        subject: "hello " + i,
        text: "body " + i,
      });
      results.push("sent");
    } catch (e) {
      results.push({ code: e.code === undefined ? null : e.code, message: String(e.message) });
    }
  }
  return { results };
}
