#!/usr/bin/env bash
# End-to-end smoke for the leader-pinned webhook-server thread
# (Phase 5.5 d, step 3).
#
# Covers:
#   - the webhook-server thread starts on the raft leader
#   - it scans `webhooks.db` and POSTs ready rows to the customer URL
#   - it stamps `X-Rove-Webhook-Id` + `X-Rove-Webhook-Attempt`
#   - on 2xx, it proposes envelope 5 → apply writes `_callback/{id}`
#     to the tenant's app.db
#   - the existing `dispatchCallbacks` phase invokes the customer
#     `onResult` handler, which is the existing path (unchanged from
#     the customer onResult contract; unchanged from before Phase 5.5)
#
# Differs from `webhook_smoke.sh`: no `webhook.send` from JS; the row
# is injected directly into `webhooks.db` via the `webhook-test-enqueue`
# helper. This lets step 3 ship without depending on the dispatcher
# cutover (step 4).

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-webhook-server-smoke}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8198}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40298}"
ECHO_PORT="${ECHO_PORT:-9198}"
BIN="${BIN:-./zig-out/bin/loop46}"
ENQUEUE="${ENQUEUE:-./zig-out/bin/webhook-test-enqueue}"
TOKEN="${ROVE_TOKEN:-dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd}"
ADMIN_HOST="app.loop46.localhost"
ACME_HOST="acme.loop46.localhost"
PORT="${HTTP_ADDR##*:}"
ADMIN_ORIGIN="https://${ADMIN_HOST}:${PORT}"

if [[ "$(uname -s)" == "Darwin" ]]; then
    LOOP46_DATA="${LOOP46_DATA:-$HOME/Library/Application Support/loop46}"
else
    LOOP46_DATA="${LOOP46_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/loop46}"
fi
TLS_CERT="$LOOP46_DATA/dev-cert.pem"
TLS_KEY="$LOOP46_DATA/dev-key.pem"
CACERT="$LOOP46_DATA/ca-root.pem"

if [[ ! -f "$TLS_CERT" || ! -f "$TLS_KEY" ]]; then
    echo "error: missing dev TLS at $LOOP46_DATA. Run 'loop46 dev ...' once to bootstrap." >&2
    exit 2
fi
if [[ ! -x "$BIN" || ! -x "$ENQUEUE" ]]; then
    echo "error: $BIN or $ENQUEUE missing — run 'zig build install' first" >&2
    exit 2
fi
if ! command -v python3 >/dev/null; then
    echo "error: python3 needed for the echo target" >&2
    exit 2
fi

rm -rf "$DATA_DIR"

# Pre-create acme with cbresult.mjs from the demo manifest. cbresult
# writes `cb/result/{webhookId}` so we can verify the callback ran.
"$BIN" seed \
    --data-dir "$DATA_DIR" \
    --manifest examples/loop46-demo-tenants.json >/tmp/whs-smoke-seed.out 2>&1 \
    || { cat /tmp/whs-smoke-seed.out >&2; exit 2; }

# ── 1. Tiny echo target ─────────────────────────────────────────────
ECHO_LOG=/tmp/whs-smoke-echo.out
rm -f "$ECHO_LOG"

ECHO_PY=$(mktemp --suffix=.py)
trap 'rm -f "$ECHO_PY"' EXIT
cat >"$ECHO_PY" <<'PY'
import sys, http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length') or 0)
        body = self.rfile.read(n)
        sys.stderr.write("hdr X-Rove-Webhook-Id=%s\n"
            % (self.headers.get('X-Rove-Webhook-Id') or ''))
        sys.stderr.write("hdr X-Rove-Webhook-Attempt=%s\n"
            % (self.headers.get('X-Rove-Webhook-Attempt') or ''))
        self.send_response(200)
        self.send_header('content-type', 'text/plain')
        self.send_header('content-length', str(len(body) + 5))
        self.end_headers()
        self.wfile.write(b'echo:' + body)
    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))
port = int(sys.argv[1])
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PY

python3 "$ECHO_PY" "$ECHO_PORT" >"$ECHO_LOG" 2>&1 &
ECHO_PID=$!
sleep 0.3

# ── 2. Start loop46 worker ─────────────────────────────────────────
"$BIN" worker \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$HTTP_ADDR" \
    --data-dir "$DATA_DIR" \
    --bootstrap-root-token "$TOKEN" \
    --admin-origin "$ADMIN_ORIGIN" \
    --admin-api-domain "$ADMIN_HOST" \
    --public-suffix loop46.localhost \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    --workers 1 \
    --dev-webhook-unsafe \
    >/tmp/whs-smoke.out 2>&1 &
WORKER_PID=$!

cleanup() {
    kill $WORKER_PID 2>/dev/null || true
    kill $ECHO_PID 2>/dev/null || true
    wait $WORKER_PID 2>/dev/null || true
    wait $ECHO_PID 2>/dev/null || true
    rm -f "$ECHO_PY"
}
trap cleanup EXIT

