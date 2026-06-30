#!/usr/bin/env bash
# Unprivileged lock-contention profile. perf lock / BPF / sched
# tracepoints are blocked here (paranoid=2, non-root), so this uses
# ptrace tools that work on own-uid procs:
#   - eu-stack sampled in a tight loop → all-thread stack snapshots;
#     threads parked in futex_wait under a contended lock recur as
#     identical blocked stacks (poor-man's off-CPU profiler).
#   - strace -f -c → futex syscall count + time share (contention
#     magnitude). HEAVY ptrace overhead — its throughput is NOT
#     comparable to a clean run; only the futex *share* is the signal.
#
# Drives the `readonly` tenant (1 kv.get/req — the workload where 2a
# shows ~20%). Profiles the leader for a window. $BIN selects which
# binary (e.g. the saved A/B builds) so 2a-on vs 2a-off contention can
# be diffed.
#
# Args: $1 sample_secs (default 12)   Env: BIN, HOST_T (default readonly)
set -euo pipefail
if [[ -f .env ]]; then set -a; source .env; set +a; fi
SECS="${1:-12}"
HOST_T="${HOST_T:-readonly}"
TAG="${TAG:-ctn}"
WORKERS="${WORKERS:-4}"
OUT="${OUT:-$HOME/bench/ctn}"; mkdir -p "$OUT"
DATA_DIR_PREFIX="${DATA_DIR_PREFIX:-/tmp/rove-kv-ctn}"
HTTP_PORT_BASE="${HTTP_PORT_BASE:-8295}"
RAFT_PORT_BASE="${RAFT_PORT_BASE:-40395}"
BIN="${BIN:-./zig-out/bin/loop46}"
TOKEN="${ROVE_TOKEN:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
PUBLIC_SUFFIX="rewindjsapp.localhost"; SYSTEM_SUFFIX="rewindjscom.localhost"
ADMIN_HOST="app.${PUBLIC_SUFFIX}"
LOOP46_DATA="${LOOP46_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/loop46}"
TLS_CERT="$LOOP46_DATA/dev-cert.pem"; TLS_KEY="$LOOP46_DATA/dev-key.pem"
CACERT="$LOOP46_DATA/ca-root.pem"
[[ -x "$BIN" ]] || { echo "$BIN missing"; exit 2; }

. "$(dirname "$0")/../smoke/_smoke_helpers.sh"
SMOKE_TAG=kv-ctn; SMOKE_PROTO=https
init_cluster_addrs "$DATA_DIR_PREFIX" "$HTTP_PORT_BASE" "$RAFT_PORT_BASE"
export S3_KEY_PREFIX_BASE="${S3_KEY_PREFIX_BASE:-bench-ctn-$(hostname)-$(id -u)-$(date +%s)/}"
export LOOP46_SERVICES_JWT_SECRET="$(gen_jwt_secret)"
export LOOP46_ROOT_TOKEN="$TOKEN"
seed_all_dirs ./examples/loop46-demo-tenants.json

PIDS=()
for i in 0 1 2; do
  P="${HTTP_ADDRS[$i]##*:}"
  "$BIN" worker --node-id "$i" --peers "$PEERS_CSV" \
    --listen "${RAFT_ADDRS[$i]}" --http "${HTTP_ADDRS[$i]}" \
    --data-dir "${DATA_DIRS[$i]}" \
    --admin-origin "https://${ADMIN_HOST}:${P}" --admin-api-domain "$ADMIN_HOST" \
    --public-suffix "$PUBLIC_SUFFIX" --system-suffix "$SYSTEM_SUFFIX" \
    --tls-cert "$TLS_CERT" --tls-key "$TLS_KEY" --workers "$WORKERS" \
    --rate-limit-request-capacity 1000000 --rate-limit-request-refill 1000000 \
    "${RAFT_TIMING_FLAGS[@]}" >"/tmp/${SMOKE_TAG}-w${i}.out" 2>&1 &
  PIDS+=($!)
