// blob.* — tenant object storage (blob-storage-plan P1; `docs/architecture/routing-and-ingress.md`).
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

function _rejectRenamedBlob(verb, opts) {
  if (!opts || typeof opts !== "object") return;
  for (const pair of [["content_type", "contentType"], ["max_bytes", "maxBytes"], ["on_result", "on"], ["context", "ctx"]]) {
    if (pair[0] in opts) throw new TypeError(verb + ": option `" + pair[0] + "` was renamed — use `" + pair[1] + "`");
  }
}

const BLOB_ORIGIN = "http://rove-blob.internal/";
const COMPOSE_ORIGIN = "http://rove-compose.internal/";
const HASH_RE = /^[0-9a-f]{64}$/;

function assertHash(hash, verb) {
  if (typeof hash !== "string" || !HASH_RE.test(hash))
    throw new TypeError(verb + ": hash must be 64 lowercase hex chars (a sha256 digest)");
}

// ── The recipe substrate (blob-write-recipes.md) ─────────────
//
// An open accumulation is kv rows, not worker RAM: `write` appends a
// row + advances a sha256 midstate, `seal` freezes the recipe (the
// durable marker) and emits the compose Cmd. Everything load-bearing
// is replicated kv — replayable by construction, and the caps below
// are policy, not memory protection.

const RECIPE_MAX_ROWS = 4096;
const RECIPE_INLINE_APPEND_MAX = 256 * 1024;   // mirrors MAX_FIRE_BYTES
const RECIPE_INLINE_TOTAL_MAX = 16 * 1024 * 1024;
// Plan-tier input eventually (§12.2); one constant until plans carry it.
const RECIPE_TOTAL_MAX = 1024 * 1024 * 1024;

// One open recipe per chain: the sid IS the chain's correlation id
// (recorded → replay-pure). Chain-less dispatch (test paths) shares
// one local recipe, matching the one-session-per-chain semantics the
// RAM implementation had.
function _recipeSid() {
  return request.correlation_id || "local";
}

function _recipeMetaKey(sid) { return "_blob/recipe/" + sid + "/meta"; }

function _recipeRowKey(sid, seq) {
  return "_blob/recipe/" + sid + "/r/" + String(seq).padStart(4, "0");
}

function _recipeMeta(sid) {
  const raw = kv.get(_recipeMetaKey(sid));
  return raw == null ? null : JSON.parse(raw);
}

// Sealed-but-unmaterialized hashes fail loud on dereference —
// readiness is announced by the seal's `on` activation, never
// inferred (the row is deleted by the compose flip).
function _assertMaterialized(hash, verb) {
  if (kv.get("_blob/pending/" + hash) != null)
    throw new Error(verb + ": " + hash + " is sealed but not yet materialized — wait for your seal `on` activation");
}

