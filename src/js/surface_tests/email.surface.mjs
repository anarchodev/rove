// email.send — Resend-shaped transactional email over webhook.send.
// Observable in-process: the durable marker it composes, recipient
// array-ification, header/auth shaping, and the option contract.
export default function () {
  check("email.send", () => {
    const id = email.send({
      apiKey: "re_test_key",
      from: "noreply@acme.test",
      to: "ada@example.com",
      subject: "Welcome",
      html: "<h1>Hi</h1>",
      cc: "cc@example.com",
      replyTo: "reply@acme.test",
    });
    ok(typeof id === "string" && id.length > 0, "id: " + id);
    const marker = JSON.parse(kv.get("_send/owed/" + id));
    eq(marker.url, "https://api.resend.com/emails");
    eq(marker.method, "POST");
    eq(marker.headers["Authorization"], "Bearer re_test_key");
    eq(marker.headers["Content-Type"], "application/json");
    const body = JSON.parse(marker.body);
    eq(body.to, ["ada@example.com"]);        // scalar → array
    eq(body.cc, ["cc@example.com"]);
    eq(body.from, "noreply@acme.test");
    eq(body.subject, "Welcome");
    eq(body.html, "<h1>Hi</h1>");
    eq(body.reply_to, "reply@acme.test");

    // Array recipients pass through; maxAttempts forwards.
    const id2 = email.send({
      apiKey: "k", from: "a@b.test", subject: "s",
      to: ["x@example.com", "y@example.com"], maxAttempts: 2,
    });
    const m2 = JSON.parse(kv.get("_send/owed/" + id2));
    eq(JSON.parse(m2.body).to, ["x@example.com", "y@example.com"]);
    eq(m2.max_attempts, 2);

    // Fail-loud contract.
    throws(() => email.send(), /requires an options object/);
    throws(() => email.send({ key: "k" }), /`key` was renamed/);
    throws(() => email.send({ from: "a@b.c", to: "x", subject: "s" }), /`apiKey` must be a non-empty string/);
    throws(() => email.send({ apiKey: "k", to: "x", subject: "s" }), /`from` must be a string/);
    throws(() => email.send({ apiKey: "k", from: "a@b.c", to: "x" }), /`subject` must be a string/);
    throws(() => email.send({ apiKey: "k", from: "a@b.c", subject: "s" }), /`to` is required/);
  });
  return done();
}
