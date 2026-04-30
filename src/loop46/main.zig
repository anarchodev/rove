//! `js-worker` — the production rove-js worker binary.
//!
//! Shared-nothing multi-worker model (promoted from the `dual-worker`
//! spike, 2026-04-14). A configurable number of worker threads each
//! own their own `Registry` / `Io` / `H2` / `Tenant` / `Dispatcher`,
//! all bound to the same HTTP/2 port via `SO_REUSEPORT`. The kernel
//! hashes incoming connections across workers. **Any worker handles
//! any tenant** — there is no tenant pinning.
//!
//! Shared between workers (all thread-safe):
//!   - the single `RaftNode` (proposes go through its MPSC queue;
//!     committedSeq/faultedSeq are atomics)
//!   - the single raft-owned `ApplyCtx` (only the raft thread touches
//!     its cached stores; workers never do)
//!   - the files-server + log-server subsystem threads
//!
//! Per-worker (thread-local):
//!   - rove `Registry`, rove-io `Io`, rove-h2 `H2`
//!   - per-worker `Tenant` with its own `__root__.db` sqlite connection
//!   - per-tenant `KvStore` + `LogStore` (every worker opens its own
//!     — NOMUTEX sqlite connections cannot be shared across threads)
//!   - qjs `Dispatcher` (its own arena + snapshot)
//!   - penalty box, proxy state, raft-pending collection
//!
//! ## Data layout
//!
//!   {data_dir}/
//!     __root__.db                  tenant metadata (domain → instance)
//!     raft.log.db                  shared raft log (node-scoped)
//!     acme/
//!       app.db                     acme's handler state
//!       files.db                    acme's code index (deployments)
//!       file-blobs/                acme's source + bytecode blobs
//!       log.db                     acme's request log index
//!       log-blobs/                 acme's request log blobs
//!     globex/
//!       ...
//!     penalty/
//!       ...
//!
//! acme is a hit counter; globex echoes the path; penalty is an
//! intentional `while(true) {}` that exercises the CPU-budget
//! interrupt + penalty box.
//!
//! ## Shutdown
//!
//! SIGINT/SIGTERM flip an atomic stop flag. Workers check it on every
//! poll loop iteration and exit cleanly. `io_uring_enter` returning
//! `error.SignalInterrupt` is tolerated — we just fall through to the
//! flag check. Main thread joins all worker threads before returning.

const std = @import("std");
const rove = @import("rove");
const rjs = @import("rove-js");
const kv = @import("rove-kv");
const blob_mod = @import("rove-blob");
const files_mod = @import("rove-files");
const files_server = @import("rove-files-server");
const log_server = @import("rove-log-server");
const outbox = @import("rove-outbox");
const qjs = @import("rove-qjs");
const tenant_mod = @import("rove-tenant");
const h2_mod = @import("rove-h2");

// Demo + benchmark tenants used to live inline as Zig string literals
// here. They now live as real `.mjs` files under
// `examples/loop46-demo-tenants/` and are provisioned via
// `loop46 seed --manifest examples/loop46-demo-tenants.json`. The
// worker discovers them on disk at startup; nothing about the demo
// set is hard-coded in this binary anymore.

