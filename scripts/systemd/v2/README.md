# V2 systemd env templates

The V2 stack is **four** co-located processes per host:

| Binary | Listens | Role |
|---|---|---|
| `rewind-cp` | `:9090` + raft `:9101` | directory raft + `/_control` + `/_cp` |
| `rewind-worker` | `:8443` h2c + raft `:8501` | DP multi-raft + JS dispatch |
| `rewind-front` | `:443` + `:80` | stateless public TLS edge |
| `rewind-logs` | `127.0.0.1:8444` h2c + metrics `:9113` | request-log / tape indexer + query API (per-node, S3-fed) |

## Where the units live

The **live systemd unit files were moved to the private operator repo**
(`rewind-infra`, `systemd/`), alongside the per-cluster env + secrets that
drive them, and are pushed to the nodes by that repo's `scripts/push-config.sh`
(`~/.config/systemd/user/` + `daemon-reload`). The unit files are
operator-neutral `%h`-specifier templates with no secrets, so nothing
deploy-specific leaks — they simply live next to the config that parameterizes
them.

This repo (public) keeps:
- the **env templates** here — [`common.env.example`](common.env.example) +
  [`node.env.example`](node.env.example) — the documented, secret-free
  reference for every variable each binary reads;
- the **build engine**, [`scripts/build.sh`](../../build.sh) (builds the deploy
  binaries incl. `rewind-logs` + the test gate → `zig-out/bin`). The **deploy**
  (ship + restart, rolling/genesis) moved to the private infra repo's
  `scripts/deploy.sh`, which calls `build.sh`;
- the full runbook,
  [`docs/plans/v2-production-deploy-plan.md`](../../../docs/plans/v2-production-deploy-plan.md).

## Self-hosting

A standalone, operator-neutral **self-host guide** (with example unit files +
env + the full bring-up) lives at `docs/guides/self-host.md` — start there if
you're running rove outside our deploy.
