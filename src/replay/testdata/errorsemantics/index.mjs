// Error-semantics fixture: the sim must report the PROD outcome
// for a thrown handler (500 "handler threw: …" + rollback), a pending-promise
// return (200 "{}"), and a held chain whose module has no onDisconnect (no-op).
export default function () {
  if (request.path === "/throw") {
    kv.set("before-throw", "1");
    after.fetch("https://api.example.com/x");
    response.status = 201; // discarded — the 500 wins
    throw new Error("boom");
  }
  if (request.path === "/pending") return new Promise(() => {});
  if (request.path === "/hold") return next({ n: 1 });
  return { ok: true };
}
