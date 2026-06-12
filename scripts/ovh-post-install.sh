#!/bin/bash
#
# ovh-post-install.sh — OVH installer post-installation script for the V2
# production hosts (bhs-1 / bhs-2 / bhs-3). Runs ONCE as root on first boot.
#
# Scope is deliberately minimal: deploy user + ssh key, runtime shared libs,
# the one-time root steps from scripts/systemd/v2/README.md, and the host
# firewall — which is the SOLE security boundary for the private plane
# (docs/v2-production-deploy-plan.md §2.5: raft + h2c ports have no app-layer
# auth). Everything else (env files, secrets, units, TLS cert, binaries) is
# provisioned out-of-band per the README — OVH stores this script, so it must
# never contain S3 creds / REWIND_MOVE_SECRET / REWIND_ROOT_TOKEN.
#
set -euxo pipefail

DEPLOY_USER=rove
SSH_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBXi6MzqkCfwYBzmL/WOvoL8YlpPbKi2UEGIQdhgVGRW openpgp:0x62D4D7F6'

# ── deploy user (user-scoped units + deploy.sh ssh target) ──────────────
useradd -m -s /bin/bash "$DEPLOY_USER" || true
install -d -m0700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
echo "$SSH_KEY" > "/home/$DEPLOY_USER/.ssh/authorized_keys"
chown "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh/authorized_keys"
chmod 0600 "/home/$DEPLOY_USER/.ssh/authorized_keys"

# ── runtime deps: shared libs the binaries link + deploy.sh's tools ─────
# Package names are Debian-12 era; on Debian 13 some carry t64 suffixes
# (libcurl4t64, liblmdb0t64). After first boot, `ldd ~/.local/bin/rewind`
# is the authority on what's missing.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  rsync curl ca-certificates \
  libnghttp2-14 libcurl4 libssl3 liblmdb0 zlib1g \
  nftables unattended-upgrades

# ── one-time root steps from scripts/systemd/v2/README.md ───────────────
# front binds :443/:80 unprivileged
echo 'net.ipv4.ip_unprivileged_port_start=80' > /etc/sysctl.d/99-rove.conf
sysctl --system
# user units run without an active login
loginctl enable-linger "$DEPLOY_USER"
# cgroup delegation so the units' CPUWeight/MemoryMin actually apply
install -d /etc/systemd/system/user@.service.d
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' \
  > /etc/systemd/system/user@.service.d/delegate.conf
systemctl daemon-reload

# ── firewall: public = 22/80/443 ONLY ───────────────────────────────────
# The private plane (:8443 h2c, :8501/:9101 raft, :9090 CP, :443 tenant
# door) stays CLOSED until the vRack/private-plane peers are known — open
# it peer-to-peer by uncommenting the rule below with the real interface
# and addresses, then `systemctl reload nftables`.
cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif lo accept
    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept
    tcp dport { 22, 80, 443 } accept
    # private plane — peers only (docs/v2-production-deploy-plan.md §2.5):
    # iifname "vrack0" ip saddr { <peer1>, <peer2> } tcp dport { 8443, 8501, 9090, 9101, 443 } accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
  }
}
EOF
systemctl enable --now nftables
systemctl restart nftables

# ── ssh hardening: keys only ────────────────────────────────────────────
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl reload ssh || systemctl reload sshd
