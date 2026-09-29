# Erasing a person's data with `shredKey`

When someone asks you to delete their data, the hard part is not the rows you
can find. It is every copy you cannot: the request logs, the replay tapes, the
large bodies spilled to shared storage, the backups. rewind handles those by
**crypto-shredding**: data written on behalf of a person is sealed under a key
that belongs to that person, and erasing them destroys the key. Every copy,
everywhere, becomes unreadable at once, and nothing has to be found or
rewritten.

## Naming the person

```js
export default function ({ kv, shredKey }) {
  // Your own opaque id for the person: from the query here, from the
  // session in a real handler.
  const userId = new URLSearchParams(request.query).get("user") ?? "u_7f3a9c";
  shredKey(userId);
  kv.set(`profile/${userId}`, JSON.stringify({ displayName: "Alice" }));
  return "saved";
}
```

`shredKey(id)` says "this activation's data belongs to `id`". It is
synchronous, costs nothing, and returns nothing — your code never sees key
material, so it can never keep a copy of it. You can call it late: nothing is
sealed until the handler returns, and it seals under whatever identity was
named by then. Calling it again **replaces** the identity rather than adding
one.

Once named, the activation's writes are sealed under that person's key:

- **KV values** it writes;
- its **log record** and **replay tape** (what it read, what it received);
- **request bodies and fetched responses**, including large ones spilled to
  shared storage.

An activation that names no one is not erasable one person at a time: its KV
values are stored as written, and what it logs belongs to your tenant as a
whole. Deleting your tenant still erases all of it.

## Erasing them

```js
export default function ({ shredKey }) {
  const userId = new URLSearchParams(request.query).get("user") ?? "u_7f3a9c";
  shredKey.destroy(userId);
  return "erased";
}
```

`shredKey.destroy(id)` commits with the activation, so when your response
arrives the key is gone on every node. It is **permanent**: nothing can bring
it back, including us. Afterwards:

- `kv.get` of a value sealed under it reads as **not found**;
- its log records and tapes open as **erased** (410) rather than as data;
- replaying one of its requests stops with a defined "sealed under a
  destroyed key" outcome instead of guessing.

Because it cannot be undone, destroys are capped per activation — a loop with
a bug should not be able to erase your whole user base in one request. Naming
new identities is rate-limited too: every new identity is a key kept forever,
so a per-request value (a request id, a timestamp, a fresh UUID) used as a
shred key is always a mistake, and the limit surfaces it as an error rather
than letting it grow silently.

## What `shredKey` cannot reach

Sealing covers **values**. Some things have to stay readable for rewind to
work, and anything you put in them is stored as you wrote it:

- **KV key names.** Keys are what range scans and lookups run over, so they
  are never sealed. `profile/alice@example.com` puts the address on disk in
  the clear, next to a value that is properly sealed.
- **Tags** (`tag(key, value)`) are an index by design — plaintext, and kept
  for as long as your logs are.
- **The request URL** (host and path) is recorded in the log index so you can
  find requests.

rewind does not inspect or police these. What goes in your keys and URLs is
your data model, and only you know whether `a1b2c3` is an opaque id or an
email in disguise. The recommendation:

- **Key rows by an opaque id you assign** (a random id created at signup), not
  by an email, name, or phone number. The id means nothing once the person's
  sealed rows are unreadable.
- **Keep identifying fields in values**, where they are sealed, not in keys.
- If you must look people up by email, the lookup row is the one place an
  identifier meets a key name — keep that row minimal, and delete it when you
  erase the person.
- Keep identifiers out of URL paths and tags for the same reason.

## Backups

rewind's backups carry keys, so that a failed disk does not cost you your
data. The price is that a backup taken **before** an erasure still holds the
erased person's key and data until that backup ages out. An erasure is
complete once every backup older than it has expired; the retention window is
set by whoever operates your cluster, and is the number to quote in an
erasure commitment. Backups taken after the erasure never contain the key.