/// JS source for the admin handler. Deployed to `__admin__` at
/// bootstrap. Each RPC function is a named export; the UI calls them
/// by name (`?fn=listInstance` or `POST {fn:"listInstance",args:[...]}`).
///
/// Reads platform-level state (instances, domains) via the
/// `platform.root.*` globals, which are only installed on the admin
/// handler (gated by `Instance.platform` being non-null). Writes go
/// through the same primitives but aren't replicated through raft
/// yet (single-node admin writes only) — multi-node correctness for
/// admin-handler writes is a follow-up; signup-driven instance
/// creation already goes through the replicated Zig-native path.
///
/// The KV RPCs (`listKv`, `setKv`, etc.) still operate on whatever
/// store the dispatcher selected — admin's own app.db by default,
/// the target tenant's app.db under `X-Rove-Scope: <id>`.
///
/// Status on error flows through the ambient `response` global;
/// non-200 return values use the `{ error }` shape as the body.
const ADMIN_HANDLER_SRC =
    \\function validId(id) {
    \\    return typeof id === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(id);
    \\}
    \\
    \\export function listInstance() {
    \\    const entries = platform.root.prefix("instance/", "", 1000);
    \\    return {
    \\        instances: entries.map((e) => ({
    \\            id: e.key.slice("instance/".length),
    \\        })),
    \\    };
    \\}
    \\
    \\export function getInstance(id) {
    \\    if (!validId(id)) { response.status = 400; return { error: "invalid id" }; }
    \\    const v = platform.root.get("instance/" + id);
    \\    if (v === null) { response.status = 404; return { error: "not found" }; }
    \\    return { id: id };
    \\}
    \\
    \\export function createInstance(id) {
    \\    if (!validId(id)) { response.status = 400; return { error: "invalid id" }; }
    \\    platform.root.set("instance/" + id, "");
    \\    response.status = 201;
    \\    return { id: id };
    \\}
    \\
    \\export function deleteInstance(id) {
    \\    if (!validId(id)) { response.status = 400; return { error: "invalid id" }; }
    \\    platform.root.delete("instance/" + id);
    \\    const doms = platform.root.prefix("domain/", "", 1000);
    \\    for (let i = 0; i < doms.length; i++) {
    \\        if (doms[i].value === id) platform.root.delete(doms[i].key);
    \\    }
    \\    response.status = 204;
    \\    return null;
    \\}
    \\
    \\export function listDomain() {
    \\    const entries = platform.root.prefix("domain/", "", 1000);
    \\    return {
    \\        domains: entries.map((e) => ({
    \\            host: e.key.slice("domain/".length),
    \\            instance_id: e.value,
    \\        })),
    \\    };
    \\}
    \\
    \\export function assignDomain(host, instance_id) {
    \\    if (!host || !instance_id) {
    \\        response.status = 400;
    \\        return { error: "host and instance_id required" };
    \\    }
    \\    const exists = platform.root.get("instance/" + instance_id);
    \\    if (exists === null) {
    \\        response.status = 404;
    \\        return { error: "instance not found" };
    \\    }
    \\    platform.root.set("domain/" + host, instance_id);
    \\    response.status = 201;
    \\    return { host: host, instance_id: instance_id };
    \\}
    \\
    \\export function listKv(prefix, cursor, limit) {
    \\    const p = prefix || "";
    \\    const c = cursor || "";
    \\    const l = Math.max(1, Math.min(parseInt(limit ?? 100, 10) || 100, 1000));
    \\    const entries = kv.prefix(p, c, l);
    \\    const body = {
    \\        entries: entries.map((e) => ({ key: e.key, value: e.value })),
    \\    };
    \\    if (entries.length === l && entries.length > 0) {
    \\        body.next_cursor = entries[entries.length - 1].key;
    \\    }
    \\    return body;
    \\}
    \\
    \\export function getKv(key) {
    \\    if (!key) {
    \\        response.status = 400;
    \\        return { error: "missing key" };
    \\    }
    \\    const v = kv.get(key);
    \\    if (v === null) {
    \\        response.status = 404;
    \\        return { error: "not found" };
    \\    }
    \\    return v;
    \\}
    \\
    \\export function setKv(key, value) {
    \\    if (!key) {
    \\        response.status = 400;
    \\        return { error: "missing key" };
    \\    }
    \\    if (typeof value !== "string") {
    \\        response.status = 400;
    \\        return { error: "value must be a string" };
    \\    }
    \\    kv.set(key, value);
    \\    return { key: key };
    \\}
    \\
    \\export function deleteKv(key) {
    \\    if (!key) {
    \\        response.status = 400;
    \\        return { error: "missing key" };
    \\    }
    \\    kv.delete(key);
    \\    response.status = 204;
    \\    return null;
    \\}
    \\
    \\// ── /v1/* path-routed admin handlers ────────────────────────────────
    \\//
    \\// The named exports above are the dashboard's RPC surface
    \\// (?fn=name); they're auth-gated in Zig (extractAdminAuth) and
    \\// don't see this default. The default below owns the path-routed
    \\// admin endpoints — signup, magic-link redeem, login, logout,
    \\// session whoami — that 2d will route off `worker.zig`'s prefix
    \\// dispatch and onto admin's deployed bundle. Until 2d cuts over,
    \\// Zig still serves /v1/*; this code is dormant on the wire.
    \\
    \\const SESSION_COOKIE = "rove_session";
    \\const SESSION_TTL_NS = 7 * 24 * 3600 * 1_000_000_000;
    \\const MAGIC_TTL_NS   = 30 * 60 * 1_000_000_000;
    \\
    \\function platformEmailFrom() {
    \\    return kv.get("platform_email_from") || "noreply@loop46.me";
    \\}
    \\
    \\// Same RESERVED_INSTANCE_NAMES as worker.zig — admin's JS owns
    \\// the list once the port lands so operators can adjust without a
    \\// Zig recompile.
    \\const RESERVED_NAMES = [
    \\    "__admin__","admin","api","app","www",
    \\    "auth","login","signup","logout","dashboard",
    \\    "static","system","public","root","mail",
    \\];
    \\
    \\function bytesToHex(bytes) {
    \\    let s = "";
    \\    for (let i = 0; i < bytes.length; i++) {
    \\        const b = bytes[i];
    \\        s += (b < 16 ? "0" : "") + b.toString(16);
    \\    }
    \\    return s;
    \\}
    \\
    \\// ms × 1e6 = ns. Date.now() returns ms so the multiply keeps
    \\// precision in the same class as stored expires_at_ns values.
    \\// Loss past 2^53 is real but uniform across both sides, so the
    \\// inequality comparisons used below are within ~256 ns at the
    \\// boundary — irrelevant for 30-min / 7-day TTLs.
    \\function nowNs() { return Date.now() * 1_000_000; }
    \\
    \\function isHex64(s) {
    \\    if (typeof s !== "string" || s.length !== 64) return false;
    \\    for (let i = 0; i < 64; i++) {
    \\        const c = s.charCodeAt(i);
    \\        if (!((c >= 48 && c <= 57)
    \\           || (c >= 97 && c <= 102)
    \\           || (c >= 65 && c <= 70))) return false;
    \\    }
    \\    return true;
    \\}
    \\
    \\function validInstanceName(name) {
    \\    return typeof name === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(name);
    \\}
    \\
    \\function validEmail(s) {
    \\    if (typeof s !== "string") return false;
    \\    if (s.length === 0 || s.length > 254) return false;
    \\    const at = s.indexOf("@");
    \\    if (at <= 0 || at !== s.lastIndexOf("@")) return false;
    \\    if (at === s.length - 1) return false;
    \\    return true;
    \\}
    \\
    \\function isReserved(name) {
    \\    const lower = name.toLowerCase();
    \\    for (let i = 0; i < RESERVED_NAMES.length; i++) {
    \\        if (RESERVED_NAMES[i] === lower) return true;
    \\    }
    \\    return false;
    \\}
    \\
    \\function mintOpaque() { return bytesToHex(crypto.randomBytes(32)); }
    \\
    \\function parseBody() {
    \\    if (!request.body) return null;
    \\    try { return JSON.parse(request.body); } catch (_) { return null; }
    \\}
    \\
    \\function jsonError(status, message) {
    \\    response.status = status;
    \\    return { error: message };
    \\}
    \\
    \\function formatSessionCookie(opaqueHex, clearing) {
    \\    if (clearing) {
    \\        return SESSION_COOKIE
    \\            + "=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0";
    \\    }
    \\    const maxAgeS = Math.floor(SESSION_TTL_NS / 1_000_000_000);
    \\    return SESSION_COOKIE + "=" + opaqueHex
    \\        + "; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=" + maxAgeS;
    \\}
    \\
    \\// Authenticate via session cookie OR Authorization: Bearer
    \\// (root token issued at bootstrap). Cookie path: hash, kv.get
    \\// session/{hash}, sweep on expiry. Bearer path: hash, look up
    \\// root_token/{hash} in root.db. Bearer-authed callers always
    \\// get is_root=true; the dashboard's RPC path uses cookies.
    \\function checkSession() {
    \\    const opaque = request.cookies[SESSION_COOKIE];
    \\    if (isHex64(opaque)) {
    \\        const hash = crypto.sha256(opaque);
    \\        const raw = kv.get("session/" + hash);
    \\        if (raw) {
    \\            let row = null;
    \\            try { row = JSON.parse(raw); } catch (_) {}
    \\            if (!row) { kv.delete("session/" + hash); }
    \\            else if (nowNs() >= row.expires_at_ns) {
    \\                kv.delete("session/" + hash);
    \\            } else {
    \\                return { is_root: !!row.is_root };
    \\            }
    \\        }
    \\    }
    \\    const auth = request.headers.authorization;
    \\    if (typeof auth === "string" && auth.length > 7) {
    \\        const lower = auth.slice(0, 7).toLowerCase();
    \\        if (lower === "bearer ") {
    \\            const token = auth.slice(7).trim();
    \\            if (isHex64(token)) {
    \\                if (platform.root.get("root_token/" + crypto.sha256(token)) !== null) {
    \\                    return { is_root: true };
    \\                }
    \\            }
    \\        }
    \\    }
    \\    return null;
    \\}
    \\
    \\function parseQueryParam(query, name) {
    \\    const parts = (query || "").split("&");
    \\    const prefix = name + "=";
    \\    for (let i = 0; i < parts.length; i++) {
    \\        if (parts[i].indexOf(prefix) === 0) {
    \\            return parts[i].slice(prefix.length);
    \\        }
    \\    }
    \\    return null;
    \\}
    \\
    \\function buildSignupEmailText(magicLink, name) {
    \\    return "Welcome to Loop46!\n\n"
    \\        + "Click the link below to finish signing up and land "
    \\        + "in your dashboard:\n\n"
    \\        + magicLink + "\n\n"
    \\        + "This link expires in 30 minutes and can only be used once.\n\n"
    \\        + "Your API will be live at:\n"
    \\        + "  https://" + name + ".loop46.me";
    \\}
    \\
    \\// POST /v1/signup — body {name, email}. Lazy creation: writes
    \\// pending/{name} reservation + magic/{hash} record, queues
    \\// signup email via outbox. Does NOT create the customer tenant
    \\// — that happens at redeem time in handleAuth.
    \\function handleSignup() {
    \\    const body = parseBody();
    \\    if (!body || typeof body.name !== "string"
    \\              || typeof body.email !== "string") {
    \\        return jsonError(400, "bad request body");
    \\    }
    \\    const name = body.name;
    \\    const userEmail = body.email;
    \\
    \\    if (!validEmail(userEmail))     return jsonError(400, "invalid email");
    \\    if (!validInstanceName(name))   return jsonError(400, "invalid name");
    \\    if (isReserved(name))           return jsonError(409, "name unavailable");
    \\
    \\    // Duplicate check: live tenant OR non-expired pending.
    \\    if (platform.root.get("instance/" + name) !== null) {
    \\        return jsonError(409, "name unavailable");
    \\    }
    \\    const existingPending = kv.get("pending/" + name);
    \\    if (existingPending) {
    \\        let row = null;
    \\        try { row = JSON.parse(existingPending); } catch (_) {}
    \\        if (row && nowNs() < row.expires_at_ns) {
    \\            return jsonError(409, "name unavailable");
    \\        }
    \\        kv.delete("pending/" + name);
    \\    }
    \\
    \\    const opaque = mintOpaque();
    \\    const magicHash = crypto.sha256(opaque);
    \\    const expires_at_ns = nowNs() + MAGIC_TTL_NS;
    \\
    \\    kv.set("magic/" + magicHash, JSON.stringify({
    \\        email: userEmail,
    \\        instance_id: name,
    \\        expires_at_ns: expires_at_ns,
    \\    }));
    \\    kv.set("pending/" + name, JSON.stringify({
    \\        email: userEmail,
    \\        expires_at_ns: expires_at_ns,
    \\        magic_hash_hex: magicHash,
    \\    }));
    \\
    \\    const magicLink = "https://" + request.host + "/v1/auth?mt=" + opaque;
    \\
    \\    const resendKey = kv.get("resend_key");
    \\    if (resendKey) {
    \\        // Production: queue real email via the existing email.send
    \\        // wrapper. It writes _outbox/{id} into THIS handler's kv
    \\        // (admin's app.db), which the leader-side drainer scans.
    \\        email.send({
    \\            key: resendKey,
    \\            from: platformEmailFrom(),
    \\            to: userEmail,
    \\            subject: "Finish signing up for Loop46",
    \\            text: buildSignupEmailText(magicLink, name),
    \\        });
    \\        response.status = 202;
    \\        return { ok: true, name: name };
    \\    }
    \\    // Dev path: no Resend key configured → return link in body so
    \\    // smoke + CLI can click through without an SMTP endpoint.
    \\    response.status = 202;
    \\    return { ok: true, name: name, magic_link: magicLink };
    \\}
    \\
    \\// GET /v1/auth?mt=<64-hex> — redeem the magic link, lazy-create
    \\// the tenant + deploy starter, mint session, 302 to dashboard.
    \\function handleAuth() {
    \\    const mt = parseQueryParam(request.query, "mt");
    \\    if (!isHex64(mt)) {
    \\        response.status = 401;
    \\        return { error: "invalid or expired magic link" };
    \\    }
    \\
    \\    const magicHash = crypto.sha256(mt);
    \\    const raw = kv.get("magic/" + magicHash);
    \\    if (!raw) {
    \\        response.status = 401;
    \\        return { error: "invalid or expired magic link" };
    \\    }
    \\    let row = null;
    \\    try { row = JSON.parse(raw); } catch (_) {}
    \\    // Single-use: drop the magic record up front (matches today's
    \\    // tenant.redeemMagic). Re-clicks of the same link 401.
    \\    kv.delete("magic/" + magicHash);
    \\    if (!row || nowNs() >= row.expires_at_ns) {
    \\        response.status = 401;
    \\        return { error: "invalid or expired magic link" };
    \\    }
    \\
    \\    const name = row.instance_id;
    \\    const userEmail = row.email;
    \\
    \\    // Pending reservation must still exist — sweep would have
    \\    // dropped it past expires_at_ns. Email mismatch protects
    \\    // against magic/pending desync (shouldn't happen in practice).
    \\    const pendingRaw = kv.get("pending/" + name);
    \\    if (!pendingRaw) {
    \\        response.status = 401;
    \\        return { error: "signup not found" };
    \\    }
    \\    let pendingRow = null;
    \\    try { pendingRow = JSON.parse(pendingRaw); } catch (_) {}
    \\    if (!pendingRow || pendingRow.email !== userEmail) {
    \\        response.status = 401;
    \\        return { error: "signup not found" };
    \\    }
    \\
    \\    // Lazy creation: dir + app.db + marker, then starter content.
    \\    // platform.instances.create is idempotent so a retried redeem
    \\    // (e.g. session mint failed last time) doesn't double-create.
    \\    try { platform.instances.create(name); }
    \\    catch (e) {
    \\        response.status = 500;
    \\        return { error: "create failed: " + (e && e.message) };
    \\    }
    \\    // Starter content best-effort: same posture as today's Zig
    \\    // signup — log on failure, customer still has a usable account
    \\    // and can push their own code via the files API.
    \\    try { platform.instances.deployStarter(name); } catch (_) {}
    \\
    \\    kv.delete("pending/" + name);
    \\
    \\    const opaqueSession = mintOpaque();
    \\    const sessionHash = crypto.sha256(opaqueSession);
    \\    kv.set("session/" + sessionHash, JSON.stringify({
    \\        expires_at_ns: nowNs() + SESSION_TTL_NS,
    \\        is_root: true,
    \\    }));
    \\
    \\    response.status = 302;
    \\    response.headers.location = "/#/" + name;
    \\    response.cookies.push(formatSessionCookie(opaqueSession, false));
    \\    return "";
    \\}
    \\
    \\// POST /v1/login — body {token}. Operator-issued root token →
    \\// session cookie. Token must already exist as a root_token/{hash}
    \\// row in root.db (provisioned by --bootstrap-root-token).
    \\function handleLogin() {
    \\    const body = parseBody();
    \\    if (!body || !isHex64(body.token)) {
    \\        response.status = 401;
    \\        return { error: "invalid token" };
    \\    }
    \\    const tokenHash = crypto.sha256(body.token);
    \\    if (platform.root.get("root_token/" + tokenHash) === null) {
    \\        response.status = 401;
    \\        return { error: "invalid token" };
    \\    }
    \\    const opaque = mintOpaque();
    \\    const sessionHash = crypto.sha256(opaque);
    \\    kv.set("session/" + sessionHash, JSON.stringify({
    \\        expires_at_ns: nowNs() + SESSION_TTL_NS,
    \\        is_root: true,
    \\    }));
    \\    response.status = 200;
    \\    response.cookies.push(formatSessionCookie(opaque, false));
    \\    return { ok: true };
    \\}
    \\
    \\// POST /v1/logout — revoke the session cookie's record + clear
    \\// the cookie on the client. Idempotent.
    \\function handleLogout() {
    \\    const opaque = request.cookies[SESSION_COOKIE];
    \\    if (isHex64(opaque)) {
    \\        kv.delete("session/" + crypto.sha256(opaque));
    \\    }
    \\    response.status = 200;
    \\    response.cookies.push(formatSessionCookie("", true));
    \\    return { ok: true };
    \\}
    \\
    \\// GET /v1/session — whoami for a still-authenticated request.
    \\function handleSession(auth) {
    \\    return { is_root: !!auth.is_root };
    \\}
    \\
    \\export default function() {
    \\    // request.path carries the full URL path including any
    \\    // ?query suffix; strip it for exact-match dispatch below.
    \\    const fullPath = request.path;
    \\    const q = fullPath.indexOf("?");
    \\    const path = q === -1 ? fullPath : fullPath.slice(0, q);
    \\    const method = request.method;
    \\
    \\    // Pre-auth: signup + magic-link redeem + token login + logout
    \\    // never require a session cookie.
    \\    if (method === "POST" && path === "/v1/signup") return handleSignup();
    \\    if (method === "GET"  && path === "/v1/auth")   return handleAuth();
    \\    if (method === "POST" && path === "/v1/login")  return handleLogin();
    \\    if (method === "POST" && path === "/v1/logout") return handleLogout();
    \\
    \\    // Everything else under default is auth-gated. The dashboard's
    \\    // ?fn=<name> RPCs bypass default entirely (named-export
    \\    // dispatch) and stay Zig-auth-gated for now — see worker.zig's
    \\    // `extractAdminAuth`. Revisiting that is post-2d cleanup.
    \\    const auth = checkSession();
    \\    if (!auth) {
    \\        response.status = 401;
    \\        return { error: "unauthenticated" };
    \\    }
    \\    if (method === "GET" && path === "/v1/session") return handleSession(auth);
    \\
    \\    response.status = 404;
    \\    return { error: "not found" };
    \\}
