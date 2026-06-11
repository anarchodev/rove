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

// X-Rove-Scope no longer rebinds the global `kv` (that conflated
// "which principal" with "which store" and made auth impossible to
// validate in a scoped dispatch — auth-domain-plan §4.7 "Primitive-
// fix pivot"). `kv` is now ALWAYS __admin__-home. A scoped KV browse
// reaches the target explicitly via the `platform.scope(id).kv`
// control-plane accessor; an unscoped browse uses __admin__'s own kv.
// Returns the kv-like store, or null after stamping a 4xx (unknown
// instance → 404, mirroring the old dispatch-level behavior).
function scopedKvStore() {
    const tgt = request.headers["x-rove-scope"];
    if (!tgt || tgt.length === 0) return kv;
    try {
        return platform.scope(tgt).kv;
    } catch (e) {
        if (e && e.code === "InstanceNotFound") {
            response.status = 404;
            return null;
        }
        throw e;
    }
}

export function listKv(prefix, cursor, limit) {
    const store = scopedKvStore();
    if (store === null) return { error: "unknown instance" };
    const p = prefix || "";
    const c = cursor || "";
    const l = Math.max(1, Math.min(parseInt(limit ?? 100, 10) || 100, 1000));
    const entries = store.prefix(p, c, l);
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
    const store = scopedKvStore();
    if (store === null) return { error: "unknown instance" };
    const v = store.get(key);
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
    const store = scopedKvStore();
    if (store === null) return { error: "unknown instance" };
    store.set(key, value);
    return { key: key };
}

export function deleteKv(key) {
    if (!key) {
        response.status = 400;
        return { error: "missing key" };
    }
    const store = scopedKvStore();
    if (store === null) return { error: "unknown instance" };
    store.delete(key);
    response.status = 204;
    return null;
}

// Publish a release for `instance_id` at `dep_id`. Stamps
// `_deploy/current = dep_id` on the target tenant + proposes
// through raft + enqueues the deployment loader. Fire-and-forget
// — the response returns once the local commit + raft queue
// insert + loader enqueue are done (typically sub-millisecond).
// Raft consensus settles in the background; bytecode load
// happens on the loader thread.
//
// Replaces the old `/_system/release` system route. Customer
// flow: customer pushes manifest to files-server, then calls
// this with the dep_id it returned.
export function publishRelease(instance_id, dep_id) {
    if (!validId(instance_id)) {
        response.status = 400;
        return { error: "invalid instance_id" };
    }
    const n = parseInt(dep_id, 10);
    if (!Number.isFinite(n) || n < 1) {
        response.status = 400;
        return { error: "dep_id must be a positive integer" };
    }
    try {
        platform.releases.publish(instance_id, n);
    } catch (e) {
        if (e && e.code === "InstanceNotFound") {
            response.status = 404;
            return { error: "instance not found" };
        }
        throw e;
    }
    response.status = 202;
    return { instance_id: instance_id, dep_id: n, status: "queued" };
}

// ── OIDC relying-party surface (auth-domain-plan §4.7 "3-6 part 2")
//
// admin is a pure OIDC relying party. Authentication lives in the
// __auth__ IdP; `_middlewares/index.mjs` resolves the RP session and
// sets `request.auth = { sub, is_root }` (or 401s). The named
// exports above are the dashboard's ?fn RPC surface (now trusting
// request.auth); the default export below owns the path-routed
// `/_rp/*` handshake + `/v1/{session,logout}`. There is no
// rove_session cookie, no magic-link, and no root-token human path
// — those were deleted with Fork B. `/_system/*` keeps its own
// independent root-token M2M gate (unaffected).

// Same RESERVED_INSTANCE_NAMES as worker.zig — admin's JS owns the
// list so operators can adjust without a Zig recompile.
const RESERVED_NAMES = [
    "__admin__","admin","api","app","www",
    "auth","login","signup","logout","dashboard",
    "static","system","public","root","mail",
    "__replay__","replay",
];

function isReserved(name) {
    const lower = name.toLowerCase();
    for (let i = 0; i < RESERVED_NAMES.length; i++) {
        if (RESERVED_NAMES[i] === lower) return true;
    }
    return false;
}

function jsonError(status, message) {
    response.status = status;
    return { error: message };
}

// ── Account model ───────────────────────────────────────────────────
// The OIDC-verified id_token `sub` (email) is the account identity.
// account/{sha256(sub)}/plan stores the tier;
// account/{hash}/instances/{instance_id} marks ownership. v1
// hardcodes a single "free" tier with max_instances=1 — Phase 10
// will branch on plan values (rate caps, DLQ retention, blob caps,
// custom-domain counts, Stripe linkage). Seed-manifest tenants stay
// outside the account model entirely (no account/* rows, no count
// toward any limit). All these rows live in __admin__-home kv.

const PLAN_LIMITS = {
    free: { max_instances: 1 },
};

function accountHashFor(email) { return crypto.sha256(email); }

function planLimitsFor(accountHash) {
    const plan = kv.get("account/" + accountHash + "/plan") || "free";
    return PLAN_LIMITS[plan] || PLAN_LIMITS.free;
}

