// Typed wrapper around the rove admin API.
//
// Auth is OIDC: the admin dashboard is a pure relying party of the
// __auth__ IdP. Login is a full-page redirect to `/_rp/login`; the
// server binds a session to the platform `__Host-rove_sid` cookie
// (oidc.rp), which every subsequent fetch replays automatically
// (`credentials: "include"`). No tokens in localStorage, no
// rove_session cookie, no client-held credential.
//
// Every RPC call is a named function on the `__admin__` handler:
// `?fn=<name>` (GET, URL-encoded JSON args) or `POST {fn, args}`.
// Path-routed surfaces (deploy, logs, cp) are plain same-origin fetches
// that carry the session cookie.
//
// Two scopes for the RPC handler, both reached on the bare admin host:
// 1. No header             → `kv` = root store (tenant / domain CRUD).
// 2. `X-Rove-Scope: <id>`  → per-tenant KV browsing (platform.scope).
//
// Logs, deploy, and cluster (CP) ops go through the admin app's OWN
// same-origin chokepoints (`/v1/logs/*`, `/v1/deploy`, `/v1/cp/*`),
// which issue the privileged internal-door fetches server-side. No
// services token, log token, or move-secret ever enters the browser.

const BASE_KEY = "rove.admin.api_base";

export class ApiError extends Error {
  constructor(status, statusText, body) {
    super(`${status} ${statusText}`);
    this.status = status;
    this.body = body;
  }
}

/// The admin API base. Defaults to this page's origin (prod shape:
/// same-origin as the UI bundle). Override via `?api=` once and it
/// sticks in localStorage — useful for dev against a remote worker.
function adminBase() {
  const override = window.__rove_api_base ?? localStorage.getItem(BASE_KEY);
  if (override && override.length > 0) return override.replace(/\/+$/, "");
  return window.location.origin;
}

/// Call a named export on the admin handler. `?fn=<name>&args=...` for
/// GET, JSON body for POST. Sends cookies. `scope` sets the target
/// tenant via the `X-Rove-Scope` header for per-tenant KV browsing.
async function rpc(fn, args, { method = "GET", scope = null } = {}) {
  const argsArr = args ?? [];
  const base = adminBase();
  const headers = {};
  if (scope) headers["X-Rove-Scope"] = scope;
  let url, init;
  if (method === "POST") {
    url = base + "/";
    headers["Content-Type"] = "application/json";
    init = {
      method: "POST",
      headers,
      credentials: "include",
      body: JSON.stringify({ fn, args: argsArr }),
    };
  } else {
    const qs = new URLSearchParams({ fn });
    if (argsArr.length > 0) qs.set("args", JSON.stringify(argsArr));
    url = `${base}/?${qs.toString()}`;
    init = { method: "GET", headers, credentials: "include" };
  }
  const res = await fetch(url, init);
  const ct = res.headers.get("content-type") ?? "";
  const parsed = ct.includes("application/json")
    ? await res.json().catch(() => null)
    : await res.text();
  if (!res.ok) throw new ApiError(res.status, res.statusText, parsed);
  return parsed;
}

/// Minimal JSON POST used by /v1/logout. Returns the parsed body or
/// throws on non-2xx. Always same-origin, cookie-authenticated.
async function postJson(url, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    credentials: "include",
    body: JSON.stringify(body),
  });
  const ct = res.headers.get("content-type") ?? "";
  const parsed = ct.includes("application/json")
    ? await res.json().catch(() => null)
    : await res.text();
  if (!res.ok) throw new ApiError(res.status, res.statusText, parsed);
  return parsed;
}

/// Same-origin GET against an admin chokepoint path (logs / cp reads).
/// Carries the RP session cookie; throws ApiError on non-2xx.
async function originGet(path) {
  const res = await fetch(adminBase() + path, { credentials: "same-origin" });
  if (!res.ok) {
    const txt = await res.text().catch(() => "");
    throw new ApiError(res.status, res.statusText, txt);
  }
  return res;
}

