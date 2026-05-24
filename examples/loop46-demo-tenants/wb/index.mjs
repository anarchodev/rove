// Target tenant for the webhook.send fast-path smokes. Pure echo
// handler — READ-ONLY (no kv.set) so any cluster node can serve it
// without needing to be the raft leader. The webhook_recovery_smoke
// and leader_failover_smoke send fetches to a survivor port which
// might land on a follower; a read-only echo lets any node respond
// 200 + body, which is what the on_result chain needs to fire the
// terminal `httpresult` hop. (Phase 5 PR-3: with the JS-shim
// webhook path, customer-facing retries cap at 5 and target a fixed
// URL — no leader-following retry — so the target must be
// node-agnostic.)
export default function () {
    let payload = null;
    try { payload = JSON.parse(request.body); } catch (_) {}
    const tag = (payload && payload.tag) || "<no-tag>";
    response.status = 200;
    return "echoed:" + tag;
}
