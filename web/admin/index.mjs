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
// Replaces the old `/_system/release` system route. Customer flow: stage a
// bundle (→ dep_id), then call this with that dep_id.
//
// Authz (step3-auth-plan.md B5): an operator (is_root) may release any tenant;
// a non-operator may release ONLY a tenant they own (`account/{hash}/instances/
// {id}` via `ownedInstances`). Previously this checked nothing — any
// authenticated session could release any tenant.
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
    const auth = request.auth || {};
    if (!auth.sub) return jsonError(401, "unauthenticated");
    if (!auth.is_root &&
        ownedInstances(accountHashFor(auth.sub)).indexOf(instance_id) === -1) {
        return jsonError(403, "not your instance");
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

// ── Log query chokepoint (step3-auth-plan.md A5) ────────────────────
//
// The dashboard reads a tenant's request logs THROUGH the admin app, not
// by holding a services token in the browser. The admin issues a buffered
// `on.fetch` at the privileged `rewind-logs.internal` door: the worker
// (only for `__admin__`) mints a tenant-scoped `logs-read` capability and
// the log-server verifies cap+tenant (`standalone.zig`, A4). So the token
// never enters JS/the browser, and the read is confined to one tenant.
//
// Cross-tenant read is operator-only for now (is_root); per-owner scoping
// (a customer reading their own instance's logs) is a follow-up that reuses
// `ownedInstances`. The result comes back in `onFetchResult` (the buffered
// on.fetch convention) and is relayed verbatim.
const LOG_DOOR = "http://rewind-logs.internal/v1/";

function handleLogQuery(path, qs) {
    const auth = request.auth || {};
    if (!auth.sub) return jsonError(401, "unauthenticated");
    if (!auth.is_root) return jsonError(403, "operator only");
    // path = /v1/logs/{tenant}/{list|count|show/{id}}
    const rest = path.slice("/v1/logs/".length);
    const slash = rest.indexOf("/");
    if (slash < 1) return jsonError(400, "bad log path");
    const tenant = rest.slice(0, slash);
    const sub = rest.slice(slash + 1);
    if (!validId(tenant)) return jsonError(400, "invalid tenant");
    if (sub !== "list" && sub !== "count" && !sub.startsWith("show/")) {
        return jsonError(404, "no such log route");
    }
    on.fetch(LOG_DOOR + tenant + "/" + sub + (qs ? "?" + qs : ""));
    return next();
}

// ── Control-plane chokepoint (step3-auth-plan.md B4) ────────────────
//
// Operators drive CP control ops — provision / move / host / plan —
// through the dashboard, NOT by holding the move-secret on a shell. The
// admin issues a buffered `on.fetch` at the privileged `rewind-cp.internal`
// door; the worker (only for `__admin__`) attaches the move-secret and
// rewrites to the CP. So no CP secret enters the browser/operator shell.
// Operator-only (is_root). The result rides `onFetchResult` (shared with the
// log chokepoint — both just relay the upstream verbatim).
const CP_DOOR = "http://rewind-cp.internal/_control/";
// CP read surface (GET _cp/route?host= / _cp/plan?tenant=) — the cluster page
// reads placement + plan through the same door (the worker attaches the
// move-secret). Operator-only, like the control ops.
const CP_READ = "http://rewind-cp.internal/_cp/";

function handleCpOp(cpPath, body) {
    const auth = request.auth || {};
    if (!auth.sub) return jsonError(401, "unauthenticated");
    if (!auth.is_root) return jsonError(403, "operator only");
    on.fetch(CP_DOOR + cpPath, {
        method: "POST",
        body: body,
        headers: { "content-type": "application/json" },
    });
    return next();
}

// GET cluster-status reads (operator-only): /v1/cp/route?host=H and
// /v1/cp/plan?tenant=T → the CP _cp/* read surface via the door. Powers the
// #/cluster operator page's placement/plan lookups (the GUI twin of
// `rewind-ops status`).
function handleCpRead(cpSub, qs) {
    const auth = request.auth || {};
    if (!auth.sub) return jsonError(401, "unauthenticated");
    if (!auth.is_root) return jsonError(403, "operator only");
    on.fetch(CP_READ + cpSub + (qs ? "?" + qs : ""));
    return next();
}

// Buffered on.fetch result for the log + CP chokepoints — relay the upstream
// status + body back to the dashboard. A door/upstream failure (e.g. an expired
// cap, or the CP unreachable) surfaces as 502.
export function onFetchResult() {
    response.headers = { "content-type": "application/json" };
    if (request.ok) {
        response.status = request.status;
        return new TextDecoder().decode(request.body || new Uint8Array());
    }
    response.status = 502;
    return JSON.stringify({ error: "internal door fetch failed",
                            status: request.status || 0 });
}

// ── Deploy surface — per-file WORKSPACE deploy ──────────────────────
//
// Files are uploaded ONE AT A TIME into a durable per-tenant workspace
// (`scope(t).kv` `_workspace/{path}` → the staged entry; bytes are
// content-addressed in S3 via blob.put/compile), then a release is CUT from
// whatever's in the workspace (stampManifest). This replaces the old single
// mega-POST, which base64-buffered the whole bundle in the JS heap and hit
// QuickJS's per-context memory limit (InternalError: out of memory) on any
// real static-bearing bundle. Per-file keeps each request small.
//
// Authz (each op): an operator (is_root — root token via _middlewares M2M, or
// an operator OIDC session) may deploy any tenant; a customer session may
// deploy ONLY a tenant they own. Does NOT activate — that's publishRelease.
//
// Wire (POST):
//   /v1/deploy/reset {tenant}                             → clear workspace
//   /v1/deploy/file  {tenant, path, kind, source | b64,
//                     content_type?}                      → stage one file
//   /v1/deploy/cut   {tenant}                             → {ok, dep_id}
const WS = "_workspace/";

// Parse + ownership-gate a deploy op. Returns the body on success, or null
// after stamping the error response.
function deployGate(body) {
    const auth = request.auth || {};
    let b;
    try { b = JSON.parse(body); } catch (e) { jsonError(400, "expected JSON body"); return null; }
    if (!validId(b.tenant)) { jsonError(400, "invalid tenant"); return null; }
    if (!auth.is_root) {
        if (!auth.sub) { jsonError(401, "unauthenticated"); return null; }
        if (ownedInstances(accountHashFor(auth.sub)).indexOf(b.tenant) === -1) {
            jsonError(403, "not your instance"); return null;
        }
    }
    return b;
}

function handleWsReset(body) {
    const b = deployGate(body); if (!b) return null;
    const sk = platform.scope(b.tenant).kv;
    const rows = sk.prefix(WS, "", 1000);
    for (let i = 0; i < rows.length; i++) sk.delete(rows[i].key);
    return { ok: true, cleared: rows.length };
}

function handleWsFile(body) {
    const b = deployGate(body); if (!b) return null;
    if (!b.path) return jsonError(400, "path required");
    // Statics stream straight to S3 via PUT /v1/upload (scope(t).blob.receive),
    // which records their own workspace entry — only handlers come through here.
    if (b.kind !== "handler")
        return jsonError(400, "kind must be 'handler' (statics stream via PUT /v1/upload)");
    platform.compile([{ path: b.path, source: b.source || "" }], {
        scope: b.tenant, name: "onFileStaged",
        ctx: { target: b.tenant, path: b.path, content_type: b.content_type || "" },
    });
    return next();
}

// compile bound-resume (continuation — skips _middlewares) → record the entry.
export function onFileStaged() {
    const ctx = request.ctx;
    if (!ctx || !ctx.ok) {
        response.status = 500;
        return JSON.stringify({ stage: "compile", ctx: ctx || null });
    }
    const app = ctx.app || {};
    const r = ctx.results[0];
    platform.scope(app.target).kv.set(WS + app.path, JSON.stringify({
        kind: "handler", content_type: app.content_type || "",
        source_hex: r.source_hex, bytecode_hex: r.bytecode_hex }));
    response.status = 200;
    return JSON.stringify({ ok: true, path: app.path, hash: r.source_hex });
}

function handleWsCut(body) {
    const b = deployGate(body); if (!b) return null;
    const rows = platform.scope(b.tenant).kv.prefix(WS, "", 1000);
    if (rows.length === 0) return jsonError(400, "workspace empty — nothing to cut");
    const entries = rows.map(function (row) {
        const e = JSON.parse(row.value);
        return { path: row.key.slice(WS.length), kind: e.kind,
                 content_type: e.content_type || "",
                 source_hex: e.source_hex, bytecode_hex: e.bytecode_hex || "" };
    });
    platform.scope(b.tenant).deploy.stampManifest(entries, { name: "onCut" });
    return next();
}

// stampManifest barrier resume — the cut deployment is durable here.
export function onCut() {
    response.status = 200;
    response.headers = { "content-type": "application/json" };
    return JSON.stringify(request.ctx); // { ok, dep_id }
}

// ── Source read (cross-tenant read door) ────────────────────────────
//
// Composes a deployment's handler sources from the general cross-tenant read
// primitives (`platform.scope(t).deploy.readManifest` + `scope(t).blob.get`) —
// the engine just signs the S3 reads; the assembly is JS. Powers the Code
// tab's edit-existing flow + the replay bundle's module sources. Because rove
// has no suspended await, the per-handler source reads are threaded
// sequentially through the fetch `ctx` across re-entries (manifest → source 0
// → source 1 → … → respond). Handler count is small (a deployment's .mjs
// files), so the O(N) round trips are cheap.
//
// GET /v1/sources/{tenant}/{dep_hex|current}. Authz mirrors deploy/release:
// operator (is_root) any tenant; a customer only their own.
function handleReadSources(tenant, depArg) {
    const auth = request.auth || {};
    if (!auth.is_root && !auth.sub) return jsonError(401, "unauthenticated");
    if (!validId(tenant)) return jsonError(400, "invalid tenant");
    if (!auth.is_root &&
        ownedInstances(accountHashFor(auth.sub)).indexOf(tenant) === -1) {
        return jsonError(403, "not your instance");
    }
    let dep = depArg;
    if (dep === "current") {
        let cur;
        try { cur = platform.scope(tenant).kv.get("_deploy/current"); }
        catch (e) { return jsonError(404, "instance not found"); }
        if (!cur) return jsonError(404, "no current deployment");
        dep = cur; // stored as hex
    }
    if (!/^[0-9a-fA-F]{1,16}$/.test(dep)) return jsonError(400, "bad dep_id");
    platform.scope(tenant).deploy.readManifest(dep,
        { name: "onManifest", ctx: { tenant: tenant, dep: dep } });
    return next();
}

// Read-door continuation: the manifest JSON arrives on request.body. Parse it,
// then kick off the sequential handler-source reads (or finish if there are
// none).
export function onManifest() {
    const ctx = request.ctx || {};
    if (!request.ok) {
        response.headers = { "content-type": "application/json" };
        response.status = request.status === 404 ? 404 : 502;
        return JSON.stringify({ error: "manifest read failed", status: request.status || 0 });
    }
    let manifest;
    try { manifest = JSON.parse(new TextDecoder().decode(request.body || new Uint8Array())); }
    catch (e) { response.status = 502; return JSON.stringify({ error: "manifest parse failed" }); }
    // manifest_json stores the source/content hash under "hash".
    const entries = (manifest.entries || []).map((e) => ({
        path: e.path, kind: e.kind, content_type: e.content_type, hash: e.hash,
    }));
    const handlers = entries.filter((e) => e.kind === "handler");
    if (handlers.length === 0) return finishSources(ctx.dep, entries, []);
    platform.scope(ctx.tenant).blob.get(handlers[0].hash, {
        name: "onModuleSource",
        ctx: { tenant: ctx.tenant, dep: ctx.dep, entries: entries, idx: 0, acc: [] },
    });
    return next();
}

// Read-door continuation: one handler's source bytes arrive on request.body.
// Accumulate, then either read the next handler or assemble the response.
export function onModuleSource() {
    const ctx = request.ctx || {};
    const handlers = (ctx.entries || []).filter((e) => e.kind === "handler");
    const src = request.ok
        ? new TextDecoder().decode(request.body || new Uint8Array()) : null;
    const acc = ctx.acc.concat([{
        path: handlers[ctx.idx].path, source: src, missing: !request.ok,
    }]);
    const nextIdx = ctx.idx + 1;
    if (nextIdx < handlers.length) {
        platform.scope(ctx.tenant).blob.get(handlers[nextIdx].hash, {
            name: "onModuleSource",
            ctx: { tenant: ctx.tenant, dep: ctx.dep, entries: ctx.entries, idx: nextIdx, acc: acc },
        });
        return next();
    }
    return finishSources(ctx.dep, ctx.entries, acc);
}

// Merge handler sources into the manifest entries + respond (releases the held
// chain). Handlers carry `source` (or `missing:true` if the blob read failed);
// statics carry metadata only.
function finishSources(dep, entries, sources) {
    const srcByPath = {};
    for (const s of sources) srcByPath[s.path] = s;
    const out = entries.map((e) => {
        const r = { path: e.path, kind: e.kind, content_type: e.content_type, source_hex: e.hash };
        if (e.kind === "handler") {
            const s = srcByPath[e.path];
            if (s && s.source != null) r.source = s.source; else r.missing = true;
        }
        return r;
    });
    response.status = 200;
    response.headers = { "content-type": "application/json" };
    return JSON.stringify({ ok: true, dep_id: dep, entries: out });
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
    // Browser-facing full logout (RP-Initiated): clears the RP session AND
    // ends the IdP SSO session so /authorize stops silently re-logging in.
    if (method === "GET"  && path === "/_rp/logout")   return rp.logoutRedirect();

    if (method === "POST" && path === "/v1/logout")  return rp.logout();
    if (method === "GET"  && path === "/v1/session") return handleSession();

    // CLI/device gateway (Track 3): the `rewind` customer CLI POSTs its
    // device-grant id_token here → RP session bound to this request's sid.
    // Pre-auth (the CLI has no session yet — this establishes one).
    if (method === "POST" && path === "/v1/cli/exchange") {
        let b; try { b = JSON.parse(request.body || "{}"); } catch (_) { b = {}; }
        return rp.exchangeToken(b.id_token);
    }

    // Deploy chokepoint — per-file workspace flow. request.auth is set by
    // _middlewares (operator root-token M2M or an OIDC session); each op
    // gates on is_root OR ownership of the target tenant.
    if (method === "POST" && path === "/v1/deploy/reset") return handleWsReset(request.body || "{}");
    if (method === "POST" && path === "/v1/deploy/file")  return handleWsFile(request.body || "{}");
    if (method === "POST" && path === "/v1/deploy/cut")   return handleWsCut(request.body || "{}");

    // Log query chokepoint → rewind-logs.internal door (A5).
    if (method === "GET" && path.startsWith("/v1/logs/")) {
        return handleLogQuery(path, q === -1 ? "" : fullPath.slice(q + 1));
    }

    // Source read → rove-blob-read.internal door. /v1/sources/{tenant}/{dep|current}.
    if (method === "GET" && path.startsWith("/v1/sources/")) {
        const rest = path.slice("/v1/sources/".length);
        const slash = rest.indexOf("/");
        if (slash < 1) return jsonError(400, "bad sources path");
        return handleReadSources(rest.slice(0, slash), rest.slice(slash + 1));
    }

    // CP control chokepoint → rewind-cp.internal door (B4). The operator
    // POSTs the same {tenant, …} body the CP /_control/* routes expect; the
    // worker attaches the move-secret. `move` picks move-live when body.live.
    if (method === "POST" && path === "/v1/cp/provision") return handleCpOp("provision", request.body || "{}");
    if (method === "POST" && path === "/v1/cp/host")      return handleCpOp("host", request.body || "{}");
    if (method === "POST" && path === "/v1/cp/plan")      return handleCpOp("plan", request.body || "{}");
    if (method === "POST" && path === "/v1/cp/move") {
        let live = false;
        try { live = !!JSON.parse(request.body || "{}").live; } catch (_) {}
        return handleCpOp(live ? "move-live" : "move", request.body || "{}");
    }
    // CP read surface for the cluster page (operator-only).
    if (method === "GET" && path === "/v1/cp/route") {
        return handleCpRead("route", q === -1 ? "" : fullPath.slice(q + 1));
    }
    if (method === "GET" && path === "/v1/cp/plan") {
        return handleCpRead("plan", q === -1 ? "" : fullPath.slice(q + 1));
    }

    response.status = 404;
    return { error: "not found" };
}
