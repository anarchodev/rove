import { scenario, expect } from "rewind:test";

const RP = {
  issuer: "https://auth.rewindjs.com",
  client_id: "test-rp",
  redirect_uri: "https://app.test/_rp/callback",
  operator_prefix: "_admin/operator/",
};
const FAR = 4102444800000;
const j = JSON.stringify;
const call = (row) => scenario({
  now: "2026-08-15T00:00:00Z", seed: 1,
  kv: { "_config/oidc/rp/default": RP, "_rp/sess/al": row },
}).inbound({ method: "GET", path: "/", host: "app.test", session: { id: "al" } });

// UNSTAMPED reads as v1 — the row the previous version of this package wrote.
// This is the case that matters: refusing it logs every user out on upgrade.
const unstamped = call(j({ sub: "alice@x.com", is_root: false, exp: FAR }));
expect(unstamped.body.authed).toBe(true);
expect(unstamped.body.sub).toBe("alice@x.com");

// Stamped at the current version reads the same way.
const stamped = call(j({ v: 1, sub: "alice@x.com", is_root: false, exp: FAR }));
expect(stamped.body.authed).toBe(true);
expect(stamped.body.sub).toBe("alice@x.com");

// A NEWER version is still refused — the shape is unknown and these
// namespaces are shim-writable, so acting on fields that may mean something
// else now is the misread the field exists to prevent.
expect(call(j({ v: 99, sub: "alice@x.com", is_root: false, exp: FAR })).body.authed).toBe(false);

// A `v` that is PRESENT and not a number is a hand-written row of unknown
// shape, and is refused for the same reason. Distinct from absent.
expect(call(j({ v: "1", sub: "alice@x.com", is_root: false, exp: FAR })).body.authed).toBe(false);

// The other guards still hold on an unstamped row — expiry is still checked,
// so "reads as v1" is not "skips validation".
expect(call(j({ sub: "alice@x.com", is_root: false, exp: 1 })).body.authed).toBe(false);

// Unparseable is unchanged.
expect(call("{not json").body.authed).toBe(false);
