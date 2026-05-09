#!/usr/bin/env bash
# Browser-in-the-loop smoke for the Stripe-style RPC-via-notifications
# recipe (docs/notifications.md §2). Runs a real Chromium against the
# real loop46 cluster + sse-server + a fake Stripe target. Exercises
# the full path:
#
#   1. Browser navigates to https://acme.<suffix>:<port>/. Customer
#      handler returns an HTML page that loads `/_static/rove.js`.
#   2. Page-side JS opens the notifications channel via
#      `rove.events.subscribe()`, generates a correlation_id, and
#      registers a `waitFor('checkout.created', e => e.data.correlation_id === id)`.
#   3. Page POSTs to /api/checkout/start with the correlation_id.
#   4. Customer handler runs `webhook.send({url: fake-stripe,
#      onResult: 'on_stripe_response', context: {correlation_id, sid}})`
#      and returns 202.
#   5. Worker → fake Stripe POST. Stripe responds 200 with a
#      synthesized session id + url.
#   6. Envelope-5 callback dispatch fires `on_stripe_response.mjs`,
#      which calls `events.emit({to: ctx.sid, type: 'checkout.created',
#      data: {correlation_id, stripe_url, session_id}})`.
#   7. Worker fires emit POST at sse-server. sse-server pushes the
#      frame to the browser's open EventSource.
#   8. rove.js dispatches the event; the page's waitFor predicate
#      matches; the promise resolves; the page flips #status to "ok".
#   9. Playwright sees #status === "ok" and exits 0.
#
# What this catches that wire-level smokes can't:
#   - Real browser EventSource semantics (CORS, withCredentials,
#     auto-reconnect, named-event dispatch).
#   - rove.js's auto token mint, .on / .waitFor / dispatch.
#   - The actual customer-facing pattern from notifications.md, end
#     to end. If a customer following the docs finds it broken, this
#     smoke should catch it first.
#
# Dependencies (lazy-installed on first run into /tmp/rove-pw-venv):
#   - python3-venv + pip
#   - playwright (Python pkg) + Chromium browser bundle
# Both cached across reruns. Smoke is slow on cold install (~2 min,
# ~250 MB Chromium download); subsequent runs are ~30s.

set -euo pipefail

DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-notif-browser-smoke}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8270}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40370}"
SSE_PORT="${SSE_PORT:-8278}"
STRIPE_PORT="${STRIPE_PORT:-9202}"
BIN="${BIN:-./zig-out/bin/loop46}"
SSE_BIN="${SSE_BIN:-./zig-out/bin/sse-server-standalone}"
TOKEN="${ROVE_TOKEN:-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff}"
ADMIN_HOST="app.loop46.localhost"
PUBLIC_SUFFIX="loop46.localhost"
TENANT_A="notifbrowsmoke"
SSE_HOST="sse.${PUBLIC_SUFFIX}"
FILES_ADDR="${FILES_ADDR:-127.0.0.1:8277}"
LOG_ADDR="${LOG_ADDR:-127.0.0.1:8276}"
FILES_PORT="${FILES_ADDR##*:}"
LOG_PORT="${LOG_ADDR##*:}"
FILES_HOST="files.${PUBLIC_SUFFIX}"
LOG_HOST="logs.${PUBLIC_SUFFIX}"

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
for b in "$BIN" "$SSE_BIN" "${BIN%/loop46}/files-server-standalone" "${BIN%/loop46}/log-server-standalone"; do
    if [[ ! -x "$b" ]]; then
        echo "error: $b missing — run 'zig build install' first" >&2
        exit 2
    fi
done

# ── Lazy Playwright install ────────────────────────────────────────
PLAYWRIGHT_VENV="${PLAYWRIGHT_VENV:-/tmp/rove-pw-venv}"
if [[ ! -x "$PLAYWRIGHT_VENV/bin/playwright" ]]; then
    echo "Installing Playwright into $PLAYWRIGHT_VENV (one-time, ~250 MB)..."
    python3 -m venv "$PLAYWRIGHT_VENV"
    "$PLAYWRIGHT_VENV/bin/pip" install --quiet --upgrade pip
    "$PLAYWRIGHT_VENV/bin/pip" install --quiet playwright
    "$PLAYWRIGHT_VENV/bin/playwright" install chromium
    echo "Playwright installed."
fi
PYTHON="$PLAYWRIGHT_VENV/bin/python"

. "$(dirname "$0")/_smoke_helpers.sh"
SMOKE_TAG=notif-browser-smoke
SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"

