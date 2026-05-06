#!/usr/bin/env bash
# Phase 5.5 (a) step 2 smoke for the standalone log-server.
#
# Hand-populates a local batch-store directory with sidecar +
# ndjson pairs (no worker involvement yet — the worker S3-write
# path lands in step 3), spawns the binary on a loopback port, and
# verifies:
#
#   - the indexer picks up the sidecars and inserts rows into
#     log_index.db
#   - GET /v1/{tenant}/list returns those rows newest-first as JSON
#   - GET /v1/{tenant}/list?after_received_ns=...&after_request_id=...
#     paginates correctly
#   - GET /v1/{tenant}/show/{request_id} range-reads the .ndjson
#     payload and returns the record bytes
#   - GET /v1/{unknown}/list returns an empty record set
#   - bad routes return 404
#
# h2c on loopback (no TLS) — `--http2-prior-knowledge` to skip the
# upgrade dance.

set -euo pipefail

BIN="${BIN:-./zig-out/bin/log-server-standalone}"
DATA_DIR="${DATA_DIR:-/tmp/rove-log-smoke}"

if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi
if ! command -v python3 >/dev/null; then
    echo "error: python3 needed (sidecar fixture generator)" >&2
    exit 2
fi

rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR/acme/00000001" "$DATA_DIR/globex/00000001"

# ── Hand-build two acme batches + one globex batch ─────────────────
#
# Each .ndjson holds one record per line ending in '\n'; the matching
# .idx.json carries (offset, length) pointing into the decompressed
# stream so /show can range-read.
python3 - "$DATA_DIR" <<'PY'
import json, os, sys, hashlib

root = sys.argv[1]

def write_batch(tenant, node, batch_id, records):
    base = os.path.join(root, tenant, node)
    os.makedirs(base, exist_ok=True)
    ndjson_key = f"{tenant}/{node}/{batch_id}.ndjson"
    idx_key    = f"{tenant}/{node}/{batch_id}.idx.json"

    # Build payload + per-record offsets.
    payload = b""
    rec_index = []
    for r in records:
        line = (json.dumps(r, sort_keys=True) + "\n").encode()
        rec_index.append({
            "request_id":   r["request_id"],
            "received_ns":  r["received_ns"],
            "duration_ns":  r["duration_ns"],
            "method":       r["method"],
            "path":         r["path"],
            "host":         r["host"],
            "status":       r["status"],
            "outcome":      r["outcome"],
            "deployment_id": r["deployment_id"],
            "offset":       len(payload),
            "length":       len(line),
        })
        payload += line

    sidecar = {
        "v": 1,
        "tenant_id":         tenant,
        "node_id":           node,
        "batch_id":          batch_id,
        "ndjson_key":        ndjson_key,
        "ndjson_size":       len(payload),
        "ndjson_sha256":     hashlib.sha256(payload).hexdigest(),
        "first_received_ns": records[0]["received_ns"],
        "last_received_ns":  records[-1]["received_ns"],
        "records":           rec_index,
    }

    # Payload first, sidecar second — same crash-ordering as the
    # worker's flush will use (orphan ndjson is harmless; orphan
    # sidecar pointing at missing payload is what we never want).
    with open(os.path.join(root, ndjson_key), "wb") as f:
        f.write(payload)
    with open(os.path.join(root, idx_key), "w") as f:
        json.dump(sidecar, f)

write_batch("acme", "00000001", "00000000000000000001-0001730764800000", [
    {"request_id": 1, "received_ns": 1000, "duration_ns": 500_000,
     "method": "GET",  "path": "/api/foo", "host": "acme.test",
     "status": 200, "outcome": "ok", "deployment_id": 7,
     "console": "", "exception": ""},
    {"request_id": 2, "received_ns": 2000, "duration_ns": 800_000,
     "method": "POST", "path": "/users",   "host": "acme.test",
     "status": 500, "outcome": "handler_error", "deployment_id": 7,
     "console": "boom", "exception": "Error: kaboom"},
])

write_batch("acme", "00000001", "00000000000000000003-0001730764810000", [
    {"request_id": 3, "received_ns": 5000, "duration_ns": 100_000,
     "method": "GET", "path": "/health", "host": "acme.test",
     "status": 200, "outcome": "ok", "deployment_id": 8,
     "console": "", "exception": ""},
])

write_batch("globex", "00000001", "00000000000000000010-0001730764820000", [
    {"request_id": 10, "received_ns": 9000, "duration_ns": 250_000,
     "method": "GET", "path": "/", "host": "globex.test",
     "status": 200, "outcome": "ok", "deployment_id": 1,
     "console": "", "exception": ""},
])
PY

# ── Spawn binary ────────────────────────────────────────────────────
LOG_OUT=/tmp/log-server-smoke.out
rm -f "$LOG_OUT"
"$BIN" \
    --batch-store-dir "$DATA_DIR" \
    --listen 127.0.0.1:0 \
    --poll-interval-ms 100 \
    >"$LOG_OUT" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT

# Wait for the "listening on port N" line.
PORT=""
for _ in $(seq 1 50); do
    if grep -q '^listening on port ' "$LOG_OUT" 2>/dev/null; then
        PORT=$(awk '/^listening on port / {print $4; exit}' "$LOG_OUT")
        break
    fi
    sleep 0.1
done
if [[ -z "$PORT" ]]; then
    echo "FAIL no listening line within 5s" >&2
    cat "$LOG_OUT" >&2 || true
    exit 1
fi

ok() { echo "ok  $1"; }
fail() {
    echo "FAIL $1" >&2
    echo "--- log-server stderr (tail 60) ---" >&2
    tail -60 "$LOG_OUT" >&2 || true
    exit 1
}

