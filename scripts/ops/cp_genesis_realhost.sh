#!/usr/bin/env bash
# DEFINITIVE cross-host cold-multi CP genesis validation — on the 3 REAL hosts
# over the REAL private network (vRack). This is the test the 2026-06-24 outage
# actually failed ("works single-process, fails on real nodes"); loopback +
# netns can't reproduce a real-NIC/real-latency/cross-kernel issue.
#
# Run from your WORKSTATION (it ssh's to the 3 nodes — you hold the ControlMaster;
# never let the agent pkill ssh). PREREQUISITE: prod's rewind-cp services are
# STOPPED on all 3 nodes (this binds the real :9090/:9101 ports). It uses a
# THROWAWAY data dir (/tmp/cp-genesis-test) — it does NOT touch prod's directory
# store — and tears the test CPs down by PID afterward. Safe while prod is down.
#
#   HOSTS="bhs-1 bhs-2 bhs-3" IPS="10.0.0.1 10.0.0.2 10.0.0.3" \
#       bash scripts/ops/cp_genesis_realhost.sh
set -uo pipefail

read -ra H <<< "${HOSTS:?set HOSTS='ssh1 ssh2 ssh3'}"
read -ra IP <<< "${IPS:?set IPS='10.0.0.1 10.0.0.2 10.0.0.3'}"
[ "${#H[@]}" -eq 3 ] && [ "${#IP[@]}" -eq 3 ] || { echo "need exactly 3 HOSTS + 3 IPS"; exit 1; }
SSH="${SSH:-ssh -o ConnectTimeout=10 -o ServerAliveInterval=15}"
CPBIN="${CPBIN:-\$HOME/.local/bin/rewind-cp}"
DATA=/tmp/cp-genesis-test
PEERS="${IP[0]}:9101,${IP[1]}:9101,${IP[2]}:9101"
PEER_URLS="http://${IP[0]}:9090,http://${IP[1]}:9090,http://${IP[2]}:9090"
CLUSTERS="prod=http://${IP[0]}:8443,http://${IP[1]}:8443,http://${IP[2]}:8443"
declare -a PID

teardown() {
  echo "--- teardown (kill test CPs by PID, rm $DATA) ---"
  for i in 0 1 2; do
    [ -n "${PID[$i]:-}" ] && $SSH "${H[$i]}" "kill ${PID[$i]} 2>/dev/null; sleep 1; kill -9 ${PID[$i]} 2>/dev/null; rm -rf $DATA" || true
  done
}
trap teardown EXIT

echo "=== guard: prod rewind-cp must be stopped (else :9090 is busy) ==="
for i in 0 1 2; do
  busy=$($SSH "${H[$i]}" "systemctl --user is-active rewind-cp.service 2>/dev/null || true")
  [ "$busy" = "active" ] && { echo "ABORT: rewind-cp is ACTIVE on ${H[$i]} — stop it first (systemctl --user stop rewind-cp)"; exit 1; }
done

echo "=== launch test rewind-cp on each host (real ports, throwaway data) ==="
for i in 0 1 2; do
  id=$((i + 1))
  # The remote command string: local vars ($DATA/$id/$PEERS/…) expand HERE;
  # remote vars (\$HOME/\$!) are escaped to expand on the node. The node sources
  # its own common.env for S3 creds + REWIND_MOVE_SECRET, then nohup's the test CP
  # and echoes its PID (which $(...) captures).
  PID[$i]=$($SSH "${H[$i]}" "
    set -a; . \$HOME/.config/rove/common.env 2>/dev/null; set +a
    rm -rf $DATA; mkdir -p $DATA
    REWIND_RAFT_NET_DEBUG=1 REWIND_CP_NODE_ID=$id REWIND_CP_VOTERS=1,2,3 REWIND_CP_PEERS=$PEERS REWIND_CP_PEER_URLS=$PEER_URLS REWIND_CP_DATA_DIR=$DATA REWIND_CLUSTERS='$CLUSTERS' REWIND_RAFT_TICK_MS=${TICK_MS:-10} nohup $CPBIN 9090 >$DATA/cp.log 2>&1 &
    echo \$!
  ")
  echo "  ${H[$i]} (id $id, ${IP[$i]}) → test CP pid ${PID[$i]}"
done

echo "=== poll /_cp/leader for up to 30s ==="
leader=""; t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 30 ]; do
  for i in 0 1 2; do
    code=$($SSH "${H[$i]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://${IP[$i]}:9090/_cp/leader" 2>/dev/null || true)
    [ "$code" = "200" ] && { leader="${H[$i]} (${IP[$i]})"; break; }
  done
  [ -n "$leader" ] && break
  sleep 1
done

dt=$(( $(date +%s) - t0 ))
echo
if [ -n "$leader" ]; then
  echo "ELECTS ✓ — $leader leads the __directory__ group after ~${dt}s (REAL cross-host vRack)"
  echo ">>> cold-multi 3-CP genesis is validated on real hardware → proceed with 3-CP HA bring-up."
  exit 0
fi
echo "WEDGED ✗ — no CP leader within 30s on the real hosts"
echo "    This is the cross-host failure the loopback/distinct-IP runs could NOT catch."
for i in 0 1 2; do
  echo "--- ${H[$i]} (node $((i+1)), ${IP[$i]}): ALL :9101 socket states (ESTAB/SYN-SENT/SYN-RECV) ---"
  $SSH "${H[$i]}" "ss -tan 2>/dev/null | grep ':9101' || echo '  (none)'" 2>/dev/null || true
  # The raft_net dial lifecycle (REWIND_RAFT_NET_DEBUG=1): DIAL / CONNECTED /
  # connect FAILED / ACCEPT / IDENT / TEARDOWN. This tells us, per directed
  # edge, which outbound dials this node attempted and whether they ever
  # established — i.e. exactly which half of the mesh is missing and why
  # (so_error / errno). A FULL mesh here with still-no-leader = an election
  # bug, not transport; a missing edge = the dial that never completes.
  echo "--- ${H[$i]} (node $((i+1))) raft_net dial trace ---"
  $SSH "${H[$i]}" "grep -E 'DIAL|CONNECTED|FAILED|ACCEPT|IDENT|TEARDOWN' $DATA/cp.log 2>/dev/null | tail -40 || echo '  (none)'" 2>/dev/null || true
  echo "--- ${H[$i]} (node $((i+1))) cp.log tail ---"
  $SSH "${H[$i]}" "tail -20 $DATA/cp.log" 2>/dev/null || true
done
exit 1
