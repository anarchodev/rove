const SESSION_COOKIE = "rove_session";

const PRE_AUTH_PATHS = [
    "/v1/signup", "/v1/auth", "/v1/login", "/v1/logout",
];

function isHex64(s) {
    if (typeof s !== "string" || s.length !== 64) return false;
    for (let i = 0; i < 64; i++) {
        const c = s.charCodeAt(i);
        if (!((c >= 48 && c <= 57)
           || (c >= 97 && c <= 102)
           || (c >= 65 && c <= 70))) return false;
    }
    return true;
}

// Cookie path: hash, kv.get session/{hash}, sweep on expiry.
// Bearer path: hash, look up root_token/{hash} in root.db.
// Bearer-authed callers always get is_root=true; the dashboard's
// RPC path uses cookies, the operator's curl/CLI uses bearer.
function checkSession() {
    const opaque = request.cookies[SESSION_COOKIE];
    if (isHex64(opaque)) {
        const hash = crypto.sha256(opaque);
        const raw = kv.get("session/" + hash);
        if (raw) {
            let row = null;
            try { row = JSON.parse(raw); } catch (_) {}
            const nowNs = Date.now() * 1_000_000;
            if (!row) { kv.delete("session/" + hash); }
            else if (nowNs >= row.expires_at_ns) {
                kv.delete("session/" + hash);
            } else {
                return { is_root: !!row.is_root };
            }
        }
    }
    const auth = request.headers.authorization;
    if (typeof auth === "string" && auth.length > 7) {
        const lower = auth.slice(0, 7).toLowerCase();
        if (lower === "bearer ") {
            const token = auth.slice(7).trim();
            if (isHex64(token)) {
                if (platform.root.get("root_token/" + crypto.sha256(token)) !== null) {
                    return { is_root: true };
                }
            }
        }
    }
    return null;
}

export function before() {
    const fullPath = request.path;
    const q = fullPath.indexOf("?");
    const path = q === -1 ? fullPath : fullPath.slice(0, q);

    if (PRE_AUTH_PATHS.indexOf(path) !== -1) return; // continue

    const auth = checkSession();
    if (!auth) {
        response.status = 401;
        return { error: "unauthenticated" };
    }
    request.auth = auth;
    // fall through (undefined return) → continue to handler
}
