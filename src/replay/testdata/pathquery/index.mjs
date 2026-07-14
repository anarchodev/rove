// Echoes the path/query split: request.path never includes the query
// string — the query lives only on request.query (handler-shape.md).
// The live twin is ctl_smoke_v2.py's `pathq` assertion.
export default function () {
  return request.path + "|" + (request.query || "");
}
