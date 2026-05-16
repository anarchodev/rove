// on_result of the OIDC RP JWKS refetch (auth-domain-plan §4.7).
// Caches the IdP JWKS, RS256-verifies the id_token, validates
// iss/aud/exp, and writes _rp/sess/{sid} (= the verified session).
// A bare `_rp/*.mjs` file — invoked only as an on_result module.
export default function () {
    return oidc.rp("default").completeJwks();
}
