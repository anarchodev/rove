#!/usr/bin/env python3
"""V2 smoke harness — the `smoke_lib` equivalent for the V2 stack (branch `v2`).

The V1 `smoke_lib.Cluster` spawned a 3-node `loop46` cluster over TLS with
leader-direct addressing + follower-503 semantics. V2 is a different shape:
per-tenant raft groups behind a CP (directory + provisioning) and a stateless
front door (Host→cluster proxy, serve-or-forward), plaintext h2c, with deploys
compiled + staged IN the worker (`/_system/deploy` — files-server dissolved,
docs/rewind-cli-plan.md §4). So this is a purpose-built V2 harness rather than
a drop-in for the V1 `Cluster`.

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

import re
import json
import os
import signal
import subprocess
import sys
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke_lib import mint_jwt, HttpResponse  # noqa: E402
from v2_topology import spawn_cp, spawn_front, await_ready, CP_BIN, FRONT_BIN  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
BIN_DIR = REPO_ROOT / "zig-out" / "bin"
REWIND = BIN_DIR / "rewind-worker"
LOG_SERVER = BIN_DIR / "rewind-logs"

# Fixed shared secrets (smokes don't need rotation; these match the rewind
# defaults so behavior is reproducible).
# A non-default token: rewind refuses to boot on an unset/empty/default
# REWIND_ROOT_TOKEN (src/rewind/main.zig). The harness exports this to
# each worker (`REWIND_ROOT_TOKEN`) and uses it for admin-surface auth.
ROOT_TOKEN = "smoke-nonprod-root-token-0123456789abcdef"
MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"
JWT_SECRET_HEX = "a" * 64  # LOOP46_SERVICES_JWT_SECRET
PUBLIC_SUFFIX = "localhost"

# Base dir for node/cp/files/log DATA dirs (the raft WAL lives here). Defaults to
# /tmp — which on most Linux distros is TMPFS (RAM), making the WAL fsync a no-op.
# That's fine (fast) for functional smokes, but USELESS for an fsync-sensitive
# soak: a too-tight election timeout only flakes when fsync actually STALLS on
# real disk. Set V2_SMOKE_DATA_BASE to a real-disk path (e.g. under $HOME) so the
# WAL fsync hits the NVMe and the pause tail is real.
_DATA_BASE = os.environ.get("V2_SMOKE_DATA_BASE", "/tmp")

# ── fn-RPC dispatch recipe ──────────────────────────────────────────────
# The platform invokes only the activation's conventional export
# (decisions.md §4.5) — `?fn=`/`{fn,args}` routing is handler JS. This is
# the handler-shape.md recipe; `rpc_wrap` applies it to a smoke handler
# whose named exports the smoke drives via `?fn=` URLs, preserving the
# wire format every existing smoke uses.
RPC_SHIM = """\
// fn-RPC dispatch recipe (handler-shape.md; decisions.md §4.5) — the
// platform invokes only the conventional export, so named-function
// routing is handler JS.
function __rpc(fns) {
  return function () {
    let fn = null, args = [];
    for (const part of (request.query || "").split("&")) {
      const eq = part.indexOf("=");
      const k = eq === -1 ? part : part.slice(0, eq);
      if (k !== "fn" && k !== "args") continue;
      const v = eq === -1 ? "" : decodeURIComponent(part.slice(eq + 1).replace(/\\+/g, "%20"));
      if (k === "fn" && v) fn = v;
      else if (k === "args" && v) { try { args = JSON.parse(v); } catch (_) {} }
    }
    if (!fn && request.body) {
      try {
        const b = JSON.parse(request.body);
        if (b && typeof b.fn === "string") { fn = b.fn; args = Array.isArray(b.args) ? b.args : []; }
      } catch (_) {}
    }
    const f = fn ? fns[fn] : null;
    if (!f) { response.status = 404; return "no such fn: " + fn; }
    return f(...args);
  };
}
"""

_EXPORT_FN_RE = re.compile(r"^export\s+(?:async\s+)?function\s+([A-Za-z_$][\w$]*)", re.M)


def rpc_wrap(src: str) -> str:
    """Prepend the fn-RPC shim and add `export default __rpc({...})` over
    the module's exported named functions. The smoke's `?fn=`/`{fn,args}`
    wire calls are unchanged — dispatch just happens in handler JS now.
    Modules that already have a default export must compose the recipe by
    hand instead (assert so a silent double-default never deploys)."""
    assert "export default" not in src, "rpc_wrap: module already has a default export"
    names = list(dict.fromkeys(_EXPORT_FN_RE.findall(src)))
    assert names, "rpc_wrap: no exported named functions found"
    return RPC_SHIM + src + "\nexport default __rpc({ " + ", ".join(names) + " });\n"


def metric_counter(text: str, name: str) -> Optional[float]:
    """Value of a single Prometheus counter/gauge line `name <value>` in the
    `/_system/metrics` text, or None if absent."""
    for line in text.splitlines():
        if line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) == 2 and parts[0] == name:
            try:
                return float(parts[1])
            except ValueError:
                return None
    return None


def metric_hist_mean_us(text: str, name: str) -> Optional[tuple[float, int]]:
    """(_sum/_count, _count) for a Prometheus histogram `name` in µs, or None if
    no samples. For `raft_heartbeat_rtt_us` this is (mean broadcastTime µs, n)."""
    s = metric_counter(text, name + "_sum")
    c = metric_counter(text, name + "_count")
    if s is None or c is None or c == 0:
        return None
    return (s / c, int(c))


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
    return _curl_run(args, data if data is not None else b"", timeout)


def _curl_run(args: list, data: bytes, timeout: float) -> HttpResponse:
    """Run a built curl argv (with `-D - -o -`) and parse status/headers/body.
    Shared by `_curl` (h2c) and `V2Cluster.tls_curl` (https)."""
    proc = subprocess.run(args, input=data, capture_output=True, timeout=timeout)
    # Exit 55 = "failed sending data": the server replied before reading the
    # whole upload and reset the rest (RST_STREAM NO_ERROR — legal h2; an
    # onHeaders handler answering from headers alone does this on purpose).
    # curl forgives early replies only for >=400 statuses; for an early 2xx
    # it still exits 55 with the complete response in hand — report the
    # response, not a phantom transport failure.
    if proc.returncode != 0 and not (proc.returncode == 55 and b"\r\n\r\n" in proc.stdout):
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


def _gen_self_signed(prefix: str) -> tuple[str, str]:
    """Self-signed `*.localhost` cert+key (SAN also covers `localhost`) for the
    TLS front. Verification is OFF everywhere it's used — curl `-k`, and the
    worker's outbound `verify_tls=false` under `unsafe_outbound` — so validity
    is irrelevant; this only needs to make the TLS handshake + SNI succeed."""
    cert = f"/tmp/v2smoke-{prefix}-cert.pem"
    key = f"/tmp/v2smoke-{prefix}-key.pem"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", key, "-out", cert, "-days", "1",
         "-subj", "/CN=*.localhost",
         "-addext", "subjectAltName=DNS:*.localhost,DNS:localhost"],
        check=True, capture_output=True)
    return cert, key


@dataclass
class V2Cluster:
    tag: str
    cluster_id: str
    node_ports: list[int]
    raft_ports: list[int]
    cp_port: int
    front_port: int
    log_port: int
    s3_prefix: str
    data_dirs: list[Path]
    cp_data_dir: Path
    log_data_dir: Path
    procs: list = field(default_factory=list)
    node_procs: dict = field(default_factory=dict)  # node index → Popen (for stop/start)
    log_paths: dict = field(default_factory=dict)
    root_token: str = ROOT_TOKEN
    services_jwt: str = ""
    # Workers get REWIND_UNSAFE_OUTBOUND=1 by default: smoke upstream echo
    # tenants live on loopback over plaintext h2c, which the SSRF gate
    # (rove-ssrf, wired 2026-06-11) blocks in production. ssrf_smoke_v2
    # passes unsafe_outbound=False to test the production posture.
    unsafe_outbound: bool = True
    # Optional second, TLS-terminating front (step3-auth-plan.md B2). When set,
    # a `rewind-front` runs with REWIND_TLS_CERT/KEY on this port, and every
    # worker's tenant door (REWIND_INTERNAL_FRONT) pins outbound tenant-host
    # fetches HERE — so a server-side hop like the OIDC RP→IdP token exchange
    # reaches the IdP over real TLS with a consistent `https://{host}:{port}`
    # issuer. The h2c front (front_port) still serves deploys + plain requests.
    tls_front_port: int = 0
    tls_cert_path: str = ""
    tls_key_path: str = ""
    _voters: str = ""
    _peers: str = ""

    # ── lifecycle ──────────────────────────────────────────────────────
    @classmethod
    def spawn(cls, tag: str, *, nodes: int = 1, http_base: int = 18300,
              raft_base: int = 18400, cp_port: int = 0, front_port: int = 0,
              cluster_id: str = "cluster-1",
              unsafe_outbound: bool = True,
              tls_idp: bool = False) -> "V2Cluster":
        if not os.environ.get("S3_ENDPOINT"):
            raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")
        for b in (REWIND, CP_BIN, FRONT_BIN):
            if not Path(b).exists():
                raise SystemExit(f"{b} missing — `zig build rewind-worker rewind-cp "
                                 f"rewind-front`")
        base = _free_base(http_base)
        rbase = _free_base(raft_base)
        pid = os.getpid()
        node_ports = [base + i for i in range(nodes)]
        raft_ports = [rbase + i for i in range(nodes)]
        cert_path, key_path = ("", "")
        if tls_idp:
            cert_path, key_path = _gen_self_signed(f"{tag}-{pid}")
        c = cls(
            tag=tag, cluster_id=cluster_id,
            node_ports=node_ports, raft_ports=raft_ports,
            cp_port=cp_port or (base + 50),
            front_port=front_port or (base + 51),
            log_port=base + 53,
            tls_front_port=(base + 54) if tls_idp else 0,
            tls_cert_path=cert_path, tls_key_path=key_path,
            s3_prefix=f"v2smoke-{tag}-{pid}/",
            data_dirs=[Path(f"{_DATA_BASE}/v2smoke-{tag}-n{i}-{pid}") for i in range(nodes)],
            cp_data_dir=Path(f"{_DATA_BASE}/v2smoke-{tag}-cp-{pid}"),
            log_data_dir=Path(f"{_DATA_BASE}/v2smoke-{tag}-log-{pid}"),
            unsafe_outbound=unsafe_outbound,
        )
        for d in (*c.data_dirs, c.cp_data_dir):
            subprocess.run(["rm", "-rf", str(d)])
        c._boot(nodes)
        return c

    def _boot(self, nodes: int) -> None:
        voters = ",".join(str(i + 1) for i in range(nodes))
        peers = ",".join(f"127.0.0.1:{rp}" for rp in self.raft_ports)
        self._voters, self._peers = voters, peers
        for i in range(nodes):
            self._spawn_node(i, voters, peers)
        nodes_csv = ",".join(f"http://127.0.0.1:{p}" for p in self.node_ports)
        spawn_cp(self.procs, self.cp_port,
                 clusters=f"{self.cluster_id}={nodes_csv}",
                 hosts="", placement="", cp_data_dir=str(self.cp_data_dir),
                 move_secret=MOVE_SECRET)
        spawn_front(self.procs, self.front_port,
                    f"http://127.0.0.1:{self.cp_port}", route_cache_ms=0)
        if self.tls_front_port:
            # Second front, TLS-terminating, same CP. The workers' tenant door
            # pins outbound to THIS port (see _spawn_node), so RP→IdP rides real
            # TLS; deploys + plain requests stay on the h2c front above.
            spawn_front(self.procs, self.tls_front_port,
                        f"http://127.0.0.1:{self.cp_port}", route_cache_ms=0,
                        name="front-tls",
                        extra_env={"REWIND_TLS_CERT": self.tls_cert_path,
                                   "REWIND_TLS_KEY": self.tls_key_path,
                                   # Disable the privileged :80 ACME/redirect
                                   # listener (TLS mode defaults it to 80).
                                   "REWIND_HTTP_PORT": "0"})
        # Deploy now runs IN the worker (/_system/deploy) — no files-server to
        # spawn. The services JWT stays minted client-side for the log-server
        # query surface (spawn_log_server verifies sig+exp).
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
        # Step 3 (step3-auth-plan.md A2/A3): wire the `rewind-logs.internal`
        # fetch-engine door so the `__admin__` chokepoint reads tenant logs
        # with a worker-minted, tenant-scoped `logs-read` token. The secret is
        # the SAME hex the co-spawned log-server verifies with; the base points
        # at the log-server's deterministic port. Harmless when no door fetch
        # fires (the door is gated to `__admin__` outbound only).
        env["LOOP46_SERVICES_JWT_SECRET"] = JWT_SECRET_HEX
        env["REWIND_LOG_INTERNAL_BASE"] = f"http://127.0.0.1:{self.log_port}"
        # Scope this cluster's request-log/tape batches under the same per-run
        # S3 prefix as its blobs (the shared bucket hosts every smoke run), so
        # a co-spawned `rewind-logs` reads exactly this cluster's
        # batches. rewind defaults the log key prefix to LOG_S3_KEY_PREFIX.
        env["LOG_S3_KEY_PREFIX"] = self.s3_prefix
        if self.unsafe_outbound:
            env["REWIND_UNSAFE_OUTBOUND"] = "1"
        # When the tenant door is enabled (REWIND_INTERNAL_FRONT, set by the
        # door smoke), the door only fires for the front's TLS port. Our test
        # front binds a high port, not 443, so tell the worker which port to
        # accept — otherwise the door declines every test fetch.
        if self.tls_front_port:
            # OIDC RP→IdP (and any tenant-host outbound) pins to the TLS front.
            env["REWIND_INTERNAL_FRONT"] = "127.0.0.1"
            env["REWIND_INTERNAL_FRONT_PORT"] = str(self.tls_front_port)
        elif env.get("REWIND_INTERNAL_FRONT"):
            env["REWIND_INTERNAL_FRONT_PORT"] = str(self.front_port)
        log = f"/tmp/v2smoke-{self.tag}-n{i + 1}-{os.getpid()}.log"
        self.log_paths[f"n{i + 1}"] = log
        logf = open(log, "w+")
        p = subprocess.Popen([str(REWIND), str(self.data_dirs[i]), str(self.node_ports[i])],
                             stdout=logf, stderr=subprocess.STDOUT, env=env)
        p._name = f"n{i + 1}"
        p._logf = logf
        self.procs.append(p)
        self.node_procs[i] = p
        await_ready(p, f"n{i + 1}", "listening on")

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
        # A handled SIGTERM exits 0; anything else (SIGABRT = a Zig panic,
        # SIGSEGV, nonzero) is a teardown bug — drain and surface it.
        for p in self.procs:
            if p.returncode not in (0, -signal.SIGKILL):
                tail = p.stdout.read() if p.stdout else ""
                name = getattr(p, "_name", "?")
                print(f"TEARDOWN: {name} (pid {p.pid}) exited rc={p.returncode}")
                print("\n".join("  | " + l for l in tail.splitlines()[-40:]))
        for d in (*self.data_dirs, self.cp_data_dir, self.log_data_dir):
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

    def log_url(self) -> str:
        return f"http://127.0.0.1:{self.log_port}"

    # ── rewind-logs (tape / request-log query surface) ───────
    def spawn_log_server(self, *, poll_interval_ms: int = 200,
                         startup_timeout_s: float = 5.0):
        """Spawn `rewind-logs` (h2c) reading THIS cluster's request-
        log / tape batches from S3. It shares the cluster's S3 connection +
        per-run `LOG_S3_KEY_PREFIX` (so it sees exactly the batches the rewind
        workers flushed) and the services JWT secret (auth = a valid signed
        token — `self.services_jwt`). Polls S3 LIST every `poll_interval_ms`
        to index new batches; query via `log_get`. Appended to `self.procs`
        for teardown."""
        env = dict(os.environ)
        env["LOOP46_SERVICES_JWT_SECRET"] = JWT_SECRET_HEX
        env["S3_KEY_PREFIX_BASE"] = self.s3_prefix
        env["LOG_S3_KEY_PREFIX"] = self.s3_prefix
        subprocess.run(["rm", "-rf", str(self.log_data_dir)])
        log = f"/tmp/v2smoke-{self.tag}-logsrv-{os.getpid()}.log"
        self.log_paths["logsrv"] = log
        logf = open(log, "w+")
        p = subprocess.Popen(
            [str(LOG_SERVER),
             "--data-dir", str(self.log_data_dir),
             "--listen", f"127.0.0.1:{self.log_port}",
             "--poll-interval-ms", str(poll_interval_ms)],
            stdout=logf, stderr=subprocess.STDOUT, env=env)
        p._name = "logsrv"
        p._logf = logf
        self.procs.append(p)
        await_ready(p, "logsrv", "listening on", timeout=startup_timeout_s)
        return p

    def log_scoped_token(self, tenant: str, *, caps=("logs-read",),
                         ttl_s: int = 300) -> str:
        """Mint a TENANT-SCOPED `logs-read` services token. The log-server
        verifies cap + tenant (step3-auth-plan.md A4 / rewind-cli-plan.md §7),
        so a read token must carry both `caps:[logs-read]` and the tenant it
        reads. Exposed so negative tests can mint deliberately-mismatched
        tokens (wrong tenant / missing cap / unscoped)."""
        payload = {"exp": int((time.time() + ttl_s) * 1000), "tenant": tenant}
        if caps:
            payload["caps"] = list(caps)
        return mint_jwt(JWT_SECRET_HEX, payload)

    def log_get(self, subpath: str, *, timeout: float = 15.0,
                tenant: Optional[str] = None) -> HttpResponse:
        """GET `{log_url}/v1/{subpath}` with a tenant-scoped `logs-read` token.
        The tenant defaults to the first path segment (e.g. `acme/list?limit=20`
        → scoped to `acme`); pass `tenant=` to override. E.g.
        `log_get(f"{tenant}/list?limit=20")` or `log_get(f"{tenant}/show/{rid}")`."""
        t = tenant or subpath.split("/", 1)[0]
        token = self.log_scoped_token(t)
        return _curl(f"{self.log_url()}/v1/{subpath}",
                     headers={"Authorization": f"Bearer {token}"},
                     timeout=timeout)

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

    @staticmethod
    def _b64(content: bytes | str) -> str:
        import base64
        b = content.encode() if isinstance(content, str) else content
        return base64.b64encode(b).decode()

    def _ensure_admin_app(self) -> None:
        """Idempotently bring up the standing __admin__ deploy app. Provision
        __admin__ (forms its raft group), then POST /_system/reset (root-gated,
        no body) — the worker's bootstrap+break-glass endpoint that (re)deploys
        the BAKED deploy app and stamps _deploy/current (rewind-cli-plan §4).
        reset stamps the release via raft, so a follower 503s — try each node
        until the leader accepts. The app answers POST on "/" — a GET → 405
        confirms it's live. Runs once per cluster."""
        if getattr(self, "_admin_app_ready", False):
            return
        self.provision("__admin__")  # 204 or 409 (already) — both fine
        deadline = time.time() + 30.0
        last = None
        while time.time() < deadline:
            for n in range(len(self.node_ports)):
                last = _curl(f"{self.node_url(n)}/_system/reset", method="POST",
                             host=self.admin_host(n),
                             headers={"Authorization": f"Bearer {self.root_token}"},
                             timeout=30.0)
                if last.status == 200:
                    break
            if last is not None and last.status == 200:
                break
            time.sleep(0.2)
        if last is None or last.status != 200:
            self.dump_node_log(grep=["reset", "deploy", "admin", "leader",
                                     "loader", "error", "warn"])
            raise RuntimeError(
                f"/_system/reset bootstrap failed: "
                f"{last.status if last else '?'} {last.body if last else ''!r}")
        r = self.wait_for_handler("__admin__", "/", want_status=405, timeout_s=30.0)
        if r.status != 405:
            self.dump_node_log(grep=["reset", "deploy", "admin", "loader",
                                     "error", "warn"])
            raise RuntimeError(f"deploy app not live after reset: {r.status} {r.body!r}")
        self._admin_app_ready = True

    def deploy_bundle(self, tenant: str, files: list[dict], *, node: int = 0) -> str:
        """Deploy a full bundle by POSTing it to the standing __admin__ deploy
        app through the front door (rewind-cli-plan §4 — the ONE deploy path;
        the Zig /_system/deploy route is gone). `files` is a list of
        `{"path","kind","content_type","b64"}` dicts. The app compiles handlers
        (platform.compile), content-addresses every file into the TARGET
        tenant's own blobs (cross-tenant platform.scope(t).blob.put), and stamps
        the manifest (platform.scope(t).deploy.stampManifest — an S3 PUT, any
        node). Returns the hex dep_id. Does NOT release.

        `node` is vestigial (the front Host-routes to __admin__); kept for
        call-site compatibility."""
        import base64
        import json
        self._ensure_admin_app()
        handlers, statics = [], []
        for f in files:
            if f.get("kind") == "static":
                statics.append({"path": f["path"],
                                "content_type": f.get("content_type",
                                                      "application/octet-stream"),
                                "b64": f["b64"]})
            else:
                handlers.append({"path": f["path"],
                                 "source": base64.b64decode(f["b64"]).decode()})
        r = _curl(f"{self.front_url()}/", method="POST",
                  host=self.host_for("__admin__"),
                  headers={"Authorization": f"Bearer {self.root_token}",
                           "Content-Type": "application/json"},
                  data=json.dumps({"tenant": tenant, "handlers": handlers,
                                   "statics": statics}), timeout=30.0)
        if r.status != 200:
            raise RuntimeError(f"deploy {tenant}: {r.status} {r.body}")
        payload = json.loads(r.body)
        if payload.get("ok") is not True or not payload.get("dep_id"):
            raise RuntimeError(f"deploy {tenant}: bad payload {r.body[:200]!r}")
        return payload["dep_id"]  # 16-hex-digit string

    def release(self, tenant: str, dep_id: str | int, *, node: int = 0) -> HttpResponse:
        """POST the release flip. Leader-aware: the release proposes through
        the tenant's raft group, so a follower 421s (NotLeader, rolled back —
        decisions.md §10.5c); try each node starting from `node` until one
        accepts. Single-node clusters never 421."""
        import json
        r = None
        for k in range(max(1, len(self.node_ports))):
            i = (node + k) % max(1, len(self.node_ports))
            r = _curl(f"{self.node_url(i)}/_system/release", method="POST",
                      host=self.admin_host(i),
                      headers={"Authorization": f"Bearer {self.root_token}",
                               "Content-Type": "application/json"},
                      data=json.dumps({"tenant_id": tenant, "dep_id": int(dep_id)}))
            if r.status != 421:
                return r
        return r

    def deploy_handlers(self, tenant: str, files: dict[str, str], *,
                        node: int = 0) -> str:
        """Deploy handler sources (all compiled) + release. Returns the dep_id
        (decimal str). (Tenant must already be provisioned.)"""
        bundle = [{"path": p, "kind": "handler", "content_type": "",
                   "b64": self._b64(c)} for p, c in files.items()]
        dep_hex = self.deploy_bundle(tenant, bundle, node=node)
        r = self.release(tenant, int(dep_hex, 16), node=node)
        if r.status != 204:
            raise RuntimeError(f"release {tenant}/{dep_hex}: {r.status} {r.body}")
        return str(int(dep_hex, 16))

    def deploy_with_static(self, tenant: str, handler_files: dict[str, str],
                           static_files: dict[str, tuple], *, node: int = 0) -> str:
        """Deploy handlers PLUS one or more STATIC manifest entries (e.g. a
        `_config/*.json` row) in ONE `/_system/deploy` bundle, then release.
        Statics drive the deploy-time `_config/` → kv mirror
        (`src/js/config_mirror.zig` via the loader's `reloadDeployment`).

        `static_files` maps path → `(bytes_or_str, content_type)`. The worker
        stamps an explicit manifest from exactly this bundle (no carry-forward
        of prior entries). Returns the new dep_id (decimal str)."""
        bundle = [{"path": p, "kind": "handler", "content_type": "",
                   "b64": self._b64(c)} for p, c in handler_files.items()]
        bundle += [{"path": p, "kind": "static", "content_type": ct,
                    "b64": self._b64(content)}
                   for p, (content, ct) in static_files.items()]
        dep_hex = self.deploy_bundle(tenant, bundle, node=node)
        r = self.release(tenant, int(dep_hex, 16), node=node)
        if r.status != 204:
            raise RuntimeError(f"release {tenant}/{dep_hex}: {r.status} {r.body}")
        return str(int(dep_hex, 16))

    def deploy_manifest(self, tenant: str, files: dict[str, tuple[str, bytes | str]],
                        *, node: int = 0) -> str:
        """Content-addressed deploy with explicit per-file kind. `files` maps
        each path → (kind, content) where kind is "handler" or "static".
        Handlers compile server-side; statics are stored verbatim (content-type
        inferred: `.json`→application/json, else application/octet-stream). The
        only way to deploy a non-JS file (e.g. a subscription `spec.json`, which
        the loader requires to be `kind=static`). Returns dep_id (decimal str).
        (Tenant must be provisioned.)"""
        bundle = []
        for path, (kind, content) in files.items():
            ct = ""
            if kind == "static":
                ct = "application/json" if path.endswith(".json") \
                    else "application/octet-stream"
            bundle.append({"path": path, "kind": kind, "content_type": ct,
                           "b64": self._b64(content)})
        dep_hex = self.deploy_bundle(tenant, bundle, node=node)
        r = self.release(tenant, int(dep_hex, 16), node=node)
        if r.status != 204:
            raise RuntimeError(f"release {tenant}/{dep_hex}: {r.status} {r.body}")
        return str(int(dep_hex, 16))

    # ── serving ────────────────────────────────────────────────────────
    def request(self, tenant: str, path: str = "/", *, method: str = "GET",
                data: Optional[bytes | str] = None, host: Optional[str] = None,
                headers: Optional[dict] = None,
                timeout: float = 15.0) -> HttpResponse:
        """Any method through the FRONT door (Host→cluster routing). Pass a
        larger `timeout` for held requests (on.* wakes can ride up to the
        §6.4 ~25s deadline before resolving)."""
        return _curl(f"{self.front_url()}{path}", method=method, data=data,
                     host=host or self.host_for(tenant), headers=headers,
                     timeout=timeout)

    def get(self, tenant: str, path: str = "/", *, host: Optional[str] = None,
            headers: Optional[dict] = None, timeout: float = 15.0) -> HttpResponse:
        """GET through the FRONT door (Host→cluster routing)."""
        return self.request(tenant, path, host=host, headers=headers,
                            timeout=timeout)

    # ── TLS front (OIDC / RP flows, B2) ────────────────────────────────
    def tls_origin(self, tenant: str) -> str:
        """`https://{tenant}.{suffix}:{tls_front_port}` — an IdP/app origin on
        the TLS front. Use as the OIDC issuer / RP redirect base so the wire
        host:port matches the `https://{host}` the IdP signs into `iss`."""
        return f"https://{self.host_for(tenant)}:{self.tls_front_port}"

    def tls_curl(self, url: str, *, method: str = "GET",
                 data: Optional[bytes | str] = None,
                 headers: Optional[dict] = None,
                 timeout: float = 15.0) -> HttpResponse:
        """HTTPS request to the TLS front. `url` is absolute
        (`https://{host}:{tls_front_port}{path}`); its host is `--resolve`'d to
        127.0.0.1 so SNI + Host both carry the tenant host. No redirect-follow
        (captures Location/Set-Cookie); `-k` — the front cert is self-signed."""
        u = urllib.parse.urlparse(url)
        host, port = u.hostname, (u.port or self.tls_front_port)
        args = ["curl", "-sS", "--http2", "-k",
                "--resolve", f"{host}:{port}:127.0.0.1",
                "-D", "-", "-o", "-", "-m", str(int(timeout)), "-X", method]
        if headers:
            for k, v in headers.items():
                args += ["-H", f"{k}: {v}"]
        if data is not None:
            if isinstance(data, str):
                data = data.encode()
            args += ["--data-binary", "@-"]
        args.append(url)
        return _curl_run(args, data if data is not None else b"", timeout)

    def node_request(self, path: str, *, method: str = "GET", node: int = 0,
                     host: Optional[str] = None, data: Optional[bytes | str] = None,
                     headers: Optional[dict] = None) -> HttpResponse:
        """Direct-to-node call (bypasses the front). For `/_system/*` admin
        surfaces — pass `host=self.admin_host(node)`."""
        return _curl(f"{self.node_url(node)}{path}", method=method, data=data,
                     host=host, headers=headers)

    def admin_kv_get(self, tenant: str, key: str, *, node: int = 0) -> HttpResponse:
        """Read a tenant KV key via the worker's `/_system/v2-kv` (move-secret
        gated) — handy for asserting a handler's durable writes landed."""
        return _curl(
            f"{self.node_url(node)}/_system/v2-kv?tenant={tenant}&key={key}",
            headers={"X-Rewind-Move-Secret": MOVE_SECRET})

    def admin_kv_put(self, tenant: str, key: str, value: str, *,
                     node: int = 0) -> HttpResponse:
        """Write a tenant KV key via the worker's `/_system/v2-kv` (move-secret
        gated, same surface `three_node_smoke` seeds through). The PUT goes
        through the addressed node's leader propose→commit path, so target the
        leader node (a follower 503s). Symmetric to `admin_kv_get` — together
        they assert replication/durability across moves + failovers without
        needing the deployment-load path."""
        import json
        return _curl(
            f"{self.node_url(node)}/_system/v2-kv", method="PUT",
            headers={"X-Rewind-Move-Secret": MOVE_SECRET,
                     "Content-Type": "application/json"},
            data=json.dumps({"tenant": tenant, "key": key, "value": value}))

    def set_plan(self, tenant: str, plan_blob: str, *, node: int = 0) -> HttpResponse:
        """Install a tenant's resolved plan limits on its hot-path slot via the
        worker's `/_system/v2-plan` (move-secret gated) — the CP's live
        single-target push (docs/v2-cp-operational-state.md "Live tier
        change"). `plan_blob` is the opaque `{tier, overrides}` JSON the CP
        stores; an empty/malformed blob resolves to the free tier. 204 on
        success. Bumps `plan_gen` so the rate limiter re-snapshots caps — used
        by the rate-limit smoke to dial a tiny `request_capacity`."""
        import json
        return _curl(
            f"{self.node_url(node)}/_system/v2-plan", method="POST",
            headers={"X-Rewind-Move-Secret": MOVE_SECRET,
                     "Content-Type": "application/json"},
            data=json.dumps({"tenant": tenant, "plan": plan_blob}))

    def get_plan(self, tenant: str, *, node: int = 0) -> HttpResponse:
        """Read the tenant's RESOLVED effective limits (JSON + `plan_gen`) via
        `GET /_system/v2-plan` — diagnostic read-back that delivery landed."""
        return _curl(
            f"{self.node_url(node)}/_system/v2-plan?tenant={tenant}",
            headers={"X-Rewind-Move-Secret": MOVE_SECRET})

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

    # ── multi-node (failover smokes) ───────────────────────────────────
    def leader_now(self, tenant: str, *, nodes: Optional[list[int]] = None) -> Optional[int]:
        """Single-shot (NO polling): index of a live node whose
        `/_system/v2-leader` returns 200 for `tenant`, else None. For tight
        failover-timing loops where the 0.4s `leader_node` poll is too coarse."""
        for i in (nodes if nodes is not None else range(len(self.node_ports))):
            if i not in self.node_procs or self.node_procs[i].poll() is not None:
                continue
            r = _curl(f"{self.node_url(i)}/_system/v2-leader?tenant={tenant}",
                      headers={"X-Rewind-Move-Secret": MOVE_SECRET})
            if r.status == 200:
                return i
        return None

    def leader_node(self, tenant: str, *, deadline_s: float = 20.0) -> Optional[int]:
        """Index of the node currently leading `tenant`'s raft group (the node
        whose `/_system/v2-leader` returns 200), or None. Polls until a leader
        appears (a freshly-formed/re-elected group needs a moment)."""
        deadline = time.time() + deadline_s
        while time.time() < deadline:
            got = self.leader_now(tenant)
            if got is not None:
                return got
            time.sleep(0.4)
        return None

    def stop_node(self, i: int) -> None:
        """SIGTERM node `i` (simulate a node death / leader kill)."""
        p = self.node_procs.get(i)
        if p is None or p.poll() is not None:
            return
        p.send_signal(signal.SIGTERM)
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()

    def kill_node(self, i: int) -> None:
        """SIGKILL node `i` — a HARD crash with NO graceful leadership handoff
        (unlike `stop_node`'s SIGTERM, which triggers transfer_leader). Use this
        to measure ELECTION-timeout failover (the latency `election_tick` governs)
        rather than the graceful ~one-heartbeat handoff."""
        p = self.node_procs.get(i)
        if p is None or p.poll() is not None:
            return
        p.send_signal(signal.SIGKILL)
        p.wait()

    def metrics(self, node: int = 0) -> str:
        """Fetch the node's Prometheus `/_system/metrics` text (root-token gated).
        Returns "" if the node is down / unreachable."""
        r = _curl(f"{self.node_url(node)}/_system/metrics",
                  headers={"Authorization": f"Bearer {self.root_token}"})
        return r.body if r.status == 200 else ""

    def start_node(self, i: int) -> None:
        """Re-spawn node `i` with its original voter/peer config (rejoins the
        group, catches up via raft / snapshot)."""
        self._spawn_node(i, self._voters, self._peers)

    def request_retry(self, tenant: str, path: str = "/", *, want_status: int = 200,
                      want_body: Optional[str] = None, method: str = "GET",
                      data: Optional[bytes | str] = None, deadline_s: float = 20.0,
                      headers: Optional[dict] = None) -> HttpResponse:
        """Retry a front-door request while a cluster (re)elects a leader — a
        write to a follower 503s; a killed node surfaces non-want. Used by
        failover smokes after `stop_node`."""
        deadline = time.time() + deadline_s
        last = HttpResponse(status=0, body="", headers={})
        while time.time() < deadline:
            last = self.request(tenant, path, method=method, data=data, headers=headers)
            if last.status == want_status and (want_body is None or want_body in last.body):
                return last
            time.sleep(0.4)
        return last
