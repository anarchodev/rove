// A consumer of the lifted `@rewind/email` package (P-Lift, rove#123). email
// is a leaf that composes over the ambient `webhook` global — so this proves a
// lifted package can still reach an ambient PRIMITIVE (webhook) that stays
// baked, not just a pure stdlib one. `email.send` builds the Resend request and
// dispatches it via `webhook.send`, which lands a durable `_send/owed` marker
// the `toHaveSent("email", …)` matcher reads.
import email from "@rewind/email";

export default function () {
  const id = email.send({
    apiKey: "re_test_key",
    from: "noreply@acme.dev",
    to: "ada@example.com",
    subject: "Welcome",
    text: "hello ada",
  });
  return { id };
}
