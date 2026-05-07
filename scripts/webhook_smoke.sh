#!/usr/bin/env bash
# End-to-end smoke test for the webhook → callback pipeline.
#
# Covers (Phase 5.5 d direct-only path):
#   - `webhook.send` inside a handler appends a WebhookRow to the
#     dispatcher's per-batch accumulator + returns the id
#   - the type-7 multi-envelope (writeset + webhook batch) commits
#     atomically through raft
#   - the leader-pinned webhook-server thread reads webhooks.db and
#     delivers the row to a real HTTP server
#   - envelope-5 apply writes `_callback/{id}` with the delivery outcome
#   - `dispatchCallbacks` invokes the customer's callback handler
#     (`cbresult.mjs`) with a camelCase event object
#   - the callback's `kv.set` is durable + visible via the admin API
#
# Requirements:
#   - zig-out/bin/loop46 present (run `zig build install` first)
#   - python3 on PATH (used as the webhook delivery target)
#
# The loop46 runs with `--dev-webhook-unsafe` so the webhook-server's
# SSRF block and https-required check are relaxed for loopback. **That
# flag is dev-only** — do not set it in production.

set -euo pipefail

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-webhook-smoke}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8245}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40345}"
ECHO_PORT="${ECHO_PORT:-9197}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}"
ADMIN_HOST="app.loop46.localhost"
ACME_HOST="acme.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"

# TLS via mkcert. ADMIN_ORIGIN + ACME_ORIGIN are https://, so the
# worker has to listen under TLS for curl to make it past the
# handshake.
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

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=webhook-smoke
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

# Seed `acme` (with cbfire/ + cbresult.mjs handlers) onto every node.
seed_all_dirs ./examples/loop46-demo-tenants.json

# ── 1. Tiny Python echo server ────────────────────────────────────────
#
# Responds 200 to POST with body "echo:<request body>". Logs every
# request line so the smoke script can verify delivery happened even
# if the callback side races.
ECHO_LOG=/tmp/webhook-smoke-echo.out
rm -f "$ECHO_LOG"

ECHO_PY=$(mktemp --suffix=.py)
trap 'rm -f "$ECHO_PY"' EXIT
cat >"$ECHO_PY" <<'PY'
import sys, http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length') or 0)
        body = self.rfile.read(n)
        # Log metadata headers so the smoke script can assert on them.
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

# Start cluster.
PIDS=()
for i in 0 1 2; do
    P="${HTTP_ADDRS[$i]##*:}"
    "$BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --data-dir "${DATA_DIRS[$i]}" \
        --bootstrap-root-token "$TOKEN" \
        --admin-origin "https://${ADMIN_HOST}:${P}" \
        --admin-api-domain "$ADMIN_HOST" \
        --public-suffix "$PUBLIC_SUFFIX" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --workers 2 \
        "${RAFT_TIMING_FLAGS[@]}" \
        --dev-webhook-unsafe \
        >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done

cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    kill $ECHO_PID 2>/dev/null || true
    for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
    wait $ECHO_PID 2>/dev/null || true
    rm -f "$ECHO_PY"
}
trap cleanup EXIT
sleep 2

RESOLVE=()
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE+=(--resolve "${ADMIN_HOST}:${p}:127.0.0.1" \
              --resolve "${ACME_HOST}:${p}:127.0.0.1")
done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")

discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
echo "ok  leader elected: node $LEADER_IDX at $LEADER_HTTP"
PORT="$LEADER_PORT"
ADMIN_ORIGIN="https://${ADMIN_HOST}:${PORT}"
ACME_ORIGIN="https://${ACME_HOST}:${PORT}"

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    for i in 0 1 2; do
        echo "--- worker $i log ---" >&2
        tail -30 "/tmp/${SMOKE_TAG}-worker-${i}.out" >&2
    done
    echo "--- echo server log ---" >&2
    cat "$ECHO_LOG" >&2 || true
    exit 1
}

# ── 2. Sanity-check the echo target is up ─────────────────────────────
code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST --data "sanity" "http://127.0.0.1:${ECHO_PORT}/")
[[ "$code" == "200" ]] || fail "echo server sanity check got $code"
ok "python echo target up on :${ECHO_PORT}"

