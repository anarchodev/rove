// Depends on the `.js`-spelled middleware having run: request.auth is only
// set by _middlewares/index.js `before`. If the sim skips the .js spelling,
// this handler runs UNAUTHENTICATED and throws on request.auth.user — the
// worst direction to diverge in (issue #51).
export default function () {
  response.status = 200;
  return { user: request.auth.user, scopes: request.auth.scopes };
}
