// The RP session reader's version handling, offline.
//
// `@rewind/oidc` stamps every `_rp/`/`_oidc/` record with a `v`, and refuses
// one it cannot place. A record with NO `v` is not such a record: every row in
// these namespaces gained the field in a single change that altered nothing
// else, so an unstamped row is exactly the shape this build reads. Refusing it
// would log out every session written by the previous version of this package
// the moment a tenant upgrades it — silently, since `guard()` returns null and
// the caller answers 401.
//
// The reader and the writer ship together in one package, so this is a
// package-UPGRADE boundary rather than the engine skew in rove#820.
import oidc from "@rewind/oidc";

export default function () {
  const auth = oidc.rp("default").guard();
  response.status = 200;
  return { authed: !!auth, sub: auth ? auth.sub : null, isRoot: auth ? auth.is_root : null };
}