;

/// Cap on `--bootstrap-kv` repetitions. Way past anything a real
/// operator needs (a handful of API keys + email-from + maybe a
/// dashboard origin); generous enough that bumping it later is a
/// non-event. Allocator-free Cli parsing depends on a fixed bound.
const MAX_BOOTSTRAP_KV: usize = 32;

const Cli = struct {
    node_id: u32 = 0,
    /// Comma-separated `host:port` list. Position determines node_id.
    peers: []const u8 = "127.0.0.1:40100",
    /// `host:port` this node listens on for raft RPCs. Must match the
    /// peers entry at index `node_id`.
    listen: []const u8 = "127.0.0.1:40100",
    /// HTTP/2 listen address (all workers share this via SO_REUSEPORT).
    http: []const u8 = "127.0.0.1:8082",
    /// Per-node data directory. Each node MUST have a unique dir.
    data_dir: []const u8 = "/tmp/rove-js-data",
    /// If true, wipe the data dir before starting (smoke-test mode).
    fresh: bool = false,
    /// Hex-encoded 256-bit root token. When set, the worker installs
    /// it into the tenant root store at startup; any subsequent
    /// `/_system/*` request must carry this token in an
    /// `Authorization: Bearer <hex>` header.
    bootstrap_root_token: ?[]const u8 = null,
    /// Generic seed-into-admin's-app.db config pairs. Each pair is
    /// the raw `key=value` argv string; bootstrap splits at the
    /// first `=` and writes to admin's kv before workers start
    /// serving. Replaces the older typed flags
    /// (`--bootstrap-resend-key`, `--platform-email-from`) so Zig
    /// no longer enumerates which config keys exist — admin's JS
    /// handler reads whatever it cares about via `kv.get`.
    bootstrap_kv: [MAX_BOOTSTRAP_KV][]const u8 = undefined,
    bootstrap_kv_count: usize = 0,
    /// Number of worker threads. Each owns its own Registry/Io/H2/
    /// Tenant/Dispatcher and binds the same HTTP/2 port via
    /// SO_REUSEPORT. Defaults to the number of online CPUs.
    workers: u16 = 0,
    /// Origin allowed to call `/_system/*` with CORS. When set, the
    /// worker responds to preflight (OPTIONS) requests from this
    /// origin and adds `Access-Control-Allow-*` headers to all
    /// `/_system/*` responses. Required for the browser admin UI in
    /// dev (typically `http://localhost:5173`) and prod (e.g.
    /// `https://admin.example.com`). Unset = no CORS, and the admin
    /// UI must be served same-origin or go through a proxy.
    admin_origin: ?[]const u8 = null,
    /// Hostname of the admin API + dashboard. Auto-derived to
    /// `app.{public_suffix}` when only `--public-suffix` is passed
    /// (the common case); this flag is the escape hatch for serving
    /// admin on a non-`app.` host.
    ///
    /// When set, any request whose Host matches `admin_api_domain`
    /// runs the `__admin__` tenant's handler. `kv` defaults to
    /// `__admin__`'s own app.db; an `X-Rove-Scope: <id>` header
    /// rebinds `kv` onto `<id>`'s store for cross-tenant browsing.
    /// Requires a root bearer token (or session cookie minted via
    /// `/v1/login`).
    admin_api_domain: ?[]const u8 = null,
    /// Wildcard customer-app suffix. Enables `{id}.{public_suffix}` →
    /// instance `{id}` resolution without needing `assignDomain` per
    /// tenant. Explicit domain aliases still win.
    ///
    /// Also drives the default `admin_api_domain` (`app.{public_suffix}`).
    /// Example: `--public-suffix loop46.me` →
    /// admin at `app.loop46.me`, customers at `{id}.loop46.me`.
    public_suffix: ?[]const u8 = null,
    /// TLS certificate path (PEM, full chain). When both this and
    /// `tls_key` are set, the `--http` listener speaks HTTPS (h2 over
    /// TLS) instead of plaintext h2c. Changes to either file on disk
    /// are picked up on a periodic mtime check, so cert renewal by a
    /// sidecar (e.g. scripts/rove-lego-renew.sh) reloads in-process
    /// without a restart.
    tls_cert: ?[]const u8 = null,
    /// TLS private key path (PEM). See `tls_cert`.
    tls_key: ?[]const u8 = null,
    /// Raft proposal linger budget, in microseconds. Hold pending
    /// proposals up to this long so the raft thread can pack more
    /// into a single `raft_log.db` commit + fsync. Under heavy write
    /// load at multi-worker scale, the raft thread's per-tick fsync
    /// is the single hard ceiling on write throughput — every
    /// writeset funnels through one raft log regardless of how many
    /// dispatch workers are running. Trading a few hundred µs of
    /// commit latency for a 3–5× write throughput lift is usually
    /// worth it. 0 disables linger (every tick commits whatever it
    /// has). Mapped directly to `RaftNodeConfig.propose_linger_ns`
    /// at init time.
    propose_linger_us: u64 = 500,
    /// How often each tenant's `deployment/current` is polled for
    /// changes. Low values make new deploys visible fast (good for
    /// tests); high values reduce per-tenant kv work. Mapped onto
    /// `WorkerConfig.refresh_interval_ns`. 0 means "every tick".
    refresh_interval_ms: u32 = 2000,
    /// **DEV-ONLY.** Relax the outbox drainer's SSRF block on
    /// loopback (`127/8`, `::1`) and accept `http://` webhook URLs.
    /// Intended for local smoke tests against an on-box HTTP echo
    /// server. Never set this in production — it lets a malicious
    /// customer handler probe localhost and leaks request bodies
    /// over plaintext. Startup emits a loud warning when enabled.
    dev_webhook_unsafe: bool = false,
    /// **Local-dev convenience flag.** When set, the worker uses
    /// mkcert-issued TLS at the platform-default loop46 data dir
    /// (see `defaultDevTlsPaths`). On first run, if the cert is
    /// missing, the binary auto-bootstraps via mkcert (registers
    /// the local CA, generates the cert, symlinks the rootCA path)
    /// and continues. mkcert must be installed; missing → fail
    /// loudly with install hints. Per the "h2+TLS everywhere even
    /// in dev" stake-in-the-ground, `--dev` mode does NOT fall back
    /// to plaintext h2c — it's TLS or fail.
    ///
    /// Has no effect in production — explicit `--tls-cert` /
    /// `--tls-key` always win, and the unset case (no `--dev`)
    /// keeps the existing plaintext h2c behavior used by the
    /// smoke scripts.
    dev: bool = false,
    /// Per-(instance, action) rate limit caps. Defaults match
    /// `limiter.RateLimitCaps`'s defaults; flags below let
    /// operators tune them at launch + smoke tests dial them
    /// down to small values to provoke 429s in a few requests.
    rate_limit_request_capacity: u32 = 100,
    rate_limit_request_refill: u32 = 50,
    rate_limit_email_capacity: u32 = 10,
    rate_limit_email_refill: u32 = 1,
};

fn parseCli(args: []const [:0]u8) !Cli {
    var out: Cli = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--node-id")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.node_id = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--peers")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.peers = args[i];
        } else if (std.mem.eql(u8, a, "--listen")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.listen = args[i];
        } else if (std.mem.eql(u8, a, "--http")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.http = args[i];
        } else if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.data_dir = args[i];
        } else if (std.mem.eql(u8, a, "--fresh")) {
            out.fresh = true;
        } else if (std.mem.eql(u8, a, "--bootstrap-root-token")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.bootstrap_root_token = args[i];
        } else if (std.mem.eql(u8, a, "--bootstrap-kv")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            if (out.bootstrap_kv_count >= MAX_BOOTSTRAP_KV) {
                std.debug.print(
                    "error: too many --bootstrap-kv flags (max {d})\n",
                    .{MAX_BOOTSTRAP_KV},
                );
                return error.Usage;
            }
            // The argv slice survives for the lifetime of the binary;
            // store the raw `key=value` string and split at use site.
            out.bootstrap_kv[out.bootstrap_kv_count] = args[i];
            out.bootstrap_kv_count += 1;
        } else if (std.mem.eql(u8, a, "--workers")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.workers = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, a, "--admin-origin")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.admin_origin = args[i];
        } else if (std.mem.eql(u8, a, "--admin-api-domain")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.admin_api_domain = args[i];
        } else if (std.mem.eql(u8, a, "--public-suffix")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.public_suffix = args[i];
        } else if (std.mem.eql(u8, a, "--tls-cert")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.tls_cert = args[i];
        } else if (std.mem.eql(u8, a, "--tls-key")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.tls_key = args[i];
        } else if (std.mem.eql(u8, a, "--propose-linger-us")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.propose_linger_us = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--refresh-interval-ms")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.refresh_interval_ms = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--dev-webhook-unsafe")) {
            out.dev_webhook_unsafe = true;
        } else if (std.mem.eql(u8, a, "--rate-limit-request-capacity")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.rate_limit_request_capacity = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--rate-limit-request-refill")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.rate_limit_request_refill = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--rate-limit-email-capacity")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.rate_limit_email_capacity = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--rate-limit-email-refill")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.rate_limit_email_refill = try std.fmt.parseInt(u32, args[i], 10);
        } else {
            return error.Usage;
        }
    }
    return out;
}

/// Resolve the default loop46 data directory for the current OS.
/// Mirrors mkcert's convention so devs who already know mkcert
/// recognize the layout.
///
///   Linux:   ${XDG_DATA_HOME:-$HOME/.local/share}/loop46
///   macOS:   $HOME/Library/Application Support/loop46
///   other:   XDG default (best effort)
///
/// Returned slice is owned by the caller.
fn defaultLoop46DataDir(allocator: std.mem.Allocator) ![]u8 {
    const builtin = @import("builtin");
    const home = std.posix.getenv("HOME") orelse "";

    if (builtin.os.tag == .macos) {
        return std.fmt.allocPrint(allocator, "{s}/Library/Application Support/loop46", .{home});
    }

    if (std.posix.getenv("XDG_DATA_HOME")) |xdg| {
        if (xdg.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}/loop46", .{xdg});
        }
    }
    return std.fmt.allocPrint(allocator, "{s}/.local/share/loop46", .{home});
}

