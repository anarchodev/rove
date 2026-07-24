// A deterministic handler for snapshot assertions (#55).
export default function () {
  const n = request.json.n;
  kv.set("last", String(n));
  return { doubled: n * 2, at: request.path };
}
