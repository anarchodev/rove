// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// A `domain/{host}` → tenant alias, written by `__root__` in its own scope
// (rove#715).
//
// Before this, `/_system/v2-domain` was a door: it opened a txn on the
// cluster root store from the request thread and proposed the write as a
// type-2 inner anchored on `__admin__`'s group — cluster routing state
// ordered by another tenant's log. Now the route authenticates the CP
// (move secret), validates, and dispatches this module against `__root__`,
// whose own raft group was born with the cluster: the alias takes a
// position in the root log and leaves a record there.
//
// Writes go through `__system.rootKv` (rove#848): `domain/{host}` is
// storage as it lies — `tenant.resolveDomain` and the host cache read it
// raw, and the handler-rooted `kv` would re-file it where no reader looks.

// The response HEAD is the ambient `response` global — a returned object
// is a BODY, not a head (`handler-shape.md` §3).
function answer(status, body) {
    response.status = status;
    return body;
}

export default function ({ __system }) {
    if (request.method !== "POST") return answer(405, "POST only\n");
    let payload = null;
    try {
        payload = request.json;
    } catch (_e) { /* falls through to the check */ }
    const host = payload && payload.host;
    const tenant = payload && payload.tenant;
    // The route validated both before dispatching; this re-check closes the
    // gap for any future second producer of the dispatch, mirroring the
    // route's own rules (lowercase fqdn, tenant required).
    if (typeof host !== "string" || host.length === 0 || host.length > 253 ||
        !/^[a-z0-9.-]+$/.test(host) || typeof tenant !== "string" || tenant.length === 0) {
        return answer(400, "host = lowercase fqdn, tenant required\n");
    }
    __system.rootKv.set("domain/" + host, tenant);
    return answer(204, "");
}
