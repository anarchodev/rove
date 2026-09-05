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

    for (const p of pairs) __system.rootKv.set(p.key, p.value);
    for (const k of deletes) __system.rootKv.delete(k);
    return answer(200, "");
}
