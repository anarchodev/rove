import email from "@rewind/email";
// email decomposition fixture. `email.send` layers on `webhook.send`, so it
// decomposes to the SAME durable primitive webhook does — one `_send/owed/{id}`
// marker whose url is the Resend API and whose body is the built Resend request.
// The `toHaveSent("email", …)` view reads that marker back into a readable
// {to, from, subject} shape.
export default function () {
  const user = request.json.user;
  email.send({
    apiKey: "re_test_key",
    from: "noreply@acme.dev",
    to: user + "@example.com",
    subject: "Welcome, " + user,
    html: "<h1>Hi " + user + "</h1>",
    on: "hooks/onEmailed",
    ctx: { user },
  });
  kv.set("emailed/" + user, "1");
  return { ok: true };
}
