// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// blob — content-addressed tenant object storage. put/get compose
// kv markers + the fetch primitive (observable in-process); url is
// native presign (fail-loud without a configured backend — that
// documented error is the pin); write/seal/receive are the upload-
// session verbs.
const SHA_HELLO = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";

export default function () {
  check("blob.put", () => {
    const hash = blob.put("hello", { contentType: "text/plain", on: "onStored", ctx: { k: 1 } });
    eq(hash, SHA_HELLO); // content-addressed: sha256 of the bytes
    const marker = JSON.parse(kv.get("_blob/owed/" + hash));
    eq(marker.hash, SHA_HELLO);
    eq(marker.content_type, "text/plain");
    eq(marker.attempts, 1);
    eq(marker.on_result, "onStored");
    eq(marker.context, { k: 1 });
    // Uint8Array bytes hash identically to their string spelling.
    eq(blob.put(new TextEncoder().encode("hello")), SHA_HELLO);
    throws(() => blob.put(42), /bytes must be a string or Uint8Array/);
    throws(() => blob.put("x", { content_type: "t" }), /`content_type` was renamed/);
  });

  check("blob.get", () => {
    const id = blob.get(SHA_HELLO, { on: "onBlob", ctx: { want: 1 } });
    ok(typeof id === "string" && id.length > 0, "fetch id: " + id);
    throws(() => blob.get("not-a-hash"), /hash must be 64 lowercase hex chars/);
    throws(() => blob.get(SHA_HELLO, { on_result: "x" }), /`on_result` was renamed/);
  });

  check("blob.url", () => {
    throws(() => blob.url("nope"), /hash must be 64 lowercase hex chars/);
    throws(() => blob.url(SHA_HELLO, { ttl: 0 }), /ttl must be 1\.\.604800/);
    // The harness supplies a synthetic backend config (presign is pure
    // SigV4 computation — no network), so the REAL signing path runs:
    // per-tenant prefix isolation + query-mode SigV4 params.
    const url = blob.url(SHA_HELLO, { ttl: 300, contentType: "text/plain" });
    ok(url.startsWith("https://s3.test.example/surface-bucket/sfx/surface/app-blobs/" + SHA_HELLO),
      "tenant-prefixed content-addressed path, got " + url);
    for (const param of ["X-Amz-Algorithm=AWS4-HMAC-SHA256", "X-Amz-Credential=SURFACEKEY",
                         "X-Amz-Expires=300", "X-Amz-Signature=", "X-Amz-Date="]) {
      ok(url.includes(param), "presigned URL carries " + param);
    }
    // response-content-type rides the signed query (S3 echoes it).
    ok(url.includes("text%2Fplain") || url.includes("text/plain"), "signed content-type present");
  });

  check("blob.write", () => {
    throws(() => blob.write(42), /bytes must be a string or Uint8Array/);
    // The recipe substrate: appends are kv rows + a sha256 midstate —
    // replicated, replayable, no worker RAM (blob-write-recipes.md).
    // Chain-less dispatch uses the "local" sid.
    eq(blob.write("hel"), 3);
    eq(blob.write(new TextEncoder().encode("lo")), 5); // running total
    const meta = JSON.parse(kv.get("_blob/recipe/local/meta"));
    eq(meta.state, "open");
    eq(meta.rows, 2);
    eq(meta.total, 5);
    ok(meta.mid.startsWith("s2:"), "midstate token rides the meta row");
    // Rows carry the bytes: strings raw, binary base64url.
    eq(JSON.parse(kv.get("_blob/recipe/local/r/0000")), { s: "hel" });
    eq(JSON.parse(kv.get("_blob/recipe/local/r/0001")), { b: base64url.encode(new TextEncoder().encode("lo")) });
    // Multi-byte UTF-8 counts encoded bytes, not JS chars.
    eq(blob.write("é"), 7);
    throws(() => blob.write("x".repeat(256 * 1024 + 1)), /256 KiB inline cap/);
  });

  check("blob.seal", () => {
    throws(() => blob.seal(), /`on` module path is required/);
    throws(() => blob.seal({ on: "onStored", content_type: "t" }), /`content_type` was renamed/);
    // Seal freezes the recipe and returns the true hash synchronously,
    // finalized from the midstate — "hel"+"lo"+"é" accumulated above.
    const hash = blob.seal({ on: "stored", ctx: { id: 7 }, contentType: "text/plain" });
    eq(hash, crypto.sha256("helloé"));
    const meta = JSON.parse(kv.get("_blob/recipe/local/meta"));
    eq(meta.state, "sealed");
    eq(meta.hash, hash);
    eq(meta.on, "stored");
    eq(meta.ctx, { id: 7 });
    eq(meta.content_type, "text/plain");
    eq(meta.totalBytes, 7);
    // The pending row makes early dereference fail loud — readiness
    // is announced by the `on` activation, never inferred.
    eq(kv.get("_blob/pending/" + hash), "local");
    throws(() => blob.url(hash), /sealed but not yet materialized/);
    throws(() => blob.get(hash), /sealed but not yet materialized/);
    // One seal per chain: both verbs refuse after the freeze.
    throws(() => blob.write("more"), /already sealed/);
    throws(() => blob.seal({ on: "stored" }), /already sealed/);
  });

  check("blob.receive", () => {
    throws(() => blob.receive(), /`on` export name is required/);
    throws(() => blob.receive({ on_result: "x" }), /`on_result` was renamed/);
    // Only callable from onHeaders (the body is already accepted on a
    // buffered inbound) — pin the documented rejection.
    throws(() => blob.receive({ on: "onStored" }));
  });

  return done();
}
