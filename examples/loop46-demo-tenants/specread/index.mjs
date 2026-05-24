// Read-side-dual (idiom-0) fault-injection target.
// scripts/readonly_speculation_faultinj_smoke.py,
// docs/proposer-audit.md Addendum (idiom-0).
//
//   GET /?fn=write&args=["K","V"]  — kv.set(K, V); returns {wrote:K}.
//        A WRITE batch: speculative-commits into this tenant's kvexp
//        chain, then proposes. With quorum frozen the propose accepts
//        (local log append) but never commits — the speculative
//        overlay sits in the chain, uncommitted.
//
//   GET /?fn=read&args=["K"]       — kv.get(K); returns {k,v,found}.
//        A READ-ONLY batch (no writes, no webhook.send). If its kv.get
//        crosses the frozen write's chain-predecessor overlay, kvexp
//        sets Txn.saw_speculation. PRE-fix idiom-0: finalizeBatch's
//        read-only fast path releases the response immediately —
//        the uncommitted value ESCAPES to the client. POST-fix: the
//        batch takes an empty-writeset barrier propose + park, and
//        the response is released only once the predecessor write
//        commits (chain head reached); under frozen quorum it 503s
//        on the commit-wait deadline and the value never escapes.
//
//   default                       — 200 "ok" (liveness probe; never
//        touches the speculative key).

export function write(k, v) {
    kv.set(k, v);
    return JSON.stringify({ wrote: k });
}

export function read(k) {
    const v = kv.get(k);
    return JSON.stringify({ k: k, v: v, found: v !== null });
}

export default function () {
    return "ok";
}
