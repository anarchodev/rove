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
// "what does a handler of this tenant see at K", so EVERY key a caller
// names resolves the way that handler's own kv does: under the user root,
// with no exceptions and no prefix that means something else.
//
// The engine's own rows (`_deploy/current`, `_release/{ts}`) are written
// below any binding and carry no root, so they are NOT reachable by
// naming them. They are reached through the typed `release` request
// below — the caller asks for the release STATE, never for a key. That
// is the difference between a facet and an escape (rove#850): a
// spelling-based carve-out is available to whoever spells it and has to
// be kept in sync with whatever the engine writes raw, while a verb
// exposes exactly one answer and cannot be widened by a caller's string.
// The boundary is WHO WROTE the row, and the shape of the request is
// what encodes it — `_export/` rows come from `@rewind/export` through
// the handler's kv, so they sit under the user root like everything else
// the tenant owns, and they are read by naming them like everything else.
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

// A key the caller NAMED, as this tenant's store holds it. Every key,
// unconditionally — the rooting does not consult the spelling, so there is
// no string a caller can send that reaches outside the tenant's own rows.
function storeKey(named) {
    return USER_ROOT + named;
}

// The engine's release rows, which carry no root. Read through the typed
// request only (see the header), never by a caller naming the key.
const RELEASE_PTR = "_deploy/current";
const RELEASE_LOG = "_release/";
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

    // Writes need no engine-row refusal any more: a named write roots like
    // every other, so `_deploy/current` written here is the tenant's own
    // `_user/_deploy/current` row and cannot land beside the engine's
    // writer. The rule that used to need enforcing is now unreachable.
    for (const w of pairs) {
        if (!w || typeof w.key !== "string" || w.key.length === 0 ||
            typeof w.value !== "string") {
            return answer(400, JSON.stringify({ error: "each pair needs a string key and string value" }));
        }
    }
    for (const k of deletes) {
        if (typeof k !== "string" || k.length === 0) {
            return answer(400, JSON.stringify({ error: "each delete needs a string key" }));
        }
    }

    // The typed release read (rove#850): the caller asks for the release
    // state, and this is the only path to the engine's unrooted rows.
    // `history` is capped like a prefix page; the keys are timestamps, so
    // the caller gets values rather than a keyspace to walk.
    let release = null;
    if (msg.release) {
        const cur = __system.rootKv.get(RELEASE_PTR);
        const rows = __system.rootKv.prefix(RELEASE_LOG, "", MAX_PREFIX_LIMIT);
        release = {
            dep_id: cur,
            // `ts` is the row's STORED suffix, not a parsed number: the
            // key spelling is itself the thing worth seeing (a release ts
            // once shipped with a `+` sign from a signed format, which
            // sorts wrong and silently reorders history). Consumers parse;
            // one representation on the wire, and the one that can carry
            // the defect.
            history: rows.map(function (r) {
                return { ts: r.key.slice(RELEASE_LOG.length), value: r.value };
            }),
        };
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
    return answer(200, JSON.stringify({ values: values, pages: pages, release: release }));
}
