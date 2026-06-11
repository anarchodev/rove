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
// Key layout (per stream; `_seg/` is shim-managed but NOT platform-
// reserved — same `_send/`/`_blob/` rule, the shim writes via
// ordinary customer kv.set):
//
//   _seg/{stream}/n             → next seq (string int)
//   _seg/{stream}/h/{seq:020}   → hot record value (string)
//   _seg/{stream}/s/{first:020} → segment index row
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
const STREAM_RE = /^[A-Za-z0-9_-]{1,64}$/;
const PAD = "00000000000000000000";

function pad(seq) {
  const d = String(seq);
  return PAD.slice(d.length) + d;
}

function assertStream(stream, verb) {
  if (typeof stream !== "string" || !STREAM_RE.test(stream))
    throw new TypeError(verb + ": stream must match [A-Za-z0-9_-]{1,64}");
}

/**
 * Sealed-segment append log: hot kv tail + content-addressed history.
 *
 * The canonical recipe for event-sourced state (timelines, event
 * logs, audit trails): `append` is a kv write riding your handler's
 * writeset; a cron-driven `seal` compacts old rows into blob storage
 * so the kv footprint stays bounded by the working set.
 *
 * @namespace segments
 */
globalThis.segments = {
  /**
   * Append one record to a stream's hot tail. An ordinary kv write —
   * atomic with the rest of this activation's writeset, read-your-
   * writes within it.
   *
   * @param {string} stream - Stream id (`[A-Za-z0-9_-]{1,64}`).
   * @param {string} value - The record. Non-strings are rejected —
   *   serialize yourself (`JSON.stringify`) so reads are symmetric.
   * @returns {number} The record's sequence number (0-based,
   *   monotonic per stream).
   *
   * @example
   * const seq = segments.append(`room-${id}`, JSON.stringify(event));
   * kv.set(`latest/${id}`, String(seq));
   */
  append(stream, value) {
    assertStream(stream, "segments.append");
    if (typeof value !== "string")
      throw new TypeError("segments.append: value must be a string");
    const seq = Number(kv.get(NEXT(stream)) ?? "0");
    kv.set(HOT(stream) + pad(seq), value);
    kv.set(NEXT(stream), String(seq + 1));
    return seq;
  },

  /**
   * Read one record. Hot records return synchronously; sealed
   * records need a blob fetch, so the result resumes THIS held
   * connection at `opts.to` — use {@link segments.slice} there to
   * extract the record from the segment.
   *
   * @param {string} stream - Stream id.
   * @param {number} seq - Sequence number.
   * @param {object} [opts]
   * @param {string} [opts.to] - Export resumed with the segment for
   *   a sealed read. Required when the record may be sealed.
   * @returns {string|null|undefined} The value (hot), `null` (no
   *   such record), or `undefined` (sealed — the fetch is in flight,
   *   return `next()` and finish in `opts.to`).
   *
   * @example
   * export default function () {
   *   const v = segments.get("room-7", 42, { to: "onSeg" });
   *   if (typeof v === "string") return v;          // hot
   *   if (v === null) { response.status = 404; return "gone"; }
   *   return next();                                 // sealed
   * }
   * export function onSeg() {
   *   if (!request.done) return next();
   *   return segments.slice(request);
   * }
   */
  get(stream, seq, opts) {
    assertStream(stream, "segments.get");
    opts = opts || {};
    if (!Number.isInteger(seq) || seq < 0)
      throw new TypeError("segments.get: seq must be a non-negative integer");
    const hot = kv.get(HOT(stream) + pad(seq));
    if (hot !== null && hot !== undefined) return hot;

    // Sealed? Find the segment whose [first, last] covers seq.
    // O(index rows) prefix scan — fine into the thousands of
    // segments; fork the recipe with a cursor-seek if a stream
    // outgrows that.
    const rows = kv.prefix(IDX(stream), null, 4096);
    for (const row of rows) {
      const idx = JSON.parse(row.value);
      if (seq >= idx.first_seq && seq <= idx.last_seq) {
        if (typeof opts.to !== "string")
          throw new TypeError("segments.get: record is sealed — pass { to } and finish in that export");
        blob.get(idx.hash, {
          to: opts.to,
          ctx: { stream: stream, seq: seq, idx: seq - idx.first_seq },
        });
        return undefined;
      }
    }
    return null;
  },

  /**
   * Extract the requested record from a sealed-segment fetch resume.
   * Call from the `to` export `segments.get` routed to, after
   * `request.done`.
   *
   * @param {object} req - The `request` global of the resume.
   * @returns {string} The record value.
   */
  slice(req) {
    if (!req || !req.ctx || typeof req.ctx.idx !== "number")
      throw new TypeError("segments.slice: not a segments.get resume");
    const seg = JSON.parse(new TextDecoder().decode(req.body));
    const v = seg.values[req.ctx.idx];
    if (v === undefined)
      throw new RangeError("segments.slice: segment does not contain seq " + req.ctx.seq);
    return v;
  },

  /**
   * Seal the oldest hot records into one content-addressed segment.
   * Call from a cron target per stream (the cadence IS your kv-cap ↔
   * object-storage trade-off knob). The call only serializes + fires
   * the durable PUT; the swap — index row written, hot rows deleted,
   * one atomic writeset — runs in `__system/segments_onsealed`
   * strictly after storage confirmed the bytes, so a crash anywhere
   * leaves the log readable and the next seal retries idempotently.
   *
   * @param {string} stream - Stream id.
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
  seal(stream, opts) {
    assertStream(stream, "segments.seal");
    opts = opts || {};
    const min = opts.min != null ? opts.min : 64;
    const max = opts.max != null ? opts.max : 1024;
    const rows = kv.prefix(HOT(stream), null, max);
    if (rows.length < Math.max(min, 1)) return 0;

    const hot_prefix_len = HOT(stream).length;
    const first_seq = Number(rows[0].key.slice(hot_prefix_len));
    const last_seq = Number(rows[rows.length - 1].key.slice(hot_prefix_len));
    const values = rows.map((r) => r.value);

    const payload = JSON.stringify({
      v: 1,
      stream: stream,
      first_seq: first_seq,
      values: values,
    });
    blob.put(payload, {
      content_type: "application/json",
      on_result: "__system/segments_onsealed",
      context: {
        stream: stream,
        first_seq: first_seq,
        last_seq: last_seq,
        count: rows.length,
      },
    });
    return rows.length;
  },
};

})();
