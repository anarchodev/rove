// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Typed reads of the platform root store, as an activation in `__root__`'s
// own scope. The read twin of `__system/root_kv_install` (writes) and
// `__system/root_domain` (domain placement), and the surface that retires
// `platform.root.get` / `platform.root.prefix` (rove#852).
//
// ## Why verbs and not a kv door
//
// Every caller of the old door was a QUERY wearing a kv costume: list the
// instances, does this instance exist, list the domains, which instance
// owns this host. None of them wanted a keyspace; each wanted one answer.
// A kv door has to hand out the keyspace to answer them, which is how a
// caller ends up spelling `instance/` + an id and the key format becomes
// an interface nobody decided to publish.
//
// It is also the only shape that CAN work here. `__root__.db` holds engine
// rows written below the bindings, so they carry no user root — and a
// named-view door (`__system/scope_kv`) roots every key it is handed, with
// no spelling exception (rove#850). Pointing a rooted door at `__root__`
// would therefore read `_user/instance/…` and miss every row. The rows are
// raw, so the only honest way to expose them is a verb that knows which
// rows it is about.
//
// ## The keyspace stays here
//
// `instance/{id}` and `domain/{host}` are this module's to know. A caller
// asks `{ instances: true }` or `{ domain: "x.test" }` and gets data; it
// never learns a key. That is what keeps the row layout changeable without
// a cross-repo flag day, and it is the same move as `scope_kv`'s `release`
// request.

// The response HEAD is the ambient `response` global — a returned object
// is a BODY, not a head (`handler-shape.md` §3).
function answer(status, body) {
    response.status = status;
    return body;
}

const INSTANCE = "instance/";
const DOMAIN = "domain/";

// Bounds the terminal body against the engine's dispatch carry cap. The
// platform's instance count is the operator's own scale, not a tenant's, so
// one page is the realistic case; a caller that outgrows it pages by id.
const MAX_ROWS = 1000;

export default function ({ __system }) {
    const msg = request.ctx || {};
    const out = {};

    // `instances: true` → every instance id. `instance: "<id>"` → whether
    // that one exists, as a boolean, because the row's VALUE is engine
    // bookkeeping no caller has a use for.
    if (msg.instances) {
        const rows = __system.rootKv.prefix(INSTANCE, msg.after || "", MAX_ROWS);
        out.instances = rows.map(function (r) { return r.key.slice(INSTANCE.length); });
        out.more = rows.length === MAX_ROWS;
    }
    if (typeof msg.instance === "string" && msg.instance.length > 0) {
        out.instance_exists = __system.rootKv.get(INSTANCE + msg.instance) !== null;
    }

    // `domains: true` → the placement table. `domain: "<host>"` → the
    // instance that owns that host, or null. Here the value IS the answer,
    // so it is returned.
    if (msg.domains) {
        const rows = __system.rootKv.prefix(DOMAIN, msg.after || "", MAX_ROWS);
        out.domains = rows.map(function (r) {
            return { host: r.key.slice(DOMAIN.length), instance_id: r.value };
        });
        out.more = rows.length === MAX_ROWS;
    }
    if (typeof msg.domain === "string" && msg.domain.length > 0) {
        out.domain_owner = __system.rootKv.get(DOMAIN + msg.domain);
    }

    return answer(200, JSON.stringify(out));
}
