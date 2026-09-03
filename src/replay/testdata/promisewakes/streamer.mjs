// The streamed path (rove#930): the engine settled at HEADERS (no
// content-length under the cap), so the body arrives through
// `for await (const c of r.chunks)` — each chunk is its own settle hop.
export default async function ({ request, response, kv, after }) {
  const m = /(?:^|&)url=([^&]*)/.exec(request.query || "");
  const url = decodeURIComponent(m ? m[1] : "");
  const r = await after.fetch(url);
  kv.set("head", r.status + ":" + (r.headers["content-type"] || "?"));
  let n = 0;
  let got = "";
  for await (const c of r.chunks) {
    n += 1;
    got += c.text;
  }
  kv.set("chunks", String(n));
  response.status = 201;
  return got;
}
