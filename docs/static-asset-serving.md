# Static asset serving — non-blocking, immutable, content-addressed

> **Status: design + in-progress (2026-06-14).** Supersedes the interim
> "serve `text/html` inline, 302 everything else to presigned S3" behavior
> (commit `11afb3c`), whose inline path does a *blocking* `blobStore().get()`
> on the dispatch thread — the bug this design removes.

## Problem

Static assets were served by 302-redirecting to a **presigned** S3 URL. Two
faults:

1. **The redirect breaks top-level documents.** A 302 on a navigation moves
   the browser's origin to the S3 host, so an SPA's relative asset paths
   (`./app.js`), same-origin `fetch()`s, and reload-after-expiry all fail.
   (Fixed interim by serving `text/html` inline — but see fault 2.)
2. **Presigning defeats content-addressed caching.** The redirect target is
   `…/file-blobs/{hash}?X-Amz-Signature=…&X-Amz-Date=…` — the `{hash}` is
   immutable, but the signature is unique per request, so the browser's cache
   key (which includes the query) changes every time. Net: ~1 hour of caching
   (via the cached redirect), then a full re-download. The content-hash is
   wasted.

And the interim inline fix introduced a third fault: the worker now does a
**synchronous** S3 fetch on the dispatch thread to serve HTML, blocking handler
processing for the duration of the round-trip.

## Goals

- **Never block the dispatch loop.** All S3 reads happen off the request
  thread. The dispatch thread only ever touches memory or emits a redirect.
- **Immutable, content-addressed caching.** Assets served at stable
  `…/{hash}` URLs with `Cache-Control: immutable, max-age=1y` — permanent
  browser caching, automatic cache-bust on redeploy (new content → new hash →
  new URL), zero revalidation round-trips.
- **Stay private, free, no new infra.** No public bucket, no CDN dependency,
  no paid plan. Assets stay in the private `rewind-prod` bucket; the worker
  reads them. (A Cloudflare edge layer can be added later as pure upside,
  precisely because the URLs are already immutable — see §6.)

## Design

### 1. Immutable hashed asset URLs (`/_assets/{hash}`)

`/_assets/` is a reserved path prefix (`src/js/reserved.zig`). A request to
`/_assets/{hash}` serves the content-addressed blob `{hash}` for the
request's tenant (resolved from the Host, same as any tenant request), with
`Cache-Control: public, max-age=31536000, immutable`.

The browser reaches these URLs one of two ways:

- **(a) Worker 302 (no document changes).** A request for a stable static path
  (`/app.js` → `_static/app.js` in the manifest) is an in-memory lookup of the
  entry's hash; the worker `302`s to `/_assets/{hash}`. The 302 itself carries
  a *short, revalidated* `Cache-Control` (the mapping changes per deploy). One
  tiny redirect hop; the heavy bytes are then immutable. **This is what we ship
  first** — it needs no build step, which suits the hand-written SPAs.
- **(b) Publish-time ref rewriting (later optimization).** The publish step
  rewrites `./app.js` → `/_assets/{hash}` in the document, eliminating the 302
  hop entirely. Deferred (needs an HTML/CSS/JS reference rewriter).

### 2. Bounded in-memory LRU, keyed by hash

A process-wide, byte-capped LRU (`src/js/static_cache.zig`) holds static
bytes keyed by content hash. Content-addressing means entries are **immutable**
(no invalidation) and **dedupe** across tenants and deployments. Cap via
`REWIND_STATIC_CACHE_MB` (default 256). Shared by the loader thread (writes)
and worker threads (reads) under a mutex.

> **v1 simplicity:** the read path copies the bytes into the per-request
> allocator under the lock (the response then owns its copy, freed after send —
> no entry-lifetime/refcount machinery). The copy is memory-only (no I/O); the
> lock is held only for the lookup + copy. If contention shows under load, the
> follow-ups are sharding the lock and/or refcounted zero-copy entries with a
> release-on-response-completion deinit hook.

### 3. Prewarm at deploy time — on the loader thread

`reloadDeployment` (`src/js/deployment_cache.zig`, the loader thread, off the
dispatch loop) already walks the manifest to build the per-deployment
`TenantFilesSnapshot.statics` map. It additionally:

- builds a `statics_by_hash` index (hash → content_type) on the snapshot, used
  by the `/_assets/{hash}` serve path for O(1) content-type + legitimacy
  lookup; and
- **prewarms** each static blob's bytes into the LRU via the existing
  *synchronous* `slot.blob_backend.blobStore().get()` — here, on the loader
  thread, blocking is fine. Assets above a per-asset cap (e.g. 4 MB) are
  skipped (they fall back to the redirect path, §4).

So by the time a request arrives, the bytes are already in memory.

### 4. Serving — always non-blocking

`/_assets/{hash}` (resolved to the tenant via Host, snapshot pinned):

- **hash not in `statics_by_hash`** → 404 (bounds what can be served/fetched).
- **LRU hit** → serve inline, `immutable, max-age=1y`. Pure memory copy.
- **LRU miss** (evicted, oversized, cold tenant) → `302` to a presigned S3 URL
  (today's behavior — the browser fetches, the worker doesn't). Non-blocking;
  that one cold asset gets the weaker ~1h caching until it's prewarmed again.

Stable static paths (`/app.js`, `/`): `tryServeStatic` resolves the manifest
entry (in-memory) and:

- **non-HTML** → `302` to `/_assets/{hash}` (short revalidated cache on the
  302).
- **HTML documents** → served inline from the LRU (replacing the interim
  blocking `get()`), at the stable mutable path, with **ETag / revalidate**
  (the document changes per deploy and carries the fresh hashed refs). On LRU
  miss, the same non-blocking presigned-redirect fallback.

The dispatch thread therefore never issues a synchronous S3 read: hits are
memory, misses are redirects. Handler processing is never stalled.

### 5. What stays private

Only `kind=static` blobs are ever prewarmed/served this way. Handler
bytecode/source, logs, tapes, and request bodies stay in the private
`rewind-prod` bucket and never enter this path. There is no public bucket.

### 6. Cloudflare edge (optional, later)

Orange-clouding the tenant hosts lets CF edge-cache the immutable
`/_assets/{hash}` responses (and the short-cached 302s). Pure upside, no code
change — the immutability is already in the `Cache-Control`. Requires SSL mode
= Full (strict), which the fronts already satisfy. Not required for any of the
above.

## Rollout

1. `static_cache.zig` (the LRU) + unit tests.
2. Prewarm + `statics_by_hash` in `reloadDeployment` (loader thread).
3. `/_assets/{hash}` serve route; `/app.js` → 302; HTML inline from the LRU
   (remove the blocking `get()`).
4. Build + `v2-test` + `test`; deploy (rolling); verify immutable headers +
   non-blocking serve.
5. Later: publish-time ref rewriting (§1b); Cloudflare edge (§6).
