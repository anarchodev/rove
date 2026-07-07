// The surface reflector — enumerates the LIVE public API from inside
// an activation and returns its canonical names. surface_tests.zig
// diffs this against the union of every test module's `covers` claims,
// in both directions; the build fails on any mismatch.
//
// Canonical name grammar (tests claim these exact spellings):
//   ns.prop            own public prop of an object namespace (one
//                      nested level for plain-object props, e.g.
//                      platform.root.get)
//   name()             a callable global itself (schedule, cron, next,
//                      btoa, atob)
//   Name()             a constructible web-standard class
//   Name#method        a prototype method — of a class, or of the
//                      instance a config-first factory returns
//
// Keys of SHIM_ROOTS are the GLOBALS_FILES shim names, one entry per
// baked shim — surface_tests.zig asserts every shim name appears here,
// so a new shim cannot ship without declaring how it reflects.
// `_`-prefixed props are non-public by convention and skipped.

export default function () {
  const out = [];
  const errors = [];
  const skip = (k) => k.startsWith("_") || k === "constructor";

  function addObj(label, o, depth) {
    depth = depth || 0;
    for (const k of Object.keys(o)) {
      if (skip(k)) continue;
      let v = null;
      let isPlainObj = false;
      try {
        v = o[k];
        isPlainObj = v !== null && typeof v === "object" &&
          !Array.isArray(v) && !(v instanceof Uint8Array);
      } catch (_) { /* a throwing getter is still a public name — leaf */ }
      if (isPlainObj && depth > 0) addObj(label + "." + k, v, depth - 1);
      else out.push(label + "." + k);
    }
  }

  // A callable global: the call itself, plus its own public props.
  function addCallable(label, f) {
    out.push(label + "()");
    addObj(label, f);
  }

  // Prototype methods — class syntax makes these non-enumerable, so
  // walk own property names, not keys.
  function addProto(label, proto) {
    for (const k of Object.getOwnPropertyNames(proto)) {
      if (skip(k)) continue;
      out.push(label + "#" + k);
    }
  }

  function addClass(label, C) {
    out.push(label + "()");
    addProto(label, C.prototype);
  }

  function instance(label, make) {
    try {
      addProto(label, Object.getPrototypeOf(make()));
    } catch (e) {
      errors.push(label + ": " + ((e && e.message) || String(e)));
    }
  }

  const SHIM_ROOTS = {
    kv: () => addObj("kv", kv),
    console: () => addObj("console", console),
    crypto: () => addObj("crypto", crypto),
    http: () => addObj("http", http),
    platform: () => addObj("platform", platform, 1),
    base64: () => {
      out.push("btoa()");
      out.push("atob()");
      addObj("base64url", base64url);
      addObj("hex", hex);
    },
    urlsearchparams: () => addClass("URLSearchParams", URLSearchParams),
    jwt: () => addObj("jwt", jwt),
    oauth: () => {
      addObj("oauth", oauth);
      instance("OAuth", () => oauth.fromConfig({
        authorization_url: "https://idp.example/authorize",
        token_url: "https://idp.example/token",
        client_id: "cid",
        redirect_uri: "https://app.example/cb",
        on_complete_module: "onLogin",
        scopes: ["openid"],
      }));
    },
    oidc: () => {
      addObj("oidc", oidc);
      instance("OIDCProvider", () => oidc.provider({ clients: [] }));
      instance("OIDCRelyingParty", () => oidc.rp({
        issuer: "https://idp.example",
        client_id: "cid",
        redirect_uri: "https://app.example/cb",
      }));
    },
    sessions: () => {
      addObj("sessions", sessions);
      instance("Sessions", () => sessions.fromConfig({ state_path: "sess" }));
    },
    cron: () => addCallable("cron", cron),
    retry: () => addObj("retry", retry),
    schedule: () => addCallable("schedule", schedule),
    after: () => addObj("after", after),
    stream: () => addObj("stream", stream),
    next: () => addCallable("next", next),
    webhook: () => addObj("webhook", webhook),
    email: () => addObj("email", email),
    textcodec: () => {
      addClass("TextEncoder", TextEncoder);
      addClass("TextDecoder", TextDecoder);
    },
    users: () => addObj("users", users),
    activitypub: () => {
      addObj("activitypub", activitypub);
      instance("ActivityPubActor", () => activitypub.fromConfig({
        domain: "ap.example",
        username: "svc",
        verified_module: "onVerified",
      }));
    },
    blob: () => addObj("blob", blob),
    segments: () => addObj("segments", segments),
    browser: () => addObj("browser", browser),
  };

  for (const name of Object.keys(SHIM_ROOTS)) {
    try {
      SHIM_ROOTS[name]();
    } catch (e) {
      errors.push(name + ": " + ((e && e.message) || String(e)));
    }
  }

  // The per-activation Zig-built surfaces.
  addObj("request", request);
  addObj("response", response);

  return JSON.stringify({ names: out, errors: errors });
}
