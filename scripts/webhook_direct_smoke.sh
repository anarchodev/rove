#!/usr/bin/env bash
# End-to-end smoke for `--webhook-path direct` (Phase 5.5 d, step 4).
#
# Covers the full dispatcher cutover path:
#   - `webhook.send` accumulates per-batch instead of writing
#     `_outbox/{id}` in the tenant's app.db.
#   - finalizeBatch proposes a SINGLE raft entry carrying envelope 0
#     (writeset, including the handler's `kv.set("cb/last_fire", id)`)
#     + envelope 4 (the merged webhook batch) wrapped in the type-7
#     multi-envelope.
#   - applyOne unpacks both envelopes — the writeset lands in acme's
#     app.db, the webhook row lands in webhooks.db.
#   - the webhook-server thread (step 3) picks the row up, POSTs the
#     echo target, proposes envelope 5 → callback → cbresult writes
#     `cb/result/{id}` to acme's app.db.
#   - `_outbox/{id}` never gets written: the customer kv view should
#     be empty under that prefix throughout the run.
#
# Differs from `webhook_smoke.sh` (drainer mode) by passing
# `--webhook-path direct` to the worker. Same handler, same callback
# wiring, different storage path.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-webhook-direct-smoke}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8199}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40299}"
ECHO_PORT="${ECHO_PORT:-9199}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee}"
ADMIN_HOST="app.loop46.localhost"
ACME_HOST="acme.loop46.localhost"
PORT="${HTTP_ADDR##*:}"
ADMIN_ORIGIN="https://${ADMIN_HOST}:${PORT}"
ACME_ORIGIN="https://${ACME_HOST}:${PORT}"

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
if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi
if ! command -v python3 >/dev/null; then
    echo "error: python3 needed for the echo target" >&2
    exit 2
fi

rm -rf "$DATA_DIR"

"$BIN" seed \
    --data-dir "$DATA_DIR" \
    --manifest examples/loop46-demo-tenants.json >/tmp/whd-smoke-seed.out 2>&1 \
    || { cat /tmp/whd-smoke-seed.out >&2; exit 2; }

# ── 1. Echo target ──────────────────────────────────────────────────
ECHO_LOG=/tmp/whd-smoke-echo.out
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

# ── 2. Worker with --webhook-path direct ────────────────────────────
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
    --refresh-interval-ms 100 \
    --dev-webhook-unsafe \
    --webhook-path direct \
    >/tmp/whd-smoke.out 2>&1 &
WORKER_PID=$!

cleanup() {
    kill $WORKER_PID 2>/dev/null || true
    kill $ECHO_PID 2>/dev/null || true
    wait $WORKER_PID 2>/dev/null || true
    wait $ECHO_PID 2>/dev/null || true
    rm -f "$ECHO_PY"
}
trap cleanup EXIT
sleep 1.2

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    echo "--- worker log (last 60 lines) ---" >&2
    tail -60 /tmp/whd-smoke.out >&2
    echo "--- echo log ---" >&2
    cat "$ECHO_LOG" >&2 || true
    exit 1
}

code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST --data "sanity" "http://127.0.0.1:${ECHO_PORT}/")
[[ "$code" == "200" ]] || fail "echo server sanity got $code"
ok "python echo target up on :${ECHO_PORT}"

# ── 3. Fire webhook through cbfire handler ──────────────────────────
RESOLVE=(--resolve "${ADMIN_HOST}:${PORT}:127.0.0.1" \
         --resolve "${ACME_HOST}:${PORT}:127.0.0.1")
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")

