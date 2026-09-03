// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Public `after` surface — connection wake triggers (docs/handler-shape.md
// §2.3; decisions.md §4.11). Thin shim over the native
// `_system.after` binding.
//
// `after.*` registers a ONE-SHOT wake **for the current connection**: a
// held handler (one that returns `next()` / streams) is re-invoked when
// the wake fires — a duration elapses, a kv key under a watched prefix
// changes, or an outbound fetch produces a result — while it still
// holds the socket. Wakes are re-armed per activation (call `after.*`
// again to keep listening — the SSE loop shape). Ephemeral (dropped
// with the connection) and node-local (never replicated). On a
// connectionless activation (a `cron`/`schedule`/`webhook.send`
// callback) there is no connection, so `after.*` is inert.
//
// The callback-target option is `{on: "module.method"}` — the universal
// spelling across every effect.
//
// Evaluated as a global script (no module/exports) after the native
// bindings install. (The pre-rename `on.*` alias existed for one deploy
// cycle and closed 2026-07-06.)

(function () {
  const sys = _system.after;
  const sysHttp = _system.http;
  const sysHeld = _system.held;

  // The Fetch-API response handle (rove#930): wraps the raw settle value
  // — `{status, headers, complete, bytes?, truncated?}` — behind one
  // surface whether the engine buffered the body (content-length under
  // the chunk cap: `complete: true`, bytes in hand, accessors resolve as
  // microtasks) or settled at headers (`complete: false`, the body
  // arrives through chunk pulls). The body is SINGLE-READ (`text()`,
  // `bytes()`, or iterating `chunks` consumes it — the Fetch posture).
  // `text()`/`bytes()` REJECT when collection crosses the chunk cap
  // (`maxChunkBytes`) or the transfer was truncated at the total cap —
  // a loud error, never a flag to forget; iterate `chunks` for more.
  function makeFetchResponse(raw, fid, cap) {
    const complete = raw.complete === true;
    let served = false;
    const iter = {
      next() {
        if (complete) {
          if (served || raw.bytes === undefined || raw.bytes.length === 0) return Promise.resolve({ done: true });
          served = true;
          return Promise.resolve({ value: { bytes: raw.bytes, text: new TextDecoder().decode(raw.bytes) }, done: false });
        }
        return sysHeld.nextFetchChunk(fid);
      },
    };
    iter[Symbol.asyncIterator] = function () { return iter; };
    async function collect() {
      if (complete) {
        if (raw.truncated) throw new Error("after.fetch: response exceeded " + cap + " bytes — iterate r.chunks for a bounded read");
        return raw.bytes || new Uint8Array(0);
      }
      const parts = [];
      let total = 0;
      for (;;) {
        const step = await sysHeld.nextFetchChunk(fid);
        if (step.done) {
          if (step.truncated) throw new Error("after.fetch: response truncated at the total cap — iterate r.chunks for a bounded read");
          break;
        }
        total += step.value.bytes.length;
        if (total > cap) throw new Error("after.fetch: response exceeded " + cap + " bytes — iterate r.chunks for a bounded read");
        parts.push(step.value.bytes);
      }
      const out = new Uint8Array(total);
      let off = 0;
      for (const b of parts) { out.set(b, off); off += b.length; }
      return out;
    }
    return {
      status: raw.status,
      headers: raw.headers || {},
      chunks: iter,
      bytes: () => collect(),
      text: () => collect().then((u8) => new TextDecoder().decode(u8)),
    };
  }

// Fail-loud on retired option spellings (audit batch 3): silence would
// mean a silently-ignored option — worse than a break, pre-launch.
function _rejectRenamed(verb, opts, renames) {
  if (!opts || typeof opts !== "object") return;
  for (const k in renames) {
    if (k in opts) throw new TypeError(verb + ": option `" + k + "` was renamed — use `" + renames[k] + "`");
  }
}


  // The callback-target key is `on` at the native layer too — the bindings
  // read `opts.on` directly, so opts pass through with no respelling.

  /**
   * Connection wake triggers — re-invoke a held handler when something
   * happens, while it still holds the socket. Register them in the body
   * before returning `next()` (or while streaming). The runtime arms
   * every `after.*` wake before firing any connectionless effect of the
   * same activation, so a wake is never missed even when a callback
   * writes the key it watches.
   *
   * Wakes are one-shot and cannot be cancelled — they're ephemeral
   * and node-local, so an unwanted wake is simply ignored (or the
   * handler re-arms a different set). The exception is a fetch:
   * cancel an in-flight `after.fetch` by its returned id.
   *
   * @namespace after
   * @example
   * // SSE-style: stream rows, then wait for more under a prefix.
   * stream.start();
   * after.kv(`notif/${user}/`, { on: "onNotify" });
   * return next({ user });
   */
  globalThis.after = {
    /**
     * Wake the held connection after `ms` milliseconds. Named for its
     * unit — durations are milliseconds; there is deliberately no
     * `after.seconds` family (write `after.ms(5 * 60_000)`). Without
     * `on`, the wake lands in the `onWake` export.
     *
     * @param {number} ms - Delay in milliseconds (must be > 0).
     * @param {object} [opts]
     * @param {string} [opts.on] - Export to resume into
     *   (`"module.method"` or a bare `"method"`); defaults to `onWake`.
     * @returns {Promise<void>|undefined} On a held connection, a promise
     *   that settles when the timer fires — `await` it to continue in
     *   place instead of parking with `next()` and resuming in `onWake`.
     *   `undefined` where the connection cannot be held.
     * @example
     * after.ms(30_000, { on: "onTimeout" }); // deadline for a join
     * @example
     * export default async () => { await after.ms(500); return "later"; };
     */
    ms(ms, opts) {
      return sys.timer(ms, opts);
    },

    /**
     * Wake the held connection after any key under `prefix` changes —
     * anchored to the version this activation read, so a write between
     * "you read" and "you parked" still fires it. Without `on`, the
     * wake lands in the `onWake` export.
     *
     * @param {string} prefix - Tenant-scoped key prefix to watch.
     * @param {object} [opts]
     * @param {string} [opts.on] - Export to resume into; defaults to
     *   `onWake`.
     * @returns {Promise<{kind:string,prefix:string,firedAt:number}>|undefined}
     *   Without `on`, on a held connection: a promise that settles with
     *   the fired wake entry (the `wakes[]` shape) — `await` it to
     *   continue in place; the wake is an edge ("go look"), so re-read
     *   kv for the values. With `on`, or where the connection cannot be
     *   held: `undefined`, and the wake lands in the export.
     * @example
     * after.kv(`jobs/${id}/`, { on: "onJob" }); // export target
     * @example
     * export default async () => { await after.kv("rooms/1/"); return JSON.stringify(kv.prefix("rooms/1/")); };
     */
    kv(prefix, opts) {
      return sys.kv(prefix, opts);
    },

    /**
     * Perform an outbound HTTP request and wake the held connection on
     * its result. Connection-scoped: the result resumes THIS chain's
     * `{on}` export (defaults: `onFetchResult` for a non-streamed whole
     * body, `onFetchChunk`/`onFetchDone` for a streamed one) while it
     * still holds the socket; if the activation doesn't hold the socket
     * the fetch is inert (its durable twin is `webhook.send`). With
     * `opts.stream` each upstream writeback wakes the handler as it
     * arrives.
     *
     * @param {string} url - Upstream URL.
     * @param {object} [opts]
     * @param {string} [opts.method="GET"] - HTTP method.
     * @param {Object<string,string>} [opts.headers] - Request headers.
     * @param {string|Uint8Array} [opts.body] - Request body.
     * @param {boolean} [opts.stream=false] - false → one result event;
     *   true → one event per upstream chunk as it arrives.
     * @param {number} [opts.timeoutMs=30000] - Per-request timeout.
     * @param {number} [opts.maxChunkBytes=262144] - Per-chunk cap
     *   (streamed fetches).
     * @param {number} [opts.maxTotalBytes=52428800] - Cumulative
     *   response cap; exceeding sets `bodyTruncated`.
     * @param {*} [opts.ctx] - Threaded to each wake as `request.ctx`.
     * @param {string} [opts.on] - Export the result wakes; overrides the
     *   per-event-shape defaults for every event of this fetch.
     * @param {boolean} [opts.relay=false] - CAS→connection relay
     *   (platform-internal; today only the `__system/static` streamer's
     *   door engages it): intermediate chunks are spliced straight onto
     *   the held stream — `{on}` fires only for the first event and the
     *   terminal. Inert on any other fetch.
     * @returns {Promise<{status:number,headers:Object,chunks:AsyncIterable,text:function,bytes:function}>|string}
     *   Without `on`, on a held connection: a promise resolving with the
     *   RESPONSE HANDLE `r` — `r.status`/`r.headers` at settle (the
     *   engine settles at completion when the response declares
     *   `content-length` under the chunk cap, else at headers);
     *   `await r.text()` / `await r.bytes()` for the whole body (REJECTS
     *   past the cap — iterate for more); `for await (const c of
     *   r.chunks)` piecewise. The body is single-read. `status` alone is
     *   the success contract. The fetch id rides the promise as
     *   `.fetchId` (for `after.cancel`). With `on`, or where the
     *   connection cannot be held: the fetch id string (`ftch_…`,
     *   opaque — compare to `request.fetchId`).
     * @throws {Error} `code:"rate_limited"` when the per-tenant outbound
     *   rate limit is exhausted (shared with `webhook.send`/`email.send`).
     * @example
     * after.fetch('https://api.example.com/stream',
     *             { stream: true, on: 'onUpstream' });
     * return next();
     * @example
     * export default async () => { const res = await after.fetch("https://api.example.com/x"); return String(res.status); };
     */
    fetch(url, opts) {
      opts = opts || {};
      _rejectRenamed("after.fetch", opts, {
        timeout_ms: "timeoutMs",
        max_response_chunk_bytes: "maxChunkBytes",
        max_total_response_bytes: "maxTotalBytes",
        to: "on",
      });
      const native = {
        method: opts.method,
        headers: opts.headers,
        body: opts.body,
        stream: opts.stream,
        relay: opts.relay,
        ctx: opts.ctx,
      };
      if (typeof opts.on === "string") native.on = opts.on;
      if (opts.timeoutMs != null) native.timeout_ms = opts.timeoutMs;
      if (opts.maxChunkBytes != null) native.max_response_chunk_bytes = opts.maxChunkBytes;
      if (opts.maxTotalBytes != null) native.max_total_response_bytes = opts.maxTotalBytes;
      const p = sys.fetch(url, native);
      if (!(p instanceof Promise)) return p; // export flow: the fetch id
      const fid = p.fetchId;
      const cap = p.capBytes;
      const wrapped = p.then((raw) => makeFetchResponse(raw, fid, cap));
      wrapped.fetchId = fid; // for after.cancel
      return wrapped;
    },

    /**
     * Cancel an in-flight `after.fetch` by the id it returned (also on
     * `request.fetchId` in its wake events). No-op if it already
     * completed. Cooperative: a chunk already in flight at the engine
     * may still land after the cancel returns — track "we moved on" in
     * your chain ctx.
     *
     * @param {string} id - The `ftch_…` id.
     * @returns {void}
     * @example
     * const id = after.fetch("https://api.example.test/slow", { on: "onSlow" });
     * after.cancel(id); // changed our mind before it landed
     */
    cancel(id) {
      return sysHttp.cancelFetch({ id: id });
    },
  };
})();
