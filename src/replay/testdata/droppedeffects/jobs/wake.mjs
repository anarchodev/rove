// A durable-wake target (connectionless): `after.*` and `stream.write` have
// no socket to bind to — prod's bindings are inert there — while the durable
// verbs (`webhook.send`, ordinary kv writes) fire regardless.
export default function () {
  after.ms(1000, { on: "onTick" }); // no connection ⇒ inert in prod
  stream.write("never-delivered"); // no socket ⇒ inert in prod
  webhook.send("https://hooks.example.test/notify", {
    body: JSON.stringify({ fired: true }),
    key: "notify/wake",
  });
  kv.set("woke", "1");
  return {};
}