/// Default TLS cert + key paths used by `--dev` mode. Files are
/// produced by `scripts/rove-dev-setup.sh` via mkcert. Caller frees
/// both slices.
fn defaultDevTlsPaths(allocator: std.mem.Allocator) !struct { cert: []u8, key: []u8, dir: []u8 } {
    const dir = try defaultLoop46DataDir(allocator);
    errdefer allocator.free(dir);
    const cert = try std.fmt.allocPrint(allocator, "{s}/dev-cert.pem", .{dir});
    errdefer allocator.free(cert);
    const key = try std.fmt.allocPrint(allocator, "{s}/dev-key.pem", .{dir});
    return .{ .cert = cert, .key = key, .dir = dir };
}

/// Both files exist + are readable?
fn devTlsPathsExist(cert: []const u8, key: []const u8) bool {
    std.fs.cwd().access(cert, .{}) catch return false;
    std.fs.cwd().access(key, .{}) catch return false;
    return true;
}

/// Read or generate a 64-hex-char dev root token. First call writes
/// 32 random bytes hex-encoded to `<dir>/dev-root-token` (mode 0600);
/// subsequent calls read the same file so the operator's curl /
/// browser sessions keep working across worker restarts. Delete the
/// file to "rotate." Returned slice is owned by the caller.
fn resolveDevRootToken(allocator: std.mem.Allocator, dir: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/dev-root-token", .{dir});
    defer allocator.free(path);

    // Try existing file first.
    if (std.fs.cwd().readFileAlloc(allocator, path, 256)) |existing| {
        defer allocator.free(existing);
        const trimmed = std.mem.trim(u8, existing, " \t\r\n");
        // Sanity bounds: 32-128 ASCII chars per the bootstrap-root-token
        // contract. If the file is corrupt, regenerate rather than fail.
        if (trimmed.len >= 32 and trimmed.len <= 128) {
            return try allocator.dupe(u8, trimmed);
        }
    } else |_| {}

    // Generate 32 random bytes → 64 hex chars.
    var bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    const hex_chars = "0123456789abcdef";
    const hex = try allocator.alloc(u8, 64);
    errdefer allocator.free(hex);
    for (bytes, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0xf];
    }

    // Ensure dir exists, then write with mode 0600 so other local users
    // can't curl-as-admin against this dev box.
    std.fs.cwd().makePath(dir) catch {};
    const file = try std.fs.cwd().createFile(path, .{ .mode = 0o600 });
    defer file.close();
    try file.writeAll(hex);

    std.log.info("--dev: generated root token, saved to {s} (mode 0600)", .{path});
    return hex;
}

/// Extract the port from a "host:port" string. Returns null if
/// missing or malformed; caller falls back to a sensible default.
fn portFromAddr(addr: []const u8) ?u16 {
    const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return null;
    return std.fmt.parseInt(u16, addr[colon + 1 ..], 10) catch null;
}

/// Run after `parseCli`: apply the `--dev` preset (when active), then
/// derive any cli fields the operator left implicit. Each step is a
/// no-op when the corresponding flag was passed explicitly — explicit
/// flags always win.
///
/// `--dev` preset (sets only what makes dev convenient):
///   --public-suffix       → "loop46.localhost"
///   --bootstrap-root-token → read or generate at
///                            <loop46-data-dir>/dev-root-token
///   --admin-origin        → "https://<admin-api-domain>:<port-from-http>"
///
/// Always-on derivations (apply in dev and prod):
///   --admin-api-domain    → "app.{public_suffix}"
///                            (skipped when public_suffix is also unset)
///
/// Mirrors production's `*.loop46.me` layout exactly: admin at
/// `app.loop46.localhost`, customer instances at
/// `{id}.loop46.localhost`. A single 3-label wildcard SAN
/// `*.loop46.localhost` covers both. Per RFC 6761 any subdomain of
/// `localhost` resolves to loopback so no /etc/hosts edits are
/// needed. `app` is in the signup reserved-name list so customers
/// can't claim it as their instance name.
fn finalizeCli(allocator: std.mem.Allocator, cli: *Cli) !void {
    if (cli.dev) {
        if (cli.public_suffix == null) {
            cli.public_suffix = "loop46.localhost";
        }
        if (cli.bootstrap_root_token == null) {
            const dir = try defaultLoop46DataDir(allocator);
            defer allocator.free(dir);
            cli.bootstrap_root_token = try resolveDevRootToken(allocator, dir);
        }
    } else {
        // Worker mode requires --public-suffix. Without it, wildcard
        // customer-subdomain resolution is disabled and admin_api_domain
        // can't auto-default to `app.{ps}` either — the worker would
        // listen but be unreachable for any HTTP traffic that hasn't
        // been hand-aliased into root.db. Fail fast so the operator
        // learns about the misconfig at startup, not via empty
        // 404s after a deploy.
        if (cli.public_suffix == null) {
            std.debug.print(
                "error: --public-suffix is required in worker mode " ++
                    "(without it, customer subdomains cannot resolve and " ++
                    "admin_api_domain cannot default to app.{{public-suffix}}).\n" ++
                    "       pass e.g. --public-suffix loop46.me, or use " ++
                    "`loop46 dev` for local quickstart defaults.\n",
                .{},
            );
            return error.Usage;
        }
    }

    if (cli.admin_api_domain == null) {
        if (cli.public_suffix) |ps| {
            cli.admin_api_domain = try std.fmt.allocPrint(
                allocator,
                "app.{s}",
                .{ps},
            );
        }
    }

    if (cli.dev and cli.admin_origin == null and cli.admin_api_domain != null) {
        const port = portFromAddr(cli.http) orelse 8443;
        cli.admin_origin = try std.fmt.allocPrint(
            allocator,
            "https://{s}:{d}",
            .{ cli.admin_api_domain.?, port },
        );
    }
}

const MKCERT_NOT_FOUND_HINT =
    \\error: mkcert is not installed (required for --dev TLS).
    \\
    \\Install instructions:
    \\  Linux (Debian/Ubuntu):  sudo apt install libnss3-tools && \
    \\                          curl -L https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-v1.4.4-linux-amd64 -o /usr/local/bin/mkcert && \
    \\                          sudo chmod +x /usr/local/bin/mkcert
    \\  Linux (Fedora):         sudo dnf install nss-tools mkcert
    \\  macOS:                  brew install mkcert nss
    \\  Windows / other:        https://github.com/FiloSottile/mkcert#installation
    \\
    \\Then re-run `js-worker --dev`.
    \\
;

/// Run `mkcert` once at the loop46 data dir to provision a dev TLS
/// cert + key. Idempotent — re-running over an existing setup just
/// rewrites the files. Errors with install hints if mkcert isn't on
/// PATH (a stake-in-the-ground "dev = TLS or fail" — no plaintext
/// fallback, see PLAN §1.5).
///
/// Subprocess steps (matching the legacy scripts/rove-dev-setup.sh
/// the binary now subsumes):
///   1. mkcert -CAROOT  → confirm mkcert is installed AND get the
///                        rootCA path for the symlink later.
///   2. mkcert -install → register the local CA into system + browser
///                        trust stores. Inherits stdio so sudo /
///                        Keychain prompts are visible to the user.
///   3. mkcert -cert-file <cert> -key-file <key> <SANs>
///                      → generate the actual leaf cert covering
///                        every domain our smoke + dev workflows use.
///   4. symlink mkcert-CAROOT/rootCA.pem → <data-dir>/ca-root.pem so
///                        tools that need an explicit --cacert path
///                        (the upcoming loop46 CLI in non-system-
///                        trust setups) have a stable location.
fn initDevTls(allocator: std.mem.Allocator, paths: anytype) !void {
    std.log.info("--dev: no TLS cert at {s} — bootstrapping via mkcert...", .{paths.dir});

    // ── 1. mkcert installed? Capture rootCA path while we're at it.
    const caroot = caroot: {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "mkcert", "-CAROOT" },
        }) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print(MKCERT_NOT_FOUND_HINT, .{});
                std.process.exit(2);
            },
            else => return err,
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            std.debug.print(
                "error: mkcert -CAROOT exited with {any}: {s}\n",
                .{ result.term, result.stderr },
            );
            std.process.exit(2);
        }
        // Strip trailing whitespace/newline.
        const trimmed = std.mem.trimRight(u8, result.stdout, " \t\r\n");
        break :caroot try allocator.dupe(u8, trimmed);
    };
    defer allocator.free(caroot);

    // ── 2. mkdir the data dir.
    std.fs.cwd().makePath(paths.dir) catch |err| {
        std.debug.print("error: cannot create {s}: {s}\n", .{ paths.dir, @errorName(err) });
        std.process.exit(2);
    };

    // ── 3. mkcert -install (idempotent; may prompt for sudo on Linux
    //       or pop a Keychain dialog on macOS — inherited stdio so the
    //       user sees the prompts).
    {
        var child = std.process.Child.init(&.{ "mkcert", "-install" }, allocator);
        const term = child.spawnAndWait() catch |err| {
            std.debug.print("error: mkcert -install failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        if (term != .Exited or term.Exited != 0) {
            std.debug.print("error: mkcert -install exited with {any}\n", .{term});
            std.process.exit(2);
        }
    }

    // ── 4. mkcert -cert-file <cert> -key-file <key> <SANs>
    //
    // SAN list covers the dev + smoke domains.
    //
    // The dev wildcard `*.loop46.localhost` mirrors production's
    // `*.loop46.me` exactly — admin lives at `app.loop46.localhost`,
    // customer instances at `{id}.loop46.localhost`, both matched by
    // the single 3-label wildcard. Subdomains of `localhost` resolve
    // to loopback per RFC 6761 so no /etc/hosts edits are needed.
    //
    // Wildcard depth caveat: OpenSSL 3.x rejects wildcards whose
    // wildcard sits directly under a TLD-like label, so `*.localhost`
    // and `*.test` would NOT validate. Our 3-label dev wildcard
    // sidesteps that; the smoke domains keep their existing 2-label
    // wildcards but smokes don't actually verify the cert
    // (they're h2c).
    {
        const argv = [_][]const u8{
            "mkcert",
            "-cert-file", paths.cert,
            "-key-file",  paths.key,
            // Dev workflow + smoke tests both use this single
            // wildcard (mirrors prod's *.loop46.me layout). Smokes
            // get isolation via separate ports + separate data
            // dirs, not via hostnames — keeping one wildcard means
            // smoke URLs read like real dev usage.
            "*.loop46.localhost",
            // Plain localhost for direct-to-IP loopback URLs.
            "localhost",
            "127.0.0.1",
            "::1",
        };
        var child = std.process.Child.init(&argv, allocator);
        const term = child.spawnAndWait() catch |err| {
            std.debug.print("error: mkcert (cert generation) failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        if (term != .Exited or term.Exited != 0) {
            std.debug.print("error: mkcert (cert generation) exited with {any}\n", .{term});
            std.process.exit(2);
        }
    }

    // ── 5. Symlink the mkcert root CA → <data-dir>/ca-root.pem.
    //       Best-effort: if the source is missing or the symlink can't
    //       be made (pre-existing regular file, FS permissions), log
    //       a warning but don't fail the launch.
    {
        const source = try std.fmt.allocPrint(allocator, "{s}/rootCA.pem", .{caroot});
        defer allocator.free(source);
        const dest = try std.fmt.allocPrint(allocator, "{s}/ca-root.pem", .{paths.dir});
        defer allocator.free(dest);

        // Remove any pre-existing file/symlink so the operation is idempotent.
        std.fs.cwd().deleteFile(dest) catch {};
        std.fs.cwd().symLink(source, dest, .{}) catch |err| {
            std.log.warn("--dev: ca-root.pem symlink ({s} → {s}) failed: {s}", .{ dest, source, @errorName(err) });
        };
    }

    std.log.info("--dev: TLS cert + key written to {s}", .{paths.dir});
}

fn parseHostPort(allocator: std.mem.Allocator, hp: []const u8) !std.net.Address {
    const colon = std.mem.lastIndexOfScalar(u8, hp, ':') orelse return error.MalformedHostPort;
    const host = hp[0..colon];
    const port = try std.fmt.parseInt(u16, hp[colon + 1 ..], 10);

    // Special-case "localhost" so --dev defaults like `--http localhost:8443`
    // work without needing DNS resolution. RFC 6761 specifies localhost
    // always means loopback. IPv4 only — workers don't bind v6 by default.
    if (std.mem.eql(u8, host, "localhost")) {
        return std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    }

    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);
    return try std.net.Address.parseIp(host_z, port);
}

