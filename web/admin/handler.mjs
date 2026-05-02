function validId(id) {
    return typeof id === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(id);
}

export function listInstance() {
    const entries = platform.root.prefix("instance/", "", 1000);
    return {
        instances: entries.map((e) => ({
            id: e.key.slice("instance/".length),
        })),
    };
}

export function getInstance(id) {
    if (!validId(id)) { response.status = 400; return { error: "invalid id" }; }
    const v = platform.root.get("instance/" + id);
    if (v === null) { response.status = 404; return { error: "not found" }; }
    return { id: id };
}

export function createInstance(id) {
    if (!validId(id)) { response.status = 400; return { error: "invalid id" }; }
    platform.root.set("instance/" + id, "");
    response.status = 201;
    return { id: id };
}

export function deleteInstance(id) {
    if (!validId(id)) { response.status = 400; return { error: "invalid id" }; }
    platform.root.delete("instance/" + id);
    const doms = platform.root.prefix("domain/", "", 1000);
    for (let i = 0; i < doms.length; i++) {
        if (doms[i].value === id) platform.root.delete(doms[i].key);
    }
    response.status = 204;
    return null;
}

export function listDomain() {
    const entries = platform.root.prefix("domain/", "", 1000);
    return {
        domains: entries.map((e) => ({
            host: e.key.slice("domain/".length),
            instance_id: e.value,
        })),
    };
}

export function assignDomain(host, instance_id) {
    if (!host || !instance_id) {
        response.status = 400;
        return { error: "host and instance_id required" };
    }
    const exists = platform.root.get("instance/" + instance_id);
    if (exists === null) {
        response.status = 404;
        return { error: "instance not found" };
    }
    platform.root.set("domain/" + host, instance_id);
    response.status = 201;
    return { host: host, instance_id: instance_id };
}

export function listKv(prefix, cursor, limit) {
    const p = prefix || "";
    const c = cursor || "";
    const l = Math.max(1, Math.min(parseInt(limit ?? 100, 10) || 100, 1000));
    const entries = kv.prefix(p, c, l);
    const body = {
        entries: entries.map((e) => ({ key: e.key, value: e.value })),
    };
    if (entries.length === l && entries.length > 0) {
        body.next_cursor = entries[entries.length - 1].key;
    }
    return body;
}

export function getKv(key) {
    if (!key) {
        response.status = 400;
        return { error: "missing key" };
    }
    const v = kv.get(key);
    if (v === null) {
        response.status = 404;
        return { error: "not found" };
    }
    return v;
}

export function setKv(key, value) {
    if (!key) {
        response.status = 400;
        return { error: "missing key" };
    }
    if (typeof value !== "string") {
        response.status = 400;
        return { error: "value must be a string" };
    }
    kv.set(key, value);
    return { key: key };
}

export function deleteKv(key) {
    if (!key) {
        response.status = 400;
        return { error: "missing key" };
    }
    kv.delete(key);
    response.status = 204;
    return null;
}

// ── /v1/* path-routed admin handlers ────────────────────────────────
//
// The named exports above are the dashboard's RPC surface
// (?fn=name); they're auth-gated in Zig (extractAdminAuth) and
// don't see this default. The default below owns the path-routed
// admin endpoints — signup, magic-link redeem, login, logout,
// session whoami — that 2d will route off `worker.zig`'s prefix
// dispatch and onto admin's deployed bundle. Until 2d cuts over,
// Zig still serves /v1/*; this code is dormant on the wire.

const SESSION_COOKIE = "rove_session";
const SESSION_TTL_NS = 7 * 24 * 3600 * 1_000_000_000;
const MAGIC_TTL_NS   = 30 * 60 * 1_000_000_000;

function platformEmailFrom() {
    return kv.get("platform_email_from") || "noreply@loop46.me";
}

// Same RESERVED_INSTANCE_NAMES as worker.zig — admin's JS owns
// the list once the port lands so operators can adjust without a
// Zig recompile.
const RESERVED_NAMES = [
    "__admin__","admin","api","app","www",
    "auth","login","signup","logout","dashboard",
    "static","system","public","root","mail",
    "__replay__","replay",
];

function bytesToHex(bytes) {
    let s = "";
    for (let i = 0; i < bytes.length; i++) {
        const b = bytes[i];
        s += (b < 16 ? "0" : "") + b.toString(16);
    }
    return s;
}