CURL=(curl -sS --http2-prior-knowledge --max-time 5)

# Indexer poll runs every 100ms; give it a couple of ticks.
sleep 0.4

# ── /v1/acme/list ───────────────────────────────────────────────────
LIST=$("${CURL[@]}" -X GET "http://127.0.0.1:${PORT}/v1/acme/list?limit=10")
echo "$LIST" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
records = d["records"]
assert len(records) == 3, f"want 3 records, got {len(records)}: {d}"
# Newest first.
assert records[0]["request_id"] == 3, f"newest id mismatch: {records[0]}"
assert records[1]["request_id"] == 2
assert records[2]["request_id"] == 1
assert records[1]["status"] == 500
assert records[1]["outcome"] == "handler_error"
nc = d["next_cursor"]
assert nc["request_id"] == 1
assert nc["received_ns"] == 1000
' || fail "acme list shape check"
ok "list newest-first across two batches; next_cursor set"

# Pagination: cursor at the second-newest → only the oldest left.
PAGE2=$("${CURL[@]}" -X GET \
    "http://127.0.0.1:${PORT}/v1/acme/list?limit=10&after_received_ns=2000&after_request_id=2")
echo "$PAGE2" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert len(d["records"]) == 1, f"page 2 record count: {d}"
assert d["records"][0]["request_id"] == 1
' || fail "acme list pagination"
ok "list pagination: cursor correctly excludes the page-1 tail"

# ── /v1/globex/list (cross-tenant isolation) ───────────────────────
GLOBEX=$("${CURL[@]}" -X GET "http://127.0.0.1:${PORT}/v1/globex/list?limit=10")
echo "$GLOBEX" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert len(d["records"]) == 1
assert d["records"][0]["request_id"] == 10
assert d["records"][0]["host"] == "globex.test"
' || fail "globex list cross-tenant"
ok "cross-tenant list: globex sees its own records, not acme's"

# ── /v1/{unknown}/list returns empty ───────────────────────────────
UNK=$("${CURL[@]}" -X GET "http://127.0.0.1:${PORT}/v1/nope/list?limit=10")
echo "$UNK" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["records"] == []
assert d["next_cursor"] is None
' || fail "unknown tenant list shape"
ok "unknown tenant returns empty record set + next_cursor:null"

# ── /v1/acme/show/{request_id} range-reads the payload ─────────────
SHOW=$("${CURL[@]}" -X GET "http://127.0.0.1:${PORT}/v1/acme/show/2")
echo "$SHOW" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
r = d["record"]
assert r["request_id"] == 2
assert r["status"] == 500
assert r["outcome"] == "handler_error"
assert r["console"] == "boom"
assert r["exception"] == "Error: kaboom"
' || fail "acme show range-read"
ok "show: range-read returned the right line including console + exception"

# Show on unknown id → 404.
CODE=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -X GET "http://127.0.0.1:${PORT}/v1/acme/show/9999")
[[ "$CODE" == "404" ]] || fail "show on unknown id: got $CODE (want 404)"
ok "show on unknown request_id → 404"

# Bad routes → 404 / 405.
CODE=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -X GET "http://127.0.0.1:${PORT}/v1/")
[[ "$CODE" == "404" ]] || fail "/v1/ should be 404 (got $CODE)"
ok "malformed route → 404"

CODE=$("${CURL[@]}" -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:${PORT}/v1/acme/list")
[[ "$CODE" == "405" ]] || fail "POST on list should be 405 (got $CODE)"
ok "POST on /list → 405"

# ── Add a new batch after startup; indexer picks it up ─────────────
python3 - "$DATA_DIR" <<'PY'
import json, os, sys, hashlib
root = sys.argv[1]
tenant, node = "acme", "00000001"
batch_id = "00000000000000000004-0001730764830000"
records = [{"request_id": 4, "received_ns": 7000, "duration_ns": 1_000,
            "method": "GET", "path": "/late", "host": "acme.test",
            "status": 200, "outcome": "ok", "deployment_id": 8,
            "console": "", "exception": ""}]
ndjson_key = f"{tenant}/{node}/{batch_id}.ndjson"
idx_key    = f"{tenant}/{node}/{batch_id}.idx.json"
payload = b""
rec_index = []
for r in records:
    line = (json.dumps(r, sort_keys=True) + "\n").encode()
    rec_index.append({**{k: r[k] for k in
        ("request_id","received_ns","duration_ns","method","path","host","status","outcome","deployment_id")},
        "offset": len(payload), "length": len(line)})
    payload += line
sidecar = {"v":1,"tenant_id":tenant,"node_id":node,"batch_id":batch_id,
           "ndjson_key":ndjson_key,"ndjson_size":len(payload),
           "ndjson_sha256":hashlib.sha256(payload).hexdigest(),
           "first_received_ns":records[0]["received_ns"],
           "last_received_ns":records[-1]["received_ns"],
           "records":rec_index}
with open(os.path.join(root, ndjson_key), "wb") as f: f.write(payload)
with open(os.path.join(root, idx_key), "w") as f: json.dump(sidecar, f)
PY
sleep 0.4
LIST_AFTER=$("${CURL[@]}" -X GET "http://127.0.0.1:${PORT}/v1/acme/list?limit=10")
echo "$LIST_AFTER" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
records = d["records"]
assert len(records) == 4, f"want 4 records, got {len(records)}: {d}"
assert records[0]["request_id"] == 4
' || fail "incremental indexing: new batch did not appear"
ok "incremental indexing: new sidecar picked up + visible via /list"

echo ""
echo "all log-server smoke checks passed"
