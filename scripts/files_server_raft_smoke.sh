#!/usr/bin/env bash
# files-server own raft group smoke (production.md #1.4 step 1).
#
# Stands up a 3-node files-server-standalone cluster — independent
# from the loop46 worker raft group — and verifies:
#
#   1. The cluster spawns + binds 3 raft listeners + 3 HTTP listeners.
#   2. willemt elects a leader from among the 3 voters.
#   3. The standalone HTTP /v1/instance_id/* path still works
#      end-to-end (auth + a basic upload), proving raft instantiation
#      didn't break the existing serving path.
#
# What this does NOT verify (later steps):
#   - Manifest writes routing through Cluster.proposeWriteSet
#     (still goes through S3 today).
#   - Snapshot + log compaction at scale.
#   - Send-snapshot peer-to-peer for fall-behind followers.
#
# Uses raft port base 41090 + http port base 9090 to avoid colliding
# with the loop46 worker bench (40470 / 8470 ranges).

set -euo pipefail

BIN="${BIN:-./zig-out/bin/files-server-standalone}"
if [[ ! -x "$BIN" ]]; then
    echo "error: $BIN missing — run 'zig build install' first" >&2
    exit 2
fi
command -v sqlite3 >/dev/null 2>&1 || { echo "error: sqlite3 not in PATH" >&2; exit 2; }

PREFIX="${PREFIX:-/tmp/rove-fs-raft-smoke}"
HTTP_BASE="${HTTP_BASE:-9090}"
RAFT_BASE="${RAFT_BASE:-41090}"

if [[ "$(uname -s)" == "Darwin" ]]; then
    LOOP46_DATA="${LOOP46_DATA:-$HOME/Library/Application Support/loop46}"
else
    LOOP46_DATA="${LOOP46_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/loop46}"
fi
TLS_CERT="$LOOP46_DATA/dev-cert.pem"
TLS_KEY="$LOOP46_DATA/dev-key.pem"
CACERT="$LOOP46_DATA/ca-root.pem"

# Source .env for AWS / S3 creds — files-server-standalone still
# needs the blob backend (bytecodes go to S3).
__smoke_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${__smoke_repo_root}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${__smoke_repo_root}/.env"
    set +a
fi
export S3_KEY_PREFIX_BASE="smoke-fs-raft-$(hostname)-$(id -u)/"

# 3-node cluster setup. Voters at indices 0/1/2.
HTTP_ADDRS=(); RAFT_ADDRS=(); DATA_DIRS=()
for i in 0 1 2; do
    HTTP_ADDRS+=("127.0.0.1:$((HTTP_BASE + i))")
    RAFT_ADDRS+=("127.0.0.1:$((RAFT_BASE + i))")
    DATA_DIRS+=("${PREFIX}-${i}")
done
rm -rf "${DATA_DIRS[@]}"
PEERS_CSV=$(IFS=,; echo "${RAFT_ADDRS[*]}")
echo "peers: $PEERS_CSV"

# JWT secret shared across the 3 standalone instances. Same key
# the loop46 worker would use when handing tokens to clients;
# here we just need it set so each instance accepts requests.
export LOOP46_SERVICES_JWT_SECRET=$(head -c32 /dev/urandom | xxd -p | tr -d '\n')

PIDS=()
for i in 0 1 2; do
    "$BIN" \
        --data-dir "${DATA_DIRS[$i]}" \
        --listen "${HTTP_ADDRS[$i]}" \
        --tls-cert "$TLS_CERT" \
        --tls-key "$TLS_KEY" \
        --cors-origin "https://app.loop46.localhost" \
        --raft-node-id "$i" \
        --raft-peers "$PEERS_CSV" \
        --raft-listen "${RAFT_ADDRS[$i]}" \
        --raft-election-timeout-ms 200 \
        --raft-heartbeat-ms 50 \
        >"/tmp/fs-raft-smoke-worker-${i}.out" 2>&1 &
    PIDS+=($!)
