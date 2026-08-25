// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Bootstrap kv seeding for `__admin__`, written by `__admin__` in its own
// scope (rove#691 / rove#717).
//
// Before this, `/_system/admin-kv` was a door: it opened a `TrackedTxn` on
// `__admin__`'s store from whichever worker accepted the request, built a
// writeset by hand, proposed it, and parked on the commit. The order was
// right — it proposed into `__admin__`'s own group — but nothing in the
// tenant's log said anything had changed it, which is the account the log is
// supposed to be.
//
// Now the route authenticates the operator and resolves to an ordinary
// activation running this module. The writeset, the propose, the park, the
// record and the tape are all the ordinary path's.
//
// It runs at BOOTSTRAP, when `__admin__` may have no deployment at all — the
// chicken-and-egg the door existed to dodge. Baked code needs no deployment
// (rove#843), which is what lets the door stop being one.
//
// Idempotent: re-posting the same pairs re-stamps the same bytes at the same
// keys. Callers rely on that — the ops seeding scripts re-run unconditionally.

// The response HEAD is the ambient `response` global — a returned object is
// a BODY, not a head (`handler-shape.md` §3: "the head is ambient
// `response.*`"). So every answer here sets `response.status` and returns the
// body, never `{status: …}`.
function answer(status, body) {
    response.status = status;
    return body;
}

export default function () {
    if (request.method !== "POST") return answer(405, "POST only\n");

    let payload;
    try {
        payload = request.json;
    } catch (_e) {
        payload = null;
    }
    const pairs = payload && payload.pairs;
    if (!Array.isArray(pairs)) {
        return answer(400, 'expected {"pairs":[{"key":"...","value":"..."},...]}\n');
    }
    // An empty list is a no-op, not an error — same answer the door gave.
    if (pairs.length === 0) return answer(204, "");

    // Validate the WHOLE batch before writing any of it, so a bad pair
    // cannot leave a partial seed behind. The activation's writeset would
    // roll back anyway on a throw, but answering 400 without having touched
    // the store is the clearer contract.
    for (const p of pairs) {
        if (!p || typeof p.key !== "string" || typeof p.value !== "string") {
            return answer(400, "each pair needs string key and value\n");
        }
        if (p.key.length === 0) return answer(400, "empty key\n");
        if (p.key.indexOf("\0") !== -1 || p.value.indexOf("\0") !== -1) {
            return answer(400, "key/value contains NUL\n");
        }
    }

    for (const p of pairs) kv.set(p.key, p.value);
    return answer(204, "");
}
