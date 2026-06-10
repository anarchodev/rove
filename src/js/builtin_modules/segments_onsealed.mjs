// `docs/blob-storage-plan.md` §6: segments.seal's on_result — the
// SWAP half of the seal. The shim serialized the hot rows and fired
// a durable blob.put; this module runs when that PUT settled and,
// only on success, performs the pointer swap in ONE atomic writeset:
//
//   - write the segment index row
//     `_seg/{stream}/s/{first_seq:020}` → {hash, first_seq, last_seq, count}
//   - delete the sealed hot rows `_seg/{stream}/h/{first..last}`
//
// Ordering is the design's crash-safety: the hot rows are released
// only after the segment blob — their sole home past tape retention —
// is confirmed durable. PUT failure ⇒ no swap (the `_blob/owed`
// marker stays as evidence); the next cron seal re-reads the same
// rows and retries idempotently (same bytes → same hash).
//
// Overlapping seals converge: same first_seq ⇒ the later index write
// wins and its blob contains a superset of the earlier one's rows;
// double deletes are no-ops.

const PAD = "00000000000000000000";

function pad(seq) {
    const d = String(seq);
    return PAD.slice(d.length) + d;
}

export default function () {
    const body = JSON.parse(request.body).ctx;
    const result = body.result || {};
    const c = body.context || {};
    if (!result.ok) {
        // Marker evidence persists per blob.put semantics; next seal
        // retries. Nothing to clean.
        return { status: 200 };
    }
    const stream = c.stream;
    const first = c.first_seq;
    const last = c.last_seq;
    if (typeof stream !== "string" || !Number.isInteger(first) || !Number.isInteger(last)) {
        return { status: 200 };
    }

    kv.set("_seg/" + stream + "/s/" + pad(first), JSON.stringify({
        hash: result.hash,
        first_seq: first,
        last_seq: last,
        count: c.count,
    }));
    for (let seq = first; seq <= last; seq++) {
        kv.delete("_seg/" + stream + "/h/" + pad(seq));
    }
    return { status: 200 };
}
