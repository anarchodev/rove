// surface test: oidc — the provider's front controller + a REAL
// handleRotate tick (keyset genesis → advance → durable re-arm), and
// every RP method under the standard (sid-less) request, pinning the
// documented fail-closed arms.

const RP_INLINE = {
  issuer: "https://idp.example",
  client_id: "cid",
  redirect_uri: "https://app.example/cb",
};

export default function () {
  check("oidc.provider", () => {
    ok(oidc.provider(), "seeded _config/oidc/default resolves");
    ok(oidc.provider({ clients: [] }), "inline config resolves");
    throws(() => oidc.provider("nope"), /no client registry at _oidc\/config\/nope/);
    throws(() => oidc.provider(42), /expected string name or config object/);
  });

  check("oidc.rp", () => {
    ok(oidc.rp(), "seeded _oidc/rp/default resolves");
    ok(oidc.rp(RP_INLINE), "inline config resolves");
    throws(() => oidc.rp("nope"), /no RP config at _oidc\/rp\/nope/);
    throws(() => oidc.rp({ issuer: "x" }), /config needs issuer, client_id, redirect_uri/);
    throws(() => oidc.rp(42), /expected string name or config object/);
  });

  check("OIDCProvider#handle", () => {
    // The front controller routes on path — POST /surface is none of
    // the OIDC endpoints, so the fallback arm answers.
    eq(oidc.provider({ clients: [] }).handle(), "not found");
    eq(response.status, 404);
    response.status = 200;
  });

  check("OIDCProvider#handleRotate", () => {
    // A real tick: genesis mints the keyset, _advance no-ops (fresh
    // key), and the re-arm lands as a durable send with the stable
    // rot handle.
    const p = oidc.provider({ clients: [] }); // name "_inline"
    const body = JSON.parse(p.handleRotate());
    eq(body, { ok: true, keys: 1 });
    eq(response.headers["content-type"], "application/json");
    const ks = JSON.parse(kv.get("_oidc/keyset/_inline"));
    eq(ks.keys.length, 1);
    eq(ks.keys[0].status, "current");
    eq(ks.keys[0].jwk.kty, "RSA");
    eq(ks.min_iat, 0);
    // Stable handle ⇒ deterministic send id; aimed at this host's
    // own /_oidc/rotate.
    const rot_id = base64url.encode(hex.decode(crypto.sha256("oidc-rot/_inline")));
    const marker = JSON.parse(kv.get("_send/owed/" + rot_id));
    eq(marker.url, "https://surface.test/_oidc/rotate");
    response.headers = {};
  });

  const rp = oidc.rp(RP_INLINE);

  check("OIDCRelyingParty#beginLogin", () => {
    // The standard request has no platform sid — fail closed.
    eq(rp.beginLogin(), "no session context");
    eq(response.status, 400);
    response.status = 200;
  });

  check("OIDCRelyingParty#handleCallback", () => {
    // Query has no code/state.
    eq(rp.handleCallback(), "missing code or state");
    eq(response.status, 400);
    response.status = 200;
  });

  check("OIDCRelyingParty#completeToken", () => {
    // Inbound activation carries no fetch result (request.status unset) —
    // the failed-exchange arm, status placeholder "?".
    eq(rp.completeToken(), "token exchange failed: ?");
    eq(response.status, 200);
  });

  check("OIDCRelyingParty#completeJwks", () => {
    eq(rp.completeJwks(), "jwks fetch failed");
    eq(response.status, 200);
  });

  check("OIDCRelyingParty#exchangeToken", () => {
    eq(rp.exchangeToken("tok"), { error: "no session context" });
    eq(response.status, 400);
    response.status = 200;
  });

  check("OIDCRelyingParty#guard", () => {
    eq(rp.guard(), null); // no sid → unauthenticated
  });

  check("OIDCRelyingParty#pollStatus", () => {
    eq(JSON.parse(rp.pollStatus()), { authed: false });
    eq(response.headers["content-type"], "application/json");
    response.headers = {};
  });

  check("OIDCRelyingParty#logout", () => {
    eq(JSON.parse(rp.logout()), { ok: true });
    response.headers = {};
  });

  check("OIDCRelyingParty#logoutRedirect", () => {
    eq(rp.logoutRedirect(), null);
    eq(response.status, 302);
    // No same-origin return_to in the query → post_login "/", bounced
    // through the IdP's end-session endpoint.
    eq(response.headers.location,
      "https://idp.example/logout?post_logout_redirect_uri=" +
      encodeURIComponent("https://surface.test/"));
    response.status = 200;
    response.headers = {};
  });

  return done();
}
