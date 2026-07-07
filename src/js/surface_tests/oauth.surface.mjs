// surface test: oauth — startLogin's redirect (incl. the PKCE
// challenge recomputed from the stored verifier), the callback's
// validation contract, refresh's durable send, and the sync
// verifyIdToken path against a self-minted RS256 id_token.

const INLINE = {
  authorization_url: "https://idp.example/authorize",
  token_url: "https://idp.example/token",
  client_id: "cid",
  client_secret: "sec",
  redirect_uri: "https://app.example/cb",
  on_complete_module: "users/oauth_complete",
  scopes: ["openid", "email"],
};

export default function () {
  check("oauth.fromConfig", () => {
    // kv-backed (deploy-seeded row) and inline configs are the same shape.
    ok(oauth.fromConfig("default"), "seeded _config/oauth/default resolves");
    ok(oauth.fromConfig(INLINE), "inline config resolves");
    throws(() => oauth.fromConfig("nope"),
      /config not found at _config\/oauth\/nope/);
    throws(() => oauth.fromConfig(42), /expected string name or inline config/);
    throws(() => oauth.fromConfig({ client_id: "only" }),
      /missing required config key/);
    throws(() => oauth.fromConfig(Object.assign({}, INLINE, { scopes: "openid" })),
      /scopes must be an array/);
  });

  check("OAuth#startLogin", () => {
    const p = oauth.fromConfig(INLINE);
    eq(p.startLogin({ return_to: "/home", context: { a: 1 } }), null);
    eq(response.status, 302);
    const loc = response.headers.location;
    ok(loc.startsWith("https://idp.example/authorize?"), "redirects to the IdP");
    const params = new URLSearchParams(loc.split("?")[1]);
    eq(params.get("client_id"), "cid");
    eq(params.get("redirect_uri"), "https://app.example/cb");
    eq(params.get("response_type"), "code");
    eq(params.get("scope"), "openid email");
    eq(params.get("code_challenge_method"), "S256");
    // The stored state row carries the verifier; the challenge in the
    // URL must be base64url(sha256(verifier)) — recompute it.
    const state = params.get("state");
    const stored = JSON.parse(kv.get("state/oauth/_inline/" + state));
    eq(stored.return_to, "/home");
    eq(stored.context, { a: 1 });
    eq(params.get("code_challenge"),
      base64url.encode(hex.decode(crypto.sha256(stored.verifier))));
    response.status = 200;
    response.headers = {};
  });

  check("OAuth#handleCallback", () => {
    // The standard request's query has no state/code — the 400 arm.
    const body = oauth.fromConfig(INLINE).handleCallback();
    eq(response.status, 400);
    eq(body, "OAuth: missing state or code on callback");
    response.status = 200;
  });

  check("OAuth#refresh", () => {
    const id = oauth.fromConfig(INLINE).refresh("rtok", { user_sub: "u1" });
    ok(typeof id === "string" && id.length > 0, "returns the send id");
    const marker = JSON.parse(kv.get("_send/owed/" + id));
    eq(marker.url, "https://idp.example/token");
    eq(marker.method, "POST");
    eq(marker.on_result, "users/oauth_complete");
    eq(marker.context, { refresh: true, user_sub: "u1" });
    const body = new URLSearchParams(marker.body);
    eq(body.get("grant_type"), "refresh_token");
    eq(body.get("refresh_token"), "rtok");
    eq(body.get("client_secret"), "sec");
  });

  // A real RS256 id_token minted in-process backs the verify path.
  const { priv, jwk } = crypto.oidcGenerateKey();
  const enc = (o) => base64url.encode(new TextEncoder().encode(JSON.stringify(o)));
  const now_s = Math.floor(Date.now() / 1000);
  const mkToken = (claims) => {
    const input = enc({ alg: "RS256", kid: jwk.kid }) + "." + enc(claims);
    return input + "." + crypto.oidcSign(priv, input);
  };
  const good = mkToken({
    iss: "https://idp.example", aud: "cid", sub: "u1",
    exp: now_s + 600, nonce: "n1",
  });
  const opts = {
    issuer: "https://idp.example", client_id: "cid",
    jwks_uri: "https://idp.example/jwks", cache_path: "cache/oauth/t",
  };

  check("oauth.verifyIdToken", () => {
    eq(oauth.verifyIdToken("", opts), { ok: false, error: "missing id_token" });
    throws(() => oauth.verifyIdToken(good, { issuer: "x" }),
      /needs issuer, client_id, jwks_uri/);
    // Cold cache → the caller must run the async fetchJwks hop.
    eq(oauth.verifyIdToken(good, opts),
      { ok: false, need_jwks: true, jwks_uri: opts.jwks_uri });
    // Prime the cache (what cacheJwks would write) → full accept.
    kv.set("cache/oauth/t/jwks", JSON.stringify({ keys: [jwk] }));
    const r = oauth.verifyIdToken(good, Object.assign({ nonce: "n1" }, opts));
    eq(r.ok, true);
    eq(r.claims.sub, "u1");
    eq(oauth.verifyIdToken(good, Object.assign({ nonce: "other" }, opts)).error,
      "nonce mismatch");
    eq(oauth.verifyIdToken(mkToken({ iss: "https://evil.example", aud: "cid" }), opts).error,
      "id_token issuer-mismatch");
    // Unknown kid in a multi-key cache = stale-cache signal, not forgery.
    const stranger = crypto.oidcGenerateKey().jwk;
    kv.set("cache/oauth/t/jwks", JSON.stringify({ keys: [stranger, crypto.oidcGenerateKey().jwk] }));
    eq(oauth.verifyIdToken(good, opts).need_jwks, true);
  });

  check("oauth.fetchJwks", () => {
    oauth.fetchJwks(opts, "users/oauth_jwks", { sid: "s1" });
    const rows = kv.prefix("_send/owed/", null, 1000)
      .map((r) => JSON.parse(r.value))
      .filter((m) => m.url === opts.jwks_uri);
    eq(rows.length, 1);
    eq(rows[0].method, "GET");
    eq(rows[0].on_result, "users/oauth_jwks");
    eq(rows[0].context, { sid: "s1" });
  });

  check("oauth.cacheJwks", () => {
    // Inbound activations carry no fetch result (request.ok is not
    // set) — cacheJwks is a no-op false outside an {on} module.
    eq(oauth.cacheJwks("cache/oauth/t"), false);
  });

  return done();
}
