// Deliberately `.js`, and deliberately never run — see ../index.mjs. If this
// executes, `request.auth` becomes non-null and the fixture fails.
export function before() {
  request.auth = { user: "jess", scopes: ["read"] };
}
