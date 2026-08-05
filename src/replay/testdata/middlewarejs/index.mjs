// A `.js` middleware must NOT run. `_middlewares/index.js` sits next to this
// handler and would set `request.auth` if the sim honoured the spelling — so
// `auth: null` here is the assertion, not an accident.
//
// The rule is prod's: the CLI ships only `.mjs`, and the compiler builds a
// `.js` as a classic script (`export` is a syntax error). A sim that ran the
// `.js` would gate a request offline that reaches production UNGATED, which is
// the worst direction to diverge in for the file where auth lives.
export default function () {
  response.status = 200;
  return { auth: request.auth ?? null };
}