// ms × 1e6 = ns. Date.now() returns ms so the multiply keeps
// precision in the same class as stored expires_at_ns values.
// Loss past 2^53 is real but uniform across both sides, so the
// inequality comparisons used below are within ~256 ns at the
// boundary — irrelevant for 30-min / 7-day TTLs.
function nowNs() { return Date.now() * 1_000_000; }

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

function validInstanceName(name) {
    return typeof name === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(name);
}

function validEmail(s) {
    if (typeof s !== "string") return false;
    if (s.length === 0 || s.length > 254) return false;
    const at = s.indexOf("@");
    if (at <= 0 || at !== s.lastIndexOf("@")) return false;
    if (at === s.length - 1) return false;
    return true;
}

function isReserved(name) {
    const lower = name.toLowerCase();
    for (let i = 0; i < RESERVED_NAMES.length; i++) {
        if (RESERVED_NAMES[i] === lower) return true;
    }
    return false;
}

function mintOpaque() { return bytesToHex(crypto.randomBytes(32)); }

function parseBody() {
    if (!request.body) return null;
    try { return JSON.parse(request.body); } catch (_) { return null; }
}

function jsonError(status, message) {
    response.status = status;
    return { error: message };
}

function formatSessionCookie(opaqueHex, clearing) {
    if (clearing) {
        return SESSION_COOKIE
            + "=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0";
    }
    const maxAgeS = Math.floor(SESSION_TTL_NS / 1_000_000_000);
    return SESSION_COOKIE + "=" + opaqueHex
        + "; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=" + maxAgeS;
}

// Auth check moved to `_middlewares/index.mjs`. Handlers below
// trust `request.auth = {is_root: bool}` set by the middleware.

function parseQueryParam(query, name) {
    const parts = (query || "").split("&");
    const prefix = name + "=";
    for (let i = 0; i < parts.length; i++) {
        if (parts[i].indexOf(prefix) === 0) {
            return parts[i].slice(prefix.length);
        }
    }
    return null;
}

function buildSignupEmailText(magicLink, name) {
    return "Welcome to Loop46!\n\n"
        + "Click the link below to finish signing up and land "
        + "in your dashboard:\n\n"
        + magicLink + "\n\n"
        + "This link expires in 30 minutes and can only be used once.\n\n"
        + "Your API will be live at:\n"
        + "  https://" + name + ".loop46.me";
}

// ── Account model ───────────────────────────────────────────────────
// Email is the account identity. account/{sha256(email)}/plan stores
// the tier; account/{hash}/instances/{instance_id} marks ownership.
// v1 hardcodes a single "free" tier with max_instances=1 — Phase 10
// will branch on plan values (rate caps, DLQ retention, blob caps,
// custom-domain counts, Stripe linkage). Seed-manifest tenants stay
// outside the account model entirely (no email, no account/* rows,
// no count toward any limit).

const PLAN_LIMITS = {
    free: { max_instances: 1 },
};

function accountHashFor(email) { return crypto.sha256(email); }

function planLimitsFor(accountHash) {
    const plan = kv.get("account/" + accountHash + "/plan") || "free";
    return PLAN_LIMITS[plan] || PLAN_LIMITS.free;
}

// Count this email's owned instances + non-expired pending
// reservations. Both kinds count against the limit — without the
// pending half, the free tier is trivially evadable: spam /v1/signup
// with N different names, never redeem, hold N name reservations
// forever (well, until expiry). Pending scan is O(global pending
// count); fine at v1 scale.
function countAccountUsage(accountHash, email) {
    const ownedRows = kv.prefix("account/" + accountHash + "/instances/", "", 1000);
    let pending = 0;
    const nowNsVal = nowNs();
    const pendingRows = kv.prefix("pending/", "", 1000);
    for (let i = 0; i < pendingRows.length; i++) {
        let row = null;
        try { row = JSON.parse(pendingRows[i].value); } catch (_) {}
        if (!row || row.email !== email) continue;
        if (nowNsVal >= row.expires_at_ns) continue; // expired; doesn't count
        pending++;
    }
    return { owned: ownedRows.length, pending: pending };
}

