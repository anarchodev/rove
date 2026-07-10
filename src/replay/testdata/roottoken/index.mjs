// platform.auth.checkRootToken gate. An admin endpoint that only proceeds when
// the request carries the operator root token — the sim validates the token
// against the configured value (scenario({ rootToken })) instead of blanket
// success, so a broken/absent token is actually rejected.
export default function () {
  const tok = request.headers["x-root-token"];
  if (!platform.auth.checkRootToken(tok)) {
    response.status = 403;
    return { ok: false };
  }
  return { ok: true, admin: true };
}
