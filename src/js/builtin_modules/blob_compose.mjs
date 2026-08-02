// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// blob-write-recipes.md §4: the seal-time prompt compose. The
// rove-compose.internal door fires this with ctx {sid, hash, on, ctx}
// after the seal's writeset committed. It assembles the recipe's
// inline rows and hands the payload to blob.put — reusing the owed
// marker + signed PUT door wholesale; blob.put's on_result then runs
// __system/blob_compose_onresult (the flip + customer handoff).
//
// This fire is the LATENCY path and is allowed to be lost — the
// sealed meta row is the durable intent the materializer sweeps. So
// every abnormal exit here just leaves the recipe in place.

export default function () {
    // Fired durable_wake-shaped: the seal Cmd's ctx IS request.ctx
    // (the webhook_fire convention).
    const c = request.ctx || {};
    const sid = c.sid;
    if (!sid) return { status: 400 };

    const metaKey = "_blob/recipe/" + sid + "/meta";
    const raw = kv.get(metaKey);
    if (raw == null) return { status: 200 }; // already composed (dup fire)
    const meta = JSON.parse(raw);
    if (meta.state !== "sealed") return { status: 200 }; // not frozen yet — not ours

    const te = new TextEncoder();
    const parts = [];
    let total = 0;
    for (let i = 0; i < meta.rows; i++) {
        const rraw = kv.get("_blob/recipe/" + sid + "/r/" + String(i).padStart(4, "0"));
        if (rraw == null) {
            // A sealed recipe can't lose rows — this is corruption.
            // Leave everything; the wedged materializer mark is the
            // operator signal (plan §12.4), never a customer error.
            console.error("blob_compose: recipe " + sid + " missing row " + i + " of " + meta.rows);
            return { status: 500 };
        }
        const row = JSON.parse(rraw);
        const bytes = row.b !== undefined ? base64url.decode(row.b) : te.encode(row.s);
        parts.push(bytes);
        total += bytes.length;
    }
    const payload = new Uint8Array(total);
    let off = 0;
    for (const p of parts) { payload.set(p, off); off += p.length; }

    // End-to-end integrity: the assembled bytes must finalize to the
    // hash the midstate promised at seal time.
    const hash = crypto.sha256(payload);
    if (hash !== meta.hash) {
        console.error("blob_compose: recipe " + sid + " assembled to " + hash + " but sealed as " + meta.hash);
        return { status: 500 };
    }

    blob.put(payload, {
        contentType: meta.content_type || undefined,
        on: "__system/blob_compose_onresult",
        ctx: { sid: sid, hash: hash, on: meta.on, ctx: meta.ctx, totalBytes: meta.totalBytes },
    });
    return { status: 200 };
}
