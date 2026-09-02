// `await after.fetch(url)` — resolves once with the whole buffered response;
// a rejection (transport shape the promise cannot carry) surfaces as the
// handler's own throw path.
export default async function ({ request, response, after }) {
  const m = /(?:^|&)url=([^&]*)/.exec(request.query || "");
  const url = decodeURIComponent(m ? m[1] : "");
  const res = await after.fetch(url);
  response.status = 201;
  return JSON.stringify({ status: res.status, text: res.text, truncated: res.truncated,
                          idForm: typeof res === "object" ? "obj" : "str" });
}
