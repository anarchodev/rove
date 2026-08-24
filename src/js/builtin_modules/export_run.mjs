// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// rove#340 — the durable data-export job.
//
// Walks a tenant's KV into content-addressed parts, one part per
// activation, then (format 2, when the marker's `bundle_requested` is set
// and a deployment exists) ships one final `kind:"bundle"` part — the raw
// deployment manifest, whose per-file hashes `blob.fileUrl` presigns out of
// the tenant's immutable file-blobs — and records everything under
// `_export/{id}`. Composed from the
// primitives the effect algebra already has — a durable kv marker, the
// scheduler's durable wake, and the one outbound Cmd — so there is no new
// envelope type, no sweep thread, and no per-feature recovery path.
//
// TWO activation kinds land here and the flow is deliberately shared:
//
//   durable_wake  — the watchdog (or the initial arm). Issues the next part
//                   from whatever cursor is committed.
//   fetch_chunk   — the terminal event of a part's upload, carrying
//                   `{id, part:{hash, bytes, entries, done, next_cursor}}`.
//                   Records the part, then issues the next one.
//
// Both paths end in the same "advance and issue" tail, so there is one
// place where the cursor moves.
//
// ## What the job never sees
//
// It never sees an exported value. The Cmd targets `rove-kvexport.internal`
// and the engine rewrites it into a content-addressed PUT (see
// `src/js/kv_export.zig`), so the bytes go store → S3 without passing
// through a handler. What comes back is a descriptor: a cursor and a digest.
// That distinction is what keeps an export off the request tape — a JS loop
// over `kv.prefix` would record the entire store into the tenant's own log
// budget.
//
// ## Recovery
//
// Every part is issued BEHIND a re-armed watchdog, the `webhook_fire`
// discipline: the fired entry's `_sched/` keys are deleted in this
// activation's writeset, so without the re-arm a crash mid-part would strand
// the job forever. Same key ⇒ same entry, so a re-arm moves the existing
// watchdog rather than accumulating them. At-least-once firing means a part
// can be issued twice; that is harmless, because a part is content-addressed
// (same cursor over the same store ⇒ same bytes ⇒ same hash) and recording
// it is idempotent on the hash.

// One part's upload plus slack. A wake only re-issues a part whose attempt
// has definitively failed, so a live attempt is never duplicated.
const WATCHDOG_MS = 60_000;

// Consecutive failures on the SAME part before the export gives up (rove#429).
//
// Retrying is right for a transient upload failure and wrong for a permanent
// one: without a bound, a part that can never land re-fires every WATCHDOG_MS
// forever, and the customer sees an export stuck at "running" with no reason —
// which is exactly how the storage-quota refusal presented before the export
// pool made it unmetered. Counted per part (reset on progress) rather than per
// export, so a long export is not failed by unrelated blips accumulated across
// hundreds of successful parts.
const MAX_PART_ATTEMPTS = 5;

// Durable-scheduler arm/cancel, inlined over the ambient `kv`/`crypto`: a
// baked `__system/*` module runs post-harden and cannot reach the private
// `_system.sched` closure. Writes the exact `_sched/` rows
// globals/schedule.js + scheduler_tick.mjs use.
const SCHED_TICK_NS = 1_000_000_000n;
// `_sched/by_id/{id}` record version (`format-versioning.md` §1f). The
// record shape is written from every module that arms a wake, so the
// field is what stops one of them shipping a new shape that another
// reads at the old one.
//
// An unknown `v` is NOT treated like an unparseable record. Corrupt
// bytes are unrecoverable, so dropping them loses nothing; a record
// written by a newer build is recoverable by that build, and deleting
// it would destroy durable customer work during an ordinary rolling
// deploy. Readers defer such a record and leave both its rows alone.
// The version an UNSTAMPED record is. Permanently 1: every `_`-namespace
// gained its `v` in one commit, so a row without the field is the shape v1
// describes. It must NOT track the current version — when a format reaches
// v2, an unstamped row is still v1, and defaulting to "whatever we read
// now" would silently reinterpret it.
const UNSTAMPED_V = __rove.formats.unstamped;

const SCHED_REC_V = __rove.formats.sched;

// `_export/{id}` record version (`format-versioning.md` §1f).
const EXPORT_REC_V = __rove.formats.exportRec;

