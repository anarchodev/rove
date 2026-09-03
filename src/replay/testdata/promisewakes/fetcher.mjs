// `await after.fetch(url)` — the Fetch-API shape (rove#930): the promise
// resolves with the response handle; `await r.text()` collects the whole
// body (rejecting past the chunk cap); a rejection (transport shape the
// promise cannot carry) surfaces as the handler's own throw path.
export default async function ({ request, response, after }) {
  const m = /(?:^|&)url=([^&]*)/.exec(request.query || "");
  const url = decodeURIComponent(m ? m[1] : "");
  const r = await after.fetch(url);
  const t = await r.text();
  response.status = 201;
  return JSON.stringify({ status: r.status, text: t, form: typeof r.text });
}