done
trap '
    for p in "${PIDS[@]}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    for p in "${PIDS[@]}"; do
        [ -n "$p" ] && wait "$p" 2>/dev/null || true
    done
' EXIT
sleep 3

# ── Verify each node booted + has a raft.log.db ───────────────────
for i in 0 1 2; do
    if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
        echo "FAIL: node $i (PID ${PIDS[$i]}) exited" >&2
        echo "--- log ---" >&2
        tail -30 "/tmp/fs-raft-smoke-worker-${i}.out" >&2
        exit 1
    fi
    if [[ ! -f "${DATA_DIRS[$i]}/raft.log.db" ]]; then
        echo "FAIL: node $i has no raft.log.db at ${DATA_DIRS[$i]}/" >&2
        exit 1
    fi
done
echo "ok  3 files-server-standalone processes alive + raft.log.db files exist"

# ── Verify the raft listener actually bound + persisted state ─────
#
# Each node's raft.log.db should exist + be in WAL mode + have
# auto_vacuum=INCREMENTAL set (the contract from #1's compaction
# wiring). Validates the Cluster.init path drove RaftLog.open
# correctly + the per-node raft network is listening.
for i in 0 1 2; do
    db="${DATA_DIRS[$i]}/raft.log.db"
    av=$(sqlite3 "$db" "PRAGMA auto_vacuum;" 2>/dev/null || echo "?")
    jm=$(sqlite3 "$db" "PRAGMA journal_mode;" 2>/dev/null || echo "?")
    if [[ "$av" != "2" ]]; then
        echo "FAIL: node $i raft.log.db auto_vacuum=$av (want 2 = INCREMENTAL)" >&2
        exit 1
    fi
    if [[ "$jm" != "wal" ]]; then
        echo "FAIL: node $i raft.log.db journal_mode=$jm (want wal)" >&2
        exit 1
    fi
done
echo "ok  3 raft.log.db files in WAL + INCREMENTAL auto_vacuum"

# ── Verify the raft TCP listeners are open ────────────────────────
for i in 0 1 2; do
    addr="${RAFT_ADDRS[$i]}"
    host="${addr%:*}"
    port="${addr##*:}"
    if ! (echo > /dev/tcp/$host/$port) 2>/dev/null; then
        echo "FAIL: node $i raft listener at $addr not accepting connections" >&2
        exit 1
    fi
done
echo "ok  3 raft TCP listeners accepting connections"

# ── Mint a JWT to call the /_system/leader endpoint ──────────────
mint_jwt() {
    LOOP46_SERVICES_JWT_SECRET="$LOOP46_SERVICES_JWT_SECRET" python3 - <<'PY'
import base64, hmac, hashlib, json, os, time
secret = bytes.fromhex(os.environ["LOOP46_SERVICES_JWT_SECRET"])
header = b'{"alg":"HS256","typ":"JWT"}'
payload = json.dumps({"exp": int(time.time() * 1000) + 5 * 60 * 1000}).encode()
def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
signing_input = b64u(header) + "." + b64u(payload)
sig = hmac.new(secret, signing_input.encode(), hashlib.sha256).digest()
print(signing_input + "." + b64u(sig))
PY
}
JWT=$(mint_jwt)

