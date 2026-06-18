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
    // CLI device-grant token exchange establishes the session — it can't
    // require one. The real gate is the cryptographic id_token verify inside
    // oidc.rp.exchangeToken (same as the _rp/* completion modules).
    "/v1/cli/exchange",
    // The async-completion on_result modules. callback_dispatch runs
    // dispatcher.run → _middlewares BEFORE the module, and a
    // synthesized callback request has NO request.session — so
    // guard() would 401 and the login chain would never complete.
    // Safe to pre-auth: these are bare `_rp/*.mjs` files, NOT
    // HTTP-routable (only invokable as on_result modules); the real
    // gate is the cryptographic jwt.verify inside oidc.rp._finish.
    "/_rp/complete", "/_rp/jwks",
];

// Machine-to-machine routes that accept a platform root-token bearer in
// addition to (or instead of) an OIDC session. This is the operator /
// bootstrap / break-glass path for `rewind-ops` and `POST /_system/reset`
// continuity — NOT a human login path (the dashboard UI stays pure-OIDC).
// A valid root token grants operator authority (is_root) with no `sub`;
// the deploy handler gates on is_root OR session-ownership of the target.
const M2M_PATHS = ["/v1/deploy/reset", "/v1/deploy/file", "/v1/deploy/cut"];

export function before() {
    const fullPath = request.path;
    const q = fullPath.indexOf("?");
    const path = q === -1 ? fullPath : fullPath.slice(0, q);

    if (PRE_AUTH_PATHS.indexOf(path) !== -1) return; // continue

    // M2M root-token bearer (operator/bootstrap). Only honored on M2M_PATHS;
    // everywhere else the dashboard is a pure OIDC relying party.
    if (M2M_PATHS.indexOf(path) !== -1) {
        const hdr = request.headers["authorization"] || "";
        const tok = hdr.indexOf("Bearer ") === 0 ? hdr.slice(7) : "";
        if (tok && platform.auth.checkRootToken(tok)) {
            request.auth = { sub: null, is_root: true, root: true };
            return; // continue → handler
        }
        // No/invalid root token → fall through to the OIDC guard so a
        // logged-in customer can deploy their own tenant via session.
    }

    const auth = oidc.rp("default").guard();
    if (!auth) {
        response.status = 401;
        return { error: "unauthenticated" };
    }
    request.auth = auth; // { sub, is_root }
    // fall through (undefined return) → continue to handler
}