fn parsePeerList(allocator: std.mem.Allocator, peers_str: []const u8) ![]kv.RaftPeerAddr {
    var count: usize = 1;
    for (peers_str) |b| {
        if (b == ',') count += 1;
    }

    const out = try allocator.alloc(kv.RaftPeerAddr, count);
    errdefer allocator.free(out);

    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, peers_str, ',');
    while (it.next()) |entry| : (idx += 1) {
        const colon = std.mem.lastIndexOfScalar(u8, entry, ':') orelse return error.MalformedPeer;
        const host = try allocator.dupe(u8, entry[0..colon]);
        errdefer allocator.free(host);
        const port = try std.fmt.parseInt(u16, entry[colon + 1 ..], 10);
        out[idx] = .{ .host = host, .port = port };
    }
    return out;
}

// ── Signal-driven shutdown ────────────────────────────────────────────
//
// sigaction handler has to be signal-safe; it only stores into an
// atomic. The main thread polls it and the worker threads check it
// on every poll-loop iteration.

var stop_flag: std.atomic.Value(bool) = .init(false);

fn handleSignal(_: c_int) callconv(.c) void {
    stop_flag.store(true, .release);
}

fn installSignalHandlers() !void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

// ── Worker thread ─────────────────────────────────────────────────────

const Worker = rjs.Worker(.{});

/// Per-worker state assembled on the worker thread itself. Everything
/// in here is thread-local: allocating on the worker thread keeps the
/// rove registry's allocations co-located for cache locality.
const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    worker_idx: u16,
    data_dir: []const u8,
    http_addr: std.net.Address,
    raft: *kv.RaftNode,
    code_addr: std.net.Address,
    log_addr: std.net.Address,
    admin_origin: ?[]const u8,
    admin_api_domain: ?[]const u8,
    public_suffix: ?[]const u8,
    rate_limit_caps: rjs.RateLimitCaps,
    /// Per-worker QuickJS compiler used by the signup endpoint to
    /// bytecode-compile starter handler content. Runtimes can't be
    /// shared across threads, so each worker owns its own.
    /// Initialized at the top of `workerMain` and destroyed at exit.
    compiler: *QjsCompiler,
    refresh_interval_ms: u32,
    /// Shared TlsConfig (or null for plaintext h2c). When present,
    /// all workers hand it to their h2 session on accept. Lives in
    /// the main thread; workers borrow.
    tls_config: ?*h2_mod.TlsConfig,
    /// Shared across all workers — every per-tenant `app.db` `KvStore`
    /// opens with a counter from this registry so seq allocation
    /// stays globally monotonic.
    seq_counters: *kv.SeqCounterRegistry,
    /// Main thread blocks on these until every worker has bound its
    /// h2 listener — this is what `SO_REUSEPORT` needs before requests
    /// can hit any of them.
    ready: *std.Thread.ResetEvent,
};

fn workerMain(args: *WorkerCtx) !void {
    const allocator = args.allocator;

    // Per-worker QuickJS compiler. Initialized on THIS thread so the
    // runtime + context pointers are thread-local per QuickJS's own
    // rules. Used by the signup endpoint to compile starter content.
    var compiler = try QjsCompiler.init();
    defer compiler.deinit();
    args.compiler = &compiler;

    // Per-worker rove registry. Every entity, every collection, every
    // deferred-op queue is owned by this registry and only touched by
    // this thread.
    var reg = try rove.Registry.init(allocator, .{
        .max_entities = 65536,
        .deferred_queue_capacity = 4096,
    });
    defer reg.deinit();

    // Per-worker tenant. Opens its OWN connection to __root__.db.
    // Multiple connections to the same sqlite file are fine in WAL
    // mode, and each worker's connection respects the NOMUTEX
    // "one thread per connection" rule because it's created here.
    const root_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/__root__.db",
        .{args.data_dir},
        0,
    );
    defer allocator.free(root_path);
    const root_kv = try kv.KvStore.open(allocator, root_path);
    defer root_kv.close();

    const tenant = try tenant_mod.Tenant.createWithCounters(
        allocator,
        root_kv,
        args.data_dir,
        args.seq_counters,
    );
    defer tenant.destroy();
    try tenant.setPublicSuffix(args.public_suffix);

    // The main thread created __admin__ + the root token + any
    // pre-seeded tenants before spawning us. Promote them into THIS
    // worker's in-memory cache so `Worker.create` can open their
    // per-tenant stores eagerly. __admin__ is always present;
    // additional tenants are discovered by walking the data dir.
    //
    // For the per-tenant `app.db` stores we also set `busy_timeout=0`
    // so BEGIN IMMEDIATE returns SQLITE_BUSY immediately instead of
    // blocking up to 5s. The batched dispatcher handles that: it
    // records the tenant as blocked for this tick and moves on to
    // pick a different anchor. The WAL-transition race startup
    // happens via the main thread's `prewarmTenantDbs`, so worker
    // opens never need the original 5s wait anymore.
    try tenant.createInstance(tenant_mod.ADMIN_INSTANCE_ID);
    // Skip the busy_timeout=0 hack on __admin__ — its kv ALIASES to
    // the root store, and root.db needs normal busy handling so
    // concurrent bootstrap writes across workers (marker + domain
    // updates) serialize instead of racing to SQLITE_BUSY.
    const discovered_ids = try discoverTenantIds(allocator, args.data_dir);
    defer {
        for (discovered_ids) |id| allocator.free(id);
        allocator.free(discovered_ids);
    }
    for (discovered_ids) |id| {
        try tenant.createInstance(id);
        if (tenant.instances.get(id)) |inst| inst.kv.setBusyTimeout(0);
    }

    const worker = try Worker.create(allocator, &reg, .{
        .tenant = tenant,
        .raft = args.raft,
        .addr = args.http_addr,
        .io_opts = .{
            .max_connections = 4096,
            .buf_count = 1024,
            .buf_size = 16384,
            .listen_backlog = 4096,
            .reuseport = true,
        },
        .h2_opts = .{
            .max_concurrent_streams = 512,
            .initial_window_size = 1024 * 1024,
            .max_frame_size = 16384,
            .tls_config = args.tls_config,
        },
        .code_addr = args.code_addr,
        .log_addr = args.log_addr,
        .admin_origin = args.admin_origin,
        .admin_api_domain = args.admin_api_domain,
        .log_worker_id = args.worker_idx,
        .refresh_interval_ns = @as(i64, args.refresh_interval_ms) * std.time.ns_per_ms,
        .rate_limit_caps = args.rate_limit_caps,
        .compile_fn = QjsCompiler.compile,
        .compile_ctx = args.compiler,
    });
    defer worker.destroy();

    std.log.info("worker {d}: ready, listening on same port via SO_REUSEPORT", .{args.worker_idx});
    args.ready.set();

    // Scratch list of tenants that returned SQLITE_BUSY on BEGIN
    // IMMEDIATE during THIS tick. Cleared at the top of each tick so
    // a tenant temporarily held by another worker gets a fresh
    // chance next tick. Bounded at 32 — well above the realistic
    // handful-of-tenants-per-tick workloads we've measured.
    var blocked_tenants: rjs.BlockedTenants = .{};

    while (!stop_flag.load(.acquire)) {
        // Bounded-wait poll. The worker has multiple pieces of
        // background state that need periodic attention regardless of
        // incoming I/O:
        //   - parked raft entries (drainRaftPending)
        //   - deployment refresh deadlines (refreshDeployments)
        //   - buffered log records waiting on a flush threshold (flushLogs)
        // The cheapest correct shape is: every poll has a deadline,
        // the loop body runs at least that often, idle CPU stays
        // negligible because each tick is microseconds.
        //
        // `error.SignalInterrupt` is not fatal — it just means SIGINT
        // or SIGTERM arrived during `io_uring_enter`. Fall through to
        // the stop-flag check at the top of the loop.
        worker.pollWithTimeout(1 * std.time.ns_per_ms) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };

        // Code-server proxy: maintain the upstream session, forward
        // any parked /_system/files/* requests, map upstream responses
        // back onto their server-side peers. Order matters — ingest
        // before flush (so a connection that just came up is usable
        // in the same tick), and drain after flush (so responses
        // that came back in the same tick flow onward).
        try rjs.connectProxies(worker);
        try rjs.ingestProxyConnects(worker);
        try reg.flush();
        try rjs.flushProxyPending(worker);
        try reg.flush();
        try rjs.drainProxyResponses(worker);
        try reg.flush();

        // Drain request_out one tenant-batch at a time. Each call
        // processes at most one tenant's requests; the flush between
        // calls is what lets the next call see a smaller request_out
        // and pick a fresh anchor tenant. A BUSY anchor this tick is
        // remembered in `blocked_tenants` so subsequent calls skip it
        // and try different tenants.
        blocked_tenants.clear();
        while (true) {
            const processed = try rjs.dispatchOnce(worker, &blocked_tenants);
            try reg.flush();
            if (processed == 0) break;
        }
        try rjs.drainRaftPending(worker);
        try reg.flush();
        try rjs.cleanupResponses(worker);
        try reg.flush();
        try rjs.refreshDeployments(worker);

        // Webhook callback dispatch: on the raft leader, worker 0
        // scans every tenant's `_callback/*` rows left by the outbox
        // drainer and invokes the customer's `onResult` handler in
        // its own transaction. Gated to worker 0 so two threads on
        // the same node don't race on the same receipt — the inner
        // SQLite txn would serialize them anyway via SQLITE_BUSY,
        // but pinning avoids the wasted turnaround.
        if (args.worker_idx == 0) {
            _ = rjs.dispatchCallbacks(worker, rjs.CALLBACK_DEFAULT_MAX_PER_TENANT) catch |err| {
                std.log.warn("worker {d}: dispatchCallbacks: {s}", .{ args.worker_idx, @errorName(err) });
            };
        }

        // Best-effort log batch flush: drains each tenant's in-memory
        // buffer if any threshold (count/bytes/time) has been crossed
        // and proposes through raft (leader) or writes locally
        // (follower).
        try rjs.flushLogs(worker);
    }

    std.log.info("worker {d}: shutting down", .{args.worker_idx});
}

