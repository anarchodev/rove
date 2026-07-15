// A handler whose held chain fetches three classes of URL: a metadata
// endpoint prod's SSRF blocklist always rejects, a plain-http URL prod's
// scheme policy always rejects, and an ordinary public https URL. Issuing is
// legal in every case (the policy surfaces ASYNC in prod, never a throw) —
// what the offline harness must police is which OUTCOMES are authorable.
export default function () {
  after.fetch("https://169.254.169.254/latest/meta-data/", { on: "onMeta" });
  after.fetch("http://api.example.test/plain", { on: "onPlain" });
  after.fetch("https://localhost:8080/svc", { on: "onLocal" });
  after.fetch("https://api.example.test/ok", { on: "onOk" });
  return next({});
}

export function onMeta() {
  return { status: request.status };
}

export function onOk() {
  return { ok: request.status === 200 };
}
