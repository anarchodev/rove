// A deterministic handler for snapshot assertions (#55).
export default function ({ kv }) {
  const n = request.json.n;
  kv.set("last", String(n));
  return { doubled: n * 2, at: request.path };
}