fn workerThreadEntry(args: *WorkerCtx) void {
    workerMain(args) catch |err| {
        std.log.err("worker {d}: exited with error: {s}", .{ args.worker_idx, @errorName(err) });
        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        // Release the main thread if we died before reaching the
        // `ready.set()` line — otherwise main would block forever.
        args.ready.set();
        // Flip stop_flag so the surviving workers don't keep running
        // on their own while main thinks everything is fine.
        stop_flag.store(true, .release);
    };
}

fn raftThreadMain(node: *kv.RaftNode) void {
    node.run(null) catch |err| {
        std.log.err("raft thread exited: {s}", .{@errorName(err)});
    };
}

// ── main ──────────────────────────────────────────────────────────────

const USAGE =
    \\usage: loop46 <command> [opts]
    \\
    \\commands:
    \\  dev                         start a local-quickstart worker (TLS via mkcert,
    \\                              dev defaults, persistent root token under
    \\                              the loop46 data dir)
    \\  worker                      start a worker with explicit flags (production)
    \\  seed                        provision tenants from a JSON manifest into
    \\                              an offline data dir (one-shot, run before
    \\                              `loop46 worker`)
    \\  help                        print this message
    \\
    \\seed flags:
    \\  --data-dir <path>           target data dir (will be created if missing)
    \\  --manifest <path>           JSON manifest listing tenants + their files
    \\
    \\common worker flags:
    \\  --node-id <n>               index into --peers (default 0)
    \\  --peers <h:p,h:p,...>       raft peer list (default 127.0.0.1:40100)
    \\  --listen <host:port>        raft RPC listen (default 127.0.0.1:40100)
    \\  --http <host:port>          HTTP/2 listen (default 127.0.0.1:8082)
    \\  --data-dir <path>           per-node data dir (default /tmp/rove-js-data)
    \\  --fresh                     wipe data dir before start
    \\  --bootstrap-root-token HEX  seed the root auth token at startup
    \\  --bootstrap-kv key=value    seed a kv pair into __admin__/app.db at
    \\                              startup. Repeatable. Admin's JS handler
    \\                              reads these via kv.get; well-known keys
    \\                              (defined by admin's deployed bundle, not
    \\                              this binary) include resend_key and
    \\                              platform_email_from.
    \\  --public-suffix <domain>    customer wildcard suffix (e.g. loop46.me).
    \\                              admin host derives to app.<suffix> unless
    \\                              --admin-api-domain overrides
    \\  --tls-cert <path>           PEM cert for h2 TLS (with --tls-key)
    \\  --tls-key  <path>           PEM key  for h2 TLS (with --tls-cert)
    \\  --workers <n>               number of worker threads (default 0 = nCPU - 1)
    \\  --propose-linger-us <n>     raft proposal linger budget in µs (default 500)
    \\  --dev-webhook-unsafe        DEV ONLY: allow http:// + loopback webhook targets
    \\
;

fn printUsage() !void {
    var stderr_buf: [1024]u8 = undefined;
    var sw = std.fs.File.stderr().writer(&stderr_buf);
    try sw.interface.writeAll(USAGE);
    try sw.interface.flush();
}

fn parseAndFinalize(allocator: std.mem.Allocator, args: []const [:0]u8, dev: bool) !Cli {
    var cli = try parseCli(args);
    cli.dev = dev;
    try finalizeCli(allocator, &cli);
    return cli;
}

/// Schema for `loop46-demo-tenants.json`-style manifests. Driven by
/// `loop46 seed`. `source` paths are interpreted relative to the
/// manifest file's parent directory so the manifest stays portable.
const SeedManifest = struct {
    tenants: []SeedTenant,
};
const SeedTenant = struct {
    id: []const u8,
    domains: []const []const u8 = &.{},
    files: []const SeedFile = &.{},
    /// Optional initial KV rows written directly into the tenant's
    /// `app.db` before any worker opens it. Used by readonly-style
    /// benchmarks that need pre-seeded state.
    seed_kv: ?std.json.ArrayHashMap([]const u8) = null,
};
const SeedFile = struct {
    /// Path inside the tenant's deployment (e.g. `index.mjs`,
    /// `api/index.mjs`, `_static/foo.html`).
    path: []const u8,
    /// File on disk to read bytes from. Resolved relative to the
    /// manifest file's parent directory.
    source: []const u8,
};

/// Drive `loop46 seed --data-dir <dir> --manifest <path>`. One-shot:
/// reads the manifest, opens `<data-dir>/__root__.db`, registers each
/// tenant + its domains, deploys the listed files via the same
/// content-addressed pipeline customers use, and seeds optional KV.
/// The data dir is left ready for `loop46 worker` to start against.
fn runSeed(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    var data_dir: ?[]const u8 = null;
    var manifest_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--data-dir")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            data_dir = args[i];
        } else if (std.mem.eql(u8, a, "--manifest")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            manifest_path = args[i];
        } else {
            return error.Usage;
        }
    }
    const dd = data_dir orelse return error.Usage;
    const mf = manifest_path orelse return error.Usage;

    try std.fs.cwd().makePath(dd);

    // Resolve manifest dir so relative file paths inside the manifest
    // are interpreted against the manifest file's directory, not cwd.
    const manifest_dir = std.fs.path.dirname(mf) orelse ".";

    const mf_bytes = try std.fs.cwd().readFileAlloc(allocator, mf, 1 << 20);
    defer allocator.free(mf_bytes);

    var parsed = try std.json.parseFromSlice(
        SeedManifest,
        allocator,
        mf_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const root_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/__root__.db",
        .{dd},
        0,
    );
    defer allocator.free(root_path);
    const root_kv = try kv.KvStore.open(allocator, root_path);
    defer root_kv.close();

    const tenant = try tenant_mod.Tenant.create(allocator, root_kv, dd);
    defer tenant.destroy();

    for (parsed.value.tenants) |t| {
        try tenant.createInstance(t.id);
        for (t.domains) |dom| {
            try tenant.assignDomain(dom, t.id);
        }

        var deploy_files: std.ArrayList(DeployFile) = .empty;
        defer {
            for (deploy_files.items) |f| allocator.free(f.content);
            deploy_files.deinit(allocator);
        }

        for (t.files) |entry| {
            const full = try std.fs.path.join(allocator, &.{ manifest_dir, entry.source });
            defer allocator.free(full);
            const bytes = try std.fs.cwd().readFileAlloc(allocator, full, 1 << 20);
            errdefer allocator.free(bytes);
            try deploy_files.append(allocator, .{
                .path = entry.path,
                .content = bytes,
            });
        }

        try bootstrapHandler(allocator, dd, t.id, deploy_files.items);

        if (t.seed_kv) |kvs| {
            const inst_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dd, t.id });
            defer allocator.free(inst_dir);
            try std.fs.cwd().makePath(inst_dir);
            const app_db_path = try std.fmt.allocPrintSentinel(
                allocator,
                "{s}/app.db",
                .{inst_dir},
                0,
            );
            defer allocator.free(app_db_path);
            const app_kv = try kv.KvStore.open(allocator, app_db_path);
            defer app_kv.close();
            var it = kvs.map.iterator();
            while (it.next()) |entry| {
                try app_kv.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    std.debug.print("seed: provisioned {d} tenant(s) into {s}\n", .{ parsed.value.tenants.len, dd });
}

