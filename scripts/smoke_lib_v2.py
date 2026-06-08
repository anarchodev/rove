#!/usr/bin/env python3
"""V2 smoke harness — the `smoke_lib` equivalent for the V2 stack (branch `v2`).

The V1 `smoke_lib.Cluster` spawned a 3-node `loop46` cluster over TLS with
leader-direct addressing + follower-503 semantics. V2 is a different shape:
per-tenant raft groups behind a CP (directory + provisioning) and a stateless
front door (Host→cluster proxy, serve-or-forward), plaintext h2c, with a
cluster-free `files-server-v2` publishing deployments to S3. So this is a
purpose-built V2 harness rather than a drop-in for the V1 `Cluster`.

`V2Cluster` brings up the topology and exposes the deploy contract the
functional smokes need:

    with V2Cluster.spawn("my-smoke", nodes=1) as c:
        c.provision("acme")                          # CP forms the group + host map
        c.deploy_handlers("acme", {"index.mjs": SRC})  # publish + flip via worker
        r = c.wait_for_handler("acme", "/")          # GET through the front door
        assert r.status == 200

Generalizes the proven flow in `v2_handler_smoke.py`. Reuses `smoke_lib`'s
`mint_jwt` + `HttpResponse`. S3 is mandatory (V2 has no fs blob backend) —
`set -a; . ./.env; set +a` first.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import mint_jwt, HttpResponse  # noqa: E402
from v2_topology import spawn_cp, spawn_front, await_ready, CP_BIN, FRONT_BIN  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
BIN_DIR = REPO_ROOT / "zig-out" / "bin"
REWIND = BIN_DIR / "rewind"
FILES_V2 = BIN_DIR / "files-server-v2"

# Fixed shared secrets (smokes don't need rotation; these match the rewind
# defaults / v2_handler_smoke so behavior is reproducible).
ROOT_TOKEN = "rewindtestroottokenpadding0123456789abcd"  # DEFAULT_ADMIN_ROOT_TOKEN
MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"
JWT_SECRET_HEX = "a" * 64  # LOOP46_SERVICES_JWT_SECRET
PUBLIC_SUFFIX = "localhost"


def _free_base(default: int) -> int:
    """Per-process port base, nudged by PID so concurrent smokes don't collide."""
    return default + (os.getpid() % 200) * 20


def _curl(url: str, *, method: str = "GET", headers: Optional[dict] = None,
          data: Optional[bytes | str] = None, host: Optional[str] = None,
          timeout: float = 15.0) -> HttpResponse:
    """Plaintext (h2c) curl → HttpResponse. V2 is h2c on localhost; no TLS/cacert."""
    args = ["curl", "-sS", "--http2-prior-knowledge", "-D", "-", "-o", "-",
            "-m", str(int(timeout)), "-X", method]
    if host:
        args += ["-H", f"Host: {host}"]
    if headers:
        for k, v in headers.items():
            args += ["-H", f"{k}: {v}"]
    if data is not None:
        if isinstance(data, str):
            data = data.encode()
        args += ["--data-binary", "@-"]
    args.append(url)
    proc = subprocess.run(args, input=data if data is not None else b"",
                          capture_output=True, timeout=timeout)
    if proc.returncode != 0:
        return HttpResponse(status=0, body=proc.stderr.decode(errors="replace"), headers={})
    raw = proc.stdout
    split = raw.rfind(b"\r\n\r\n")
    if split < 0:
        return HttpResponse(status=0, body=raw.decode(errors="replace"), headers={})
    header_block = raw[:split].decode(errors="replace")
    body = raw[split + 4:].decode(errors="replace")
    lines = header_block.splitlines()
    status_line = next((l for l in reversed(lines) if l.startswith("HTTP/")), "")
    status = 0
    parts = status_line.split(" ", 2)
    if len(parts) >= 2 and parts[1].isdigit():
        status = int(parts[1])
    headers_out: dict[str, str] = {}
    for line in lines:
        if not line.startswith("HTTP/") and ":" in line:
            k, _, v = line.partition(":")
            headers_out[k.strip().lower()] = v.strip()
    return HttpResponse(status=status, body=body, headers=headers_out)


