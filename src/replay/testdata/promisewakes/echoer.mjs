// Streamed inbound (rove#931): the body crossed the size cap, so it
// arrives via `for await (const c of request.chunks)`. `request.text`
// throws (the body was never buffered).
export default async function ({ request, response, kv }) {
  let n = 0;
  let total = 0;
  let acc = "";
  for await (const c of request.chunks) { n++; total += c.bytes.length; acc += c.text; }
  kv.set("body/chunks", String(n));
  kv.set("body/bytes", String(total));
  response.status = 201;
  return acc;
}
