// RTAP (Rove Tape) wire-format parser + builder.
//
// Mirrors src/tape/root.zig in rove. Big-endian throughout.
// Header per tape:
//
//   [u32 magic 0x52544150 'RTAP']
//   [u16 version (= 1)]
//   [u16 channel]
//   [u32 entry_count]
//   for each entry: [u32 len][entry bytes]
//
// Per-channel entry encodings — see `Entry` union in root.zig for the
// authoritative definition. Anything that doesn't round-trip a Zig
// `Tape.serialize` -> JS `parseTapeBlob` cycle byte-for-byte is a bug
// here, not in rove.
//
// Lift target: this file is intended to move into rove's web/ tree
// once a shared location is needed by both the existing iframe
// replay (web/replay/app.js) and the new WASM-driven scrubber UI.
// Keeping it standalone here in the arenajs build dir lets us
// verify wire-format compatibility without a rove repo round-trip.

export const RTAP_MAGIC   = 0x52544150;
// Bumped 1 → 2 by `docs/primitive-gaps.md` §8 (minimal kv read
// set). Wire shape unchanged — semantic shift: kv channel records
// only foreign reads, replay maintains its own writeset overlay
// for kv.set / kv.delete. See src/tape/root.zig VERSION doc for
// the full rationale.
export const RTAP_VERSION = 2;

export const CHANNEL_KV            = 0;
export const CHANNEL_DATE          = 1;
export const CHANNEL_MATH_RANDOM   = 2;
export const CHANNEL_CRYPTO_RANDOM = 3;
export const CHANNEL_MODULE        = 4;

export const KV_OP_GET     = 0;
export const KV_OP_SET     = 1;
export const KV_OP_DELETE  = 2;
export const KV_OP_PREFIX  = 3;
export const KV_OUTCOME_OK        = 0;
export const KV_OUTCOME_NOT_FOUND = 1;
export const KV_OUTCOME_ERR       = 2;

const _decoder = new TextDecoder("utf-8", { fatal: false });
const _encoder = new TextEncoder();

// ── Parse ────────────────────────────────────────────────────────────

export function parseTapeBlob(bytes) {
    if (!(bytes instanceof Uint8Array))
        throw new Error("parseTapeBlob: expected Uint8Array");
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let off = 0;
    const magic   = view.getUint32(off); off += 4;
    if (magic !== RTAP_MAGIC) throw new Error("bad RTAP magic 0x" + magic.toString(16));
    const version = view.getUint16(off); off += 2;
    if (version !== RTAP_VERSION) throw new Error("unsupported RTAP version " + version);
    const channel = view.getUint16(off); off += 2;
    const count   = view.getUint32(off); off += 4;
    const entries = [];
    for (let i = 0; i < count; i++) {
        const elen = view.getUint32(off); off += 4;
        const ebytes = bytes.subarray(off, off + elen); off += elen;
        entries.push(decodeEntry(channel, ebytes));
    }
    return { channel, entries };
}

function decodeEntry(channel, bytes) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let off = 0;
    const readLenPrefixed = () => {
        const n = view.getUint32(off); off += 4;
        const slice = bytes.subarray(off, off + n); off += n;
        return slice;
    };
    const readUtf8 = () => _decoder.decode(readLenPrefixed());

    switch (channel) {
        case CHANNEL_KV: {
            const op = bytes[off++]; const outcome = bytes[off++];
            const key = readUtf8();
            if (op === KV_OP_PREFIX) {
                const cursor = readUtf8();
                const limit = view.getUint32(off); off += 4;
                const count = view.getUint32(off); off += 4;
                const results = [];
                for (let i = 0; i < count; i++) {
                    const k = readUtf8();
                    const v = readUtf8();
                    results.push({ key: k, value: v });
                }
                return { op, outcome, key, cursor, limit, results };
            }
            const value = readUtf8();
            return { op, outcome, key, value };
        }
        case CHANNEL_DATE:
            return { ms: Number(view.getBigInt64(off)) };
        case CHANNEL_MATH_RANDOM:
            return { value: view.getFloat64(off) };
        case CHANNEL_CRYPTO_RANDOM:
            return { bytes: new Uint8Array(readLenPrefixed()) };
        case CHANNEL_MODULE: {
            const specifier = readUtf8();
            const source_hash_hex = readUtf8();
            return { specifier, source_hash_hex };
        }
        default:
            throw new Error("unknown RTAP channel " + channel);
    }
}

