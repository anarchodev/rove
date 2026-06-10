// blob.* — tenant object storage (`docs/blob-storage-plan.md` P1).
//
// The storage doctrine in one line: kv is for state you mutate; the
// object store is for facts you accumulate. Every object is
// content-addressed — the store has no names, only sha256 hashes;
// your naming layer (`media/{id} → hash`) lives in kv where it is
// transactional and replicated.
//
// Transport: `blob.put` / `blob.get` fetch the special origin
// `http://rove-blob.internal/{hash}`. The fetch engine rewrites that
// to YOUR tenant's `app-blobs/` prefix on the real object store and
// signs it natively — the signing keys never exist in JS, and the
// tenant in the key comes from the activation, so no handler can
// reach another tenant's prefix. `blob.url` is the one verb that is
// native end-to-end (`_system.blob.presign`): it mints a presigned
// GET URL from the activation's taped clock, so replay reproduces
// it bit-for-bit.

// IIFE-wrapped (like on.js): bare top-level function declarations
// corrupt the arenajs base-snapshot freeze — green unit tests,
// segfault on the first live request. Everything below stays in the
// closure; only `globalThis.blob` escapes.
(() => {

// Capture the natives at eval time (before `_harden.js` deletes
// `globalThis._system`) — same closure posture as webhook.js/on.js.
const sysHttp = _system.http;
const sysBlob = _system.blob;

const BLOB_ORIGIN = "http://rove-blob.internal/";
const HASH_RE = /^[0-9a-f]{64}$/;

function assertHash(hash, verb) {
  if (typeof hash !== "string" || !HASH_RE.test(hash))
    throw new TypeError(verb + ": hash must be 64 lowercase hex chars (a sha256 digest)");
}

/**
 * Content-addressed tenant object storage.
 *
 * @namespace blob
 */
globalThis.blob = {
  /**
   * Store bytes content-addressed. Returns the sha256 hash (the
   * object's permanent key) synchronously — index it in kv in the
   * same activation; the index write, the durable `_blob/owed/{hash}`
   * marker, and the rest of your writeset commit atomically, then
   * the PUT fires post-commit (idempotent: same bytes → same key).
   *
   * Durability semantics (P1): the owed marker is written before the
   * PUT and cleared by the platform when the PUT succeeds. On
   * terminal PUT failure the marker persists with `failed: true` as
   * durable evidence, and your `on_result` module (if given) sees
   * `ok: false` — re-putting the same bytes is always safe.
   * Automatic re-PUT via source-activation re-execution is the §2.5
   * recovery model and lands after P1.
   *
   * @param {string|Uint8Array} bytes - Object content. Strings store
   *   their UTF-8 bytes; use Uint8Array for binary. Bounded by the
   *   activation arena — multi-MB media wants the streaming verbs
   *   (P2/P3, not yet shipped).
   * @param {object} [opts]
   * @param {string} [opts.content_type] - Stored Content-Type,
   *   returned on direct GETs of the object.
   * @param {string} [opts.on_result] - Module path receiving the
   *   terminal result as `request.ctx.result = {hash, ok, status}`.
   * @param {*} [opts.context] - Opaque payload echoed to `on_result`.
   * @returns {string} The object's sha256 hash (64 hex chars).
   *
   * @example
   * const hash = blob.put(JSON.stringify(event));
   * kv.set(`timeline/${room}/${seq}`, JSON.stringify({ hash }));
   */
  put(bytes, opts) {
    opts = opts || {};
    if (typeof bytes !== "string" && !(bytes instanceof Uint8Array))
      throw new TypeError("blob.put: bytes must be a string or Uint8Array");
    const hash = crypto.sha256(bytes);
    const on_result = typeof opts.on_result === "string" ? opts.on_result : null;
    const context = opts.context !== undefined ? opts.context : null;

    const marker = {
      hash: hash,
      content_type: opts.content_type || null,
      attempts: 1,
      on_result: on_result,
      context: context,
      created_at_ns: String(BigInt(Date.now()) * 1_000_000n),
    };
    kv.set("_blob/owed/" + hash, JSON.stringify(marker));

    sysHttp.fetch({
      url: BLOB_ORIGIN + hash,
      method: "PUT",
      body: bytes,
      headers: opts.content_type ? { "content-type": opts.content_type } : {},
      on_chunk: "__system/blob_onresult",
      ctx: { hash: hash, on_result: on_result, context: context },
    });
    return hash;
  },

  /**
   * Read an object. Connection-scoped (`on.fetch` semantics): the
   * result resumes THIS held connection — by default in
   * `onFetchResult`, or the export named by `to`. Inert in a
   * connectionless activation. A missing object surfaces as a
   * non-2xx result; reads carry no marker — the caller retries.
   *
   * @param {string} hash - The object's sha256 hash.
   * @param {object} [opts]
   * @param {string} [opts.to] - Export name to resume in.
   * @param {boolean} [opts.stream] - Per-chunk delivery (default
   *   false: one whole-body result, up to `max_bytes`).
   * @param {number} [opts.max_bytes] - Whole-body transport cap
   *   (default 8 MB). The per-request arena (100 MiB allocation
   *   volume) comfortably covers decoding bodies this size; for
   *   serving bytes your handler doesn't execute on, prefer the
   *   `blob.url` redirect — the bytes then never touch the worker.
   * @returns {string} The fetch id.
   *
   * @example
   * export default function () {
   *   blob.get(JSON.parse(kv.get(`media/${id}`)).hash, { to: "onBlob" });
   *   return next();
   * }
   * export function onBlob() { return request.result.body; }
   */
  get(hash, opts) {
    opts = opts || {};
    assertHash(hash, "blob.get");
    const fetch_opts = {
      method: "GET",
      stream: !!opts.stream,
      max_response_chunk_bytes: opts.stream
        ? (opts.max_chunk_bytes || 256 * 1024)
        : (opts.max_bytes || 8 * 1024 * 1024),
    };
    return on.fetch(BLOB_ORIGIN + hash, fetch_opts,
                    opts.to ? { to: opts.to } : undefined);
  },

  /**
   * Mint a presigned download URL for an object — the zero-copy
   * read path. Answer a download request with a redirect and the
   * bytes flow storage→client without touching the worker:
   *
   *   response.status = 307;
   *   response.headers = { location: blob.url(hash, { ttl: 300 }) };
   *   return "";
   *
   * The URL's timestamp derives from the activation's taped clock,
   * so replay reproduces it exactly.
   *
   * @param {string} hash - The object's sha256 hash.
   * @param {object} [opts]
   * @param {number} [opts.ttl] - Validity in seconds (default 300,
   *   max 604800 = 7 days).
   * @param {string} [opts.content_type] - Signed response
   *   Content-Type override (S3 returns exactly this).
   * @returns {string} The presigned URL.
   */
  url(hash, opts) {
    opts = opts || {};
    assertHash(hash, "blob.url");
    return sysBlob.presign(hash, opts.ttl != null ? opts.ttl : null,
                           opts.content_type != null ? opts.content_type : null);
  },

  /**
   * Append bytes to this connection's upload session (created on
   * the first write). The session accumulates across the chain's
   * activations — write each streamed `on.fetch` chunk from its
   * resume, or call repeatedly within one activation — then
   * {@link blob.seal} turns the whole accumulation into one
   * content-addressed object.
   *
   * Caps (P2): 64 MiB per session, 2 open sessions per tenant —
   * exceeding either throws. A session whose chain dies without
   * sealing is swept after ~2 minutes idle; nothing reaches storage
   * before `seal`, so abandonment costs nothing.
   *
   * @param {string|Uint8Array} bytes - Chunk to append. Strings
   *   append their UTF-8 bytes; use Uint8Array for binary.
   * @returns {number} Total session bytes after the append.
   *
   * @example
   * export function onMirrorChunk() {
   *   if (!request.done) { blob.write(request.body); return next(); }
   *   blob.seal({ to: "onStored", content_type: "image/png" });
   *   return next();
   * }
   */
  write(bytes) {
    if (typeof bytes !== "string" && !(bytes instanceof Uint8Array))
      throw new TypeError("blob.write: bytes must be a string or Uint8Array");
    return sysBlob.write(bytes);
  },

  /**
   * Seal this connection's upload session: hash the accumulated
   * bytes (sha256 = the object's key), return the hash
   * synchronously, and PUT the bytes content-addressed. The PUT's
   * result resumes THIS connection at the `to` export with
   * `request.status`; thread the hash there via `next({ hash })`
   * (the chain-ctx idiom). Connection-scoped like `on.fetch`:
   * without a held connection the seal is inert.
   *
   * Durability contract: there is no owed marker — your `to` export
   * observing a 2xx status IS the signal the object is durable;
   * write your kv index there. On failure, re-uploading the same
   * bytes is always safe (same hash, idempotent PUT).
   *
   * @param {object} opts
   * @param {string} opts.to - Export resumed with the PUT result
   *   (required).
   * @param {string} [opts.content_type] - Stored Content-Type.
   * @returns {string} The object's sha256 hash (64 hex chars).
   *
   * @example
   * const hash = blob.seal({ to: "onStored", content_type: "image/png" });
   * return next({ hash });
   *
   * // ...
   * export function onStored() {
   *   if (request.status !== 200) { response.status = 502; return "store failed"; }
   *   kv.set(`media/${mxc()}`, JSON.stringify({ hash: request.ctx.hash }));
   *   return JSON.stringify({ content_uri: request.ctx.hash });
   * }
   */
  seal(opts) {
    opts = opts || {};
    if (typeof opts.to !== "string" || !opts.to.length)
      throw new TypeError("blob.seal: `to` export name is required");
    return sysBlob.seal(opts.to,
                        opts.content_type != null ? opts.content_type : undefined);
  },
};

})();
