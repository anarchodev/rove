# Tutorial — a followable fediverse bot in ~30 lines

This walks through building `@announce@your-domain`: a real
ActivityPub actor that anyone on Mastodon (or Pleroma, Akkoma,
Misskey, …) can follow, and that publishes notes which fan out to its
followers' timelines. It is server-to-server only — the smallest
surface that is a genuine, interoperable federated participant, not a
toy.

It exists to show off three things rewind.js is uniquely good at:

1. **The Cmd-pattern effect model is exactly how ActivityPub is
   specified to work** — the inbox can't verify a signature inline, and
   the protocol already mandates the async answer.
2. **Durable `http.send` fan-out** — delivery to N follower inboxes,
   retried by the platform, with no retry loop in your code.
3. **Deterministic replay → regression test** — a real `Follow` from a
   server in the wild becomes a test you own, without that server.

The library it uses (`activitypub`) is built in; nothing to install or
import. It owns no kv namespace and ships full JSDoc — see
`src/js/globals/activitypub.js` and `docs/plans/builtin-libs-docs-plan.md`.

---

## 0. Prerequisites

- A deployed rewind.js app on a stable host. ActivityPub identities
  are domain-bound and effectively permanent (remote servers cache
  your actor + key), so use a domain you will keep — your custom
  domain or your `*.rewindjs.app` host. WebFinger **must** be served
  from the same host that appears in `@username@host`.
- The front door every production deployment already runs terminates
  long-tail HTTP/1.1 clients (remote fediverse servers) and speaks h2 to
  your worker (`docs/architecture/routing-and-ingress.md`). No special
  transport setup.
- Deploy with the same `_deploy/current` flow you already use
  (`docs/architecture/deployment-and-logs.md`). Nothing here is deploy-special.

---

## 1. Project layout

Routing is path-based (PLAN §2.4): a file at `foo/index.mjs` serves
`/foo`. So the whole bot is six tiny handlers plus one config file:

```
_config/activitypub.json              # actor identity (mirrored to kv at deploy)
.well-known/webfinger/index.mjs       # GET  /.well-known/webfinger   discovery
actor/index.mjs                       # GET  /actor                   the actor doc
actor/inbox/index.mjs                 # POST /actor/inbox             receive activities
actor/outbox/index.mjs                # GET  /actor/outbox            published notes
ap/inbox_verified/index.mjs           #      (http.send result module — not a route)
post/index.mjs                        # POST /post                    your publish trigger
```

Every handler is a one-liner that delegates to the library. The
library does the JSON-LD, the HTTP Signatures, the key handling, and
the fan-out.

---

## 2. Configure the actor

`_config/activitypub.json` — a plain file in your tree. At deploy it
is mirrored read-only into kv (the `_config/*` convention, same as
`_config/oauth/*`), so `activitypub.fromConfig()` can read it:

```json
{
  "domain":          "your-domain",
  "username":        "announce",
  "name":            "Announce Bot",
  "summary":         "Release notes, federated.",
  "type":            "Service",
  "verified_module": "ap/inbox_verified"
}
```

- `domain` is the host your app is served on. Your actor will be
  `https://your-domain/actor` and your handle `@announce@your-domain`.
- `type` is `Service` for a bot (Mastodon shows the bot badge) or
  `Person`.
- `verified_module` is the module path that finishes inbox processing
  after the async key fetch (step 4). It must match the file location
  exactly: `ap/inbox_verified` → `ap/inbox_verified/index.mjs`.

---

## 3. Discovery: WebFinger + actor document

When you type `@announce@your-domain` into Mastodon's search, the
remote server first asks WebFinger "who is this?", then fetches the
actor document it points at.

`.well-known/webfinger/index.mjs`:

```js
export default () => activitypub.fromConfig().webfinger();
```

`actor/index.mjs`:

```js
export default function () {
  const ap = activitypub.fromConfig();
  ap.ensureKeypair();   // idempotent: generates the RSA key on first call only
  return ap.actor();
}
```

`ensureKeypair()` is the only setup. It generates an RSA-2048 keypair
(`crypto.oidcGenerateKey`) and stores it in kv. There is no special
secrets primitive and no ceremony: the private key sits in kv and is
**page-encrypted at rest by the platform** like every other value.
Calling it from the actor route means the key is guaranteed to exist
the moment anyone first looks you up — which is exactly when a follow
begins.

At this point, deploy and search `@announce@your-domain` from a
Mastodon account. The profile should resolve. It has no posts and you
can't follow it yet — that needs the inbox.

---

## 4. The inbox — and why it's two requests

This is the interesting part. When someone clicks **Follow**, their
server `POST`s a signed `Follow` activity to `/actor/inbox`. To trust
it you must verify its HTTP Signature — which requires the **sender's**
public key, which you don't have, which means an outbound fetch of
their actor document.

A pure handler cannot make a blocking outbound call mid-request — and
critically, **ActivityPub already says you shouldn't**. Inbox delivery
is fire-and-forget: the spec has the sender expect a fast `202
Accepted` and do no synchronous waiting. So the honest implementation
*is* the platform's effect model:

```
POST /actor/inbox
  → 202 Accepted immediately
  → http.send(GET sender's actor)        [durable Cmd]
  → (later) result module: verify signature, then act
```

`actor/inbox/index.mjs`:

```js
export default () => activitypub.fromConfig().inbox();
```