export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"
export LOOP46_ROOT_TOKEN="$TOKEN"
export SSE_INTERNAL_TOKEN="$(head -c 24 /dev/urandom | xxd -p | tr -d '\n')"
# Browsers can't speak h2c — sse-server must run TLS for the
# EventSource open to work. Worker → sse-server emit POST also goes
# over TLS; the dev cert isn't in the system CA bundle so we tell
# libcurl to skip peer verification for that hop. Production never
# sets this.
export LOOP46_SSE_INSECURE_TLS=1

PIDS=()
SSE_PID=""
STRIPE_PID=""
trap '
    for p in "${PIDS[@]}" "${CS_PID:-}" "${LS_PID:-}" "${SSE_PID:-}" "${STRIPE_PID:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    for p in "${PIDS[@]}" "${CS_PID:-}" "${LS_PID:-}" "${SSE_PID:-}" "${STRIPE_PID:-}"; do
        [ -n "$p" ] && wait "$p" 2>/dev/null || true
    done
' EXIT

# ── Fake Stripe (a Python echo synthesizing a `cs_test_…` session) ─
STRIPE_LOG="/tmp/${SMOKE_TAG}-stripe.out"
python3 -u - "$STRIPE_PORT" >"$STRIPE_LOG" 2>&1 <<'STRIPE' &
import http.server, json, sys
port = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        self.rfile.read(n)
        body = json.dumps({
            "id": "cs_test_smoke_session",
            "url": "https://stripe.example.test/c/cs_test_smoke_session",
            "object": "checkout.session",
        })
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, fmt, *args):
        sys.stderr.write("stripe %s\n" % (fmt % args))
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
STRIPE
STRIPE_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf -X POST -d '' "http://127.0.0.1:${STRIPE_PORT}/" >/dev/null 2>&1; then break; fi
    sleep 0.1
done

# ── sse-server (TLS, before workers) ───────────────────────────────
# Real Chromium can't speak h2c, so sse-server has to terminate TLS
# for the browser EventSource open to work. ALPN handles h2 from
# there. Worker emit POST also goes over TLS (LOOP46_SSE_INSECURE_TLS
# above tells libcurl to skip dev-cert verification).
"$SSE_BIN" --listen "127.0.0.1:${SSE_PORT}" \
    --tls-cert "$TLS_CERT" --tls-key "$TLS_KEY" \
    >/tmp/${SMOKE_TAG}-sse.out 2>&1 &
SSE_PID=$!
for _ in $(seq 1 30); do
    if curl -sk -f --http2 "https://127.0.0.1:${SSE_PORT}/v1/health" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

SSE_PUBLIC_BASE="https://${SSE_HOST}:${SSE_PORT}"

# ── 3-node loop46 cluster ──────────────────────────────────────────
for i in 0 1 2; do
    "$BIN" worker \
        --node-id "$i" \
        --peers "$PEERS_CSV" \
        --listen "${RAFT_ADDRS[$i]}" \
        --http "${HTTP_ADDRS[$i]}" \
        --log-public-base "https://${LOG_HOST}:${LOG_PORT}" \
        --files-public-base "https://${FILES_HOST}:${FILES_PORT}" \
        --sse-public-base "$SSE_PUBLIC_BASE" \
        --data-dir "${DATA_DIRS[$i]}" \
        --public-suffix "$PUBLIC_SUFFIX" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --workers 1 \
        --dev-webhook-unsafe \
        "${RAFT_TIMING_FLAGS[@]}" \
        >"/tmp/${SMOKE_TAG}-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done
sleep 2

RESOLVE=(--resolve "${FILES_HOST}:${FILES_PORT}:127.0.0.1" \
         --resolve "${LOG_HOST}:${LOG_PORT}:127.0.0.1")
for h in "${HTTP_ADDRS[@]}"; do
    p="${h##*:}"
    RESOLVE+=(--resolve "${ADMIN_HOST}:${p}:127.0.0.1" \
              --resolve "${TENANT_A}.${PUBLIC_SUFFIX}:${p}:127.0.0.1")
done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")

discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
echo "ok  leader elected: node $LEADER_IDX at $LEADER_HTTP"
PORT="$LEADER_PORT"
ADMIN_ORIGIN="https://${ADMIN_HOST}:${PORT}"
TENANT_ORIGIN="https://${TENANT_A}.${PUBLIC_SUFFIX}:${PORT}"

spawn_files_server "$FILES_ADDR" "${DATA_DIRS[$LEADER_IDX]}" \
    /tmp/${SMOKE_TAG}-cs.out "$ADMIN_ORIGIN" "$ADMIN_ORIGIN" || exit 1