function schedByTimeKey(whenNs, id) {
    return "_sched/by_time/" + String(whenNs).padStart(20, "0") + "/" + id;
}
function schedArm(whenNs, target, msg, key) {
    const rounded = whenNs <= 0n ? 0n
        : ((whenNs + SCHED_TICK_NS - 1n) / SCHED_TICK_NS) * SCHED_TICK_NS;
    const id = key ? crypto.sha256b64url(key) : crypto.randomUUID();
    const byIdKey = "_sched/by_id/" + id;
    const prev = kv.get(byIdKey);
    if (prev !== null) {
        try {
            const old = JSON.parse(prev);
            if (old.v !== SCHED_REC_V) throw new Error("version");
            const oldWhen = BigInt(old.when_ns);
            if (oldWhen !== rounded) kv.delete(schedByTimeKey(oldWhen, id));
        } catch (_e) { /* corrupt or unknown-version prior — overwrite below */ }
    }
    const rec = { v: SCHED_REC_V, when_ns: String(rounded), target: target, msg: msg === undefined ? null : msg };
    // Provenance: the arming saga rides to the fired record as the
    // reserved `_parent` tag (handler-shape.md §3.2). A re-arm's armer
    // is the CURRENT fire — the linked-list-through-fires shape.
    if (typeof request !== "undefined" && typeof request.sagaId === "string" && request.sagaId) rec.armed_by = request.sagaId;
    if (key) rec.key = key;
    kv.set(byIdKey, JSON.stringify(rec));
    kv.set(schedByTimeKey(rounded, id), "");
    return id;
}
function schedCancel(id) {
    const raw = kv.get("_sched/by_id/" + id);
    if (raw === null) return false;
    try {
        const rec = JSON.parse(raw);
        if (rec.v !== SCHED_REC_V) throw new Error("version");
        kv.delete(schedByTimeKey(BigInt(rec.when_ns), id));
    } catch (_e) { /* corrupt or unknown-version record — still drop by_id below */ }
    kv.delete("_sched/by_id/" + id);
    return true;
}