`ap/inbox_verified/index.mjs` — the `verified_module`, invoked with the
`http.send` result once the sender's actor (and key) is fetched:

```js
export default (event) => activitypub.fromConfig().completeInbox(event);
```

`completeInbox` caches the signer's key, recomputes the `Digest`,
verifies the RSA-SHA256 signature against a **frozen snapshot** of the
request headers captured at inbox time (so verification is a pure
function of taped inputs — replay-identical), and then dispatches:

- `Follow` → record the follower and **auto-send a signed `Accept`**
  back to their inbox (without the `Accept`, Mastodon shows "Pending"
  forever).
- `Undo` of a `Follow` → drop the follower.
- anything else → acknowledged no-op.

Note the shape: this is the exact `oauth.verifyIdToken → fetchJwks →
cacheJwksFromEvent → re-verify` chain the platform already uses for
OIDC. "Fetch a key you don't have, then decide" is one pattern here,
not a special case.

---

## 5. Posting — durable fan-out

`post/index.mjs` — your trigger to publish. **Authenticate this**
(it's your megaphone): a shared bearer header is enough for the
tutorial; use `sessions`/`users` for anything real.

```js
export default function () {
  if (request.headers["x-admin-token"] !== "CHANGE-ME") {
    response.status = 401;
    return "no";
  }
  const { content } = JSON.parse(request.body || "{}");
  const ap = activitypub.fromConfig();
  return JSON.stringify(ap.publishNote(content));
}
```

`publishNote` builds a `Note` wrapped in a `Create`, appends it to the
outbox, then signs and `http.send`s it to every follower inbox. Each
delivery is a durable Cmd: followers that are slow or down are the
platform's retry problem, not yours, and one dead inbox never blocks
the rest. It returns `{ id, delivered }`.

`actor/outbox/index.mjs` — so profiles can render your post history:

```js
export default () => activitypub.fromConfig().outbox();
```

Publish one:

```sh
curl -XPOST https://your-domain/post \
  -H 'x-admin-token: CHANGE-ME' \
  -d '{"content":"Hello, fediverse 👋"}'
```

It appears in the timeline of everyone who followed the bot.

---

## 6. End-to-end, against a real server

1. Deploy.
2. From your own Mastodon account, search `@announce@your-domain`.
3. Click **Follow**. Watch it flip from "Pending" to followed within a
   second — that round trip is: their server → your `inbox` (202) →
   your `http.send` fetch of their actor → `inbox_verified` verifies
   and sends `Accept` → their server marks you followed.
4. `curl` the `/post` route. The note lands in your home timeline.
5. Reply / unfollow / re-follow — all flow through the same inbox.

You are now a real federated actor interoperating with software you
don't run, over the HTTP surface the edge proxy already handles. No
WebSockets, no HTTP/1.1 server code, no new transport — ActivityPub is
pure HTTP, and the parts that look synchronous (the inbox) decompose
cleanly into the Cmd model.

---

## 7. The payoff: a real interaction becomes a regression test

That `Follow` in step 3 came from a third-party server you don't
control and can't easily summon on demand. But the whole interaction —
the exact bytes, the real HTTP Signature, the real key fetch, the
`Accept` you sent back — was recorded as a deterministic tape (one
invocation for the `inbox` 202, one for the `inbox_verified` result;
they stitch together through the carried context).

Open that recorded request in the replay/sim surface (`rewind replay
<id>` / the sim-test framework — PLAN §10.12,
`docs/plans/sim-test-framework.md`) and you can re-run the verification path
deterministically and synthesize a regression test from it: a test
that pins "this real Follow, this real signature, still verifies and
still produces the right `Accept`" — **without** the remote server,
**without** hand-mocking HTTP Signatures, **without** a fixture you
faked by hand.

That is the thing no other platform can hand you: federation interop
is the most legible possible demo of "real production interaction →
deterministic replay → owned regression test", because the hard part
(a correct remote signature) is precisely the part you otherwise can't
reproduce.

---

## What this intentionally does not cover

Honest scope, so you know the edges:

- **S2S only.** No client-to-server (C2S) API — posting is your own
  authenticated route, not the AP client protocol. A `Person` actor
  with C2S is a natural follow-on.
- **No media / attachments / threading.** `publishNote` takes HTML
  content and an optional `inReplyTo`; that's it.
- **Inbox is at-least-once.** `webhook.send` callbacks can
  double-deliver and leadership change can re-fire. `Follow`/`Undo`
  are idempotent as written (set/delete by signer id); if you add
  activity types with non-idempotent effects, dedupe on the activity
  `id` yourself — idempotency is the customer's responsibility here,
  consistently with `webhook.send`.
- **One actor per config.** Multi-actor (one app hosting many
  accounts) means one config per actor via
  `activitypub.fromConfig("name")` reading `_config/activitypub/name`.
- **No AT Protocol / firehose.** That needs WebSockets and the
  connection-actor primitive (`docs/architecture/effects-and-handlers.md`,
  `docs/architecture/routing-and-ingress.md`) and is deliberately v2.
  ActivityPub needs none of it.

Reference: `src/js/globals/activitypub.js` (full JSDoc + `@example` on
every method), `src/js/bindings/webhook.send.js` (the durable outbound
Cmd this rides), `docs/architecture/routing-and-ingress.md` (where the
held-connection work goes when it's time).