# ── 3. Fire the webhook through the acme handler ──────────────────────
#
# The handler is at cbfire/index.mjs → URL /cbfire?fn=fire.
# It calls webhook.send(...) and returns { id } so the smoke can
# correlate the receipt.
ARGS_JSON=$(python3 -c "
import json, urllib.parse
print(urllib.parse.quote(json.dumps(['http://127.0.0.1:${ECHO_PORT}/hook','smoke1'])))
")
FIRE_BODY=$("${CURL[@]}" "${ACME_ORIGIN}/cbfire?fn=fire&args=${ARGS_JSON}")
ID=$(echo "$FIRE_BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
[[ -n "$ID" ]] || fail "fire didn't return an id: $FIRE_BODY"
ok "handler fired webhook, id=$ID"

# ── 4. Wait for webhook-server to deliver + callback to run ──────────
FOUND_ECHO=0
for _ in $(seq 1 30); do
    if grep -q 'POST /hook' "$ECHO_LOG"; then
        FOUND_ECHO=1
        break
    fi
    sleep 0.1
done
[[ $FOUND_ECHO -eq 1 ]] || fail "webhook-server never delivered to echo server"
ok "webhook-server delivered webhook to echo target"

# ── 4a. Metadata headers stamped on outbound request ──────────────────
grep -q "hdr X-Rove-Webhook-Id=${ID}" "$ECHO_LOG" \
    || fail "X-Rove-Webhook-Id header missing or wrong"
grep -q "hdr X-Rove-Webhook-Attempt=1" "$ECHO_LOG" \
    || fail "X-Rove-Webhook-Attempt header missing or wrong"
ok "webhook-server stamped X-Rove-Webhook-Id + X-Rove-Webhook-Attempt"

# ── 5. Read the callback result via admin API ─────────────────────────
#
# X-Rove-Scope: acme rebinds the __admin__ handler's kv view onto
# acme's app.db. `listKv` returns {entries:[{key,value}]}.
RESULT_BODY=""
for _ in $(seq 1 40); do
    QS=$(python3 -c "
import json, urllib.parse
print(urllib.parse.quote(json.dumps(['cb/result/','',100])))
")
    RESULT_BODY=$("${CURL[@]}" \
        -H "Authorization: Bearer $TOKEN" \
        -H "X-Rove-Scope: acme" \
        "${ADMIN_ORIGIN}/?fn=listKv&args=${QS}")
    if echo "$RESULT_BODY" | grep -q '"key":"cb/result/'; then
        break
    fi
    sleep 0.1
done
echo "$RESULT_BODY" | grep -q '"key":"cb/result/' \
    || fail "no cb/result/* row after 4s: $RESULT_BODY"
ok "callback handler wrote cb/result/{id} to acme kv"

# Extract the value for the specific id and verify the event shape.
VERIFY_PY=$(mktemp --suffix=.py)
cat >"$VERIFY_PY" <<'PY'
import json, sys, os
id = os.environ["ID"]
doc = json.loads(sys.stdin.read())
match = None
for e in doc.get("entries", []):
    if e["key"] == "cb/result/" + id:
        match = json.loads(e["value"])
        break
if match is None:
    print("no match for cb/result/" + id, file=sys.stderr)
    sys.exit(2)
assert match["outcome"] == "delivered", f"outcome={match['outcome']!r}"
assert match["status"] == 200, f"status={match['status']!r}"
assert match["body"] == "echo:ping", f"body={match['body']!r}"
assert match["attempts"] == 1, f"attempts={match['attempts']!r}"
assert match["context"]["tag"] == "smoke1", f"context={match['context']!r}"
assert match.get("error") in (None, ""), f"error={match.get('error')!r}"
print(json.dumps(match))
PY

ID="$ID" python3 "$VERIFY_PY" <<<"$RESULT_BODY" \
    || { rm -f "$VERIFY_PY"; fail "event shape check failed: $RESULT_BODY"; }
rm -f "$VERIFY_PY"
ok "callback event shape: outcome=delivered, status=200, body='echo:ping', attempts=1, context.tag=smoke1"

# ── 6. Receipt should be deleted after delivery ───────────────────────
QS=$(python3 -c "
import json, urllib.parse
print(urllib.parse.quote(json.dumps(['_callback/','',100])))
")
CB_BODY=$("${CURL[@]}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Rove-Scope: acme" \
    "${ADMIN_ORIGIN}/?fn=listKv&args=${QS}")
if echo "$CB_BODY" | grep -q '"key":"_callback/'; then
    fail "_callback/* receipt not deleted: $CB_BODY"
fi
ok "_callback/{id} receipt cleared after callback ran"

echo ""
echo "all webhook-callback smoke checks passed"