# Wait for the worker to come up + become leader. The webhook-server
# thread also opens webhooks.db at spawn (creating the file).
sleep 1.2

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    echo "--- worker log (last 60 lines) ---" >&2
    tail -60 /tmp/whs-smoke.out >&2
    echo "--- echo server log ---" >&2
    cat "$ECHO_LOG" >&2 || true
    exit 1
}

# Sanity check echo target.
code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST --data "sanity" "http://127.0.0.1:${ECHO_PORT}/")
[[ "$code" == "200" ]] || fail "echo server sanity check got $code"
ok "python echo target up on :${ECHO_PORT}"

# ── 3. Inject a webhook row directly into webhooks.db ──────────────
WEBHOOK_ID="aaaabbbbccccddddeeeeffff00001111aaaabbbbccccddddeeeeffff00001111"
"$ENQUEUE" \
    --data-dir "$DATA_DIR" \
    --tenant acme \
    --webhook-id "$WEBHOOK_ID" \
    --url "http://127.0.0.1:${ECHO_PORT}/whs" \
    --on-result cbresult \
    --max-attempts 3 \
    --body "ping" \
    >/tmp/whs-enqueue.out 2>&1 \
    || { cat /tmp/whs-enqueue.out >&2; fail "webhook-test-enqueue failed"; }
ok "injected webhook id=${WEBHOOK_ID:0:16}… into webhooks.db"

# ── 4. Wait for webhook-server to deliver ──────────────────────────
FOUND_ECHO=0
for _ in $(seq 1 60); do
    if grep -q "POST /whs" "$ECHO_LOG"; then
        FOUND_ECHO=1
        break
    fi
    sleep 0.1
done
[[ $FOUND_ECHO -eq 1 ]] || fail "webhook-server never delivered to echo target"
ok "webhook-server thread delivered webhook to echo target"

grep -q "hdr X-Rove-Webhook-Id=${WEBHOOK_ID}" "$ECHO_LOG" \
    || fail "X-Rove-Webhook-Id header missing or wrong"
grep -q "hdr X-Rove-Webhook-Attempt=1" "$ECHO_LOG" \
    || fail "X-Rove-Webhook-Attempt header missing or wrong"
ok "webhook-server stamped X-Rove-Webhook-Id + X-Rove-Webhook-Attempt"

# ── 5. Verify the callback fired (via cbresult writing cb/result/) ─
RESOLVE=(--resolve "${ADMIN_HOST}:${PORT}:127.0.0.1")
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")

RESULT_BODY=""
for _ in $(seq 1 60); do
    QS=$(python3 -c "
import json, urllib.parse
print(urllib.parse.quote(json.dumps(['cb/result/','',100])))
")
    RESULT_BODY=$("${CURL[@]}" \
        -H "Authorization: Bearer $TOKEN" \
        -H "X-Rove-Scope: acme" \
        "${ADMIN_ORIGIN}/?fn=listKv&args=${QS}")
    if echo "$RESULT_BODY" | grep -q "\"key\":\"cb/result/${WEBHOOK_ID}\""; then
        break
    fi
    sleep 0.1
done
echo "$RESULT_BODY" | grep -q "\"key\":\"cb/result/${WEBHOOK_ID}\"" \
    || fail "no cb/result/${WEBHOOK_ID:0:16}… row after 6s: $RESULT_BODY"
ok "envelope 5 → apply → _callback → cbresult → cb/result/{id}"

VERIFY_PY=$(mktemp --suffix=.py)
cat >"$VERIFY_PY" <<'PY'
import json, sys, os
wid = os.environ["WEBHOOK_ID"]
doc = json.loads(sys.stdin.read())
match = None
for e in doc.get("entries", []):
    if e["key"] == "cb/result/" + wid:
        match = json.loads(e["value"])
        break
if match is None:
    print("no match for cb/result/" + wid, file=sys.stderr)
    sys.exit(2)
assert match["outcome"] == "delivered", f"outcome={match['outcome']!r}"
assert match["status"] == 200, f"status={match['status']!r}"
assert match["body"] == "echo:ping", f"body={match['body']!r}"
assert match["attempts"] == 1, f"attempts={match['attempts']!r}"
assert match["context"]["smoke"] is True, f"context={match['context']!r}"
PY
WEBHOOK_ID="$WEBHOOK_ID" python3 "$VERIFY_PY" <<<"$RESULT_BODY" \
    || { rm -f "$VERIFY_PY"; fail "callback shape check failed"; }
rm -f "$VERIFY_PY"
ok "callback shape: outcome=delivered, status=200, body='echo:ping', attempts=1"

# ── 6. webhooks.db row should be deleted by envelope 5 apply ────────
# Use a tiny inline python+sqlite peek; no public admin surface for
# webhooks.db (yet).
LEFT=$(python3 - <<PY
import sqlite3
conn = sqlite3.connect("$DATA_DIR/webhooks.db")
c = conn.execute("SELECT count(*) FROM kv WHERE key LIKE 'wh/%'")
print(c.fetchone()[0])
PY
)
[[ "$LEFT" == "0" ]] || fail "webhooks.db still has rows after delivery: $LEFT"
ok "webhooks.db row removed by envelope 5 apply"

echo ""
echo "all webhook-server smoke checks passed"
