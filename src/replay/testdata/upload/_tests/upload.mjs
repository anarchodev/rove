// Headers-first inbound (`onHeaders`) + the `blob.receive` → `onStored`
// continuation, offline (docs/architecture/replay-and-sim.md). Before the harness
// gained `scenario.inboundHeaders` + `node.receive().stored()`, neither leg of a
// streamed-upload handler was reachable, so the whole path (auth branches, the
// receive→store handoff, the scoped workspace write) was dark. This exercises all
// of it. The handler touches `platform.*`, so the run is admin; `isRoot`
// declares the operator-root verdict the engine computes in prod.
import { scenario, expect } from "rewind:test";

// `instances` declares the scope target — platform.scope resolves eagerly
// (ghost id ⇒ InstanceNotFound, like prod).
const s = scenario({ admin: true, isRoot: true, now: "2026-07-01T00:00:00Z", instances: { acme: {} } });

function upload(query, sc = s) {
  return sc.inboundHeaders({ method: "PUT", path: "/v1/upload?" + query });
}

// The un-credentialed twin. Auth is a property of the ACTIVATION, not a header
// the handler parses — so it is declared per scenario, not per request.
const anon = scenario({ admin: true, isRoot: false, now: "2026-07-01T00:00:00Z", instances: { acme: {} } });

// ── auth branches (all terminal, no receive armed) ──
// Missing tenant/path → 400 before auth even runs.
const bad = upload("tenant=acme");
expect(bad.status).toBe(400);
expect(bad.disposition).toBe("terminal");

// No operator credential → 401.
const noauth = upload("tenant=acme&path=logo.png", anon);
expect(noauth.status).toBe(401);

// ── authed: onHeaders holds + arms the receive ──
const h = upload("tenant=acme&path=logo.png&content_type=image/png");
expect(h.disposition).toBe("held");
// the streamed receive is armed (the only body-accepting move from onHeaders)
expect(h.effects.some((e) => e.kind === "blob" && e.op === "receive")).toBe(true);

// ── the object lands durably → onStored writes the workspace row + returns the hash ──
const stored = h.receive().stored({ hash: "abc123def", len: 4096 });
expect(stored.status).toBe(200);
// The completion resumes as a BOUND fetch_chunk (blob_receive.zig emitTerminal
// bind:true, final:true) — not a bespoke "blob_stored" kind — with the
// top-level `done` flatten, matching what onStored sees in prod.
expect(stored.kv("probe/resume")).toEqual({ kind: "fetch_chunk", done: true });
expect(JSON.parse(stored.body)).toEqual({ ok: true, path: "logo.png", hash: "abc123def" });
// The write went to the TARGET tenant's isolated store (platform.scope("acme")),
// with {tenant, path, content_type} threaded from the issue-time ctx via app.
expect(stored.instanceKv("acme", "_workspace/logo.png")).toEqual({
  kind: "static", content_type: "image/png", source_hex: "abc123def", len: 4096,
});

// ── a torn upload (client disconnect / storage error) → onStored 502, nothing stored ──
const failed = h.receive().stored({ ok: false });
expect(failed.status).toBe(502);
expect(JSON.parse(failed.body)).toEqual({ ok: false, error: "receive failed" });
expect(failed.instanceKv("acme", "_workspace/logo.png")).toBe(null);
