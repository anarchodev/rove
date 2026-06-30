#!/bin/bash
#
# vrack-setup.sh — bring up this host's vRack (private-plane) interface and
# open the private plane to the named peers. Run ONCE as root on each host,
# AFTER the server's private interface has been attached to the vRack in the
# OVH manager (Bare Metal Cloud → vRack → add the servers' private
# interfaces) or via the API (scripts/ovh-api.py).
#
# The private plane carries worker h2c (:8443), raft (:8501/:9101), CP http
# (:9090) and the tenant door (worker→front :443) — none of which have
# app-layer auth, so the nftables rule written here IS the security
# boundary (docs/architecture/configuration-and-network.md "Firewall / network plane"). It opens those ports
# to the two peer addresses on the vRack NIC only; the public interface
# stays 22/80/443.
#
# Usage: vrack-setup.sh <this-host-ip/prefix> <peer-ip,peer-ip> [iface]
#   bhs-1$ sudo ./vrack-setup.sh 10.0.0.1/24 10.0.0.2,10.0.0.3
#   bhs-2$ sudo ./vrack-setup.sh 10.0.0.2/24 10.0.0.1,10.0.0.3
#   bhs-3$ sudo ./vrack-setup.sh 10.0.0.3/24 10.0.0.1,10.0.0.2
#
# [iface] defaults to auto-detect: the physical NIC that is NOT carrying the
# default route (OVH wires the secondary NIC to the vRack). Pass it
# explicitly on hosts with more than two physical NICs. vRack is plain L2
# between the members — static addressing, no gateway, no DHCP.
set -euo pipefail

ADDR=${1:?usage: vrack-setup.sh <ip/prefix> <peer,peer> [iface]}
PEERS_CSV=${2:?usage: vrack-setup.sh <ip/prefix> <peer,peer> [iface]}
IFACE=${3:-}

# ── pick the vRack NIC ───────────────────────────────────────────────────
PUB_IF=$(ip -4 route show default | awk '{print $5; exit}')
if [[ -z $IFACE ]]; then
  CANDS=()
  for d in /sys/class/net/*; do
    n=$(basename "$d")
    [[ $n == "$PUB_IF" || $n == lo ]] && continue
    [[ -e $d/device ]] || continue   # physical NICs only — skips bond/veth/etc
    CANDS+=("$n")
  done
  if (( ${#CANDS[@]} != 1 )); then
    echo "cannot auto-pick the vRack NIC (candidates: ${CANDS[*]:-none});" \
         "pass it as the 3rd arg" >&2
    exit 1
  fi
  IFACE=${CANDS[0]}
fi
echo "public NIC: $PUB_IF — vRack NIC: $IFACE — addr: $ADDR"

# ── persistent interface config ──────────────────────────────────────────
# OVH's Debian image manages the public NIC via cloud-init + ifupdown
# (/etc/network/interfaces.d/50-cloud-init); a sibling file for the vRack
# NIC survives cloud-init re-renders. Fall back to systemd-networkd where
# ifupdown isn't present (networkd only touches interfaces it matches).
if command -v ifup >/dev/null && [[ -d /etc/network/interfaces.d ]]; then
  cat > /etc/network/interfaces.d/60-vrack <<EOF
auto $IFACE
iface $IFACE inet static
    address $ADDR
EOF
  ifdown "$IFACE" 2>/dev/null || true
  ifup "$IFACE"
else
  cat > /etc/systemd/network/60-vrack.network <<EOF
[Match]
Name=$IFACE

[Network]
Address=$ADDR
EOF
  systemctl enable --now systemd-networkd
  networkctl reload 2>/dev/null || systemctl restart systemd-networkd
fi

# ── firewall: open the private plane to the peers, on this NIC only ─────
# Idempotent: drops any previously-written tagged rule, re-inserts after
# the public-ports rule in the ovh-post-install.sh baseline.
PEERS_NFT=${PEERS_CSV//,/, }
TAG="# private-plane peers (vrack-setup.sh)"
sed -i "\\|$TAG|d" /etc/nftables.conf
sed -i "/tcp dport { 22, 80, 443 } accept/a\\    iifname \"$IFACE\" ip saddr { $PEERS_NFT } tcp dport { 8443, 8501, 9090, 9101, 443 } accept  $TAG" /etc/nftables.conf
nft -c -f /etc/nftables.conf
systemctl reload nftables

# ── verify ───────────────────────────────────────────────────────────────
ip -4 addr show dev "$IFACE"
IFS=, read -ra PEERS <<< "$PEERS_CSV"
for p in "${PEERS[@]}"; do
  if ping -c1 -W2 "$p" >/dev/null 2>&1; then
    echo "peer $p: reachable"
  else
    echo "peer $p: NOT reachable (expected until that host runs this script too)"
  fi
done
