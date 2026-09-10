// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Root-scope kv writes, as an activation in `__root__`'s own scope. Cluster
// routing state (`instance/{id}`, `domain/{host}`) is ordinary kv in the
// root group's own log: an admin caller DISPATCHES this module against
// `__root__` (`platform.dispatch` — owed marker, watchdog, engine-sent
// resolution), so the write takes a position in the root log, leaves a
// record there, and the caller resumes on the marker's resolution in its
// own store. One primitive, no special-cased envelope.
//
// The payload rides the dispatch ctx (`request.ctx`), never the body — a
// platform_dispatch activation's body is the synthesized ctx envelope.
// Writes go through `__system.rootKv` (rove#848): `instance/{id}` and
// `domain/{host}` are storage as it lies; every reader (host resolution,
// the tenant registry, the dashboard's own root.get) reads them raw.

// The response HEAD is the ambient `response` global — a returned object
// is a BODY, not a head (`handler-shape.md` §3).
function answer(status, body) {
    response.status = status;
    return body;
}

export default function ({ __system }) {
    const msg = request.ctx || {};
    const pairs = Array.isArray(msg.pairs) ? msg.pairs : [];
    const deletes = Array.isArray(msg.deletes) ? msg.deletes : [];
    const requires = Array.isArray(msg.requires) ? msg.requires : [];
    if (pairs.length === 0 && deletes.length === 0) return answer(200, "");

    // Validate the WHOLE batch before writing any of it — the writeset
    // would roll back on a throw anyway, but refusing without touching the
    // store is the clearer contract, and the dispatcher's marker still
    // resolves (a refused op is a completed activation, not a retry).
    for (const p of pairs) {
        if (!p || typeof p.key !== "string" || p.key.length === 0 ||
            typeof p.value !== "string") {
            return answer(400, "each pair needs string key and value\n");
        }
    }
    for (const k of deletes) {
        if (typeof k !== "string" || k.length === 0) {
            return answer(400, "each delete needs a string key\n");
        }
    }

    // Preconditions, checked HERE so the check and the write are one
    // activation in the root store's own log (rove#852). The caller used to
    // read the root store first and write second — two activations with a
    // window between them, in which the row it checked could be deleted by
    // whatever it was guarding against. A `requires` list closes that by
    // construction: if a required key is absent, nothing is written.
    for (const k of requires) {
        if (typeof k !== "string" || k.length === 0) {
            return answer(400, "each require needs a string key\n");
        }
        if (__system.rootKv.get(k) === null) {
            return answer(409, JSON.stringify({ error: "precondition failed", missing: k }));
        }
    }

    for (const p of pairs) __system.rootKv.set(p.key, p.value);
    for (const k of deletes) __system.rootKv.delete(k);

    // Report what landed, so the caller confirms from THIS activation
    // rather than reading the root store back afterwards (rove#852).
    //
    // Seeing this body already proves the write committed: the result row
    // and the owed-marker delete ride the same writeset as the writes
    // above, so a caller that can read the result is a caller whose write
    // reached quorum. A follow-up read would prove the same thing later,
    // through a second dispatch, with a window in between — strictly more
    // machinery for strictly less certainty about WHICH write it saw.
    return answer(200, JSON.stringify({
        wrote: pairs.map(function (p) { return p.key; }),
        deleted: deletes,
    }));
}