// ── Build ────────────────────────────────────────────────────────────
// Helpers for synthesising tape blobs from in-memory entries — useful
// for tests and for any tool that wants to reconstruct a blob.

class Writer {
    constructor() { this.parts = []; this.length = 0; }
    u8(v)         { const a = new Uint8Array(1); a[0] = v;            this._push(a); }
    u16(v)        { const a = new Uint8Array(2); new DataView(a.buffer).setUint16(0, v);                                    this._push(a); }
    u32(v)        { const a = new Uint8Array(4); new DataView(a.buffer).setUint32(0, v);                                    this._push(a); }
    i64(v)        { const a = new Uint8Array(8); new DataView(a.buffer).setBigInt64(0, BigInt(v));                          this._push(a); }
    u64Bits(v)    { const a = new Uint8Array(8); new DataView(a.buffer).setBigUint64(0, BigInt.asUintN(64, BigInt(v)));    this._push(a); }
    f64(v)        { const a = new Uint8Array(8); new DataView(a.buffer).setFloat64(0, v);                                   this._push(a); }
    raw(bytes)    { this._push(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)); }
    str(s)        { const b = _encoder.encode(s); this.u32(b.length); this.raw(b); }
    bytes(b)      { this.u32(b.length); this.raw(b); }
    _push(a)      { this.parts.push(a); this.length += a.length; }
    finish() {
        const out = new Uint8Array(this.length);
        let off = 0;
        for (const p of this.parts) { out.set(p, off); off += p.length; }
        return out;
    }
}

function encodeEntry(channel, entry) {
    const w = new Writer();
    switch (channel) {
        case CHANNEL_KV: {
            w.u8(entry.op); w.u8(entry.outcome);
            w.str(entry.key);
            if (entry.op === KV_OP_PREFIX) {
                w.str(entry.cursor || "");
                w.u32(entry.limit | 0);
                w.u32((entry.results || []).length);
                for (const p of (entry.results || [])) {
                    w.str(p.key); w.str(p.value);
                }
            } else {
                w.str(entry.value || "");
            }
            break;
        }
        case CHANNEL_DATE:         w.i64(entry.ms); break;
        case CHANNEL_MATH_RANDOM:  w.f64(entry.value); break;
        case CHANNEL_CRYPTO_RANDOM: w.bytes(entry.bytes); break;
        case CHANNEL_MODULE:
            w.str(entry.specifier);
            w.str(entry.source_hash_hex);
            break;
        default:
            throw new Error("unknown channel " + channel);
    }
    return w.finish();
}

export function serializeTape(channel, entries) {
    const w = new Writer();
    w.u32(RTAP_MAGIC);
    w.u16(RTAP_VERSION);
    w.u16(channel);
    w.u32(entries.length);
    for (const e of entries) {
        const eb = encodeEntry(channel, e);
        w.u32(eb.length);
        w.raw(eb);
    }
    return w.finish();
}

// ── Bridge: parsed blobs → Module.tapes shape ────────────────────────
//
// The WASM-side bindings consume Module.tapes with one array per
// channel name (kv, date, math_random, crypto_random, module).
// Each array entry has the shape decodeEntry returns. Cursors are
// added lazily by the EM_JS host imports on first access.

export function buildTapesFromBlobs(blobs) {
    const out = {};
    const map = {
        kv: CHANNEL_KV,
        date: CHANNEL_DATE,
        math_random: CHANNEL_MATH_RANDOM,
        crypto_random: CHANNEL_CRYPTO_RANDOM,
        module: CHANNEL_MODULE,
    };
    for (const name of Object.keys(map)) {
        const blob = blobs[name];
        if (!blob) { out[name] = []; continue; }
        const { channel, entries } = parseTapeBlob(blob);
        if (channel !== map[name]) {
            throw new Error(`RTAP channel ${channel} on '${name}' blob (expected ${map[name]})`);
        }
        out[name] = entries;
    }
    return out;
}
