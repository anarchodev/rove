// Wake-coalescing smoke helper — fires N kv writes against the
// `burst/` prefix in ONE handler invocation (a single writeset → a
// single apply-thread broadcast → ONE fired-arm stamp on the watching
// stream, however large N is; issue #8 / decisions.md §3.10).
//
// Body shape: `{ "count": <int> }` (default 50). Response: 204.
export default function () {
    const body = JSON.parse(request.text || "{}");
    const count = body.count ?? 50;
    for (let i = 0; i < count; i++) {
        kv.set("burst/k" + i, "v" + i);
    }
    response.status = 204;
    return "";
}
