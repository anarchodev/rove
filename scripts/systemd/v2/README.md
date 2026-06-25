# V2 systemd units — production deploy

User-scoped systemd units for the V2 three-process stack, **replacing the
retired V1 four-binary units** (`loop46`/files/log/sse, deleted at this commit).
Topology, spec, and the full runbook: [`docs/v2-production-deploy-plan.md`](../../../docs/v2-production-deploy-plan.md).

## The 3 processes (co-located, per host)

| Unit | Binary | Listens | Role |
|---|---|---|---|
| `rewind-cp.service` | `rewind-cp` | `:9090` + raft `:9101` | directory raft + `/_control` + `/_cp` |
| `rewind-worker.service` | `rewind-worker` | `:8443` h2c + raft `:8501` | DP multi-raft + JS dispatch |
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
zig build rewind-worker rewind-cp rewind-front -Doptimize=ReleaseFast
install -D -m0755 zig-out/bin/rewind-worker ~/.local/bin/rewind-worker
install -D -m0755 zig-out/bin/rewind-cp    ~/.local/bin/rewind-cp
install -D -m0755 zig-out/bin/rewind-front ~/.local/bin/rewind-front

# 2. env (secrets — chmod 0600; NOT pushed by deploy.sh)
#    Pick the profile — see "Genesis vs rolling" below:
#      from EMPTY (new / torn-down cluster) → the *.genesis.example pair
#      onto a RUNNING cluster               → the plain *.example pair
install -D -m0600 scripts/systemd/v2/common.env.genesis.example ~/.config/rove/common.env
install -D -m0600 scripts/systemd/v2/node.env.genesis.example   ~/.config/rove/node.env
$EDITOR ~/.config/rove/common.env   # S3 creds, secrets, topology, suffixes
$EDITOR ~/.config/rove/node.env     # this host's REWIND_NODE_ID / _CP_NODE_ID / _RAFT_ADDR

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

## Private plane (vRack) — one-time, before the env files are real

The `10.0.0.x` addresses in `common.env.example` live on the OVH vRack
between the 3 hosts. The post-install firewall ships with those ports
closed; this step opens them peer-to-peer.

1. Activate a vRack (free with the servers) and attach each server's
   **private** network interface to it — OVH Manager → Bare Metal Cloud →
   vRack → add the 3 servers — or via the API
   ([`scripts/ovh-api.py`](../../ovh-api.py)).
2. On each host, as root, with that host's IP and the other two as peers:

   ```bash
   sudo scripts/vrack-setup.sh 10.0.0.1/24 10.0.0.2,10.0.0.3   # bhs-1
   ```

   This configures the private NIC (static, no gateway — vRack is plain
   L2) and opens the §2.5 private-plane ports (8443/8501/9090/9101 + 443
   tenant door) to the two peers on that NIC only.
3. Verify from each host: `ping 10.0.0.N` for both peers, and from
   *outside* confirm the public IP still answers only 22/80/443. The
   nftables peer rule is the **sole** security boundary for these ports
   (no app-layer auth — deploy plan §2.5).

## Genesis vs rolling: two modes, two env profiles

A cluster is brought up **once from empty** (genesis), then **upgraded in place**
(rolling). They use different worker env, and mixing them up is unsafe — so each
has its own `*.example`:

| | Genesis (from empty) | Rolling (running cluster) |
|---|---|---|
| Env | `common.env.genesis.example` + `node.env.genesis.example` | `common.env.example` + `node.env.example` |
| Worker membership | **self-only**: `REWIND_RAFT_ADDR`, no `REWIND_VOTERS`/`REWIND_PEERS` → groups born `{1}` and grown | static `REWIND_VOTERS`/`REWIND_PEERS` |
| CP reconciler | `REWIND_CP_RECONCILE_MEMBERSHIP=1` (grows tenant groups) | off (or on as a healer) |
| Driven by | `rewind-ops genesis` (below) | `scripts/deploy.sh` |

The CP **directory** group is cold-multi static in *both* profiles
(`REWIND_CP_VOTERS`/`_PEERS`) — a born-`{1,2,3}` group that elects on its own.
The genesis profile is also steady-state-safe: tenant-group membership is durable
in the raft WAL, so you do **not** have to swap back to the rolling env after the
grow.

### Cold genesis bring-up (from empty)

1. Install **binaries** + the **`*.genesis.example`** env (steps 1–4 above) + units, on all 3 hosts.
2. `systemctl --user start rewind-cp rewind-worker rewind-front` on all 3 — the
   CP directory group elects (cold-multi); workers boot self-only and idle,
   holding no tenant groups yet.
3. From your workstation, run the operator command once (it registers node
   addresses, provisions `__admin__` as born-`{1}`, waits for the reconciler to
   grow it to 3 voters, and deploys the baked app):

   ```bash
   export ROVE_CP_URL_INTERNAL=http://10.0.0.1:9090
   export ROVE_WORKER_URLS=http://10.0.0.1:8443,http://10.0.0.2:8443,http://10.0.0.3:8443
   export ROVE_CLUSTER=prod
   export ROVE_GENESIS_NODES='1=10.0.0.1:8501,10.0.0.1:9101,http://10.0.0.1:8443;2=10.0.0.2:8501,10.0.0.2:9101,http://10.0.0.2:8443;3=10.0.0.3:8501,10.0.0.3:9101,http://10.0.0.3:8443'
   # REWIND_MOVE_SECRET / REWIND_ROOT_TOKEN / REWIND_ADMIN_DOMAIN from your operator env
   rewind-ops genesis
   ```

   It is idempotent — safe to re-run if a step times out. Then provision +
   publish the rest (`rewind-ops provision …`, `rewind-ops deploy … --release`).

## Ongoing deploys (rolling)

Use [`scripts/deploy.sh`](../../deploy.sh) from your workstation — it builds,
runs the test gate, and does a quorum-safe rolling restart across all 3 nodes
(one at a time, health-gated). It pushes **binaries only**; env/secrets are
provisioned out-of-band by the steps above. Use this only on a cluster that is
already up (it assumes existing data + a leader); for a from-empty cluster use
the genesis bring-up above.

## Notes

- **`%h` is NOT expanded inside the env files** (systemd `EnvironmentFile` is
  plain `KEY=VALUE`). Anything needing the home dir (data dirs, TLS paths) is set
  via `Environment=` in the unit, where specifiers do expand.
- **The private plane has no app-layer auth** (raft `:8501`/`:9101`, worker
  `:8443` h2c). Firewall those to the 3 nodes only — see the security note in the
  plan §2.5, and set strong `REWIND_MOVE_SECRET` + `REWIND_ROOT_TOKEN`.
- **Resource directives** (`CPUWeight`/`MemoryHigh`) need cgroup-v2 controller
  delegation to the user manager to take effect; they're harmless if ignored.
