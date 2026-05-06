// Typed wrapper around the rove admin API.
//
// Auth is cookie-based: the server mints a `rove_session` cookie after
// POST /v1/login, and every subsequent fetch replays it automatically
// (we send `credentials: "include"`). No tokens in localStorage.
//
// Every RPC call is still a named function on the `__admin__` handler:
// `?fn=<name>` (GET, URL-encoded JSON args) or `POST {fn, args}`.
//
// Two scopes for the admin handler, both reached on the bare admin
// host (`app.loop46.me`):
// 1. No header                  → `kv` = root store (tenant / domain
//                                  CRUD + session store).
// 2. `X-Rove-Scope: <id>`       → `kv` = {id}'s app.db (per-tenant
//                                  KV browsing).
//
// Out-of-band (still the native Zig proxies): logs + code via
// `/_system/log/*` and `/_system/files/*`.

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
/// tenant via the `X-Rove-Scope` header; the server rebinds `kv` to
/// that tenant's store on handler dispatch.
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

/// Minimal JSON POST used by /v1/login, /v1/logout. Returns the parsed
/// body or throws on non-2xx.
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

async function rawGet(base, path) {
  const res = await fetch(base + path, { credentials: "include" });
  if (!res.ok) {
    const txt = await res.text().catch(() => "");
    throw new ApiError(res.status, res.statusText, txt);
  }
  return res;
}

/// Phase 5.5(a) Step B — minted by the worker at /_system/log-token,
/// cached for 4 of its 5 minute lifetime so the dashboard rarely
/// blocks on a refresh round-trip. Reset to null on 401 so the next
/// call re-mints.
let _logTokenCache = null; // { token, log_url, refresh_at_ms } | null

async function getLogToken() {
  const now = Date.now();
  if (_logTokenCache && now < _logTokenCache.refresh_at_ms) return _logTokenCache;
  const res = await rawGet(adminBase(), "/_system/log-token");
  const body = await res.json();
  _logTokenCache = {
    token: body.token,
    log_url: body.log_url.replace(/\/+$/, ""),
    // Refresh ~1 minute before exp so an in-flight call never blocks.
    refresh_at_ms: body.exp_ms - 60_000,
  };
  return _logTokenCache;
}

/// Cross-origin fetch against the standalone log-server. Stamps the
/// JWT, refreshes once on 401, throws ApiError on any other failure.
async function logFetch(path) {
  let creds = await getLogToken();
  let res = await fetch(creds.log_url + path, {
    headers: { authorization: "Bearer " + creds.token },
  });
  if (res.status === 401) {
    _logTokenCache = null;
    creds = await getLogToken();
    res = await fetch(creds.log_url + path, {
      headers: { authorization: "Bearer " + creds.token },
    });
  }
  if (!res.ok) {
    const txt = await res.text().catch(() => "");
    throw new ApiError(res.status, res.statusText, txt);
  }
  return res;
}

/// URL-encode a file path that may contain `/` separators. Slashes are
/// preserved; each segment gets `encodeURIComponent`'d.
function encodePath(path) {
  return path.split("/").map(encodeURIComponent).join("/");
}

/// SHA-256(bytes) → 64-char lowercase hex string. Used by the
/// two-phase deploy to address each file by its content hash before
/// asking the server which blobs it already has.
///
/// `bytes` can be a Uint8Array, ArrayBuffer, or a string (encoded
/// UTF-8 via TextEncoder). Returns a Promise.
export async function hashBytes(bytes) {
  let buffer;
  if (typeof bytes === "string") {
    buffer = new TextEncoder().encode(bytes);
  } else if (bytes instanceof ArrayBuffer) {
    buffer = bytes;
  } else if (bytes && bytes.buffer instanceof ArrayBuffer) {
    buffer = bytes;
  } else {
    throw new TypeError("hashBytes: expected Uint8Array, ArrayBuffer, or string");
  }
  const digest = await crypto.subtle.digest("SHA-256", buffer);
  const view = new Uint8Array(digest);
  let out = "";
  for (const b of view) out += b.toString(16).padStart(2, "0");
  return out;
}