# ── Verify leader election via /_system/leader ──────────────────
#
# Probe each node. Exactly one should return 200 ("leader\n");
# the other two return 503 ("not leader..."). With election
# timeout 200ms, election lands well within 2s on a clean cluster.
LEADER_NODE=""
LEADER_COUNT=0
FOLLOWER_COUNT=0
for tries in $(seq 1 30); do
    LEADER_NODE=""
    LEADER_COUNT=0
    FOLLOWER_COUNT=0
    for i in 0 1 2; do
        addr="${HTTP_ADDRS[$i]}"
        port="${addr##*:}"
        code=$(curl -sS --cacert "$CACERT" --max-time 2 -o /dev/null -w '%{http_code}' \
            -H "Authorization: Bearer $JWT" \
            "https://127.0.0.1:${port}/_system/leader" 2>/dev/null || echo 000)
        if [[ "$code" == "200" ]]; then
            LEADER_NODE="$i"
            LEADER_COUNT=$((LEADER_COUNT + 1))
        elif [[ "$code" == "503" ]]; then
            FOLLOWER_COUNT=$((FOLLOWER_COUNT + 1))
        fi
    done
    if [[ "$LEADER_COUNT" == "1" && "$FOLLOWER_COUNT" == "2" ]]; then
        break
    fi
    sleep 0.3
done

if [[ "$LEADER_COUNT" != "1" ]]; then
    echo "FAIL: expected 1 leader + 2 followers, got leaders=$LEADER_COUNT followers=$FOLLOWER_COUNT" >&2
    for i in 0 1 2; do
        echo "--- node $i log (last 20 lines) ---" >&2
        tail -20 "/tmp/fs-raft-smoke-worker-${i}.out" >&2
    done
    exit 1
fi
echo "ok  raft elected node $LEADER_NODE as leader (1 leader + 2 followers via /_system/leader)"

# ── Verify propose-and-wait + replication via /_system/cluster-* ──
#
# Write a kv pair through the leader's /_system/cluster-put and
# read it back from EVERY node's /_system/cluster-get. Validates:
#   - Leader's writeset envelope round-trips raft commit.
#   - Apply path runs on every node (no leader-skip on type 2).
#   - Local cluster store is populated on followers, readable
#     without a raft round-trip.
LEADER_PORT="${HTTP_ADDRS[$LEADER_NODE]##*:}"
TEST_KEY="hello-$(date +%s%N)"
TEST_VALUE="raft-replicated-$(hostname)"
PUT_BODY="{\"store\":\"acme\",\"key\":\"$TEST_KEY\",\"value\":\"$TEST_VALUE\"}"

put_resp=$(curl -sS --cacert "$CACERT" --max-time 10 \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d "$PUT_BODY" \
    "https://127.0.0.1:${LEADER_PORT}/_system/cluster-put" 2>&1)
if ! echo "$put_resp" | grep -q "committed at seq="; then
    echo "FAIL: cluster-put response unexpected: $put_resp" >&2
    exit 1
fi
echo "ok  leader: $put_resp"

# Followers may need a beat to apply. Loop with a small budget.
for try in $(seq 1 20); do
    all_match=1
    for i in 0 1 2; do
        port="${HTTP_ADDRS[$i]##*:}"
        got=$(curl -sS --cacert "$CACERT" --max-time 2 \
            -H "Authorization: Bearer $JWT" \
            "https://127.0.0.1:${port}/_system/cluster-get/acme/$TEST_KEY" 2>/dev/null || echo "")
        if [[ "$got" != "$TEST_VALUE" ]]; then
            all_match=0
            break
        fi
    done
    if [[ "$all_match" == "1" ]]; then break; fi
    sleep 0.2
done

if [[ "$all_match" != "1" ]]; then
    echo "FAIL: not all nodes have the replicated key. Per-node values:" >&2
    for i in 0 1 2; do
        port="${HTTP_ADDRS[$i]##*:}"
        got=$(curl -sS --cacert "$CACERT" --max-time 2 \
            -H "Authorization: Bearer $JWT" \
            "https://127.0.0.1:${port}/_system/cluster-get/acme/$TEST_KEY" 2>/dev/null || echo "<error>")
        echo "  node $i: $got" >&2
    done
    exit 1
fi
echo "ok  all 3 nodes replicated $TEST_KEY (write committed at leader, read from local store on every node)"

