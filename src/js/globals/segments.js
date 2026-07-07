// segments.* — sealed-segment append log (blob-storage-plan §6; `docs/architecture/routing-and-ingress.md`).
//
// The universal log-structured storage move, shipped as a readable,
// forkable stdlib recipe (rule 4: durability compositions are visible
// JavaScript): a small HOT TAIL of recent records lives as kv rows —
// addressable, transactional, counted against the kv cap — and a cron
//-driven `seal` periodically freezes a run of them into ONE immutable
// content-addressed blob, swapping in a kv pointer. kv usage plateaus
// at the working set; history grows in cheap object storage. The seal
// cadence is the knob trading kv-cap consumption against byte-ring
// consumption.
//
// Key layout (per log; `_seg/` is shim-managed but NOT platform-
// reserved — same `_send/`/`_blob/` rule, the shim writes via
// ordinary customer kv.set):
//
//   _seg/{log}/n             → next seq (string int)
//   _seg/{log}/h/{seq:020}   → hot record value (string)
//   _seg/{log}/s/{first:020} → segment index row
//                                 {hash, first_seq, last_seq, count}
//
// Crash safety — the design's load-bearing joint: a sealed segment is
// DURABLE-CLASS (once the hot rows are deleted it is the sole copy
// past tape retention), so the swap (index write + hot deletes, one
// atomic writeset) runs in `__system/segments_onsealed` — the
// blob.put on_result — strictly AFTER the PUT confirmed. A crash
// before the swap leaves the hot rows intact and the next seal
// retries; content addressing makes every retry idempotent (same
// rows → same bytes → same hash). Two overlapping seals converge:
// same first_seq → last index write wins, and the winning blob
// contains a superset of the loser's rows.

