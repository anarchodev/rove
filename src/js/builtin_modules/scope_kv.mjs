// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Scoped kv, as an activation in the TARGET tenant's own scope. The admin
// dashboard's cross-tenant kv (deployment history, kv browse, export
// status) used to be synchronous `platform.scope(t).kv.*` natives — reads
// put one tenant's data in another's tape, and writes rode the ADMIN's
// raft log into the target's store, leaving the target's replicas ordered
// by two independent logs. Dispatching THIS module against the target
// instead makes the op an ordinary activation in the target's log: the
// target's own record carries its reads, its writes take a position in its
// own log, and the engine hands the terminal body back on the dispatch
// result (`_dispatch/result/{id}` in the caller's store — data with a
// request-body's trust posture).
//
// The keyspace is the NAMED view — the question a scoped read answers is
// "what does a handler of this tenant see at K", so keys resolve the way
// that handler's own kv does: under the user root, except the rows the
// ENGINE writes below any binding (`_deploy/current`, `_release/{ts}`),
// which never carried a root and read raw. The boundary is WHO WROTE the
// row, not what it is named — `_export/` rows come from `@rewind/export`
// through the handler's kv, so they sit under the user root like
// everything else the tenant owns. This mapping is the successor of the
// scoped door's (`globals_platform.zig`, `SCOPE_RAW_PREFIXES`): when the
// door goes, this module is the one place the rule lives.
//
// The payload rides the dispatch ctx; the reply is this module's terminal
// body, capped by the engine's carry limit — a caller that needs more
// paginates with `after`.

// The response HEAD is the ambient `response` global — a returned object
// is a BODY, not a head (`handler-shape.md` §3).
function answer(status, body) {
    response.status = status;
    return body;
}

const USER_ROOT = "_user/";
const RAW_PREFIXES = ["_deploy/", "_release/"];

function isRaw(named) {
    return RAW_PREFIXES.some(function (p) { return named.indexOf(p) === 0; });
}
// A key the caller NAMED, as this tenant's store holds it.
function storeKey(named) {
    return isRaw(named) ? named : USER_ROOT + named;
}
// The inverse, for row keys coming back off a scan — so a key this module
// hands out is a key it accepts.
function namedKey(stored) {
    return stored.indexOf(USER_ROOT) === 0 ? stored.slice(USER_ROOT.length) : stored;
}

// Rows per prefix page. Bounds the terminal body against the engine's
// carry cap — a page of maximal rows must still fit, so callers page
// rather than losing a tail to `overflow`.
const MAX_PREFIX_LIMIT = 500;

export default function ({ __system }) {
    const msg = request.ctx || {};
    const gets = Array.isArray(msg.gets) ? msg.gets : [];
    const prefixes = Array.isArray(msg.prefixes) ? msg.prefixes : [];
    const pairs = Array.isArray(msg.pairs) ? msg.pairs : [];
    const deletes = Array.isArray(msg.deletes) ? msg.deletes : [];

    // Validate the WHOLE ask before reading any of it — a refused op is a
    // completed activation (the marker resolves with this status), not a
    // retry.
    for (const k of gets) {
        if (typeof k !== "string" || k.length === 0) {
            return answer(400, JSON.stringify({ error: "each get needs a string key" }));
        }
    }
    for (const p of prefixes) {
        if (!p || typeof p.prefix !== "string" ||
            (p.after !== undefined && typeof p.after !== "string") ||
            (p.limit !== undefined && (typeof p.limit !== "number" ||
                p.limit < 1 || p.limit > MAX_PREFIX_LIMIT))) {
            return answer(400, JSON.stringify({ error: "each prefix needs {prefix, after?, limit? <= " + MAX_PREFIX_LIMIT + "}" }));
        }
    }

    // Writes are NAMED-view only: the raw carve-outs are rows the ENGINE
    // writes through dedicated verbs (the release flip owns
    // `_deploy/current`), so a write that names one is refused rather than
    // silently landing beside the engine's own writer.
    for (const w of pairs) {
        if (!w || typeof w.key !== "string" || w.key.length === 0 ||
            typeof w.value !== "string" || isRaw(w.key)) {
            return answer(400, JSON.stringify({ error: "each pair needs a named string key (raw engine rows are refused) and string value" }));
        }
    }
    for (const k of deletes) {
        if (typeof k !== "string" || k.length === 0 || isRaw(k)) {
            return answer(400, JSON.stringify({ error: "each delete needs a named string key (raw engine rows are refused)" }));
        }
    }

    const values = {};
    for (const k of gets) values[k] = __system.rootKv.get(storeKey(k));
    const pages = prefixes.map(function (p) {
        const rows = __system.rootKv.prefix(
            storeKey(p.prefix), p.after ? storeKey(p.after) : "", p.limit || 100);
        return rows.map(function (r) {
            return { key: namedKey(r.key), value: r.value };
        });
    });
    for (const w of pairs) __system.rootKv.set(storeKey(w.key), w.value);
    for (const k of deletes) __system.rootKv.delete(storeKey(k));
    return answer(200, JSON.stringify({ values: values, pages: pages }));
}
