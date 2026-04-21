#!/usr/bin/env bash
# End-to-end smoke test for the webhook → callback pipeline.
#
# Covers:
#   - `webhook.send` inside a handler writes `_outbox/{id}` + returns the id
#   - the outbox drainer delivers the row to a real HTTP server
#   - the drainer writes `_callback/{id}` with the delivery outcome
#   - `dispatchCallbacks` invokes the customer's callback handler
#     (`_code/cbresult.mjs`) with a camelCase event object
#   - the callback's `kv.set` is durable + visible via the admin API
#
# Requirements:
#   - zig-out/bin/js-worker present (run `zig build install` first)
#   - python3 on PATH (used as the webhook delivery target)
#
# The js-worker runs with `--dev-webhook-unsafe` so the drainer's SSRF
# block and https-required check are relaxed for loopback. **That flag
# is dev-only** — do not set it in production.

set -euo pipefail

DATA_DIR="${DATA_DIR:-/tmp/rove-webhook-smoke}"
HTTP_ADDR="${HTTP_ADDR:-127.0.0.1:8197}"
RAFT_ADDR="${RAFT_ADDR:-127.0.0.1:40297}"
ECHO_PORT="${ECHO_PORT:-9197}"
BIN="${BIN:-./zig-out/bin/js-worker}"
TOKEN="${ROVE_TOKEN:-cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}"
ADMIN_HOST="api.test"
ACME_HOST="acme.test"
PORT="${HTTP_ADDR##*:}"
ADMIN_ORIGIN="http://${ADMIN_HOST}:${PORT}"
ACME_ORIGIN="http://${ACME_HOST}:${PORT}"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi
if ! command -v python3 >/dev/null; then
    echo "error: python3 needed for the echo target" >&2
    exit 2
fi

rm -rf "$DATA_DIR"

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

# Start worker.
"$BIN" \
    --node-id 0 \
    --peers "$RAFT_ADDR" \
    --listen "$RAFT_ADDR" \
    --http "$HTTP_ADDR" \
    --data-dir "$DATA_DIR" \
    --bootstrap-root-token "$TOKEN" \
    --admin-origin "$ADMIN_ORIGIN" \
    --admin-api-domain "$ADMIN_HOST" \
    --workers 1 \
    --refresh-interval-ms 100 \
    --dev-webhook-unsafe \
    --fresh >/tmp/webhook-smoke.out 2>&1 &
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

RESOLVE=(--resolve "${ADMIN_HOST}:${PORT}:127.0.0.1" \
         --resolve "${ACME_HOST}:${PORT}:127.0.0.1")
CURL=(curl --http2-prior-knowledge -sS "${RESOLVE[@]}")

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    echo "--- worker log (last 40 lines) ---" >&2
    tail -40 /tmp/webhook-smoke.out >&2
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
# The handler is at _code/cbfire/index.mjs → URL /cbfire?fn=fire.
# It calls webhook.send(...) and returns { id } so the smoke can
# correlate the receipt.
ARGS_JSON=$(python3 -c "
import json, urllib.parse
print(urllib.parse.quote(json.dumps(['http://127.0.0.1:${ECHO_PORT}/hook','smoke1'])))
")
FIRE_BODY=$("${CURL[@]}" "${ACME_ORIGIN}/cbfire?fn=fire&args=${ARGS_JSON}")
ID=$(echo "$FIRE_BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
[[ -n "$ID" ]] || fail "fire didn't return an id: $FIRE_BODY"
ok "handler fired webhook, outbox id=$ID"

# ── 4. Wait for drainer to deliver + callback to run ─────────────────
FOUND_ECHO=0
for _ in $(seq 1 30); do
    if grep -q 'POST /hook' "$ECHO_LOG"; then
        FOUND_ECHO=1
        break
    fi
    sleep 0.1
done
[[ $FOUND_ECHO -eq 1 ]] || fail "drainer never delivered to echo server"
ok "drainer delivered webhook to echo target"

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