// POST /v1/signup — body {name, email}. Lazy creation: writes
// pending/{name} reservation + magic/{hash} record, queues
// signup email via outbox. Does NOT create the customer tenant
// — that happens at redeem time in handleAuth.
function handleSignup() {
    const body = parseBody();
    if (!body || typeof body.name !== "string"
              || typeof body.email !== "string") {
        return jsonError(400, "bad request body");
    }
    const name = body.name;
    const userEmail = body.email;

    if (!validEmail(userEmail))     return jsonError(400, "invalid email");
    if (!validInstanceName(name))   return jsonError(400, "invalid name");
    if (isReserved(name))           return jsonError(409, "name unavailable");

    // Duplicate check: live tenant OR non-expired pending.
    if (platform.root.get("instance/" + name) !== null) {
        return jsonError(409, "name unavailable");
    }
    const existingPending = kv.get("pending/" + name);
    if (existingPending) {
        let row = null;
        try { row = JSON.parse(existingPending); } catch (_) {}
        if (row && nowNs() < row.expires_at_ns) {
            return jsonError(409, "name unavailable");
        }
        kv.delete("pending/" + name);
    }

    // Per-account instance limit. owned+pending must stay under the
    // plan cap; signup-time check rejects most over-limit attempts,
    // redeem-time recheck (handleAuth) is the authoritative gate
    // against simultaneous-signup races. Default plan written
    // here on first signup so future limit lookups for this email
    // see the same value (Phase 10 will let operators bump).
    const accHash = accountHashFor(userEmail);
    const limits = planLimitsFor(accHash);
    const usage = countAccountUsage(accHash, userEmail);
    if (usage.owned + usage.pending >= limits.max_instances) {
        response.status = 403;
        return {
            error: "account_limit_reached",
            limit: limits.max_instances,
            owned: usage.owned,
            pending: usage.pending,
        };
    }
    if (kv.get("account/" + accHash + "/plan") === null) {
        kv.set("account/" + accHash + "/plan", "free");
    }

    const opaque = mintOpaque();
    const magicHash = crypto.sha256(opaque);
    const expires_at_ns = nowNs() + MAGIC_TTL_NS;

    kv.set("magic/" + magicHash, JSON.stringify({
        email: userEmail,
        instance_id: name,
        expires_at_ns: expires_at_ns,
    }));
    kv.set("pending/" + name, JSON.stringify({
        email: userEmail,
        expires_at_ns: expires_at_ns,
        magic_hash_hex: magicHash,
    }));

    const magicLink = "https://" + request.host + "/v1/auth?mt=" + opaque;

    const resendKey = kv.get("resend_key");
    if (resendKey) {
        // Production: queue real email via the existing email.send
        // wrapper. It writes _outbox/{id} into THIS handler's kv
        // (admin's app.db), which the leader-side drainer scans.
        email.send({
            key: resendKey,
            from: platformEmailFrom(),
            to: userEmail,
            subject: "Finish signing up for Loop46",
            text: buildSignupEmailText(magicLink, name),
        });
        response.status = 202;
        return { ok: true, name: name };
    }
    // Dev path: no Resend key configured → return link in body so
    // smoke + CLI can click through without an SMTP endpoint.
    response.status = 202;
    return { ok: true, name: name, magic_link: magicLink };
}