// Owned-instance count for this account. The old "pending
// reservation" half is gone: provisioning is now synchronous behind
// a proven-authenticated OIDC session (no unredeemed-reservation
// abuse vector — the IdP owns the email round-trip).
function ownedInstances(accountHash) {
    return kv.prefix("account/" + accountHash + "/instances/", "", 1000)
        .map((e) => e.key.slice(("account/" + accountHash + "/instances/").length));
}

// POST ?fn=provisionInstance, args [name]. Identity is the
// OIDC-verified id_token `sub` the RP guard put on request.auth —
// NOT a client-supplied field (closes the old signup trust-the-body
// gap). Creates the tenant + deploys starter + records ownership.
// Synchronous behind a proven session, so no pending-reservation
// dance. All account/* rows are __admin__-home kv.
export function provisionInstance(name) {
    const auth = request.auth;
    const sub = auth && auth.sub;
    if (!sub) return jsonError(401, "unauthenticated");
    if (!validId(name))   return jsonError(400, "invalid name");
    if (isReserved(name)) return jsonError(409, "name unavailable");
    if (platform.root.get("instance/" + name) !== null) {
        return jsonError(409, "name unavailable");
    }

    const accHash = accountHashFor(sub);
    const limits = planLimitsFor(accHash);
    const owned = ownedInstances(accHash);
    if (owned.length >= limits.max_instances) {
        response.status = 403;
        return {
            error: "account_limit_reached",
            limit: limits.max_instances,
            owned: owned.length,
        };
    }
    if (kv.get("account/" + accHash + "/plan") === null) {
        kv.set("account/" + accHash + "/plan", "free");
    }

    // platform.instances.create is idempotent (retry-safe).
    try { platform.instances.create(name); }
    catch (e) {
        response.status = 500;
        return { error: "create failed: " + (e && e.message) };
    }
    // Starter content best-effort — the account is usable without it
    // and the customer can push their own code via the files API.
    try { platform.instances.deployStarter(name); } catch (_) {}

    kv.set("account/" + accHash + "/instances/" + name, "");
    response.status = 201;
    return { ok: true, name: name };
}

// GET /v1/session — whoami. request.auth = {sub,is_root} (set by the
// RP guard in _middlewares). `owned` lets the SPA route a customer
// with no instance to the provisioning view.
function handleSession() {
    const a = request.auth || {};
    const owned = a.sub ? ownedInstances(accountHashFor(a.sub)) : [];
    return { is_root: !!a.is_root, sub: a.sub || null, owned: owned };
}

// ── fn-RPC dispatch (JS recipe) ─────────────────────────────────────
//
// The platform no longer interprets `?fn=` / `{fn,args}` (decisions.md
// §4.5 — only the activation's conventional export is invoked);
// named-function routing is the handler's own job. This is the
// documented recipe from handler-shape.md: parse the same wire shapes
// the dashboard has always sent (api.js is unchanged) and dispatch to
// a local table. Reading `request.query` / `request.body` here is what
// puts the dispatch inputs on the replay tape.
const FNS = {
    listInstance, getInstance, createInstance, deleteInstance,
    listDomain, assignDomain,
    listKv, getKv, setKv, deleteKv,
    publishRelease, provisionInstance,
};

function rpcDispatch() {
    let fn = null, args = [];
    for (const part of (request.query || "").split("&")) {
        const eq = part.indexOf("=");
        const k = eq === -1 ? part : part.slice(0, eq);
        if (k !== "fn" && k !== "args") continue;
        const v = eq === -1 ? "" : decodeURIComponent(part.slice(eq + 1).replace(/\+/g, "%20"));
        if (k === "fn" && v) fn = v;
        else if (k === "args" && v) { try { args = JSON.parse(v); } catch (_) {} }
    }
    if (!fn && request.body) {
        try {
            const b = JSON.parse(request.body);
            if (b && typeof b.fn === "string") {
                fn = b.fn;
                args = Array.isArray(b.args) ? b.args : [];
            }
        } catch (_) {}
    }
    if (!fn) return null;
    const f = FNS[fn];
    if (!f) { response.status = 404; return { error: "no such fn: " + fn }; }
    return { result: f(...args) };
}

// ── Path-routed surface (default export) ────────────────────────────
//
// fn-RPC first (the dashboard's `?fn=`/`{fn,args}` calls all target
// `/`), then `/_rp/*` — the browser-facing OIDC relying-party
// handshake (oidc.rp) — and `/v1/*`, the dashboard's whoami/logout.
// The async completion modules `_rp/complete.mjs` / `_rp/jwks.mjs`
// are invoked directly by callback dispatch, NOT routed here.
// Everything below is either pre-auth (see _middlewares
// PRE_AUTH_PATHS) or trusts request.auth.
export default function() {
    const rpc = rpcDispatch();
    if (rpc !== null) return rpc.result;

    const fullPath = request.path;
    const q = fullPath.indexOf("?");
    const path = q === -1 ? fullPath : fullPath.slice(0, q);
    const method = request.method;
    const rp = oidc.rp("default");

    if (method === "GET"  && path === "/_rp/login")    return rp.beginLogin();
    if (method === "GET"  && path === "/_rp/callback") return rp.handleCallback();
    if (method === "GET"  && path === "/_rp/poll")     return rp.pollStatus();

    if (method === "POST" && path === "/v1/logout")  return rp.logout();
    if (method === "GET"  && path === "/v1/session") return handleSession();

    response.status = 404;
    return { error: "not found" };
}