spawn_log_server "$LOG_ADDR" "${DATA_DIRS[$LEADER_IDX]}" \
    /tmp/${SMOKE_TAG}-ls.out "$ADMIN_ORIGIN" || exit 1

ROVE_TOKEN="$TOKEN"
mint_services_token

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    for i in 0 1 2; do
        echo "--- worker $i log ---" >&2
        tail -30 "/tmp/${SMOKE_TAG}-worker-${i}.out" >&2
    done
    echo "--- sse-server log ---" >&2
    tail -20 /tmp/${SMOKE_TAG}-sse.out >&2
    echo "--- fake stripe log ---" >&2
    tail -20 "$STRIPE_LOG" >&2
    exit 1
}

# ── Tenant signup ──────────────────────────────────────────────────
SIGNUP_BODY=$("${CURL[@]}" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${TENANT_A}\",\"email\":\"${TENANT_A}@example.com\"}" \
    "${ADMIN_ORIGIN}/v1/signup")
echo "$SIGNUP_BODY" | grep -q '"ok":true' || fail "signup: $SIGNUP_BODY"
MT=$(echo "$SIGNUP_BODY" | python3 -c 'import json,sys;print(json.load(sys.stdin)["magic_link"])' | sed 's/.*mt=//')
CODE=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${ADMIN_ORIGIN}/v1/auth?mt=${MT}")
[[ "$CODE" == "302" ]] || fail "redeem signup: $CODE"
ok "signed up tenant $TENANT_A"

# ── Deploy customer app: handler + callback + rove.js static ──────
put_file() {
    local path="$1" body="$2" ctype="${3:-application/javascript}"
    local resp
    resp=$("${CURL[@]}" -w $'\n%{http_code}' \
        -X PUT \
        -H "Authorization: Bearer $JWT" \
        -H "Content-Type: $ctype" \
        --data-binary "$body" \
        "${FILES_BASE}/${TENANT_A}/file/${path}")
    local code="${resp##*$'\n'}"
    local dep_id="${resp%$'\n'*}"
    [[ "$code" == "201" ]] || { echo "PUT ${path}: $code body=$resp" >&2; fail "PUT $path"; }
    release_deployment "$TENANT_A" "$dep_id" || fail "release ${TENANT_A}/${dep_id}"
}

# Static rove.js (browser library). The page below pulls it via
# <script src="/_static/rove.js">.
put_file "_static/rove.js" "$(cat web/rove.js)" "application/javascript"
ok "deployed _static/rove.js (customer-facing browser library)"

# Static test page. Overrides the starter content's index.html — the
# worker serves _static/<path> directly when the path matches, before
# routing to the customer's handler.
TEST_HTML=$(cat <<'HTML_END'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>rove notifications smoke</title>
<style>
body { font-family: ui-monospace, monospace; padding: 2rem; max-width: 60ch; }
#status { font-size: 1.25rem; }
#status.ok { color: #0a7; }
#status.fail { color: #b00; }
pre { background: #f4f4f4; padding: 1rem; border-radius: 4px; }
</style>
<script src="/rove.js"></script>
</head>
<body>
<h1>rove notifications smoke</h1>
<p id="status">starting</p>
<pre id="result"></pre>
<script>
(async () => {
  const setStatus = (s, cls) => {
    const el = document.getElementById('status');
    el.textContent = s;
    el.className = cls || '';
  };
  const setResult = (s) => { document.getElementById('result').textContent = s; };
  try {
    const events = await rove.events.subscribe();
    setStatus('subscribed');
    const cid = (crypto.randomUUID && crypto.randomUUID()) ||
                (Math.random().toString(36).slice(2) + Date.now());
    // Subscribe BEFORE firing the request — the response can race
    // back faster than we'd otherwise wire the listener.
    const promise = events.waitFor(
      'checkout.created',
      e => e.data && e.data.correlation_id === cid,
      { timeoutMs: 20000 },
    );
    const r = await fetch('/api/checkout/start', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ correlation_id: cid, items: [{ sku: 'foo', qty: 1 }] }),
    });
    if (!r.ok) throw new Error('start ' + r.status + ': ' + await r.text());
    setStatus('awaiting webhook callback');
    const evt = await promise;
    if (!evt.data || !evt.data.session_id || !evt.data.stripe_url) {
      throw new Error('event missing fields: ' + JSON.stringify(evt));
    }
    setResult(JSON.stringify({
      correlation_id: evt.data.correlation_id,
      stripe_url: evt.data.stripe_url,
      session_id: evt.data.session_id,
      event_id: evt.id,
    }, null, 2));
    setStatus('ok', 'ok');
  } catch (err) {
    setStatus('fail: ' + (err && err.message || String(err)), 'fail');
    console.error('smoke error:', err);
  }
})();
</script>
</body>
</html>
HTML_END
)
put_file "_static/index.html" "$TEST_HTML" "text/html; charset=utf-8"
ok "deployed _static/index.html (test page, overrides starter)"