(() => {

const HOT = (s) => "_seg/" + s + "/h/";
const IDX = (s) => "_seg/" + s + "/s/";
const NEXT = (s) => "_seg/" + s + "/n";
const LOG_RE = /^[A-Za-z0-9_-]{1,64}$/;
const PAD = "00000000000000000000";

function pad(seq) {
  const d = String(seq);
  return PAD.slice(d.length) + d;
}

function assertLog(log, verb) {
  if (typeof log !== "string" || !LOG_RE.test(log))
    throw new TypeError(verb + ": log must match [A-Za-z0-9_-]{1,64}");
}

/**
 * Sealed-segment append log: hot kv tail + content-addressed history.
 *
 * The canonical recipe for event-sourced state (timelines, event
 * logs, audit trails): `append` is a kv write riding your handler's
 * writeset; a cron-driven `seal` compacts old rows into blob storage
 * so the kv footprint stays bounded by the working set.
 *
 * "Seal" here is the same metaphor as `blob.seal`: freeze bytes into
 * an immutable, content-addressed blob — there it seals an upload,
 * here it seals a log tail. Not related to `stream.*` (connection
 * output): a segments log is named state, not a socket.
 *
 * A log id is a name YOU choose, exactly like a kv key — there is no
 * allocation step; the log exists once something has been appended to
 * it. Enumerate existing logs with `segments.logs()`.
 *
 * @namespace segments
 */
globalThis.segments = {
  /**
   * Append one record to a log's hot tail. An ordinary kv write —
   * atomic with the rest of this activation's writeset, read-your-
   * writes within it.
   *
   * @param {string} log - Log id (`[A-Za-z0-9_-]{1,64}`).
   * @param {string} value - The record. Non-strings are rejected —
   *   serialize yourself (`JSON.stringify`) so reads are symmetric.
   * @returns {number} The record's sequence number (0-based,
   *   monotonic per log).
   *
   * @example
   * const seq = segments.append(`room-${id}`, JSON.stringify(event));
   * kv.set(`latest/${id}`, String(seq));
   */
  /**
   * List the log ids that currently exist (kv-visible: hot rows,
   * sealed-segment index rows, or a seq counter). Paged: pass the
   * returned `cursor` back to continue; `cursor: null` means done.
   * Ids come back in byte order. Cost is one point read per id per
   * page — a seek-scan over the `_seg/` key space, not a full scan.
   *
   * @param {string} [cursor] - Opaque resume cursor from a prior call.
   * @param {number} [limit] - Max ids per page (default 20, cap 200).
   * @returns {{logs: string[], cursor: (string|null)}}
   *
   * @example
   * segments.append("inbox", "a");
   * segments.append("audit-2026", "b");
   * const page = segments.logs();
   * // page.logs → ["audit-2026", "inbox"], page.cursor → null
   * if (page.logs.indexOf("inbox") < 0) throw new Error("missing log");
   */
  logs(cursor, limit) {
    limit = Math.min(Math.max(Number(limit) || 20, 1), 200);
    const P = "_seg/";
    const out = [];
    let cur = typeof cursor === "string" && cursor ? cursor : null;
    while (out.length < limit) {
      const page = kv.prefix(P, cur, 1);
      if (!page.length) {
        cur = null;
        break;
      }
      const rest = page[0].key.slice(P.length);
      const slash = rest.indexOf("/");
      if (slash < 0) {
        cur = page[0].key; // stray non-log key under _seg/ — step past it
        continue;
      }
      const log = rest.slice(0, slash);
      out.push(log);
      // Seek past every key of this log: '0' is the first id character
      // above '/' in byte order, so `_seg/<log>0` sorts after all
      // `_seg/<log>/...` rows and before every other id's rows.
      cur = P + log + "0";
    }
    return { logs: out, cursor: cur };
  },

  append(log, value) {
    assertLog(log, "segments.append");
    if (typeof value !== "string")
      throw new TypeError("segments.append: value must be a string");
    const seq = Number(kv.get(NEXT(log)) ?? "0");
    kv.set(HOT(log) + pad(seq), value);
    kv.set(NEXT(log), String(seq + 1));
    return seq;
  },

  /**
   * Read one record. Hot records return synchronously; sealed
   * records need a blob fetch, so the result resumes THIS held
   * connection at the `{on}` export — call {@link segments.record}
   * there to unpack your record from the fetched segment.
   *
   * @param {string} log - Log id.
   * @param {number} seq - Sequence number.
   * @param {object} [opts]
   * @param {string} [opts.on] - Export resumed with the segment for
   *   a sealed read. Required when the record may be sealed.
   * @returns {string|null|undefined} The value (hot), `null` (no
   *   such record), or `undefined` (sealed — the fetch is in flight,
   *   return `next()` and finish in the `{on}` export).
   *
   * @example
   * export default function () {
   *   const v = segments.get("room-7", 42, { on: "onSeg" });
   *   if (typeof v === "string") return v;          // hot
   *   if (v === null) { response.status = 404; return "gone"; }
   *   return next();                                 // sealed
   * }
   * export function onSeg() {
   *   if (!request.done) return next();
   *   return segments.record();
   * }
   */
  get(log, seq, opts) {
    assertLog(log, "segments.get");
    opts = opts || {};
    const on_key = typeof opts.on === "string" ? opts.on : undefined;
    if (!Number.isInteger(seq) || seq < 0)
      throw new TypeError("segments.get: seq must be a non-negative integer");
    const hot = kv.get(HOT(log) + pad(seq));
    if (hot !== null && hot !== undefined) return hot;

    // Sealed? Find the segment whose [first, last] covers seq.
    // O(index rows) prefix scan — fine into the thousands of
    // segments; fork the recipe with a cursor-seek if a log
    // outgrows that.
    const rows = kv.prefix(IDX(log), null, 4096);
    for (const row of rows) {
      const idx = JSON.parse(row.value);
      if (seq >= idx.first_seq && seq <= idx.last_seq) {
        if (typeof on_key !== "string")
          throw new TypeError("segments.get: record is sealed — pass { on } and finish in that export");
        blob.get(idx.hash, {
          on: on_key,
          ctx: { log: log, seq: seq, idx: seq - idx.first_seq },
        });
        return undefined;
      }
    }
    return null;
  },

  /**
   * Unpack the requested record from a sealed-segment fetch resume —
   * the completion half of {@link segments.get}. Call from the `{on}`
   * export the get routed to, after `request.done`; reads the ambient
   * `request` itself (no arguments).
   * @returns {string} The record value.
   */
  record() {
    const req = globalThis.request;
    if (!req || !req.ctx || typeof req.ctx.idx !== "number")
      throw new TypeError("segments.record: not a segments.get resume");
    const seg = req.json;
    const v = seg.values[req.ctx.idx];
    if (v === undefined)
      throw new RangeError("segments.record: segment does not contain seq " + req.ctx.seq);
    return v;
  },

  /**
   * Seal the oldest hot records into one content-addressed segment.
   * Call from a cron target per log (the cadence IS your kv-cap ↔
   * object-storage trade-off knob). The call only serializes + fires
   * the durable PUT; the swap — index row written, hot rows deleted,
   * one atomic writeset — runs in `__system/segments_onsealed`
   * strictly after storage confirmed the bytes, so a crash anywhere
   * leaves the log readable and the next seal retries idempotently.
   *
   * @param {string} log - Log id.
   * @param {object} [opts]
   * @param {number} [opts.min=64] - Skip the seal entirely when
   *   fewer hot rows than this (avoids confetti segments).
   * @param {number} [opts.max=1024] - Seal at most this many rows
   *   per call (bounds the segment blob and this activation's work).
   * @returns {number} Rows being sealed (0 = below `min`, no-op).
   *
   * @example
   * // cron("*\/5 * * * *", "sealRooms") in your module:
   * export function sealRooms() {
   *   for (const s of JSON.parse(kv.get("rooms") ?? "[]"))
   *     segments.seal(`room-${s}`);
   * }
   */
  seal(log, opts) {
    assertLog(log, "segments.seal");
    opts = opts || {};
    const min = opts.min != null ? opts.min : 64;
    const max = opts.max != null ? opts.max : 1024;
    const rows = kv.prefix(HOT(log), null, max);
    if (rows.length < Math.max(min, 1)) return 0;

    const hot_prefix_len = HOT(log).length;
    const first_seq = Number(rows[0].key.slice(hot_prefix_len));
    const last_seq = Number(rows[rows.length - 1].key.slice(hot_prefix_len));
    const values = rows.map((r) => r.value);

    const payload = JSON.stringify({
      v: 1,
      log: log,
      first_seq: first_seq,
      values: values,
    });
    blob.put(payload, {
      contentType: "application/json",
      on: "__system/segments_onsealed",
      ctx: {
        log: log,
        first_seq: first_seq,
        last_seq: last_seq,
        count: rows.length,
      },
    });
    return rows.length;
  },
};

})();