export const api = {
  // ── Auth ─────────────────────────────────────────────────────────
  login(token) {
    return postJson(adminBase() + "/v1/login", { token });
  },
  logout() {
    return postJson(adminBase() + "/v1/logout", {});
  },
  /// Magic-link signup. Returns `{ok:true, name, magic_link?}` on
  /// success — `magic_link` is present only when no Resend key is
  /// configured (dev/MVP mode); in production the link is delivered
  /// via email and the customer follows it to /v1/auth.
  /// Errors: 409 = name unavailable / reserved, 400 = invalid email.
  signup(name, email) {
    return postJson(adminBase() + "/v1/signup", { name, email });
  },
  /// Returns `{is_root}` on a valid session, null on 401.
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

  // ── Out-of-band: files (native Zig proxy) ────────────────────────
  async listFiles(instance_id) {
    const res = await rawGet(adminBase(),
      `/_system/files/${encodeURIComponent(instance_id)}/list`);
    return res.json();
  },
  async getFile(instance_id, path) {
    const res = await rawGet(adminBase(),
      `/_system/files/${encodeURIComponent(instance_id)}/file/${encodePath(path)}`);
    return res.json();
  },
  async putFile(instance_id, path, content, contentType) {
    const res = await fetch(
      adminBase() + `/_system/files/${encodeURIComponent(instance_id)}/file/${encodePath(path)}`,
      {
        method: "PUT",
        credentials: "include",
        headers: { "Content-Type": contentType || "application/octet-stream" },
        body: content,
      },
    );
    if (!res.ok) {
      const txt = await res.text().catch(() => "");
      throw new ApiError(res.status, res.statusText, txt);
    }
    return res.text();
  },

  // ── Two-phase deploy: check → upload blobs → commit manifest ─────
  //
  // The protocol mirrors PLAN §2.4 and swaps in cleanly for presigned
  // S3 uploads later: the client always follows whatever URL the
  // server hands back in `/blobs/check`, so an FS backend returns
  // our-own-server URLs and a future S3 backend returns presigned
  // S3 URLs — same client flow. Hash files client-side with
  // SHA-256 (`hashBytes` below); 64 lowercase hex chars.

  async checkBlobs(instance_id, hashes) {
    const url = adminBase()
      + `/_system/files/${encodeURIComponent(instance_id)}/blobs/check`;
    const res = await fetch(url, {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ hashes }),
    });
    if (!res.ok) {
      const txt = await res.text().catch(() => "");
      throw new ApiError(res.status, res.statusText, txt);
    }
    return res.json(); // { missing: [...], uploads: {hash: {url, method, expires_in}} }
  },

  /// Upload one blob. `uploadInfo` comes from `checkBlobs`' `uploads`
  /// object (or is manufactured for the single-blob case). We pass
  /// credentials + let the browser follow the URL verbatim, so the
  /// same code path works against our FS backend (URL points at our
  /// own server) and a future S3 backend (URL is presigned S3).
  async uploadBlob(uploadInfo, bytes) {
    // For FS-backend upload-URLs we resolve against the admin base;
    // for absolute URLs (future S3 presign) the fetch takes them
    // as-is.
    const url = uploadInfo.url.startsWith("http")
      ? uploadInfo.url
      : adminBase() + uploadInfo.url;
    const headers = { ...(uploadInfo.headers || {}) };
    // FS-backend accepts any content-type; S3 presigns demand the
    // signed one. Only set if the server told us to.
    const init = {
      method: uploadInfo.method || "PUT",
      headers,
      body: bytes,
    };
    // Only include credentials for our own origin — presigned S3
    // URLs must not carry the session cookie.
    if (!uploadInfo.url.startsWith("http")) init.credentials = "include";
    const res = await fetch(url, init);
    if (!res.ok) {
      const txt = await res.text().catch(() => "");
      throw new ApiError(res.status, res.statusText, txt);
    }
  },

  async deployManifest(instance_id, files, { parent_id = null, comment = null } = {}) {
    const body = { files };
    if (parent_id !== null) body.parent_id = parent_id;
    if (comment !== null) body.comment = comment;
    const res = await fetch(
      adminBase() + `/_system/files/${encodeURIComponent(instance_id)}/deployments`,
      {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      },
    );
    if (!res.ok) {
      const txt = await res.text().catch(() => "");
      throw new ApiError(res.status, res.statusText, txt);
    }
    return res.json(); // { id, parent_id }
  },

  /// High-level helper: takes a map `{path: {bytes, kind, content_type?}}`,
  /// hashes each, uploads missing blobs in parallel, and commits the
  /// manifest. Returns the deploy result `{id, parent_id}`.
  ///
  /// `bytes` must be a Uint8Array or ArrayBuffer. `kind` is
  /// "handler" or "static". Pass `parent_id` (hex string) to CAS
  /// against `deployment/current`; omit to skip the check.
  async bulkDeploy(instance_id, files, { parent_id = null, comment = null } = {}) {
    // Hash each file client-side. crypto.subtle.digest is async but
    // runs in parallel if we Promise.all them.
    const entries = await Promise.all(Object.entries(files).map(async ([path, f]) => {
      const hash = await hashBytes(f.bytes);
      return { path, hash, bytes: f.bytes, kind: f.kind, content_type: f.content_type };
    }));

    const hashes = entries.map((e) => e.hash);
    const check = await this.checkBlobs(instance_id, hashes);

    // Upload missing blobs in parallel (the browser caps per-host
    // concurrency automatically; no need to throttle by hand).
    const byHash = new Map(entries.map((e) => [e.hash, e]));
    await Promise.all(
      check.missing.map((hash) => {
        const info = check.uploads[hash];
        const entry = byHash.get(hash);
        return this.uploadBlob(info, entry.bytes);
      })
    );

    // Commit the manifest.
    const manifest = {};
    for (const e of entries) {
      manifest[e.path] = { hash: e.hash, kind: e.kind };
      if (e.content_type) manifest[e.path].content_type = e.content_type;
    }
    return this.deployManifest(instance_id, manifest, { parent_id, comment });
  },

  // ── Out-of-band: logs ─────────────────────────────────────────────
  //
  // Phase 5.5(a) Step B — the dashboard talks to the standalone
  // log-server directly at `https://logs.{public_suffix}` (cross-
  // origin), not through the worker proxy. Auth is a short-lived
  // HS256 JWT minted at `/_system/log-token` on the worker. The
  // token + base URL are cached for a few minutes; refresh on demand.
  //
  // request_ids are decimal numbers (the standalone's wire shape);
  // pagination cursor is `{received_ns, request_id}`.
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

  // ── Replay bundle composer (PLAN §10.12) ────────────────────────
  //
  // Builds the bundle the replay shell consumes by fetching the log
  // record + the deployment manifest the request was dispatched
  // against + handler source bytes + captured tape blobs. Log fetches
  // go through the worker's /_system/log/* proxy → standalone
  // log-server (S3-backed). Files fetches stay on the worker's
  // /_system/files/* proxy. The composed bundle is then handed to
  // the replay shell on `replay.<suffix>` via postMessage — see
  // `replayOpen` below.
  //
  // The manifest is loaded by the request's captured deployment_id,
  // not the current pointer — replays of older requests get the
  // historical source the handler actually ran with. If retention
  // has GC'd that deployment, we fall back to the current manifest
  // and surface a `historical_manifest_missing` flag so the replay
  // shell can warn the user.
  async composeReplayBundle(instance_id, request_id) {
    const inst = encodeURIComponent(instance_id);
    const rid = encodeURIComponent(String(request_id));

    const recordRes = await logFetch(`/v1/${inst}/show/${rid}`);
    const recordWrap = await recordRes.json();
    const record = recordWrap.record;

    // Hex-encoded deployment id matches the
    // /_system/files/{inst}/deployments/{hex} route shape.
    const depHex = (record.deployment_id ?? 0).toString(16).padStart(16, "0");
    let manifest;
    let historicalManifestMissing = false;
    try {
      const r = await rawGet(adminBase(),
        `/_system/files/${inst}/deployments/${depHex}`);
      manifest = await r.json();
    } catch (err) {
      if (err instanceof ApiError && err.status === 404) {
        // Historical deployment GC'd or otherwise unreachable —
        // fall back to current. Replay shell can flag the mismatch.
        historicalManifestMissing = true;
        const r = await rawGet(adminBase(), `/_system/files/${inst}/list`);
        manifest = await r.json();
      } else {
        throw err;
      }
    }

    // Find the handler entry. PLAN §2.4 says the default export at
    // `index.mjs` (or `index.js` post-compile) is the catch-all
    // entrypoint. Fall back to the first .mjs/.js entry if neither
    // exact name is present.
    let entryHash = null;
    let entryPath = null;
    const entries = manifest.entries || [];
    for (const e of entries) {
      if (e.path === "index.mjs" || e.path === "index.js") {
        entryHash = e.hash; entryPath = e.path; break;
      }
    }
    if (!entryHash) {
      for (const e of entries) {
        if (e.kind === "handler" && (e.path.endsWith(".mjs") || e.path.endsWith(".js"))) {
          entryHash = e.hash; entryPath = e.path; break;
        }
      }
    }

    // Fetch source bytes for EVERY handler entry, not just the
    // entry. This lets the replay shell build an importmap so
    // multi-file handlers' sibling imports (`import "./lib/foo"`)
    // resolve to the right blob inside the iframe. Static entries
    // are skipped — they aren't part of the JS module graph.
    const handlerEntries = entries.filter((e) => e.kind === "handler");
    const sources = await Promise.all(handlerEntries.map(async (e) => {
      const r = await rawGet(adminBase(),
        `/_system/files/${inst}/source/${encodeURIComponent(e.hash)}`);
      return { path: e.path, hash: e.hash, source: await r.text() };
    }));
    let entrySource = "";
    for (const s of sources) {
      if (s.path === entryPath) entrySource = s.source;
    }

    // Tape blobs — fetch each non-null hash in parallel and turn the
    // raw bytes into Uint8Arrays for postMessage's structured-clone
    // transport. Replay shell parses each blob on the other side.
    // The request body lives in the same per-tenant log-blobs/ store
    // (worker dispatcher writes it via uploadTapes).
    const tapeRefs = {
      kv: record.tape_refs?.kv_tape_hex || null,
      date: record.tape_refs?.date_tape_hex || null,
      math_random: record.tape_refs?.math_random_tape_hex || null,
      crypto_random: record.tape_refs?.crypto_random_tape_hex || null,
    };
    const tapeBlobs = { kv: null, date: null, math_random: null, crypto_random: null };
    const bodyHash = record.tape_refs?.request_body_hex || null;
    let bodyBytes = null;
    await Promise.all([
      ...Object.keys(tapeRefs).map(async (name) => {
        const hash = tapeRefs[name];
        if (!hash) return;
        const r = await logFetch(
          `/v1/${inst}/blob/${encodeURIComponent(hash)}`);
        const buf = await r.arrayBuffer();
        tapeBlobs[name] = new Uint8Array(buf);
      }),
      bodyHash ? (async () => {
        const r = await logFetch(
          `/v1/${inst}/blob/${encodeURIComponent(bodyHash)}`);
        const buf = await r.arrayBuffer();
        bodyBytes = new Uint8Array(buf);
      })() : Promise.resolve(),
    ]);

    return {
      request_id: record.request_id,
      deployment_id: record.deployment_id,
      received_ns: record.received_ns,
      duration_ns: record.duration_ns,
      request: {
        method: record.method,
        path: record.path,
        host: record.host,
        // Replay shell decodes these to a string (UTF-8) and stamps
        // `window.request.body`. Null when the request had no body
        // OR the worker chose not to capture (no tenant log open at
        // capture time). Truncated bodies get an explicit flag so
        // the shell can warn the handler may see less than original.
        body_bytes: bodyBytes,
        body_truncated: !!record.tape_refs?.request_body_truncated,
      },
      response: {
        status: record.status,
        outcome: record.outcome,
        console: record.console,
        exception: record.exception,
      },
      entry_path: entryPath,
      entry_source_hash: entryHash,
      entry_source: entrySource,
      // Every handler in the deployment's manifest, not just the
      // captured imports — the replay shell builds an importmap from
      // this so any `import` in any module resolves. Sources fetched
      // by hash; the entry itself is also in here.
      modules: sources,
      tape_blobs: tapeBlobs,
      // True iff the historical manifest was unreachable and the
      // shell got the CURRENT manifest as a fallback. Replay shell
      // surfaces this in the side-effects panel so the user knows
      // the source they're stepping through may not match what
      // originally ran.
      historical_manifest_missing: historicalManifestMissing,
    };
  },

  /// Open the replay shell in a new tab and send it the bundle via
  /// postMessage. The shell is at `replay.<suffix>` — derived from
  /// the dashboard's own origin by replacing the `app.` label.
  /// Returns the opened window (caller can close it on error).
  replayOpen(bundle) {
    const replayOrigin = window.location.origin.replace("://app.", "://replay.");
    const popup = window.open(replayOrigin + "/", "_blank");
    if (!popup) {
      throw new Error("popup blocked — allow popups for the dashboard");
    }
    // The shell sends `replay:ready` once it's listening; we reply
    // with `replay:bundle`. We can't deliver the bundle until then —
    // postMessage to a not-yet-loaded page is dropped.
    function onMsg(e) {
      if (e.origin !== replayOrigin) return;
      if (e.source !== popup) return;
      if (e.data?.kind === "replay:ready") {
        window.removeEventListener("message", onMsg);
        popup.postMessage({ kind: "replay:bundle", bundle }, replayOrigin);
      }
    }
    window.addEventListener("message", onMsg);
    // 30s safety net — give up if the shell never reports ready
    // (popup blocker, navigation away, etc.). At that point the
    // dashboard has nothing to clean up — user just closes the tab.
    setTimeout(() => window.removeEventListener("message", onMsg), 30_000);
    return popup;
  },
};