# Customer handler. Only handles the API POST; the static at /
# already serves the page.
HANDLER=$(cat <<'HANDLER_END'
const STRIPE_URL = "http://localhost:9202/v1/checkout/sessions";

export default function () {
  if (request.method === "POST" && request.path === "/api/checkout/start") {
    const body = JSON.parse(request.body || "{}");
    if (!body.correlation_id) {
      response.status = 400;
      return { error: "correlation_id required" };
    }
    webhook.send({
      url: STRIPE_URL,
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ items: body.items, correlation_id: body.correlation_id }),
      onResult: "on_stripe_response",
      context: { correlation_id: body.correlation_id, sid: request.session.id },
    });
    response.status = 202;
    return { queued: true };
  }
  response.status = 404;
  return { error: "not found" };
}
HANDLER_END
)
put_file "index.mjs" "$HANDLER"
ok "deployed customer handler (index.mjs)"

# Callback handler: receives the webhook delivery event, fans the
# Stripe session back to the user's browser via events.emit. Also
# kv.sets a recovery row keyed by correlation_id so a reconnecting
# browser can poll for the result if the SSE event was missed.
CALLBACK=$(cat <<'CALLBACK_END'
export default function (event) {
  const ctx = event.context || {};
  if (event.outcome !== "delivered") {
    // Webhook failed — surface the error to the browser. Real
    // customer code would also log + alert here.
    events.emit({
      to: ctx.sid,
      type: "checkout.failed",
      data: {
        correlation_id: ctx.correlation_id,
        outcome: event.outcome,
        error: event.error || null,
      },
    });
    return;
  }
  const stripe = JSON.parse(event.response.body);
  const result = {
    correlation_id: ctx.correlation_id,
    stripe_url: stripe.url,
    session_id: stripe.id,
  };
  // Persist the result so a refresh / disconnect can recover via a
  // GET /api/checkouts/<correlation_id> read (not exercised by the
  // smoke directly, but documented in notifications.md §3 as the
  // recovery story for missed events).
  kv.set("checkouts/" + ctx.correlation_id, JSON.stringify(result));
  events.emit({
    to: ctx.sid,
    type: "checkout.created",
    data: result,
  });
}
CALLBACK_END
)
put_file "on_stripe_response.mjs" "$CALLBACK"
ok "deployed callback handler (on_stripe_response.mjs)"

sleep 0.4

# ── Run Chromium against the deployed app ──────────────────────────
TARGET_URL="${TENANT_ORIGIN}/"
echo "running headless browser against ${TARGET_URL}"
"$PYTHON" "$(dirname "$0")/notifications_browser_smoke.py" \
    --url "$TARGET_URL" \
    --timeout-ms 30000 \
    || fail "browser smoke did not reach #status === 'ok'"
ok "browser observed checkout.created with matching correlation_id"

# ── Bonus: confirm the recovery row landed in kv ───────────────────
#
# The customer handler's callback also kv.sets the result keyed by
# correlation_id. A real customer would expose a recovery endpoint;
# here we just admin-read to prove the durability story works.
LIST_ARGS=$(python3 -c "
import urllib.parse, json
print(urllib.parse.quote(json.dumps(['checkouts/','',5])))
")
RECOVERY=""
for _ in $(seq 1 30); do
    RECOVERY=$("${CURL[@]}" \
        -H "Authorization: Bearer $TOKEN" \
        -H "X-Rove-Scope: ${TENANT_A}" \
        "${ADMIN_ORIGIN}/?fn=listKv&args=${LIST_ARGS}") || true
    if echo "$RECOVERY" | grep -q '"key":"checkouts/'; then break; fi
    sleep 0.1
done
echo "$RECOVERY" | grep -q '"key":"checkouts/' \
    || fail "no checkouts/<correlation_id> recovery row in kv: $RECOVERY"
ok "callback persisted recovery row to kv (checkouts/<id>)"

echo
echo "all browser-in-the-loop notifications smoke checks passed"