// Logs go through the admin app's OWN chokepoint (`/v1/logs/*`), which issues
// the privileged `rewind-logs.internal` door fetch server-side — the worker
// mints a tenant-scoped `logs-read` cap and the log-server verifies it
// (step3-auth-plan.md A5). So there is NO services token in the browser:
// same-origin, carrying the RP session cookie. Call sites keep passing the
// log-server path shape `/v1/{inst}/...`; the chokepoint mounts it under
// `/v1/logs/`.
async function logFetch(path) {
  return originGet(path.replace(/^\/v1\//, "/v1/logs/"));
}

/// base64 → Uint8Array (browser-side; statics + tape decode).
function decodeB64(s) {
  if (!s) return null;
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/// Uint8Array | ArrayBuffer | string → base64 (for the deploy bundle's
/// static entries).
function encodeB64(bytes) {
  let view;
  if (typeof bytes === "string") view = new TextEncoder().encode(bytes);
  else if (bytes instanceof ArrayBuffer) view = new Uint8Array(bytes);
  else view = bytes;
  let bin = "";
  for (let i = 0; i < view.length; i++) bin += String.fromCharCode(view[i]);
  return btoa(bin);
}

export const api = {
  // ── Auth ─────────────────────────────────────────────────────────
  // Login is the OIDC RP handshake: a full-page navigation to
  // `/_rp/login` (see pages/login.js) — there is no token/signup form
  // and no client-held credential.
  logout() {
    return postJson(adminBase() + "/v1/logout", {});
  },
  /// Provision the caller's first instance. Identity is the
  /// OIDC-verified session `sub` server-side — `name` is the only arg.
  provisionInstance(name) {
    return rpc("provisionInstance", [name], { method: "POST" });
  },
  /// Returns `{is_root, sub, owned}` on a valid session, null on 401.
  async whoami() {
    try {
      const res = await fetch(adminBase() + "/v1/session", {
        method: "GET",
        credentials: "include",
      });
      if (res.status === 401) return null;
      if (!res.ok) throw new ApiError(res.status, res.statusText, null);
      return await res.json();
    } catch (err) {
      if (err instanceof ApiError) throw err;
      return null;
    }
  },

  // ── Admin scope: tenant CRUD + domains (kv = root) ──────────────
  listInstances() {
    return rpc("listInstance");
  },
  createInstance(id) {
    return rpc("createInstance", [id], { method: "POST" });
  },
  getInstance(id) {
    return rpc("getInstance", [id]);
  },
  deleteInstance(id) {
    return rpc("deleteInstance", [id], { method: "POST" });
  },
  listDomains() {
    return rpc("listDomain");
  },
  assignDomain(host, instance_id) {
    return rpc("assignDomain", [host, instance_id], { method: "POST" });
  },

  // ── Tenant scope: KV (kv={instance_id}.app.db) ───────────────────
  listKv(instance_id, { prefix = "", cursor = "", limit = 100 } = {}) {
    return rpc("listKv", [prefix, cursor, limit], { scope: instance_id });
  },
  getKv(instance_id, key) {
    return rpc("getKv", [key], { scope: instance_id });
  },
  setKv(instance_id, key, value) {
    return rpc("setKv", [key, value], { method: "POST", scope: instance_id });
  },
  deleteKv(instance_id, key) {
    return rpc("deleteKv", [key], { method: "POST", scope: instance_id });
  },

  // ── Deploy (the one bundle path: POST /v1/deploy) ────────────────
  //
  // rewind-cli-plan Track 0 — the standing dashboard app OWNS /v1/deploy.
  // The browser POSTs the full bundle ({tenant, handlers, statics}); the
  // server composes the deploy from platform.* (compile + content-address
  // + stampManifest barrier) and returns { ok, dep_id }. Ownership-gated
  // server-side (is_root OR the session owns the tenant). Replaces the old
  // two-phase files-server upload — the files-server was dissolved
  // (rewind-cli-plan §4).
  //
  // `files` is `{ path: { source } }` for handlers and
  // `{ path: { bytes, content_type } }` for statics (a `_static/`-prefixed
  // path, or any entry carrying `bytes`, is treated as a static).
  async deploy(instance_id, files) {
    const handlers = [];
    const statics = [];
    for (const [path, f] of Object.entries(files)) {
      const isStatic = f.bytes != null || path.startsWith("_static/") ||
                       path.startsWith("_config/");
      if (isStatic) {
        statics.push({
          path,
          content_type: f.content_type || "application/octet-stream",
          b64: encodeB64(f.bytes ?? f.source ?? ""),
        });
      } else {
        handlers.push({ path, source: f.source ?? "" });
      }
    }
    const res = await fetch(adminBase() + "/v1/deploy", {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ tenant: instance_id, handlers, statics }),
    });
    const body = await res.json().catch(() => null);
    if (!res.ok) throw new ApiError(res.status, res.statusText, body);
    return body; // { ok: true, dep_id: "<016x>" }
  },

  /// Flip the live deployment pointer. `dep_id` is the hex string from
  /// `deploy`. Ownership-gated server-side (publishRelease — step3 B5).
  /// Same-origin RPC; the worker proposes the release through raft.
  releaseDeployment(instance_id, dep_id) {
    const n = typeof dep_id === "string" ? parseInt(dep_id, 16) : dep_id;
    return rpc("publishRelease", [instance_id, n], { method: "POST" });
  },

  /// High-level helper: deploy a bundle then release it. Returns the
  /// deploy result `{ ok, dep_id }`.
  async deployAndRelease(instance_id, files) {
    const result = await this.deploy(instance_id, files);
    await this.releaseDeployment(instance_id, result.dep_id);
    return result;
  },

  // ── Operator: cluster control plane (is_root only) ───────────────
  //
  // The cluster-management surface — the GUI twin of `rewind-ops`. Each
  // call goes through the admin app's /v1/cp/* chokepoint, which issues
  // the `rewind-cp.internal` door fetch (the worker attaches the
  // move-secret) — no CP secret in the browser (step3-auth-plan.md B4).
  // All are operator-only; a non-operator session gets 403.
  async cpProvision(tenant, cluster, host) {
    return this._cpPost("provision", { tenant, cluster, host });
  },
  async cpMove(tenant, cluster, { live = false } = {}) {
    return this._cpPost("move", { tenant, cluster, live });
  },
  async cpHost(host, tenant) {
    return this._cpPost("host", { host, tenant });
  },
  async cpPlan(tenant, plan) {
    return this._cpPost("plan", { tenant, plan });
  },
  async _cpPost(op, body) {
    const res = await fetch(adminBase() + "/v1/cp/" + op, {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const txt = await res.text();
    if (!res.ok) throw new ApiError(res.status, res.statusText, txt);
    return txt ? JSON.parse(txt) : null;
  },
  /// Placement read for a host → `{cluster, tenant, moving, nodes}`.
  async clusterRoute(host) {
    const res = await originGet("/v1/cp/route?host=" + encodeURIComponent(host));
    return res.json();
  },
  /// Plan read for a tenant.
  async clusterPlan(tenant) {
    const res = await originGet("/v1/cp/plan?tenant=" + encodeURIComponent(tenant));
    return res.json();
  },

  // ── Logs (same-origin chokepoint, RP cookie) ─────────────────────
  //
  // request_ids are decimal numbers; pagination cursor is
  // `{received_ns, request_id}`.
  async listLogs(instance_id, { limit = 100, after = null } = {}) {
    const params = { limit: String(limit) };
    if (after) {
      params.after_received_ns = String(after.received_ns);
      params.after_request_id = String(after.request_id);
    }
    const qs = new URLSearchParams(params).toString();
    const res = await logFetch(
      `/v1/${encodeURIComponent(instance_id)}/list?${qs}`);
    return res.json();
  },
  async showLog(instance_id, request_id) {
    const res = await logFetch(
      `/v1/${encodeURIComponent(instance_id)}/show/${encodeURIComponent(String(request_id))}`);
    const body = await res.json();
    return body.record;
  },
  async countLogs(instance_id) {
    const res = await logFetch(
      `/v1/${encodeURIComponent(instance_id)}/count`);
    return res.text();
  },

  // ── Replay bundle composer ───────────────────────────────────────
  //
  // Composes the bundle the WASM replay shell consumes. The log record
  // (fetched via the same-origin logs chokepoint) carries the captured
  // tapes + scalars + request body INLINE, so those are available today.
  //
  // GAP (rewind-cli-plan Track 2): the handler MODULE SOURCES + the
  // historical deployment manifest used to come from the files-server,
  // which was dissolved (§4). Reading them back now requires a
  // cross-tenant blob/manifest READ door (the write twin —
  // platform.scope(t).blob.put — exists; the read door does not yet).
  // Until that door lands, `modules`/`entry_source` come back empty and
  // `sources_unavailable` is set so the replay shell can explain why it
  // can't step through source. This same door also unblocks the Code
  // tab's edit-existing-files flow.
  async composeReplayBundle(instance_id, request_id) {
    const inst = encodeURIComponent(instance_id);
    const rid = encodeURIComponent(String(request_id));

    const recordRes = await logFetch(`/v1/${inst}/show/${rid}`);
    const record = (await recordRes.json()).record;
    const tapesField = record.tapes || {};

    const tapeBlobs = {
      kv: decodeB64(tapesField.kv_tape_b64),
      request_reads: decodeB64(tapesField.request_reads_tape_b64),
    };
    const seed = tapesField.seed != null ? BigInt(tapesField.seed) : 0n;
    const timestamp_ns = tapesField.timestamp_ns != null
      ? BigInt(tapesField.timestamp_ns) : 0n;
    const bodyBytes = decodeB64(tapesField.request_body_b64);

    return {
      request_id: record.request_id,
      deployment_id: record.deployment_id,
      received_ns: record.received_ns,
      duration_ns: record.duration_ns,
      request: {
        method: record.method,
        path: record.path,
        host: record.host,
        body_bytes: bodyBytes,
        body_truncated: !!tapesField.request_body_truncated,
      },
      response: {
        status: record.status,
        outcome: record.outcome,
        console: record.console,
        exception: record.exception,
      },
      entry_path: null,
      entry_source: "",
      modules: [],
      seed,
      timestamp_ns,
      tape_blobs: tapeBlobs,
      activation: record.activation,
      // Source/manifest reads await the cross-tenant read door (see above).
      sources_unavailable: true,
      historical_manifest_missing: true,
    };
  },

  /// Open the replay shell in a new tab and send it the bundle via
  /// postMessage. The shell is at `replay.<suffix>` — derived from the
  /// dashboard's own origin by replacing the `app.` label.
  replayOpen(bundle) {
    const replayOrigin = window.location.origin.replace("://app.", "://replay.");
    const popup = window.open(replayOrigin + "/", "_blank");
    if (!popup) {
      throw new Error("popup blocked — allow popups for the dashboard");
    }
    function onMsg(e) {
      if (e.origin !== replayOrigin) return;
      if (e.source !== popup) return;
      if (e.data?.kind === "replay:ready") {
        window.removeEventListener("message", onMsg);
        popup.postMessage({ kind: "replay:bundle", bundle }, replayOrigin);
      }
    }
    window.addEventListener("message", onMsg);
    setTimeout(() => window.removeEventListener("message", onMsg), 30_000);
    return popup;
  },
};
