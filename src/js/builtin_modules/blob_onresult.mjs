// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// `docs/architecture/routing-and-ingress.md`: blob.put's on_chunk handler. The
// shim wrote a durable `_blob/owed/{hash}` marker (riding the
// handler's writeset, envelope-0 atomic) and fired the signed PUT
// through the fetch engine's rove-blob.internal door; this module
// receives the PUT's terminal event and settles the marker:
//
//   - success (2xx): kv.delete the marker — the object is durable
//     at its content-addressed key.
//   - failure: keep the marker as durable evidence, stamped
//     `failed: true` + the status. NO re-fire from here — the
//     marker deliberately carries no bytes (effect-algebra §2.5:
//     the bytes are re-derivable from the source activation), so
//     P1 cannot retry; re-execution recovery is post-P1. A re-put
//     of the same bytes is always safe (same hash, idempotent).
//
// Then hands off to the customer's on_result module (if registered)
// via __rove_next, mirroring __system/webhook_onresult.

// `_blob/owed/{hash}` marker version (`format-versioning.md` §1f).
const BLOB_OWED_V = __rove.formats.blobOwed;

export default function () {
    const a = request.activation;
    if (a.kind !== "fetch_chunk" && a.kind !== "send_callback") {
        return { status: 200 };
    }
    if (a.kind === "fetch_chunk" && !a.final) return { status: 200 };

    const ctx = request.ctx || {};
    const hash = ctx.hash;
    const on_result = ctx.on_result || null;
    const context = ctx.context !== undefined ? ctx.context : null;

    const key = "_blob/owed/" + hash;
    const owed_raw = kv.get(key);
    if (owed_raw == null) {
        // Duplicate fire (marker already settled) — no-op.
        return { status: 200 };
    }
    const owed = JSON.parse(owed_raw);
    // `_blob/owed/{hash}` record version (`format-versioning.md` §1f).
    // Loud, matching the unguarded parse above: the failure path
    // ROUND-TRIPS this marker, so continuing past a version this build
    // does not implement would rewrite it in the old shape and discard
    // whatever the new one carried.
    if (owed.v !== BLOB_OWED_V) {
        throw new Error("blob_onresult: _blob/owed/" + hash + " is v" + owed.v + ", this build writes v" + BLOB_OWED_V);
    }

    const status = (a.kind === "fetch_chunk") ? a.status : 0;
    // Success is a 2xx PUT. `status === 0` is a hard transport failure
    // (no HTTP response) — also not-ok. `status` is the single truth;
    // there is no `request.ok`.
    const ok = status >= 200 && status < 300;

    if (ok) {
        kv.delete(key);
    } else {
        owed.failed = true;
        owed.last_status = status;
        owed.failed_at_ns = String(BigInt(Date.now()) * 1_000_000n);
        kv.set(key, JSON.stringify(owed));
    }

    if (on_result) {
        // body_b64: the PUT response bytes (previously dropped — the
        // blob.put on_result surface carried no body at all;
        // decisions.md §4.11). Cross-module continuation via
        // the widened public `next(target, ctx)` (no bare `__rove_next`).
        return next(on_result, {
            result: {
                hash: hash,
                ok: ok,
                status: status,
                body_b64: (a.kind === "fetch_chunk") ? base64url.encode(a.bytes) : "",
            },
            context: context,
        });
    }
    return { status: 200 };
}
