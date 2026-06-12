# V2 systemd units — production deploy

User-scoped systemd units for the V2 three-process stack, **replacing the
retired V1 four-binary units** (`loop46`/files/log/sse, deleted at this commit).
Topology, spec, and the full runbook: [`docs/v2-production-deploy-plan.md`](../../../docs/v2-production-deploy-plan.md).

## The 3 processes (co-located, per host)

| Unit | Binary | Listens | Role |
|---|---|---|---|
| `rewind-cp.service` | `rewind-cp` | `:9090` + raft `:9101` | directory raft + `/_control` + `/_cp` |
| `rewind-worker.service` | `rewind` | `:8443` h2c + raft `:8501` | DP multi-raft + JS dispatch |
| `rewind-front.service` | `rewind-front` | `:443` + `:80` | stateless public TLS edge |

Start order is encoded via `After=`/`Wants=`: **cp → worker → front**.

## First-time install (per host)

Host bootstrap (deploy user, runtime libs, the root-level one-time steps
below, firewall) is automated by
[`scripts/ovh-post-install.sh`](../../ovh-post-install.sh) — feed it to the
OVH installer as the post-installation script. The steps here pick up from
there (binaries, env/secrets, units, TLS); on a bootstrapped host, steps 5–6's
root parts are already done.

```bash
# 1. binaries (or just run scripts/deploy.sh from your workstation)
zig build rewind rewind-cp rewind-front -Doptimize=ReleaseFast
install -D -m0755 zig-out/bin/rewind       ~/.local/bin/rewind
install -D -m0755 zig-out/bin/rewind-cp    ~/.local/bin/rewind-cp
install -D -m0755 zig-out/bin/rewind-front ~/.local/bin/rewind-front

# 2. env (secrets — chmod 0600; NOT pushed by deploy.sh)
install -D -m0600 scripts/systemd/v2/common.env.example ~/.config/rove/common.env
install -D -m0600 scripts/systemd/v2/node.env.example   ~/.config/rove/node.env
$EDITOR ~/.config/rove/common.env   # S3 creds, secrets, topology, suffixes
$EDITOR ~/.config/rove/node.env     # this host's REWIND_NODE_ID / REWIND_CP_NODE_ID

# 3. units
install -D -m0644 scripts/systemd/v2/rewind-cp.service     ~/.config/systemd/user/rewind-cp.service
install -D -m0644 scripts/systemd/v2/rewind-worker.service ~/.config/systemd/user/rewind-worker.service
install -D -m0644 scripts/systemd/v2/rewind-front.service  ~/.config/systemd/user/rewind-front.service

# 4. TLS: drop the platform wildcard cert/key
install -D -m0644 platform.crt ~/.rove/tls/platform.crt
install -D -m0600 platform.key ~/.rove/tls/platform.key

# 5. privileged ports for the front (one-time, recommended):
echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-rove.conf
sudo sysctl --system

# 6. linger (so units run without an active login) + enable
loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now rewind-cp.service rewind-worker.service rewind-front.service
```

## Ongoing deploys

Use [`scripts/deploy.sh`](../../deploy.sh) from your workstation — it builds,
runs the test gate, and does a quorum-safe rolling restart across all 3 nodes
(one at a time, health-gated). It pushes **binaries only**; env/secrets are
provisioned out-of-band by the steps above.

## Notes

- **`%h` is NOT expanded inside the env files** (systemd `EnvironmentFile` is
  plain `KEY=VALUE`). Anything needing the home dir (data dirs, TLS paths) is set
  via `Environment=` in the unit, where specifiers do expand.
- **The private plane has no app-layer auth** (raft `:8501`/`:9101`, worker
  `:8443` h2c). Firewall those to the 3 nodes only — see the security note in the
  plan §2.5, and set strong `REWIND_MOVE_SECRET` + `REWIND_ROOT_TOKEN`.
- **Resource directives** (`CPUWeight`/`MemoryHigh`) need cgroup-v2 controller
  delegation to the user manager to take effect; they're harmless if ignored.
