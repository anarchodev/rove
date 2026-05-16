// Admin auth gate. Fork B (auth-domain-plan §4.7 "3-6 part 2"):
// admin is a pure OIDC relying party — no rove_session cookie, no
// root-token human path. Authentication moved to the __auth__ IdP;
// this gate just resolves the RP session `oidc.rp` minted.
//
// `kv` here is ALWAYS __admin__-home (the 3a primitive fix —
// X-Rove-Scope no longer rebinds it), so the RP session lookup is
// naturally scope-independent and correct on every dispatch. The
// /_system/* root-token surface is separate and unaffected.

const PRE_AUTH_PATHS = [
    // The browser-facing RP handshake endpoints.
    "/_rp/login", "/_rp/callback", "/_rp/poll",
    // Logout must work without a live session.
    "/v1/logout",
    // The async-completion on_result modules. callback_dispatch runs
    // dispatcher.run → _middlewares BEFORE the module, and a
    // synthesized callback request has NO request.session — so
    // guard() would 401 and the login chain would never complete.
    // Safe to pre-auth: these are bare `_rp/*.mjs` files, NOT
    // HTTP-routable (only invokable as on_result modules); the real
    // gate is the cryptographic jwt.verify inside oidc.rp._finish.
    "/_rp/complete", "/_rp/jwks",
];

export function before() {
    const fullPath = request.path;
    const q = fullPath.indexOf("?");
    const path = q === -1 ? fullPath : fullPath.slice(0, q);

    if (PRE_AUTH_PATHS.indexOf(path) !== -1) return; // continue

    const auth = oidc.rp("default").guard();
    if (!auth) {
        response.status = 401;
        return { error: "unauthenticated" };
    }
    request.auth = auth; // { sub, is_root }
    // fall through (undefined return) → continue to handler
}