pub fn main() !void {
    // c_allocator (glibc malloc) — NOT DebugAllocator. The latter
    // spends ~20% of CPU in stack-trace capture per alloc even in
    // ReleaseFast. See memory `feedback_zig_*` / session-9 notes.
    const allocator = std.heap.c_allocator;

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (argv.len < 2) {
        try printUsage();
        std.process.exit(2);
    }

    const cmd = argv[1];
    const sub_args = argv[2..];

    if (std.mem.eql(u8, cmd, "help") or
        std.mem.eql(u8, cmd, "--help") or
        std.mem.eql(u8, cmd, "-h"))
    {
        try printUsage();
        return;
    }

    if (std.mem.eql(u8, cmd, "seed")) {
        runSeed(allocator, sub_args) catch |err| {
            if (err == error.Usage) {
                try printUsage();
            } else {
                std.debug.print("error: seed: {s}\n", .{@errorName(err)});
            }
            std.process.exit(2);
        };
        return;
    }

    const dev_mode = std.mem.eql(u8, cmd, "dev");
    const worker_mode = std.mem.eql(u8, cmd, "worker");

    if (!dev_mode and !worker_mode) {
        std.debug.print("error: unknown subcommand '{s}'\n\n", .{cmd});
        try printUsage();
        std.process.exit(2);
    }

    const cli = parseAndFinalize(allocator, sub_args, dev_mode) catch |err| {
        if (err == error.Usage) {
            try printUsage();
        } else {
            std.debug.print("error: cli: {s}\n", .{@errorName(err)});
        }
        std.process.exit(2);
    };
    if (cli.dev) {
        std.log.info("dev: admin = {s}", .{cli.admin_origin.?});
        std.log.info("dev: customer instances = https://*.{s}:{d}", .{
            cli.public_suffix.?,
            portFromAddr(cli.http) orelse 8443,
        });
    }

    // Resolve workers=0 → online CPU count (minus one for the raft thread).
    const num_workers: u16 = if (cli.workers == 0) blk: {
        const cpus = std.Thread.getCpuCount() catch 4;
        break :blk @intCast(@max(1, cpus -| 1));
    } else cli.workers;

    if (cli.fresh) {
        std.fs.cwd().deleteTree(cli.data_dir) catch {};
    }
    try std.fs.cwd().makePath(cli.data_dir);

    if (cli.dev_webhook_unsafe) {
        outbox.ssrf.dev_allow_loopback = true;
        outbox.http_client.dev_allow_plaintext = true;
        std.log.warn("*** --dev-webhook-unsafe enabled: webhook.send may target loopback over http:// — DEV ONLY ***", .{});
    }

    try installSignalHandlers();

    // ── One-time bootstrap: __root__ + instances + handler ────────────
    //
    // Done on the main thread so the workers only have to discover
    // pre-existing state on startup. Each worker will open its OWN
    // connections to these files when it spins up.
    {
        const root_path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/__root__.db",
            .{cli.data_dir},
            0,
        );
        defer allocator.free(root_path);
        const root_kv = try kv.KvStore.open(allocator, root_path);
        defer root_kv.close();

        const tenant = try tenant_mod.Tenant.create(allocator, root_kv, cli.data_dir);
        defer tenant.destroy();

        if (cli.bootstrap_root_token) |t| {
            tenant.installRootToken(t) catch |err| {
                std.debug.print("bootstrap: installRootToken failed: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            };
            std.debug.print("bootstrap: root token installed\n", .{});
        }

        // __admin__ is created first so session / magic / resend-key
        // operations (which live in its app.db) have a place to land
        // before any other bootstrap step runs. See `src/tenant/root.zig`.
        try tenant.createInstance("__admin__");

        // Generic config bootstrap: every `--bootstrap-kv key=value`
        // arg writes to admin's app.db under the given key. Zig knows
        // nothing about the keys — admin's JS handler reads whatever
        // it cares about via kv.get with whatever fallback default
        // it wants (e.g. `kv.get("platform_email_from") ||
        // "noreply@loop46.me"`).
        if (cli.bootstrap_kv_count > 0) {
            const admin_inst = (tenant.getInstance(tenant_mod.ADMIN_INSTANCE_ID) catch |err| {
                std.debug.print("bootstrap: lookup __admin__ failed: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            }).?;
            for (cli.bootstrap_kv[0..cli.bootstrap_kv_count]) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
                    std.debug.print(
                        "bootstrap-kv: expected key=value, got '{s}'\n",
                        .{pair},
                    );
                    std.process.exit(2);
                };
                const key = pair[0..eq];
                const value = pair[eq + 1 ..];
                if (key.len == 0) {
                    std.debug.print("bootstrap-kv: empty key in '{s}'\n", .{pair});
                    std.process.exit(2);
                }
                if (std.mem.indexOfScalar(u8, key, 0) != null or
                    std.mem.indexOfScalar(u8, value, 0) != null)
                {
                    std.debug.print(
                        "bootstrap-kv: key/value contains NUL byte (key='{s}')\n",
                        .{key},
                    );
                    std.process.exit(2);
                }
                admin_inst.kv.put(key, value) catch |err| {
                    std.debug.print(
                        "bootstrap-kv: write {s} failed: {s}\n",
                        .{ key, @errorName(err) },
                    );
                    std.process.exit(2);
                };
            }
            std.debug.print(
                "bootstrap: wrote {d} kv pair(s) into __admin__/app.db\n",
                .{cli.bootstrap_kv_count},
            );
        }

        // Always-deploy: the embedded admin UI bundle. Demo + benchmark
        // tenants get provisioned by `loop46 seed --manifest ...` (out
        // of band of this binary). The worker discovers them on disk
        // here.
        try bootstrapHandler(allocator, cli.data_dir, "__admin__", &ADMIN_DEPLOY_FILES);

        // Prewarm __admin__ + every disk-discovered tenant's app.db +
        // log.db on the main thread so the WAL-mode transition is
        // committed before workers race to open them. Without this,
        // `--workers 8` occasionally kills a worker with
        // `error: JournalMode` because two openers try to upgrade
        // journal_mode=WAL at the same time.
        const prewarm_ids = try discoverTenantIds(allocator, cli.data_dir);
        defer {
            for (prewarm_ids) |id| allocator.free(id);
            allocator.free(prewarm_ids);
        }
        try prewarmTenantDbs(allocator, cli.data_dir, &.{tenant_mod.ADMIN_INSTANCE_ID});
        try prewarmTenantDbs(allocator, cli.data_dir, prewarm_ids);
    }

    const subsystem_max_connections: u32 = @as(u32, num_workers) + 4;

    // ── Raft setup ─────────────────────────────────────────────────────
    //
    // ApplyCtx is raft-thread-local: it owns its own per-tenant sqlite
    // connections, opened lazily on follower applies. These are
    // DISTINCT from any worker's connections, so the raft thread and
    // the worker threads never share a NOMUTEX sqlite connection.
    var apply_ctx: rjs.apply.ApplyCtx = undefined;

    const peers = try parsePeerList(allocator, cli.peers);
    defer {
        for (peers) |p| allocator.free(p.host);
        allocator.free(peers);
    }
    const listen_addr = try parseHostPort(allocator, cli.listen);

    const raft_log_path = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/raft.log.db",
        .{cli.data_dir},
        0,
    );
    defer allocator.free(raft_log_path);

    const raft_node = try kv.RaftNode.init(allocator, .{
        .node_id = cli.node_id,
        .peers = peers,
        .listen_addr = listen_addr,
        .apply = .{
            .opaque_bytes = .{
                .apply_fn = rjs.apply.applyOne,
                .ctx = &apply_ctx,
            },
        },
        .raft_log_path = raft_log_path,
        .worker_count = 0,
        .propose_linger_ns = cli.propose_linger_us * std.time.ns_per_us,
    });
    defer raft_node.deinit();

    apply_ctx = rjs.apply.ApplyCtx.init(allocator, cli.data_dir, raft_node);
    defer apply_ctx.deinit();

    var raft_thread = try std.Thread.spawn(.{}, raftThreadMain, .{raft_node});
    raft_thread.detach();

    // ── Subsystem threads (shared across workers) ──────────────────────
    //
    // Spawn BEFORE the workers so the workers can open client
    // connections to them during startup. Spawn AFTER raft so the
    // files-server can propose files.db writesets through it. Each
    // subsystem owns its own rove context (registry + io_uring +
    // h2 server) and binds to a loopback TCP ephemeral port.
    const cs_handle = try files_server.thread.spawn(allocator, cli.data_dir, subsystem_max_connections, raft_node);
    defer cs_handle.shutdown();
    const code_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, cs_handle.port);

    const ls_handle = try log_server.thread.spawn(allocator, cli.data_dir, subsystem_max_connections);
    defer ls_handle.shutdown();
    const log_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, ls_handle.port);

    // ── Outbox drainer ──
    //
    // One thread on the raft leader scans every tenant's `_outbox/*`
    // and runs the HTTP side. At-least-once delivery; receivers dedup
    // on X-Rove-Webhook-Id. The InstanceProvider here is a simple
    // filesystem walk — cheap at our current scale; slice 3b replaces
    // it with a root-marker index once the LRU matters.
    var fs_provider_ctx = FsInstanceProvider{ .data_dir = cli.data_dir };
    const drainer_handle = try outbox.spawnDrainer(.{
        .allocator = allocator,
        .raft = raft_node,
        .instances = .{
            .snapshot = FsInstanceProvider.snapshot,
            .deinit = FsInstanceProvider.deinit,
            .ctx = &fs_provider_ctx,
        },
    });
    defer drainer_handle.join();
    defer drainer_handle.signalStop();

    // ── Spawn worker threads ───────────────────────────────────────────
    const http_addr = try parseHostPort(allocator, cli.http);

    const ctxs = try allocator.alloc(WorkerCtx, num_workers);
    defer allocator.free(ctxs);
    const threads = try allocator.alloc(std.Thread, num_workers);
    defer allocator.free(threads);
    const ready_events = try allocator.alloc(std.Thread.ResetEvent, num_workers);
    defer allocator.free(ready_events);
    for (ready_events) |*ev| ev.* = .{};

    // Shared seq-counter registry. Every per-tenant `app.db` KvStore
    // opened by any worker draws from this, so concurrent worker
    // threads allocating new seqs for the same tenant never collide.
    var seq_counters = kv.SeqCounterRegistry.init(allocator);
    defer seq_counters.deinit();

    // Optional TLS. Both flags must be set; either alone is a usage
    // error (silent fall-through to plaintext would mask a config
    // mistake in prod). When `--dev` is set AND no explicit cert/key
    // flags are passed, auto-discover the cert + key produced by
    // `scripts/rove-dev-setup.sh` at the platform-default loop46
    // data dir; missing → plaintext h2c with a hint pointing at the
    // setup script.
    var dev_tls_cert_owned: ?[]u8 = null;
    var dev_tls_key_owned: ?[]u8 = null;
    var dev_tls_dir_owned: ?[]u8 = null;
    defer if (dev_tls_cert_owned) |s| allocator.free(s);
    defer if (dev_tls_key_owned) |s| allocator.free(s);
    defer if (dev_tls_dir_owned) |s| allocator.free(s);

    const tls_config: ?*h2_mod.TlsConfig = blk: {
        var cert_path = cli.tls_cert;
        var key_path = cli.tls_key;
        const explicit = cert_path != null or key_path != null;

        if (cert_path != null and key_path == null) {
            std.debug.print("error: --tls-cert and --tls-key must be set together\n", .{});
            std.process.exit(2);
        }
        if (cert_path == null and key_path != null) {
            std.debug.print("error: --tls-cert and --tls-key must be set together\n", .{});
            std.process.exit(2);
        }

        if (!explicit and cli.dev) {
            const paths = defaultDevTlsPaths(allocator) catch |err| {
                std.debug.print("error: --dev: cannot resolve default TLS paths: {s}\n", .{@errorName(err)});
                std.process.exit(2);
            };
            dev_tls_cert_owned = paths.cert;
            dev_tls_key_owned = paths.key;
            dev_tls_dir_owned = paths.dir;
            // First run: cert missing → bootstrap via mkcert. After
            // initDevTls returns the files exist; if it doesn't, it
            // exits the process itself (mkcert missing, etc.) so we
            // never reach the next line on a real failure.
            if (!devTlsPathsExist(paths.cert, paths.key)) {
                try initDevTls(allocator, paths);
            } else {
                std.log.info("--dev: TLS cert at {s}", .{paths.dir});
            }
            cert_path = paths.cert;
            key_path = paths.key;
        }

        if (cert_path == null) break :blk null;

        const cfg = h2_mod.TlsConfig.createFromFiles(
            allocator,
            cert_path.?,
            key_path.?,
        ) catch |err| {
            std.debug.print("error: tls: {s} (cert={s}, key={s})\n", .{
                @errorName(err), cert_path.?, key_path.?,
            });
            std.process.exit(2);
        };
        std.log.info("tls: loaded {s} + {s}", .{ cert_path.?, key_path.? });
        break :blk cfg;
    };

    var i: u16 = 0;
    while (i < num_workers) : (i += 1) {
        ctxs[i] = .{
            .allocator = allocator,
            .worker_idx = i,
            .data_dir = cli.data_dir,
            .http_addr = http_addr,
            .raft = raft_node,
            .code_addr = code_addr,
            .log_addr = log_addr,
            .admin_origin = cli.admin_origin,
            .admin_api_domain = cli.admin_api_domain,
            .public_suffix = cli.public_suffix,
            .rate_limit_caps = .{
                .request_capacity = cli.rate_limit_request_capacity,
                .request_refill_per_sec = cli.rate_limit_request_refill,
                .email_capacity = cli.rate_limit_email_capacity,
                .email_refill_per_sec = cli.rate_limit_email_refill,
            },
            // The worker thread allocates its QjsCompiler on its own
            // stack (QuickJS runtime pointers have thread affinity)
            // and fills this field before `Worker.create`. The main
            // thread never dereferences it.
            .compiler = undefined,
            .refresh_interval_ms = cli.refresh_interval_ms,
            .tls_config = tls_config,
            .seq_counters = &seq_counters,
            .ready = &ready_events[i],
        };
        threads[i] = try std.Thread.spawn(.{}, workerThreadEntry, .{&ctxs[i]});
    }
    for (ready_events) |*ev| ev.wait();

    std.debug.print(
        "loop46 worker node {d} listening on http://{s}\n" ++
            "  workers:        {d} (SO_REUSEPORT)\n" ++
            "  data dir:       {s}\n" ++
            "  raft:           node {d} of {d} @ {s}\n" ++
            "  peers:          {s}\n" ++
            "  admin host:     {s}\n" ++
            "  public suffix:  {s}\n",
        .{
            cli.node_id,
            cli.http,
            num_workers,
            cli.data_dir,
            cli.node_id,
            peers.len,
            cli.listen,
            cli.peers,
            cli.admin_api_domain orelse "(disabled)",
            cli.public_suffix orelse "(disabled)",
        },
    );

    // Block until SIGINT/SIGTERM flips stop_flag, then join workers.
    // 50ms poll granularity is invisible to shutdown perception and
    // costs nothing. If TLS is on, the main thread also stat()s the
    // PEM files once per second — the sidecar (scripts/rove-lego-
    // renew.sh) rewrites these whenever lego renews, and workers pick
    // up the new cert on the next TLS accept.
    const reload_interval_ticks: u64 = 20; // 20 × 50ms = 1s
    var tick: u64 = 0;
    while (!stop_flag.load(.acquire)) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
        tick += 1;
        if (tls_config) |cfg| {
            if (tick % reload_interval_ticks == 0) {
                const changed = cfg.reloadIfChanged() catch |err| blk: {
                    std.log.warn("tls: reloadIfChanged failed: {s}", .{@errorName(err)});
                    break :blk false;
                };
                if (changed) std.log.info("tls: cert/key reloaded", .{});
            }
        }
    }
    std.log.info("js-worker: shutdown requested, joining {d} worker(s)", .{num_workers});
    for (threads) |t| t.join();
    std.log.info("js-worker: bye", .{});

    // Skip the teardown chain. The raft thread is detached and still
    // inside `node.run()`; running `raft_node.deinit()` out from under
    // it would segfault. Subsystem threads (files-server, log-server)
    // would also need a join story before it's safe to free their
    // handles. The pragmatic answer is `_exit(0)` — same as nginx,
    // envoy, etc.: the kernel reclaims memory + fds + sockets in one
    // shot and we avoid re-implementing a clean teardown graph for
    // every subsystem.
    std.process.exit(0);
}