@dataclass
class V2Cluster:
    tag: str
    cluster_id: str
    node_ports: list[int]
    raft_ports: list[int]
    cp_port: int
    front_port: int
    files_port: int
    s3_prefix: str
    data_dirs: list[Path]
    cp_data_dir: Path
    files_data_dir: Path
    procs: list = field(default_factory=list)
    log_paths: dict = field(default_factory=dict)
    root_token: str = ROOT_TOKEN
    services_jwt: str = ""

    # ── lifecycle ──────────────────────────────────────────────────────
    @classmethod
    def spawn(cls, tag: str, *, nodes: int = 1, http_base: int = 18300,
              raft_base: int = 18400, cp_port: int = 0, front_port: int = 0,
              files_port: int = 0, cluster_id: str = "cluster-1") -> "V2Cluster":
        if not os.environ.get("S3_ENDPOINT"):
            raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")
        for b in (REWIND, CP_BIN, FRONT_BIN, FILES_V2):
            if not Path(b).exists():
                raise SystemExit(f"{b} missing — `zig build rewind rewind-cp "
                                 f"rewind-front files-server-v2`")
        base = _free_base(http_base)
        rbase = _free_base(raft_base)
        pid = os.getpid()
        node_ports = [base + i for i in range(nodes)]
        raft_ports = [rbase + i for i in range(nodes)]
        c = cls(
            tag=tag, cluster_id=cluster_id,
            node_ports=node_ports, raft_ports=raft_ports,
            cp_port=cp_port or (base + 50),
            front_port=front_port or (base + 51),
            files_port=files_port or (base + 52),
            s3_prefix=f"v2smoke-{tag}-{pid}/",
            data_dirs=[Path(f"/tmp/v2smoke-{tag}-n{i}-{pid}") for i in range(nodes)],
            cp_data_dir=Path(f"/tmp/v2smoke-{tag}-cp-{pid}"),
            files_data_dir=Path(f"/tmp/v2smoke-{tag}-files-{pid}"),
        )
        for d in (*c.data_dirs, c.cp_data_dir, c.files_data_dir):
            subprocess.run(["rm", "-rf", str(d)])
        c._boot(nodes)
        return c

    def _boot(self, nodes: int) -> None:
        voters = ",".join(str(i + 1) for i in range(nodes))
        peers = ",".join(f"127.0.0.1:{rp}" for rp in self.raft_ports)
        for i in range(nodes):
            self._spawn_node(i, voters, peers)
        nodes_csv = ",".join(f"http://127.0.0.1:{p}" for p in self.node_ports)
        spawn_cp(self.procs, self.cp_port,
                 clusters=f"{self.cluster_id}={nodes_csv}",
                 hosts="", placement="", cp_data_dir=str(self.cp_data_dir),
                 move_secret=MOVE_SECRET)
        spawn_front(self.procs, self.front_port,
                    f"http://127.0.0.1:{self.cp_port}", route_cache_ms=0)
        self._spawn_files()
        # services JWT is minted client-side (files-server-v2 verifies sig+exp).
        self.services_jwt = mint_jwt(JWT_SECRET_HEX,
                                     {"exp": int((time.time() + 3600) * 1000)})

    def _spawn_node(self, i: int, voters: str, peers: str) -> None:
        env = dict(os.environ)
        env["REWIND_ADMIN_DOMAIN"] = f"n{i + 1}.localhost"
        env["REWIND_PUBLIC_SUFFIX"] = PUBLIC_SUFFIX
        env["REWIND_ROOT_TOKEN"] = self.root_token
        env["REWIND_MOVE_SECRET"] = MOVE_SECRET
        env["REWIND_NODE_ID"] = str(i + 1)
        env["REWIND_VOTERS"] = voters
        env["REWIND_PEERS"] = peers
        env["S3_KEY_PREFIX_BASE"] = self.s3_prefix
        log = f"/tmp/v2smoke-{self.tag}-n{i + 1}-{os.getpid()}.log"
        self.log_paths[f"n{i + 1}"] = log
        logf = open(log, "w+")
        p = subprocess.Popen([str(REWIND), str(self.data_dirs[i]), str(self.node_ports[i])],
                             stdout=logf, stderr=subprocess.STDOUT, env=env)
        p._name = f"n{i + 1}"
        p._logf = logf
        self.procs.append(p)
        await_ready(p, f"n{i + 1}", "listening on")

    def _spawn_files(self) -> None:
        env = dict(os.environ)
        env["LOOP46_SERVICES_JWT_SECRET"] = JWT_SECRET_HEX
        env["S3_KEY_PREFIX_BASE"] = self.s3_prefix
        p = subprocess.Popen(
            [str(FILES_V2), "--data-dir", str(self.files_data_dir),
             "--listen", f"127.0.0.1:{self.files_port}"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
        p._name = "files-v2"
        self.procs.append(p)
        await_ready(p, "files-v2", "listening on")

    def shutdown(self) -> None:
        for p in self.procs:
            if p.poll() is None:
                p.send_signal(signal.SIGTERM)
        for p in self.procs:
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
        for d in (*self.data_dirs, self.cp_data_dir, self.files_data_dir):
            subprocess.run(["rm", "-rf", str(d)])

    def __enter__(self) -> "V2Cluster":
        return self

    def __exit__(self, *exc) -> None:
        self.shutdown()

    # ── addressing ─────────────────────────────────────────────────────
    def host_for(self, tenant: str) -> str:
        return f"{tenant}.{PUBLIC_SUFFIX}"

    def admin_host(self, node: int = 0) -> str:
        return f"n{node + 1}.localhost"

    def node_url(self, node: int = 0) -> str:
        return f"http://127.0.0.1:{self.node_ports[node]}"

    def front_url(self) -> str:
        return f"http://127.0.0.1:{self.front_port}"

    def files_origin(self) -> str:
        return f"http://127.0.0.1:{self.files_port}"

    # ── provisioning + deploy ──────────────────────────────────────────
    def provision(self, tenant: str, *, host: Optional[str] = None) -> HttpResponse:
        host = host or self.host_for(tenant)
        import json
        return _curl(
            f"{self.front_url().replace(str(self.front_port), str(self.cp_port))}"
            f"/_control/provision",
            method="POST",
            headers={"X-Rewind-Move-Secret": MOVE_SECRET,
                     "Content-Type": "application/json"},
            data=json.dumps({"tenant": tenant, "cluster": self.cluster_id, "host": host}),
        )

    def upload_source(self, tenant: str, path: str, content: bytes | str) -> HttpResponse:
        return _curl(f"{self.files_origin()}/{tenant}/upload", method="POST",
                     headers={"Authorization": f"Bearer {self.services_jwt}",
                              "X-Rove-Path": path},
                     data=content)

    def deploy(self, tenant: str) -> str:
        r = _curl(f"{self.files_origin()}/{tenant}/deploy", method="POST",
                  headers={"Authorization": f"Bearer {self.services_jwt}"})
        if r.status != 200:
            raise RuntimeError(f"deploy {tenant}: {r.status} {r.body}")
        return r.body.strip()

    def release(self, tenant: str, dep_id: str | int, *, node: int = 0) -> HttpResponse:
        import json
        return _curl(f"{self.node_url(node)}/_system/release", method="POST",
                     host=self.admin_host(node),
                     headers={"Authorization": f"Bearer {self.root_token}",
                              "Content-Type": "application/json"},
                     data=json.dumps({"tenant_id": tenant, "dep_id": int(dep_id)}))

    def deploy_handlers(self, tenant: str, files: dict[str, str], *,
                        node: int = 0) -> str:
        """upload each → deploy → release. Returns dep_id. (Tenant must already
        be provisioned.)"""
        for path, content in files.items():
            r = self.upload_source(tenant, path, content)
            if r.status != 204:
                raise RuntimeError(f"upload {tenant}/{path}: {r.status} {r.body}")
        dep_id = self.deploy(tenant)
        r = self.release(tenant, dep_id, node=node)
        if r.status != 204:
            raise RuntimeError(f"release {tenant}/{dep_id}: {r.status} {r.body}")
        return dep_id

    # ── serving ────────────────────────────────────────────────────────
    def get(self, tenant: str, path: str = "/", *, host: Optional[str] = None,
            headers: Optional[dict] = None) -> HttpResponse:
        """GET through the FRONT door (Host→cluster routing)."""
        return _curl(f"{self.front_url()}{path}", host=host or self.host_for(tenant),
                     headers=headers)

    def wait_for_handler(self, tenant: str, path: str = "/", *,
                         want_status: int = 200, want_body: Optional[str] = None,
                         timeout_s: float = 25.0) -> HttpResponse:
        """Poll the front door until the deployment loads + serves (async after
        release: S3 manifest+bytecode fetch + snapshot swap)."""
        deadline = time.time() + timeout_s
        last = HttpResponse(status=0, body="", headers={})
        while time.time() < deadline:
            last = self.get(tenant, path)
            if last.status == want_status and (want_body is None or want_body in last.body):
                return last
            time.sleep(0.4)
        return last

    def dump_node_log(self, node: int = 0, *, grep: Optional[list[str]] = None) -> None:
        log = self.log_paths.get(f"n{node + 1}")
        if not log or not os.path.exists(log):
            return
        with open(log) as f:
            lines = f.read().splitlines()
        if grep:
            lines = [ln for ln in lines if any(k in ln.lower() for k in grep)]
        print(f"  --- node {node + 1} log (last 30) ---")
        for ln in lines[-30:]:
            print(f"    | {ln}")
