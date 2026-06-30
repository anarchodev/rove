#!/usr/bin/env bash
# Cross-host(-ish) cold-multi CP genesis validation via network namespaces.
#
# The loopback test (cp_genesis_3node.py) proves the mechanism but on 127.0.0.1,
# which short-circuits the real bind-to-IP + cross-socket transport path. The
# 2026-06-24 prod failure was cross-host. This stages the closest local proxy:
# 3 netns with DISTINCT IPs (10.99.0.1/2/3) on a bridge, NAT for S3 reachability,
# tc-netem latency, and the PROD raft cadence (REWIND_RAFT_TICK_MS=10). It then
# cold-starts 3 real rewind-cp processes (static voters {1,2,3}) and asks whether
# the __directory__ group elects.
#
# Run from the repo/worktree root:  sudo bash scripts/ops/cp_genesis_netns.sh [delay_ms]
set -uo pipefail

DELAY_MS="${1:-0.3}"          # one-way netem delay per hop (~2x = RTT). vRack ≈ sub-ms.
SUBNET=10.99.0
BR=br-cpg
NS=(cpg1 cpg2 cpg3)
PIDS=()
DATA=/tmp/cpnetns
LOGD=/tmp/cpnetns-log
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CP="$HERE/zig-out/bin/rewind-cp"

cleanup() {
  echo "--- cleanup ---"
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
  sleep 0.5
  for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
  for n in "${NS[@]}"; do ip netns del "$n" 2>/dev/null; done
  ip link del "$BR" 2>/dev/null
  iptables -t nat -D POSTROUTING -s "$SUBNET.0/24" ! -d "$SUBNET.0/24" -j MASQUERADE 2>/dev/null
}
trap cleanup EXIT

[ -x "$CP" ] || { echo "build first: zig build rewind-cp -Doptimize=ReleaseFast"; exit 1; }
[ -f "$HERE/.env" ] || { echo "need $HERE/.env (S3 creds)"; exit 1; }
set -a; . "$HERE/.env"; set +a

echo "=== setup: bridge + 3 netns (delay ${DELAY_MS}ms/hop) ==="
cleanup 2>/dev/null
ip link add "$BR" type bridge
ip addr add "$SUBNET.254/24" dev "$BR"
ip link set "$BR" up
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s "$SUBNET.0/24" ! -d "$SUBNET.0/24" -j MASQUERADE
UPLINK=$(ip route show default | awk '{print $5; exit}')
echo "uplink for NAT: ${UPLINK:-none}"

for i in 1 2 3; do
  n="cpg$i"
  ip netns add "$n"
  ip link add "veth$i" type veth peer name "veth${i}br"
  ip link set "veth$i" netns "$n"
  ip link set "veth${i}br" master "$BR"; ip link set "veth${i}br" up
  ip netns exec "$n" ip addr add "$SUBNET.$i/24" dev "veth$i"
  ip netns exec "$n" ip link set "veth$i" up
  ip netns exec "$n" ip link set lo up
  ip netns exec "$n" ip route add default via "$SUBNET.254"
  # latency on both ends so every cross-ns hop is delayed
  tc qdisc add dev "veth${i}br" root netem delay "${DELAY_MS}ms" 2>/dev/null
  ip netns exec "$n" tc qdisc add dev "veth$i" root netem delay "${DELAY_MS}ms" 2>/dev/null
  rm -rf "$DATA/$i"; mkdir -p "$DATA/$i" "$LOGD"
done

PEERS="$SUBNET.1:9101,$SUBNET.2:9101,$SUBNET.3:9101"
PEER_URLS="http://$SUBNET.1:9090,http://$SUBNET.2:9090,http://$SUBNET.3:9090"
CLUSTERS="cluster-1=http://$SUBNET.1:8443,http://$SUBNET.2:8443,http://$SUBNET.3:8443"

echo "=== launch 3 rewind-cp (cold-multi voters=1,2,3, tick=10ms) ==="
for i in 1 2 3; do
  ip netns exec "cpg$i" env \
    REWIND_CP_NODE_ID="$i" REWIND_CP_VOTERS="1,2,3" \
    REWIND_CP_PEERS="$PEERS" REWIND_CP_PEER_URLS="$PEER_URLS" \
    REWIND_CP_DATA_DIR="$DATA/$i" REWIND_MOVE_SECRET="${REWIND_MOVE_SECRET:-rewindmovesecretpadding0123456789abcdef0}" \
    REWIND_CLUSTERS="$CLUSTERS" REWIND_RAFT_TICK_MS=10 \
    "$CP" 9090 >"$LOGD/cp$i.log" 2>&1 &
  PIDS+=("$!")
done

echo "=== poll /_cp/leader for up to 25s ==="
leader=0; t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 25 ]; do
  for i in 1 2 3; do
    code=$(ip netns exec cpg1 curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://$SUBNET.$i:9090/_cp/leader" 2>/dev/null)
    if [ "$code" = "200" ]; then leader=$i; break; fi
  done
  [ "$leader" != "0" ] && break
  sleep 0.5
done

dt=$(( $(date +%s) - t0 ))
echo
if [ "$leader" != "0" ]; then
  echo "ELECTS ✓ — node $leader leads the __directory__ group after ~${dt}s (cross-ns, ${DELAY_MS}ms/hop)"
  echo ">>> cold-multi CP genesis holds across distinct IPs + latency."
  exit 0
fi
echo "WEDGED ✗ — no CP leader within 25s (cross-ns, ${DELAY_MS}ms/hop)"
for i in 1 2 3; do
  echo "--- cp$i log tail ---"
  grep -iE "leader|campaign|vote|elect|multi-node|listening|error|warn" "$LOGD/cp$i.log" | tail -10
done
exit 1
