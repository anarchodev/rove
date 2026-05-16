// on_result of the OIDC RP token exchange (auth-domain-plan §4.7).
// Platform-driven callback: parses the id_token, verifies it against
// cached JWKS or refetches (the §4.6 unknown-kid path), then mints
// the RP session keyed by the sid threaded through http.send context.
// A bare `_rp/*.mjs` file — invoked only as an on_result module, not
// HTTP-routable.
export default function () {
    return oidc.rp("default").completeToken();
}