/**
 * Content-addressed tenant object storage.
 *
 * Two shapes: one-shot (`put`/`get`) for values you hold in hand, and
 * the upload session (`receive` → `write` → `seal`) for large inbound
 * bodies that stream in chunk by chunk. "Seal" = freeze the bytes into
 * an immutable blob and get back its hash (`segments.seal` is the same
 * metaphor applied to a log tail). `blob.write` appends INTO an upload
 * session — the opposite direction from `stream.write`, which emits
 * response bytes OUT over the held connection.
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
   * @param {string} [opts.contentType] - Stored Content-Type,
   *   returned on direct GETs of the object.
   * @param {string} [opts.on] - Module path receiving the
   *   terminal result on the unified flattened surface (handler-shape
   *   §7): `request.status` top-level (2xx = stored; no `request.ok`,
   *   issue #7), the echoed
   *   `context` (the threaded value) IS `request.ctx`, and the stored
   *   `hash` is on `request.activation.hash`.
   * @param {*} [opts.ctx] - Opaque payload echoed to the `on` module
   *   as `request.ctx`.
   * @returns {string} The object's sha256 hash (64 hex chars).
   *
   * @example
   * const hash = blob.put(JSON.stringify(event));
   * kv.set(`timeline/${room}/${seq}`, JSON.stringify({ hash }));
   */
  put(bytes, opts) {
    opts = opts || {};
    _rejectRenamedBlob("blob.put", opts);
    if (typeof bytes !== "string" && !(bytes instanceof Uint8Array))
      throw new TypeError("blob.put: bytes must be a string or Uint8Array");
    const hash = crypto.sha256(bytes);
    const on_result = typeof opts.on === "string" ? opts.on : null;
    const context = opts.ctx !== undefined ? opts.ctx : null;

    const marker = {
      hash: hash,
      content_type: opts.contentType || null,
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
      headers: opts.contentType ? { "content-type": opts.contentType } : {},
      on_chunk: "__system/blob_onresult",
      ctx: { hash: hash, on_result: on_result, context: context },
    });
    return hash;
  },

  /**
   * Read an object. Connection-scoped (`after.fetch` semantics): the
   * result resumes THIS held connection — by default in
   * `onFetchResult`, or the export named by `to`. Inert in a
   * connectionless activation. A missing object surfaces as a
   * non-2xx result; reads carry no marker — the caller retries.
   *
   * @param {string} hash - The object's sha256 hash.
   * @param {object} [opts]
   * @param {string} [opts.on] - Export name to resume in.
   * @param {*} [opts.ctx] - Delivered as `request.ctx` on the
   *   resume (JSON round-trip).
   * @param {boolean} [opts.stream] - Per-chunk delivery (default
   *   false: one whole-body result, up to `maxBytes`).
   * @param {number} [opts.maxBytes] - Whole-body transport cap
   *   (default 8 MB). The per-request arena (100 MiB allocation
   *   volume) comfortably covers decoding bodies this size; for
   *   serving bytes your handler doesn't execute on, prefer the
   *   `blob.url` redirect — the bytes then never touch the worker.
   * @returns {string} The fetch id.
   *
   * @example
   * export default function () {
   *   const rec = JSON.parse(kv.get(`media/${id}`) ?? "{}");
   *   if (rec.hash) { blob.get(rec.hash, { on: "onBlob" }); return next(); }
   *   return next();
   * }
   * export function onBlob() { return request.bytes; } // flattened payload accessors; request.status top-level
   */
  get(hash, opts) {
    opts = opts || {};
    _rejectRenamedBlob("blob.get", opts);
    assertHash(hash, "blob.get");
    _assertMaterialized(hash, "blob.get");
    const fetch_opts = {
      method: "GET",
      stream: !!opts.stream,
      maxChunkBytes: opts.stream
        ? (opts.maxChunkBytes || 256 * 1024)
        : (opts.maxBytes || 8 * 1024 * 1024),
    };
    // `ctx` rides the fetch and resumes as `request.ctx` — how
    // composers (segments.get) thread slicing info to the `to`
    // export without kv round-trips.
    if (opts.ctx !== undefined) fetch_opts.ctx = opts.ctx;
    if (typeof opts.on === "string") fetch_opts.on = opts.on;
    return after.fetch(BLOB_ORIGIN + hash, fetch_opts);
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
   * @param {string} [opts.contentType] - Signed response
   *   Content-Type override (S3 returns exactly this).
   * @returns {string} The presigned URL.
   */
  url(hash, opts) {
    opts = opts || {};
    assertHash(hash, "blob.url");
    _assertMaterialized(hash, "blob.url");
    return sysBlob.presign(hash, opts.ttl != null ? opts.ttl : null,
                           opts.contentType != null ? opts.contentType : null);
  },

  /**
   * Append bytes to this chain's open recipe (created on the first
   * write). The accumulation is kv rows + a sha256 midstate — nothing
   * lives in worker RAM, so it spans activations, replicates, and
   * replays like any other state. Write each streamed chunk from its
   * resume, or call repeatedly within one activation — then
   * {@link blob.seal} freezes the recipe into one content-addressed
   * object.
   *
   * Caps (policy, blob-write-recipes.md §12): 4096 rows and
   * 1 GiB per recipe, 256 KiB per inline append, 16 MiB inline total
   * — exceeding any throws. A recipe whose chain dies without
   * sealing is swept after ~15 min idle; nothing reaches storage
   * before `seal`, so abandonment costs a few kv rows, briefly.
   *
   * @param {string|Uint8Array} bytes - Chunk to append. Strings
   *   append their UTF-8 bytes; use Uint8Array for binary.
   * @returns {number} Total recipe bytes after the append.
   *
   * @example
   * export function onMirrorChunk() {
   *   if (!request.done) { blob.write(request.bytes); return next(); }
   *   const hash = blob.seal({ on: "stored", contentType: "image/png" });
   *   return JSON.stringify({ hash });
   * }
   */
  write(bytes) {
    if (typeof bytes !== "string" && !(bytes instanceof Uint8Array))
      throw new TypeError("blob.write: bytes must be a string or Uint8Array");
    const len = typeof bytes === "string"
      ? new TextEncoder().encode(bytes).length
      : bytes.length;
    if (len > RECIPE_INLINE_APPEND_MAX)
      throw new Error("blob.write: append exceeds the 256 KiB inline cap");

    const sid = _recipeSid();
    const meta = _recipeMeta(sid) || {
      state: "open", mid: crypto.sha256Init(),
      rows: 0, total: 0, inline_total: 0, updated_at: 0,
    };
    if (meta.state !== "open")
      throw new Error("blob.write: recipe already sealed — one seal per chain");
    if (meta.rows >= RECIPE_MAX_ROWS)
      throw new Error("blob.write: recipe exceeds " + RECIPE_MAX_ROWS + " rows");
    if (meta.total + len > RECIPE_TOTAL_MAX)
      throw new Error("blob.write: recipe exceeds the 1 GiB cap");
    if (meta.inline_total + len > RECIPE_INLINE_TOTAL_MAX)
      throw new Error("blob.write: recipe exceeds the 16 MiB inline cap");

    const row = typeof bytes === "string"
      ? { s: bytes }
      : { b: base64url.encode(bytes) };
    kv.set(_recipeRowKey(sid, meta.rows), JSON.stringify(row));

    meta.mid = crypto.sha256Update(meta.mid, bytes);
    meta.rows += 1;
    meta.total += len;
    meta.inline_total += len;
    meta.updated_at = Date.now();
    kv.set(_recipeMetaKey(sid), JSON.stringify(meta));
    return meta.total;
  },

  /**
   * Seal this chain's recipe: freeze it (the durable marker), return
   * the object's sha256 synchronously — finalized from the recipe's
   * midstate, no byte is re-read — and emit the compose that
   * materializes the object in storage.
   *
   * The hash is an identifier; **readiness is announced by your
   * `on` activation, never inferred.** Completion is durable
   * (webhook.send's convention, not after.fetch's — `on` names a
   * MODULE, like `blob.put`'s and `webhook.send`'s, because the
   * sealed recipe, not the live connection, owes the callback): the
   * module's default export fires connectionless once the object is
   * servable, with your `ctx` as `request.ctx`, the hash on
   * `request.activation.hash`, and `{hash, totalBytes}` as
   * `request.json`. There is no failure arm — materialization
   * retries until it happens.
   *
   * Index the hash in kv NOW if you want: the pointer write, the
   * seal marker, and the rest of your writeset commit atomically.
   * Just don't hand the hash to anything that dereferences it before
   * your `on` activation ran — `blob.url`/`blob.get` on a
   * sealed-but-unmaterialized hash throw.
   *
   * @param {object} opts
   * @param {string} opts.on - Module path activated when the object
   *   is servable (required).
   * @param {*} [opts.ctx] - Threaded to the `on` activation as
   *   `request.ctx` (JSON round-trip).
   * @param {string} [opts.contentType] - Stored Content-Type.
   * @returns {string} The object's sha256 hash (64 hex chars).
   *
   * @example
   * // doc-only
   * // upload.mjs — respond at seal; readiness arrives at `stored`.
   * export function onChunk() {
   *   blob.write(request.bytes);
   *   if (!request.done) return next();
   *   const hash = blob.seal({ on: "stored", ctx: { id: request.ctx.id } });
   *   kv.set(`media/${request.ctx.id}`, JSON.stringify({ hash, status: "processing" }));
   *   response.status = 202;
   *   return JSON.stringify({ hash });
   * }
   * // stored.mjs — the completion activation.
   * export default function () {
   *   const rec = JSON.parse(kv.get(`media/${request.ctx.id}`));
   *   kv.set(`media/${request.ctx.id}`, JSON.stringify({ ...rec, status: "ready" }));
   *   return "";
   * }
   */
  seal(opts) {
    _rejectRenamedBlob("blob.seal", opts);
    opts = opts || {};
    const on_key = opts.on;
    if (typeof on_key !== "string" || !on_key.length)
      throw new TypeError("blob.seal: `on` module path is required");
    if (opts.contentType != null && typeof opts.contentType !== "string")
      throw new TypeError("blob.seal: contentType must be a string");

    const sid = _recipeSid();
    // No open recipe = sealing an empty accumulation — a legitimate
    // (empty) object, same as blob.put("").
    const meta = _recipeMeta(sid) || {
      state: "open", mid: crypto.sha256Init(),
      rows: 0, total: 0, inline_total: 0, updated_at: 0,
    };
    if (meta.state !== "open")
      throw new Error("blob.seal: recipe already sealed — one seal per chain");

    const hash = crypto.sha256Final(meta.mid);
    const ctx = opts.ctx !== undefined ? opts.ctx : null;
    kv.set(_recipeMetaKey(sid), JSON.stringify({
      state: "sealed", hash: hash,
      content_type: opts.contentType || null,
      rows: meta.rows, totalBytes: meta.total,
      on: on_key, ctx: ctx,
      updated_at: Date.now(),
    }));
    // Deleted by the compose flip; blob.url/get check it so an early
    // dereference fails loud instead of racing storage.
    kv.set("_blob/pending/" + hash, sid);

    // The prompt compose trigger — leader-local, moot-on-loss; the
    // sealed marker above is what guarantees materialization (the
    // materializer sweeps sealed-but-unmaterialized recipes).
    sysHttp.fetch({
      url: COMPOSE_ORIGIN + sid,
      method: "PUT",
      body: "",
      headers: {},
      on_chunk: "__system/blob_compose_onresult",
      ctx: { sid: sid, hash: hash, on: on_key, ctx: ctx },
    });
    return hash;
  },

  /**
   * Pipe the entire inbound request body socket → content-addressed
   * storage with ZERO chunk activations (Case B,
   * blob-storage-plan §3.5; `docs/architecture/routing-and-ingress.md`). Only callable from an
   * `onHeaders` export — the body hasn't been accepted yet; calling
   * `blob.receive` then `return next()` opens the valve. Bytes
   * stream to a tenant-prefix S3 multipart at the client's rate
   * (flow-controlled to the upload rate) and NEVER enter a handler
   * activation or the tape — the completion event is all replay
   * needs.
   *
   * The chain resumes at `to` when the object is durable:
   * `request.ctx = { hash, len }` with `request.status === 200`. On
   * failure (client disconnect, storage error) `to` runs with
   * `request.status === 0` and nothing was stored — S3 multipart is
   * commit-gated, so a torn upload is invisible. (`status` is the
   * single result signal; no `request.ok`, issue #7.)
   *
   * The litmus (vs `onChunk` + blob.write): does your logic depend
   * on the CONTENT of the bytes? No → this, one PUT. Yes → the
   * chunk path, which tapes what you read.
   *
   * @param {object} opts
   * @param {string} opts.on - Export resumed with `{hash, len}`
   *   when the object is durable (required).
   *
   * @example
   * export function onHeaders() {
   *   if (!authed(request.headers)) { response.status = 401; return "no"; }
   *   blob.receive({ on: "onStored" });
   *   return next();
   * }
   * export function onStored() {
   *   if (request.status !== 200) { response.status = 502; return "store failed"; }
   *   kv.set(`media/${request.ctx.hash}`, JSON.stringify({ len: request.ctx.len }));
   *   return JSON.stringify({ hash: request.ctx.hash });
   * }
   */
  receive(opts) {
    _rejectRenamedBlob("blob.receive", opts);
    opts = opts || {};
    const on_key = opts.on;
    if (typeof on_key !== "string" || !on_key.length)
      throw new TypeError("blob.receive: `on` export name is required");
    return sysBlob.receive(on_key);
  },
};

})();
