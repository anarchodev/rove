// `await after.kv(prefix)` — the edge wake: the settle delivers the FIRED
// PREFIX ("go look"), never the key; the handler re-reads kv, which the
// fold updated before the settle.
export default async function ({ response, kv, after }) {
  const wake = await after.kv("watch/");
  const seen = kv.get("watch/flag");
  response.status = 201;
  return JSON.stringify({ kind: wake.kind, prefix: wake.prefix, seen: seen });
}
