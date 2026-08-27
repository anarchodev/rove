// The config door (rove#830): `config.get(name)` is the only way a handler
// reads deploy-time config, and the kv spelling of the namespace is an
// ordinary key of the handler's own — the two surfaces are disjoint by
// construction. An authored world seeds config as `_config/{name}` rows
// (scope 0 resolves a name to its visible spelling).
export default function ({ kv, config }) {
  const present = config.get("oauth/google");
  const absent = config.get("oauth/missing");

  // The kv spelling reroots into the handler's own keyspace: writing it does
  // not create config, and the door cannot see it.
  kv.set("_config/oauth/google", "not-config");
  const doorAfterWrite = config.get("oauth/google");
  const kvSpelling = kv.get("_config/oauth/google");

  return { present, absent, doorAfterWrite, kvSpelling };
}