/// Compile `source` (or pass-through for static) for an instance and
/// publish it as the current deployment through that tenant's file
/// store. Mirrors what `rove-files-cli upload + deploy` would do
/// externally; kept inline so the smoke test is a single binary.
const DeployFile = struct {
    path: []const u8,
    content: []const u8,
    /// null → handler source (compile to bytecode). Non-null → static
    /// file served verbatim with this content-type.
    content_type: ?[]const u8 = null,
};

fn bootstrapHandler(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    instance_id: []const u8,
    files: []const DeployFile,
) !void {
    const inst_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, instance_id });
    defer allocator.free(inst_dir);
    try std.fs.cwd().makePath(inst_dir);

    const files_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/files.db", .{inst_dir}, 0);
    defer allocator.free(files_db_path);

    const files_blob_dir = try std.fmt.allocPrint(allocator, "{s}/file-blobs", .{inst_dir});
    defer allocator.free(files_blob_dir);

    const files_kv = try kv.KvStore.open(allocator, files_db_path);
    defer files_kv.close();
    var fs_store = try blob_mod.FilesystemBlobStore.open(allocator, files_blob_dir);
    defer fs_store.deinit();

    // Real qjs compile so the stored bytecode is real.
    var compiler = try QjsCompiler.init();
    defer compiler.deinit();

    var store = files_mod.FileStore.init(
        allocator,
        files_kv,
        fs_store.blobStore(),
        QjsCompiler.compile,
        &compiler,
    );

    for (files) |f| {
        if (f.content_type) |ct| {
            try store.putStatic(f.path, f.content, ct);
        } else {
            try store.putSource(f.path, f.content);
        }
    }
    _ = try store.deploy();
}

// The admin UI bundle is embedded into the binary so a fresh start
// ships with a functioning login page at app.loop46.me. Each file
// becomes a `_static/<path>` entry in __admin__'s initial deployment.
const ADMIN_UI_INDEX_HTML = @embedFile("admin_ui_index_html");
const ADMIN_UI_APP_JS = @embedFile("admin_ui_app_js");
const ADMIN_UI_API_JS = @embedFile("admin_ui_api_js");
const ADMIN_UI_APP_CSS = @embedFile("admin_ui_app_css");
const ADMIN_UI_PAGE_LOGIN = @embedFile("admin_ui_page_login");
const ADMIN_UI_PAGE_INSTANCES = @embedFile("admin_ui_page_instances");
const ADMIN_UI_PAGE_INSTANCE = @embedFile("admin_ui_page_instance");

const ADMIN_DEPLOY_FILES = [_]DeployFile{
    .{ .path = "index.mjs", .content = ADMIN_HANDLER_SRC },
    .{ .path = "_static/index.html", .content = ADMIN_UI_INDEX_HTML, .content_type = "text/html; charset=utf-8" },
    .{ .path = "_static/app.js", .content = ADMIN_UI_APP_JS, .content_type = "application/javascript" },
    .{ .path = "_static/api.js", .content = ADMIN_UI_API_JS, .content_type = "application/javascript" },
    .{ .path = "_static/app.css", .content = ADMIN_UI_APP_CSS, .content_type = "text/css" },
    .{ .path = "_static/pages/login.js", .content = ADMIN_UI_PAGE_LOGIN, .content_type = "application/javascript" },
    .{ .path = "_static/pages/instances.js", .content = ADMIN_UI_PAGE_INSTANCES, .content_type = "application/javascript" },
    .{ .path = "_static/pages/instance.js", .content = ADMIN_UI_PAGE_INSTANCE, .content_type = "application/javascript" },
};

/// Walk `<data_dir>/*` and return every subdirectory containing an
/// `app.db` — i.e. every tenant the worker should know about. Skips
/// `__admin__` since that's always created fresh by the worker (its
/// kv aliases the root store, so the on-disk dir is not the source of
/// truth for its existence). Caller owns the returned slice + the
/// id strings inside it.
fn discoverTenantIds(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |id| allocator.free(id);
        list.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(data_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return list.toOwnedSlice(allocator),
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, tenant_mod.ADMIN_INSTANCE_ID)) continue;
        const probe = try std.fmt.allocPrint(allocator, "{s}/{s}/app.db", .{ data_dir, entry.name });
        defer allocator.free(probe);
        std.fs.cwd().access(probe, .{}) catch continue;
        const id = try allocator.dupe(u8, entry.name);
        try list.append(allocator, id);
    }
    return list.toOwnedSlice(allocator);
}

/// Open + close each tenant's `app.db` and `log.db` once from the
/// main thread so the `PRAGMA journal_mode=WAL` transition is
/// committed to disk BEFORE any workers race to open them. Concurrent
/// WAL-mode transitions from multiple openers can fail with a
/// `JournalMode` error under load (the brief exclusive lock SQLite
/// needs can't be re-entered while another opener holds it), which
/// we observed at `--workers 8`. Prewarming fixes it once and for
/// all: subsequent openers see the existing WAL mode and skip the
/// transition.
fn prewarmTenantDbs(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    tenant_ids: []const []const u8,
) !void {
    for (tenant_ids) |id| {
        const inst_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, id });
        defer allocator.free(inst_dir);
        try std.fs.cwd().makePath(inst_dir);

        const app_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/app.db", .{inst_dir}, 0);
        defer allocator.free(app_db_path);
        const app_kv = try kv.KvStore.open(allocator, app_db_path);
        app_kv.close();

        const log_db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/log.db", .{inst_dir}, 0);
        defer allocator.free(log_db_path);
        const log_kv = try kv.KvStore.open(allocator, log_db_path);
        log_kv.close();
    }
}

/// Inline qjs compile hook — identical to the one in files_cli.zig.
/// Duplicating it here keeps the smoke test self-contained; the
/// production path reuses files_cli's helper.
const QjsCompiler = struct {
    runtime: qjs.Runtime,
    context: qjs.Context,

    fn init() !QjsCompiler {
        var rt = try qjs.Runtime.init();
        errdefer rt.deinit();
        const ctx = try rt.newContext();
        return .{ .runtime = rt, .context = ctx };
    }

    fn deinit(self: *QjsCompiler) void {
        self.context.deinit();
        self.runtime.deinit();
    }

    fn compile(
        ctx_opaque: ?*anyopaque,
        source: []const u8,
        filename: [:0]const u8,
        allocator: std.mem.Allocator,
    ) anyerror![]u8 {
        const self: *QjsCompiler = @ptrCast(@alignCast(ctx_opaque.?));
        const kind: qjs.EvalFlags = if (files_mod.isJsModule(filename))
            .{ .kind = .module }
        else
            .{};
        return self.context.compileToBytecode(source, filename, allocator, kind);
    }
};

/// InstanceProvider that walks `{data_dir}/*` on each scan and
/// reports every subdir that has an `app.db` file. Cheap at our
/// current scale (tens of tenants); slice 3b replaces it with a
/// root-marker scan once the LRU cache lands.
const FsInstanceProvider = struct {
    data_dir: []const u8,

    fn snapshot(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]outbox.InstanceInfo {
        const self: *FsInstanceProvider = @ptrCast(@alignCast(ctx.?));
        var list: std.ArrayListUnmanaged(outbox.InstanceInfo) = .empty;
        errdefer {
            for (list.items) |info| {
                allocator.free(info.id);
                allocator.free(info.dir);
            }
            list.deinit(allocator);
        }

        var dir = std.fs.cwd().openDir(self.data_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return list.toOwnedSlice(allocator),
            else => return err,
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            // Peek for an app.db to confirm this is a tenant dir.
            const probe = try std.fmt.allocPrint(allocator, "{s}/{s}/app.db", .{ self.data_dir, entry.name });
            defer allocator.free(probe);
            std.fs.cwd().access(probe, .{}) catch continue;

            const id_copy = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(id_copy);
            const dir_copy = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.data_dir, entry.name });
            errdefer allocator.free(dir_copy);
            try list.append(allocator, .{ .id = id_copy, .dir = dir_copy });
        }
        return list.toOwnedSlice(allocator);
    }

    fn deinit(_: ?*anyopaque, allocator: std.mem.Allocator, slice: []outbox.InstanceInfo) void {
        for (slice) |info| {
            allocator.free(info.id);
            allocator.free(info.dir);
        }
        allocator.free(slice);
    }
};