# ── Followers must reject writes ──────────────────────────────────
for i in 0 1 2; do
    [[ "$i" == "$LEADER_NODE" ]] && continue
    port="${HTTP_ADDRS[$i]##*:}"
    code=$(curl -sS --cacert "$CACERT" --max-time 2 -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $JWT" \
        -H "Content-Type: application/json" \
        -d "$PUT_BODY" \
        "https://127.0.0.1:${port}/_system/cluster-put" 2>/dev/null || echo 000)
    if [[ "$code" != "503" ]]; then
        echo "FAIL: follower $i accepted cluster-put (status=$code, want 503)" >&2
        exit 1
    fi
done
echo "ok  followers reject /_system/cluster-put with 503"

# ── Manifest fetch endpoint (production.md #1.4 step 4 setup) ─────
#
# Proves loop46 worker's HTTP-backed manifest_backend will work:
#   1. Write a manifest-shaped row through the leader's
#      /_system/cluster-put — store id = tenant id, key =
#      `deployment/{N:020x}/manifest`, value = arbitrary bytes.
#   2. After replication, fetch /v1/{tenant}/deployments/{N:hex}/manifest.bin
#      from EVERY node and verify the bytes round-trip exactly.
#   3. 404 path: an unknown deployment id returns 404 (not 500),
#      so the worker can distinguish "this deploy doesn't exist"
#      from "the cluster is broken."
#
# Hex is zero-padded to 20 nibbles to match the
# `deployment/{x:0>20}/manifest` key the manifest writer uses.
MANIFEST_TENANT="manifest-test-$(date +%s)"
MANIFEST_DEP_ID=42
MANIFEST_KEY=$(printf "deployment/%020x/manifest" "$MANIFEST_DEP_ID")
# The /_system/cluster-put debug helper has a naive JSON parser
# (jsonStringField) that doesn't handle escaped quotes — fine for
# the smoke since manifest.bin's job is byte-fidelity round-trip,
# not JSON validity. Real callers (writeManifestThroughCluster in
# files_server/bootstrap.zig) build the WriteSet directly and
# bypass this parser.
MANIFEST_BODY="manifest-body-bytes-$(date +%s%N)"
put_body="{\"store\":\"$MANIFEST_TENANT\",\"key\":\"$MANIFEST_KEY\",\"value\":\"$MANIFEST_BODY\"}"
put_resp=$(curl -sS --cacert "$CACERT" --max-time 10 \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d "$put_body" \
    "https://127.0.0.1:${LEADER_PORT}/_system/cluster-put" 2>&1)
if ! echo "$put_resp" | grep -q "committed at seq="; then
    echo "FAIL: manifest cluster-put response unexpected: $put_resp" >&2
    exit 1
fi

# Wait for replication then fetch from every node via the
# manifest.bin route.
MANIFEST_HEX=$(printf "%x" "$MANIFEST_DEP_ID")
for try in $(seq 1 20); do
    all_match=1
    for i in 0 1 2; do
        port="${HTTP_ADDRS[$i]##*:}"
        got=$(curl -sS --cacert "$CACERT" --max-time 2 \
            -H "Authorization: Bearer $JWT" \
            "https://127.0.0.1:${port}/${MANIFEST_TENANT}/deployments/${MANIFEST_HEX}/manifest.bin" 2>/dev/null || echo "")
        if [[ "$got" != "$MANIFEST_BODY" ]]; then
            all_match=0
            break
        fi
    done
    if [[ "$all_match" == "1" ]]; then break; fi
    sleep 0.2
done
if [[ "$all_match" != "1" ]]; then
    echo "FAIL: not all nodes serve the manifest via manifest.bin route. Per-node:" >&2
    for i in 0 1 2; do
        port="${HTTP_ADDRS[$i]##*:}"
        got=$(curl -sS --cacert "$CACERT" --max-time 2 \
            -H "Authorization: Bearer $JWT" \
            "https://127.0.0.1:${port}/${MANIFEST_TENANT}/deployments/${MANIFEST_HEX}/manifest.bin" 2>/dev/null || echo "<error>")
        echo "  node $i: ${got:0:80}" >&2
    done
    exit 1
fi
echo "ok  all 3 nodes serve raft-replicated manifest via /v1/{tenant}/deployments/{N:hex}/manifest.bin"

# 404 sanity — same tenant, different (non-existent) deploy id.
miss_code=$(curl -sS --cacert "$CACERT" --max-time 2 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $JWT" \
    "https://127.0.0.1:${LEADER_PORT}/${MANIFEST_TENANT}/deployments/deadbeef/manifest.bin" 2>/dev/null || echo 000)
if [[ "$miss_code" != "404" ]]; then
    echo "FAIL: missing-deployment manifest.bin should 404, got $miss_code" >&2
    exit 1
fi
echo "ok  manifest.bin 404s on unknown deployment id"

# ── PUT manifest.bin: real-shaped manifest write through raft ─────
#
# Productized companion to the GET — takes raw bytes (no JSON
# escaping needed), proposes through the cluster, returns the
# committed seq. This is what the bench harness uses to seed N
# tenants without the full upload + deploy customer flow.
PUT_TENANT="put-manifest-test-$(date +%s)"
PUT_DEP_ID=7
PUT_HEX=$(printf "%x" "$PUT_DEP_ID")
PUT_BODY='{"version":1,"entries":[{"path":"hello.js","kind":"handler","content_type":"application/javascript","hash":"abc123"}]}'

put_resp=$(curl -sS --cacert "$CACERT" --max-time 10 \
    -X PUT \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "$PUT_BODY" \
    "https://127.0.0.1:${LEADER_PORT}/${PUT_TENANT}/deployments/${PUT_HEX}/manifest.bin" 2>&1)
if ! echo "$put_resp" | grep -q "committed at seq="; then
    echo "FAIL: PUT manifest.bin response unexpected: $put_resp" >&2
    exit 1
fi
echo "ok  PUT manifest.bin: $put_resp"

# Verify the manifest replicated and round-trips byte-for-byte
# through GET on every node.
for try in $(seq 1 20); do
    all_match=1
    for i in 0 1 2; do
        port="${HTTP_ADDRS[$i]##*:}"
        got=$(curl -sS --cacert "$CACERT" --max-time 2 \
            -H "Authorization: Bearer $JWT" \
            "https://127.0.0.1:${port}/${PUT_TENANT}/deployments/${PUT_HEX}/manifest.bin" 2>/dev/null || echo "")
        if [[ "$got" != "$PUT_BODY" ]]; then
            all_match=0
            break
        fi
    done
    if [[ "$all_match" == "1" ]]; then break; fi
    sleep 0.2
done
if [[ "$all_match" != "1" ]]; then
    echo "FAIL: PUT manifest didn't replicate byte-for-byte. Per-node:" >&2
    for i in 0 1 2; do
        port="${HTTP_ADDRS[$i]##*:}"
        got=$(curl -sS --cacert "$CACERT" --max-time 2 \
            -H "Authorization: Bearer $JWT" \
            "https://127.0.0.1:${port}/${PUT_TENANT}/deployments/${PUT_HEX}/manifest.bin" 2>/dev/null || echo "<error>")
        echo "  node $i: ${got:0:80}" >&2
    done
    exit 1
fi
echo "ok  PUT-then-GET manifest round-trips byte-for-byte across all 3 nodes"

# Followers reject PUT.
for i in 0 1 2; do
    [[ "$i" == "$LEADER_NODE" ]] && continue
    port="${HTTP_ADDRS[$i]##*:}"
    code=$(curl -sS --cacert "$CACERT" --max-time 2 -o /dev/null -w '%{http_code}' \
        -X PUT \
        -H "Authorization: Bearer $JWT" \
        --data-binary "$PUT_BODY" \
        "https://127.0.0.1:${port}/${PUT_TENANT}/deployments/${PUT_HEX}/manifest.bin" 2>/dev/null || echo 000)
    if [[ "$code" != "503" ]]; then
        echo "FAIL: follower $i accepted PUT manifest.bin (status=$code, want 503)" >&2
        exit 1
    fi
done
echo "ok  followers reject PUT manifest.bin with 503"

# ── POST /_system/manifests/batch — bulk manifest fetch ──────────
#
# Loop46 worker uses this at cold-start. Build a request with 3
# tenants (2 we just wrote, 1 that doesn't exist) and verify the
# response contains the right bytes for each + zero-length
# manifest_len for the missing one.
echo "batch manifest fetch test:"
BATCH_REQ=$(mktemp --suffix=.bin)
python3 - <<PY
import struct, sys, os
out = open("$BATCH_REQ", "wb")
tenants = [
    ("$MANIFEST_TENANT", $MANIFEST_DEP_ID, True),    # exists, 'manifest body bytes'
    ("$PUT_TENANT",      $PUT_DEP_ID,      True),    # exists, real-shaped json
    ("nonexistent-tenant", 99,             False),   # missing
]
out.write(struct.pack("<I", len(tenants)))
for tid, dep_id, _ in tenants:
    out.write(struct.pack("<H", len(tid)))
    out.write(tid.encode())
    out.write(struct.pack("<Q", dep_id))
out.close()
PY

BATCH_RESP=$(mktemp --suffix=.bin)
batch_code=$(curl -sS --cacert "$CACERT" --max-time 10 \
    -X POST \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@$BATCH_REQ" \
    -o "$BATCH_RESP" -w '%{http_code}' \
    "https://127.0.0.1:${LEADER_PORT}/_system/manifests/batch" 2>/dev/null || echo 000)
if [[ "$batch_code" != "200" ]]; then
    echo "FAIL: batch endpoint returned $batch_code" >&2
    cat "$BATCH_RESP" >&2
    exit 1
fi

# Parse response: [u32 count] then per-tenant [u16 id_len][id][u32 manifest_len][manifest_bytes]
python3 - <<PY
import struct, sys
with open("$BATCH_RESP", "rb") as f:
    data = f.read()
pos = 0
count = struct.unpack_from("<I", data, pos)[0]; pos += 4
assert count == 3, f"expected 3 entries, got {count}"
expected = {
    "$MANIFEST_TENANT": "$MANIFEST_BODY",
    "$PUT_TENANT": '$PUT_BODY',
    "nonexistent-tenant": None,
}
seen = {}
for _ in range(count):
    id_len = struct.unpack_from("<H", data, pos)[0]; pos += 2
    tid = data[pos:pos+id_len].decode(); pos += id_len
    mf_len = struct.unpack_from("<I", data, pos)[0]; pos += 4
    if mf_len == 0:
        seen[tid] = None
    else:
        seen[tid] = data[pos:pos+mf_len].decode()
        pos += mf_len

for tid, want in expected.items():
    got = seen.get(tid, "MISSING")
    if want is None and got is not None:
        print(f"FAIL: {tid} expected absent, got {got!r}", file=sys.stderr)
        sys.exit(1)
    if want is not None and got != want:
        print(f"FAIL: {tid} expected {want!r}, got {got!r}", file=sys.stderr)
        sys.exit(1)
print(f"  parsed {count} entries; 2 manifests + 1 absent verified")
PY
rm -f "$BATCH_REQ" "$BATCH_RESP"
echo "ok  POST /_system/manifests/batch returns binary-packed manifests + handles misses"

echo ""
echo "PASS files-server raft smoke"
echo "      (init, listeners, leader election, propose-replicate-read,"
echo "      manifest.bin fetch + PUT, batch fetch, and follower-reject"
echo "      all verified end-to-end)"
