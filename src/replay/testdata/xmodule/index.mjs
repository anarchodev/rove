// A handler whose fetch continuation lives in a SEPARATE module — the `on` of
// the after.fetch names `hooks/onFetched.mjs` (a different file), not a bare
// same-module export. This is the cross-module continuation shape (admin's
// `_rp/*.mjs` modules); before the harness resolved a module-path `on` to its
// own entry, `.resolve()` ran the WRONG file (the parent's).
export default function () {
  const key = new URLSearchParams(request.query || "").get("k") || "k";
  after.fetch("https://api.example.com/data", {
    method: "GET",
    ctx: { key: key },
    on: "hooks/onFetched.mjs",
  });
  return next();
}