export default function () {
    const a = request.activation;
    if (a.kind !== "durable_wake" && a.kind !== "fetch_chunk") return { status: 200 };
    // A streaming intermediate is not an outcome — only the terminal event
    // of a part's upload says whether it landed.
    if (a.kind === "fetch_chunk" && !a.final) return { status: 200 };

    const msg = request.ctx || {};
    const id = msg.id;
    if (typeof id !== "string" || id.length === 0) return { status: 200 };

    // This record CAN be forged: `_export/` is shim-writable (`reserved.zig`)
    // precisely so the `@rewind/export` verb can write the marker from handler
    // context, and a tenant can therefore author its own export bookkeeping —
    // or arm a wake here under an id it invented. So the record is treated as
    // customer input throughout, and nothing below grants authority on the
    // strength of it: the walk is scoped to the calling tenant's own store by
    // the engine, and the door that does the walking refuses a handler-issued
    // Cmd outright (rove#494).
    //
    // Absent ⇒ nothing was ever started under this id (or it was reaped): a
    // stale watchdog, or an arm by a handler that guessed an id. Either way,
    // no-op — the same defence every baked module makes.
    const key = "_export/" + id;
    const raw = kv.get(key);
    if (raw === null) return { status: 200 };

    let st;
    try {
        st = JSON.parse(raw);
    } catch (_e) {
        // Unparseable state cannot be advanced or trusted; end the chain
        // rather than re-firing a watchdog against it forever.
        kv.delete(key);
        schedCancel(crypto.sha256b64url(key));
        return { status: 200 };
    }
    // A version this build does not implement is NOT the unparseable
    // case above. Those bytes are unrecoverable; this record is
    // recoverable by a different build, and an export job is hours of
    // the customer's data. Leave the record and leave the watchdog
    // armed — cancelling it here is what would strand the job — and
    // advance nothing.
    // Absent reads as the pre-stamp shape — see `__system/scheduler_tick`.
    if (st.v !== undefined && typeof st.v !== "number") {
        kv.delete(key);
        schedCancel(crypto.sha256b64url(key));
        return { status: 200 };
    }
    const st_v = st.v ?? UNSTAMPED_V;
    if (st_v !== EXPORT_REC_V) {
        console.warn("export_run: _export/" + id + " is v" + st_v +
                     ", this build reads v" + EXPORT_REC_V + " — deferred, not dropped");
        return { status: 200 };
    }
    if (st.state !== "running") {
        // Terminal already. Cancel any watchdog still pointing here so a
        // finished export stops costing wakes.
        schedCancel(crypto.sha256b64url(key));
        return { status: 200 };
    }

    // ── record a completed part ────────────────────────────────────────
    const part = msg.part;
    if (part && typeof part.hash === "string") {
        // The terminal status rides the ACTIVATION (`a.status`), the same
        // place `webhook_onresult` reads its result from.
        const ok = a.status >= 200 && a.status < 300;
        if (!ok) {
            // Bound the retry. The cursor deliberately does not advance (the
            // watchdog re-issues the same part, reproducing the same bytes
            // under the same hash), so without this the job re-fires forever
            // on a permanent failure and never reports one.
            st.attempts = (st.attempts || 0) + 1;
            if (st.attempts >= MAX_PART_ATTEMPTS) {
                st.state = "failed";
                st.error = "part upload failed with status " + a.status +
                    " after " + st.attempts + " attempts";
                st.finished_at = Date.now();
                kv.set(key, JSON.stringify(st));
                schedCancel(crypto.sha256b64url(key));
                return { status: 200 };
            }
        }
        if (ok) {
            // Progress resets the budget: attempts bound consecutive failures
            // on one part, not lifetime failures across the whole walk.
            st.attempts = 0;
            st.parts = st.parts || [];
            // Idempotent on the hash: at-least-once firing can re-issue a
            // part, and the re-issue produces the identical object.
            if (st.parts.length === 0 || st.parts[st.parts.length - 1].hash !== part.hash) {
                const rec = { hash: part.hash, bytes: part.bytes, entries: part.entries };
                if (part.kind === "bundle") rec.kind = "bundle";
                st.parts.push(rec);
                st.bytes = (st.bytes || 0) + part.bytes;
                st.entries = (st.entries || 0) + part.entries;
            }
            if (part.kind === "bundle") {
                // The bundle is one part and always the last: record which
                // deployment the code slice captured and finish. A redeploy
                // between the kv walk and this part exported the NEWER
                // manifest — dep_id is what makes that visible.
                st.bundle = { manifest_hash: part.hash, dep_id: part.dep_id || "" };
                st.state = "done";
                st.finished_at = Date.now();
                kv.set(key, JSON.stringify(st));
                schedCancel(crypto.sha256b64url(key));
                return { status: 200 };
            }
            st.cursor = part.next_cursor || "";
            if (part.done) {
                // KV walk finished. Format 2 continues into the code slice
                // when the start requested it AND there is a deployment to
                // export; a marker without `bundle_requested` (pre-format-2,
                // or an explicit {bundle:false}) finishes kv-only, exactly
                // as before.
                if (st.bundle_requested && kv.get("_deploy/current") !== null) {
                    st.phase = "bundle";
                    // Fall through to the shared issue tail below.
                } else {
                    st.state = "done";
                    st.bundle = null;
                    st.finished_at = Date.now();
                    kv.set(key, JSON.stringify(st));
                    schedCancel(crypto.sha256b64url(key));
                    return { status: 200 };
                }
            }
        }
        // A failed upload deliberately does NOT advance the cursor: the
        // watchdog re-issues the same part, which re-produces the same
        // bytes under the same hash.
    }

    // ── issue the next part ────────────────────────────────────────────
    st.updated_at = Date.now();
    kv.set(key, JSON.stringify(st));

    // Re-arm BEFORE issuing: this activation's writeset deletes the fired
    // entry's `_sched/` keys, so a crash between here and the part's
    // terminal event would otherwise strand the job.
    schedArm(BigInt(Date.now() + WATCHDOG_MS) * 1_000_000n, "__system/export_run", { id: id }, key);

    __rove.fetch({
        url: "http://rove-kvexport.internal/",
        method: "POST",
        // `phase` picks the builder at the door: the kv walk (cursor-chained)
        // or the one-shot bundle part (the deployment manifest).
        body: JSON.stringify(st.phase === "bundle"
            ? { id: id, phase: "bundle" }
            : { id: id, cursor: st.cursor || "" }),
        headers: {},
        on_chunk: "__system/export_run",
        ctx: { id: id },
    });
    return { status: 200 };
}
