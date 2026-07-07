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
    // No blob backend in the in-process dispatcher — the documented
    // fail-loud error IS the contract here.
    throws(() => blob.url(SHA_HELLO), /blob storage backend is not configured/);
  });

  check("blob.write", () => {
    throws(() => blob.write(42), /bytes must be a string or Uint8Array/); // shim-side validation
    // Upload sessions live in worker state (the blob_write trampoline);
    // the in-process dispatcher has none — the fail-loud context error
    // is the contract here. Session behavior is blob_smoke_v2's job.
    throws(() => blob.write("chunk-1"), /not supported in this context/);
  });

  check("blob.seal", () => {
    throws(() => blob.seal(), /`on` export name is required/);
    throws(() => blob.seal({ on: "onStored", content_type: "t" }), /`content_type` was renamed/);
    throws(() => blob.seal({ on: "onStored" }), /not supported in this context/); // needs the worker's seal trampoline
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