// GET /v1/auth?mt=<64-hex> — redeem the magic link, lazy-create
// the tenant + deploy starter, mint session, 302 to dashboard.
function handleAuth() {
    const mt = parseQueryParam(request.query, "mt");
    if (!isHex64(mt)) {
        response.status = 401;
        return { error: "invalid or expired magic link" };
    }

    const magicHash = crypto.sha256(mt);
    const raw = kv.get("magic/" + magicHash);
    if (!raw) {
        response.status = 401;
        return { error: "invalid or expired magic link" };
    }
    let row = null;
    try { row = JSON.parse(raw); } catch (_) {}
    // Single-use: drop the magic record up front (matches today's
    // tenant.redeemMagic). Re-clicks of the same link 401.
    kv.delete("magic/" + magicHash);
    if (!row || nowNs() >= row.expires_at_ns) {
        response.status = 401;
        return { error: "invalid or expired magic link" };
    }

    const name = row.instance_id;
    const userEmail = row.email;

    // Pending reservation must still exist — sweep would have
    // dropped it past expires_at_ns. Email mismatch protects
    // against magic/pending desync (shouldn't happen in practice).
    const pendingRaw = kv.get("pending/" + name);
    if (!pendingRaw) {
        response.status = 401;
        return { error: "signup not found" };
    }
    let pendingRow = null;
    try { pendingRow = JSON.parse(pendingRaw); } catch (_) {}
    if (!pendingRow || pendingRow.email !== userEmail) {
        response.status = 401;
        return { error: "signup not found" };
    }

    // Authoritative account-limit recheck. Two simultaneous signups
    // by the same email could both pass the signup-time gate when
    // limit > 1; only the second to redeem hits this. After this
    // redemption: owned' = owned + 1, pending' = pending - 1
    // (we're consuming our own pending), so total stays at
    // owned + pending — reject iff that exceeds the cap.
    const accHash = accountHashFor(userEmail);
    const limits = planLimitsFor(accHash);
    const usage = countAccountUsage(accHash, userEmail);
    if (usage.owned + usage.pending > limits.max_instances) {
        kv.delete("pending/" + name);
        response.status = 403;
        return {
            error: "account_limit_reached",
            limit: limits.max_instances,
        };
    }

    // Lazy creation: dir + app.db + marker, then starter content.
    // platform.instances.create is idempotent so a retried redeem
    // (e.g. session mint failed last time) doesn't double-create.
    try { platform.instances.create(name); }
    catch (e) {
        response.status = 500;
        return { error: "create failed: " + (e && e.message) };
    }
    // Starter content best-effort: same posture as today's Zig
    // signup — log on failure, customer still has a usable account
    // and can push their own code via the files API.
    try { platform.instances.deployStarter(name); } catch (_) {}

    // Mark account ownership BEFORE deleting pending. Future
    // signups by this email will see this in countAccountUsage.
    kv.set("account/" + accHash + "/instances/" + name, "");
    kv.delete("pending/" + name);

    const opaqueSession = mintOpaque();
    const sessionHash = crypto.sha256(opaqueSession);
    kv.set("session/" + sessionHash, JSON.stringify({
        expires_at_ns: nowNs() + SESSION_TTL_NS,
        is_root: true,
    }));

    response.status = 302;
    response.headers.location = "/#/" + name;
    response.cookies.push(formatSessionCookie(opaqueSession, false));
    return "";
}

// POST /v1/login — body {token}. Operator-issued root token →
// session cookie. Token must already exist as a root_token/{hash}
// row in root.db (provisioned by --bootstrap-root-token).
function handleLogin() {
    const body = parseBody();
    if (!body || !isHex64(body.token)) {
        response.status = 401;
        return { error: "invalid token" };
    }
    const tokenHash = crypto.sha256(body.token);
    if (platform.root.get("root_token/" + tokenHash) === null) {
        response.status = 401;
        return { error: "invalid token" };
    }
    const opaque = mintOpaque();
    const sessionHash = crypto.sha256(opaque);
    kv.set("session/" + sessionHash, JSON.stringify({
        expires_at_ns: nowNs() + SESSION_TTL_NS,
        is_root: true,
    }));
    response.status = 200;
    response.cookies.push(formatSessionCookie(opaque, false));
    return { ok: true };
}

// POST /v1/logout — revoke the session cookie's record + clear
// the cookie on the client. Idempotent.
function handleLogout() {
    const opaque = request.cookies[SESSION_COOKIE];
    if (isHex64(opaque)) {
        kv.delete("session/" + crypto.sha256(opaque));
    }
    response.status = 200;
    response.cookies.push(formatSessionCookie("", true));
    return { ok: true };
}

// GET /v1/session — whoami for a still-authenticated request.
function handleSession(auth) {
    return { is_root: !!auth.is_root };
}

export default function() {
    // request.path carries the full URL path including any
    // ?query suffix; strip it for exact-match dispatch below.
    const fullPath = request.path;
    const q = fullPath.indexOf("?");
    const path = q === -1 ? fullPath : fullPath.slice(0, q);
    const method = request.method;

    // Pre-auth paths skip the auth gate; everything else has
    // already passed through `_middlewares/index.mjs` which
    // either set request.auth or short-circuited 401. Handlers
    // here trust request.auth for any authed surfaces.
    if (method === "POST" && path === "/v1/signup") return handleSignup();
    if (method === "GET"  && path === "/v1/auth")   return handleAuth();
    if (method === "POST" && path === "/v1/login")  return handleLogin();
    if (method === "POST" && path === "/v1/logout") return handleLogout();
    if (method === "GET"  && path === "/v1/session") return handleSession(request.auth);

    response.status = 404;
    return { error: "not found" };
}
