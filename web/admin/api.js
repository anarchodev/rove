// Typed wrapper around the rove admin API.
//
// Auth is cookie-based: the server mints a `rove_session` cookie after
// POST /v1/login, and every subsequent fetch replays it automatically
// (we send `credentials: "include"`). No tokens in localStorage.
//
// Every RPC call is still a named function on the `__admin__` handler:
// `?fn=<name>` (GET, URL-encoded JSON args) or `POST {fn, args}`.
//
// Two scopes for the admin handler:
// 1. Bare admin host (`app.loop46.me`) → `kv` = root store (tenant /
//    domain CRUD + session store).
// 2. `{id}.app.loop46.me`              → `kv` = {id}'s app.db
//    (per-tenant KV browsing).
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
/// tenant; the server rebinds `kv` to that tenant's store on handler
/// dispatch. Uses an `X-Rove-Scope` header rather than a subdomain
/// because SameSite=Lax cookies can't flow across subdomains without
/// PSL coverage (see PLAN §2.1).
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

  // ── Out-of-band: logs (native Zig proxy) ────────────────────────
  async listLogs(instance_id, { limit = 100 } = {}) {
    const qs = new URLSearchParams({ limit: String(limit) }).toString();
    const res = await rawGet(adminBase(),
      `/_system/log/${encodeURIComponent(instance_id)}/list?${qs}`);
    return res.json();
  },
  async showLog(instance_id, request_id_hex) {
    const res = await rawGet(adminBase(),
      `/_system/log/${encodeURIComponent(instance_id)}/show/${encodeURIComponent(request_id_hex)}`);
    return res.json();
  },
  async countLogs(instance_id) {
    const res = await rawGet(adminBase(),
      `/_system/log/${encodeURIComponent(instance_id)}/count`);
    return res.text();
  },
};
