// surface test: activitypub — a real signed-inbox roundtrip: a second
// in-process actor plays the remote signer (its actorDocument is the
// fetched signer doc, its key signs the snapshot), so completeInbox
// runs the full HTTP-Signature verify + Follow dispatch for real.

export default function () {
  check("activitypub.fromConfig", () => {
    ok(activitypub.fromConfig(), "seeded _config/activitypub resolves");
    ok(activitypub.fromConfig({ domain: "x.example", username: "u", verified_module: "m" }),
      "inline config resolves");
    throws(() => activitypub.fromConfig("nope"),
      /config not found at _config\/activitypub\/nope/);
    throws(() => activitypub.fromConfig({ domain: "x.example" }),
      /missing required config key/);
    throws(() => activitypub.fromConfig(42), /expected string name or inline config/);
  });

  const ap = activitypub.fromConfig(); // domain ap.example, username svc

  check("ActivityPubActor#ensureKeypair", () => {
    eq(kv.get("ap/key"), null);
    ap.ensureKeypair();
    const key = JSON.parse(kv.get("ap/key"));
    eq(key.jwk.kty, "RSA");
    ap.ensureKeypair(); // idempotent — same key survives
    eq(JSON.parse(kv.get("ap/key")).jwk.kid, key.jwk.kid);
  });

  check("ActivityPubActor#webfinger", () => {
    // The standard query has no resource=acct:svc@ap.example.
    eq(ap.webfinger(), "not found");
    eq(response.status, 404);
    response.status = 200;
  });

  check("ActivityPubActor#actorDocument", () => {
    const doc = ap.actorDocument();
    eq(doc.id, "https://ap.example/actor");
    eq(doc.type, "Service");
    eq(doc.preferredUsername, "svc");
    eq(doc.inbox, "https://ap.example/actor/inbox");
    eq(doc.publicKey.id, "https://ap.example/actor#main-key");
    ok(doc.publicKey.publicKeyPem.includes("BEGIN PUBLIC KEY"), "SPKI PEM");
  });

  check("ActivityPubActor#actor", () => {
    const body = ap.actor();
    eq(response.status, 200);
    eq(response.headers["content-type"], "application/activity+json");
    eq(JSON.parse(body).id, "https://ap.example/actor");
    response.headers = {};
  });

  check("ActivityPubActor#inbox", () => {
    // The standard request carries no Signature header — the 400 arm.
    eq(ap.inbox(), "missing Signature header");
    eq(response.status, 400);
    response.status = 200;
  });

  // ── The remote signer, played by a second in-process actor ───────
  const peer = activitypub.fromConfig({
    domain: "peer.example", username: "bob", verified_module: "m",
    key_path: "ap/peerkey",
  });
  peer.ensureKeypair();
  const peerDoc = peer.actorDocument();
  const peerPriv = JSON.parse(kv.get("ap/peerkey")).priv;
  const headerList = "(request-target) host date";
  const snapshot = {
    method: "POST", path: "/actor/inbox",
    headers: { host: "ap.example", date: "Tue, 07 Jul 2026 00:00:00 GMT" },
    body: "",
  };
  const signingStr = "(request-target): post /actor/inbox\n" +
    "host: ap.example\ndate: Tue, 07 Jul 2026 00:00:00 GMT";
  const signature = crypto.oidcSign(peerPriv, signingStr);
  const mkEvent = (activity, overrides) => Object.assign({
    ok: true,
    body: JSON.stringify(peerDoc),
    context: {
      ap_kind: "inbox_verify",
      keyId: "https://peer.example/actor#main-key",
      signature, headerList, snapshot, activity,
    },
  }, overrides || {});
  const follow = {
    type: "Follow",
    actor: "https://peer.example/actor",
    object: "https://ap.example/actor",
  };

  check("ActivityPubActor#completeInbox", () => {
    eq(ap.completeInbox(mkEvent(follow, { ok: false })),
      { ok: false, error: "actor fetch failed" });
    // Real verify: signer key cached, signature checked, Follow dispatched.
    eq(ap.completeInbox(mkEvent(follow)), { ok: true, action: "follow" });
    const frow = JSON.parse(
      kv.get("ap/followers/" + crypto.sha256("https://peer.example/actor")));
    eq(frow.inbox, "https://peer.example/actor/inbox");
    // The auto-Accept was queued to the follower's inbox, signed.
    const accepts = kv.prefix("_send/owed/", null, 1000)
      .map((r) => JSON.parse(r.value))
      .filter((m) => m.url === "https://peer.example/actor/inbox");
    eq(accepts.length, 1);
    eq(JSON.parse(accepts[0].body).type, "Accept");
    ok(accepts[0].headers.signature.includes('keyId="https://ap.example/actor#main-key"'),
      "delivery is HTTP-signed");
    // A flipped signature byte is a hard reject.
    const bad = mkEvent(follow);
    bad.context = Object.assign({}, bad.context, {
      signature: signature.slice(0, -2) + (signature.endsWith("A") ? "BB" : "AA"),
    });
    eq(ap.completeInbox(bad).error, "bad signature");
    eq(ap.completeInbox(mkEvent({ type: "Like" })).action, "ignored:Like");
  });

  check("ActivityPubActor#publishNote", () => {
    const r = ap.publishNote("Hello <b>fediverse</b>", { in_reply_to: "https://x.example/n/1" });
    ok(r.id.startsWith("https://ap.example/actor/notes/"), "note id minted");
    eq(r.delivered, 1); // exactly the one follower from the Follow above
  });

  check("ActivityPubActor#outbox", () => {
    const col = JSON.parse(ap.outbox());
    eq(col.type, "OrderedCollection");
    eq(col.totalItems, 1);
    eq(col.orderedItems[0].type, "Create");
    eq(col.orderedItems[0].object.content, "Hello <b>fediverse</b>");
    eq(col.orderedItems[0].object.inReplyTo, "https://x.example/n/1");
    response.headers = {};
  });

  // Undo Follow drops the follower row (ordered after publishNote so
  // the delivery count above sees the follower).
  check("ActivityPubActor#completeInbox", () => {
    eq(ap.completeInbox(mkEvent({ type: "Undo", object: follow })),
      { ok: true, action: "unfollow" });
    eq(kv.get("ap/followers/" + crypto.sha256("https://peer.example/actor")), null);
  });

  return done();
}