ARGS_JSON=$(python3 -c "
import json, urllib.parse
print(urllib.parse.quote(json.dumps(['http://127.0.0.1:${ECHO_PORT}/direct','smoke-direct'])))
")
FIRE_BODY=$("${CURL[@]}" "${ACME_ORIGIN}/cbfire?fn=fire&args=${ARGS_JSON}")
ID=$(echo "$FIRE_BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
[[ -n "$ID" ]] || fail "cbfire didn't return an id: $FIRE_BODY"
ok "handler ran webhook.send, got id=$ID"

# ── 4. Wait for delivery ────────────────────────────────────────────
FOUND_ECHO=0
for _ in $(seq 1 60); do
    if grep -q "POST /direct" "$ECHO_LOG"; then
        FOUND_ECHO=1
        break
    fi
    sleep 0.1
done
[[ $FOUND_ECHO -eq 1 ]] || fail "webhook-server never delivered to echo target"
ok "webhook-server delivered to echo target"

grep -q "hdr X-Rove-Webhook-Id=${ID}" "$ECHO_LOG" \
    || fail "X-Rove-Webhook-Id header missing or wrong"
grep -q "hdr X-Rove-Webhook-Attempt=1" "$ECHO_LOG" \
    || fail "X-Rove-Webhook-Attempt header missing or wrong"
ok "metadata headers stamped"

# ── 5. Verify the writeset side of the multi-envelope landed ────────
# `cb/last_fire` is what the cbfire handler writes via kv.set. It
# rides in envelope 0 of the multi-envelope; if it's there, envelope
# 0 applied.
QS=$(python3 -c "
import json, urllib.parse
print(urllib.parse.quote(json.dumps(['cb/last_fire','',1])))
")
LF_BODY=$("${CURL[@]}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Rove-Scope: acme" \
    "${ADMIN_ORIGIN}/?fn=listKv&args=${QS}")
echo "$LF_BODY" | grep -q "\"key\":\"cb/last_fire\"" \
    || fail "cb/last_fire missing — envelope 0 didn't apply: $LF_BODY"
echo "$LF_BODY" | grep -q "\"value\":\"${ID}\"" \
    || fail "cb/last_fire value != webhook id: $LF_BODY"
ok "envelope 0 (writeset) applied — cb/last_fire = ${ID:0:16}…"

# ── 6. Verify the webhook side — callback ran ───────────────────────
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
    if echo "$RESULT_BODY" | grep -q "\"key\":\"cb/result/${ID}\""; then
        break
    fi
    sleep 0.1
done
echo "$RESULT_BODY" | grep -q "\"key\":\"cb/result/${ID}\"" \
    || fail "no cb/result/${ID:0:16}… row after 6s: $RESULT_BODY"
ok "envelope 4 → webhook-server → envelope 5 → cbresult → cb/result/{id}"

VERIFY_PY=$(mktemp --suffix=.py)
cat >"$VERIFY_PY" <<'PY'
import json, sys, os
wid = os.environ["ID"]
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
assert match["context"]["tag"] == "smoke-direct", f"context={match['context']!r}"
PY
ID="$ID" python3 "$VERIFY_PY" <<<"$RESULT_BODY" \
    || { rm -f "$VERIFY_PY"; fail "callback shape check failed"; }
rm -f "$VERIFY_PY"
ok "callback shape: outcome=delivered, status=200, body='echo:ping'"

# ── 7. Verify _outbox/{id} was NEVER written ─────────────────────────
QS=$(python3 -c "
import json, urllib.parse
print(urllib.parse.quote(json.dumps(['_outbox/','',16])))
")
OB_BODY=$("${CURL[@]}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Rove-Scope: acme" \
    "${ADMIN_ORIGIN}/?fn=listKv&args=${QS}")
if echo "$OB_BODY" | grep -q '"key":"_outbox/'; then
    fail "_outbox/* row exists in direct mode (should never happen): $OB_BODY"
fi
ok "_outbox/* prefix is empty — direct mode bypassed the legacy path"

# ── 8. webhooks.db row deleted after envelope 5 apply ───────────────
LEFT=$(python3 - <<PY
import sqlite3
conn = sqlite3.connect("$DATA_DIR/webhooks.db")
c = conn.execute("SELECT count(*) FROM kv WHERE key LIKE 'wh/%'")
print(c.fetchone()[0])
PY
)
[[ "$LEFT" == "0" ]] || fail "webhooks.db still has rows: $LEFT"
ok "webhooks.db row removed by envelope 5 apply"

echo ""
echo "all webhook-direct smoke checks passed"