done
trap 'for p in "${PIDS[@]}" "${LOAD_PID:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done' EXIT
sleep 2
RESOLVE=(); for h in "${HTTP_ADDRS[@]}"; do p="${h##*:}"; RESOLVE+=(--resolve "${ADMIN_HOST}:${p}:127.0.0.1"); done
CURL=(curl -sS --cacert "$CACERT" "${RESOLVE[@]}")
discover_leader "$ADMIN_HOST" "$TOKEN" || exit 1
LEADER_PID="${PIDS[$LEADER_IDX]}"
echo "leader pid=$LEADER_PID port=$LEADER_PORT  bin=$BIN"
for _ in $(seq 1 30); do
  code=$("${CURL[@]}" --connect-to "${HOST_T}.${PUBLIC_SUFFIX}:${LEADER_PORT}:127.0.0.1:${LEADER_PORT}" \
    -o /dev/null -w '%{http_code}' "https://${HOST_T}.${PUBLIC_SUFFIX}:${LEADER_PORT}/?fn=handler" || echo 000)
  [[ "$code" == "200" ]] && break; sleep 0.2
done
[[ "$code" == "200" ]] || { echo "FAIL ${HOST_T} $code"; exit 1; }

# Sustained load (long enough to cover ramp + sample window).
h2load --connect-to "127.0.0.1:${LEADER_PORT}" -n 6000000 -c 10 -m 10 \
  "https://${HOST_T}.${PUBLIC_SUFFIX}:${LEADER_PORT}/?fn=handler" >"$OUT/${TAG}_h2.log" 2>&1 &
LOAD_PID=$!
sleep 3   # ramp

echo "sampling eu-stack x ~$((SECS*8)) over ${SECS}s (pid $LEADER_PID)…"
RAW="$OUT/${TAG}_stacks.txt"; : > "$RAW"
end=$((SECONDS+SECS))
while [ $SECONDS -lt $end ]; do eu-stack -p "$LEADER_PID" 2>/dev/null >> "$RAW" || true; echo "===SAMPLE===" >> "$RAW"; sleep 0.12; done

# strace futex summary on a short sub-window (heavy; separate so it
# doesn't taint the eu-stack throughput).
echo "strace -c futex summary (4s, overhead-distorted — share only)…"
timeout 5 strace -f -c -e trace=futex -p "$LEADER_PID" -o "$OUT/${TAG}_strace.txt" 2>/dev/null || true

kill "$LOAD_PID" 2>/dev/null || true
clean_rps=$(grep -oE "finished in [0-9.]+s, [0-9]+\.[0-9]+ req/s" "$OUT/${TAG}_h2.log" | head -1 || true)

echo ""
echo "==================== CONTENTION ($TAG, bin=$(basename "$BIN")) ===================="
echo "h2load (pre-strace portion): ${clean_rps:-n/a}"
echo ""
echo "-- blocked-stack histogram: threads in futex/lock-wait, by nearest app frame --"
awk '
  /===SAMPLE===/ { next }
  /^[0-9]+/      { intis=1; blocked=0; appf=""; next }   # TID line: new thread
  {
    if ($0 ~ /futex|__lll_lock_wait|pthread_mutex_lock|pthread_cond_wait|Thread\.Mutex/) blocked=1
    if (appf=="" && ($0 ~ /kvexp|manifest|kvstore|cluster|worker|raft|apply|dispatch|Manifest|Txn|Overlay/) \
        && $0 !~ /futex|lll_lock/) { appf=$0 }
    if ($0=="" && intis) { if (blocked) { gsub(/^[ \t]*#[0-9]+ *0x[0-9a-f]+ */,"",appf); c[appf]++ } intis=0 }
  }
  END { for (k in c) printf "%6d  %s\n", c[k], (k==""?"(no app frame / pure libc wait)":k) }
' "$RAW" | sort -rn | head -20
echo ""
echo "-- strace futex (overhead-distorted; look at % and calls, not time-abs) --"
grep -E "futex|% time|---|calls" "$OUT/${TAG}_strace.txt" 2>/dev/null | head -8
echo "=========================================================================="
