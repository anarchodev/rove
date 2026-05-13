"""Smoke harness — Python replacement for `scripts/_smoke_helpers.sh`.

Bash smokes use `pkill -f` for cleanup, which (1) silently matches the
wrapper bash itself if the pattern is in argv, (2) leaves stragglers
when the bash script is SIGTERM'd before its EXIT trap fires (e.g.
under `timeout` or interactive Ctrl-C). The Python harness tracks every
spawned process by `Popen` object and runs `Cluster.shutdown` in a
`finally` plus `atexit` so cleanup runs on every exit path — normal
return, exception, signal.

Other improvements over bash:

  - Leader discovery polls with `time.monotonic` instead of fixed
    `sleep 0.2` loops; spurious failures are flagged with the worker
    logs so the operator knows where to look.
  - HTTP calls shell out to `curl` (mirrors bash for h2 + TLS + resolve)
    but capture exit codes + bodies as Python strings, so assertion
    failures print a structured `expected/got` line instead of bare
    grep mismatches.
  - JWT minting and `_system/services-token` parsing are pure Python
    (no `python3 -c` inline embedded in bash quoting).

Conversion pattern: `scripts/ctl_smoke.py` is the reference example.
"""

from __future__ import annotations

import atexit
import base64
import hashlib
import hmac
import json
import os
import platform
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import time
from contextlib import suppress
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


REPO_ROOT = Path(__file__).resolve().parent.parent
BIN_DIR = REPO_ROOT / "zig-out" / "bin"


# ── env / TLS / S3 prereqs ─────────────────────────────────────────────


def _load_dotenv() -> None:
    """Mirror `_smoke_helpers.sh`'s `.env` source. AWS_* + S3_* live there."""
    env_path = REPO_ROOT / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        # Strip optional surrounding quotes.
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
            v = v[1:-1]
        os.environ.setdefault(k.strip(), v.strip())


def _require_env(*names: str) -> None:
    missing = [n for n in names if not os.environ.get(n)]
    if missing:
        sys.exit(f"error: {', '.join(missing)} not set (need .env at repo root)")


def loop46_data_dir() -> Path:
    """TLS certs + ca-root live here. Mirrors the bash `LOOP46_DATA`."""
    if "LOOP46_DATA" in os.environ:
        return Path(os.environ["LOOP46_DATA"])
    if platform.system() == "Darwin":
        return Path.home() / "Library" / "Application Support" / "loop46"
    xdg = os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local" / "share"))
    return Path(xdg) / "loop46"


@dataclass
class TlsBundle:
    cert: Path
    key: Path
    cacert: Path

    @classmethod
    def from_env(cls) -> "TlsBundle":
        d = loop46_data_dir()
        cert = d / "dev-cert.pem"
        key = d / "dev-key.pem"
        cacert = d / "ca-root.pem"
        if not cert.exists() or not key.exists():
            sys.exit(
                f"error: missing TLS at {d}. Run mkcert once to generate "
                "dev-cert.pem + dev-key.pem."
            )
        return cls(cert=cert, key=key, cacert=cacert)


# ── process tracking + cleanup ─────────────────────────────────────────


_TRACKED_PROCS: list[subprocess.Popen] = []


def _terminate_all() -> None:
    """SIGTERM every tracked process, wait briefly, then SIGKILL holdouts."""
    for p in _TRACKED_PROCS:
        if p.poll() is None:
            with suppress(ProcessLookupError):
                p.terminate()
    deadline = time.monotonic() + 2.0
    for p in _TRACKED_PROCS:
        remaining = max(0.0, deadline - time.monotonic())
        with suppress(subprocess.TimeoutExpired, ProcessLookupError):
            p.wait(timeout=remaining)
    for p in _TRACKED_PROCS:
        if p.poll() is None:
            with suppress(ProcessLookupError):
                p.kill()


atexit.register(_terminate_all)


def _install_signal_handlers() -> None:
    """Trap SIGINT / SIGTERM so atexit gets to run cleanup before exit."""
    def handler(signum, _frame):
        sys.stderr.write(f"\nsmoke: caught signal {signum}, shutting down\n")
        sys.exit(130 if signum == signal.SIGINT else 143)
    signal.signal(signal.SIGINT, handler)
    signal.signal(signal.SIGTERM, handler)


# ── HTTP helpers (shell to curl, matches bash smokes byte-for-byte) ────


@dataclass
class CurlContext:
    """Resolve-overridden curl invocation. Mirrors the `CURL` bash array."""
    cacert: Path
    resolves: list[tuple[str, int]] = field(default_factory=list)
    """[(host, port), ...] — each entry adds `--resolve host:port:127.0.0.1`."""

    def args(self) -> list[str]:
        out = ["curl", "-sS", "--cacert", str(self.cacert)]
        for host, port in self.resolves:
            out += ["--resolve", f"{host}:{port}:127.0.0.1"]
        return out


@dataclass
class HttpResponse:
    status: int
    body: str
    headers: dict[str, str]


def curl(
    ctx: CurlContext,
    url: str,
    *,
    method: str = "GET",
    headers: Optional[dict[str, str]] = None,
    data: Optional[bytes | str] = None,
    timeout: float = 30.0,
) -> HttpResponse:
    args = ctx.args() + ["-D", "-", "-o", "-", "-X", method]
    if headers:
        for k, v in headers.items():
            args += ["-H", f"{k}: {v}"]
    if data is not None:
        if isinstance(data, str):
            data = data.encode()
        args += ["--data-binary", "@-"]
    args.append(url)
    proc = subprocess.run(
        args,
        input=data if data is not None else b"",
        capture_output=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"curl {method} {url} exited {proc.returncode}: "
            f"{proc.stderr.decode(errors='replace')}"
        )
    # `-D -` interleaves headers before body on stdout. Split on the
    # blank line that separates them. With redirects, multiple header
    # blocks; take the last.
    raw = proc.stdout
    split = raw.rfind(b"\r\n\r\n")
    if split < 0:
        return HttpResponse(status=0, body=raw.decode(errors="replace"), headers={})
    header_block = raw[:split].decode(errors="replace")
    body = raw[split + 4 :].decode(errors="replace")
    lines = header_block.splitlines()
    status_line = next(
        (l for l in reversed(lines) if l.startswith("HTTP/")), ""
    )
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


# ── JWT mint (matches the bash `WRONG_JWT` recipe) ─────────────────────


def _b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def mint_jwt(secret_hex: str, payload: dict, *, alg: str = "HS256") -> str:
    """HS256 JWT with the same shape worker / files-server / log-server expect.

    `secret_hex` is the hex-encoded shared secret (what `gen_jwt_secret` in
    bash produced). `payload` is dict-ified; caller supplies `exp` etc.
    """
    if alg != "HS256":
        raise NotImplementedError(alg)
    header = json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode()
    # IMPORTANT: compact separators — the worker's `hasCap` searches for
    # the literal substring `"caps":[`, so dumps' default `, ` spacing
    # produces a 401. See memory/feedback_python_jwt_compact_json.md.
    body = json.dumps(payload, separators=(",", ":")).encode()
    signing_input = (_b64u(header) + "." + _b64u(body)).encode()
    sig = hmac.new(bytes.fromhex(secret_hex), signing_input, hashlib.sha256).digest()
    return signing_input.decode() + "." + _b64u(sig)


def gen_jwt_secret() -> str:
    """32-byte hex secret; suitable for `LOOP46_SERVICES_JWT_SECRET`."""
    return secrets.token_hex(32)


# ── cluster ────────────────────────────────────────────────────────────


@dataclass
class ClusterAddrs:
    http: list[str]
    raft: list[str]
    data_dirs: list[Path]
    public_suffix: str
    admin_host: str
    files_addr: str
    log_addr: str

    @property
    def peers_csv(self) -> str:
        return ",".join(self.raft)

    def http_port(self, idx: int) -> int:
        return int(self.http[idx].rsplit(":", 1)[1])

    @property
    def files_port(self) -> int:
        return int(self.files_addr.rsplit(":", 1)[1])

    @property
    def log_port(self) -> int:
        return int(self.log_addr.rsplit(":", 1)[1])


@dataclass
class Cluster:
    """3-node cluster + optional files-server / log-server / schedule-server.

    Usage:
        with Cluster.spawn(tag="my_smoke", http_base=8197, ...) as c:
            c.discover_leader()
            c.mint_services_token()
            ...

    `__exit__` SIGTERMs every spawned process; `atexit` does the same
    as a backstop in case the context manager is bypassed.
    """

    tag: str
    addrs: ClusterAddrs
    tls: TlsBundle
    root_token: str
    services_jwt_secret: str
    workers: list[subprocess.Popen] = field(default_factory=list)
    files_server: Optional[subprocess.Popen] = None
    log_server: Optional[subprocess.Popen] = None
    schedule_server: Optional[subprocess.Popen] = None
    sse_server: Optional[subprocess.Popen] = None
    leader_idx: Optional[int] = None
    services_jwt: Optional[str] = None
    log_base: Optional[str] = None
    files_base: Optional[str] = None
    log_dir: Path = field(default_factory=lambda: Path("/tmp"))

    @classmethod
    def alloc_addrs(
        cls,
        *,
        tag: str,
        http_base: int,
        raft_base: int,
        files_port: int,
        log_port: int,
        public_suffix: str = "loop46.localhost",
    ) -> ClusterAddrs:
        return ClusterAddrs(
            http=[f"127.0.0.1:{http_base + i}" for i in range(3)],
            raft=[f"127.0.0.1:{raft_base + i}" for i in range(3)],
            data_dirs=[Path(f"/tmp/rove-{tag}-{i}") for i in range(3)],
            public_suffix=public_suffix,
            admin_host=f"app.{public_suffix}",
            files_addr=f"127.0.0.1:{files_port}",
            log_addr=f"127.0.0.1:{log_port}",
        )

    @classmethod
    def spawn(
        cls,
        *,
        tag: str,
        http_base: int,
        raft_base: int,
        files_port: int,
        log_port: int,
        public_suffix: str = "loop46.localhost",
        workers_per_node: int = 2,
        seed_manifest: Optional[dict] = None,
        seed_extra_args: Optional[list[str]] = None,
        worker_extra_args: Optional[list[str]] = None,
    ) -> "Cluster":
        _load_dotenv()
        _require_env(
            "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY",
            "S3_BUCKET",
            "S3_ENDPOINT",
            "S3_REGION",
        )
        _install_signal_handlers()

        tls = TlsBundle.from_env()
        bin_loop46 = BIN_DIR / "loop46"
        if not bin_loop46.exists():
            sys.exit(f"error: {bin_loop46} missing — run 'zig build install' first")

        addrs = cls.alloc_addrs(
            tag=tag,
            http_base=http_base,
            raft_base=raft_base,
            files_port=files_port,
            log_port=log_port,
            public_suffix=public_suffix,
        )
        for d in addrs.data_dirs:
            if d.exists():
                shutil.rmtree(d)

        # Per-smoke S3 prefix mirrors `_smoke_helpers.sh` so reruns
        # hit the warm-S3 fast path.
        binhash = "nobin"
        fs_bin = BIN_DIR / "files-server-standalone"
        if fs_bin.exists():
            binhash = hashlib.sha256(fs_bin.read_bytes()).hexdigest()[:12]
        dev_id = f"{socket.gethostname()}-{os.getuid()}-{binhash}"
        os.environ.setdefault(
            "S3_KEY_PREFIX_BASE", f"smoke-{tag}-{dev_id}/"
        )

        # Stash JWT secret + root token into the parent process env so
        # every subsequent spawned process inherits them (workers,
        # files-server, log-server, schedule-server). The bash smokes
        # `export`ed these for the same reason.
        os.environ["LOOP46_SERVICES_JWT_SECRET"] = gen_jwt_secret()
        root_token = secrets.token_hex(16)
        os.environ["LOOP46_ROOT_TOKEN"] = root_token
        env = os.environ

        c = cls(
            tag=tag,
            addrs=addrs,
            tls=tls,
            root_token=root_token,
            services_jwt_secret=env["LOOP46_SERVICES_JWT_SECRET"],
        )

        # Seed every data dir if a manifest was supplied.
        if seed_manifest is not None:
            seed_path = Path(f"/tmp/{tag}-seed.json")
            seed_path.write_text(json.dumps(seed_manifest))
            for d in addrs.data_dirs:
                d.mkdir(parents=True, exist_ok=True)
                args = [
                    str(bin_loop46), "seed",
                    "--data-dir", str(d),
                    "--manifest", str(seed_path),
                ] + (seed_extra_args or [])
                subprocess.run(args, check=True, env=env, capture_output=True)

        # Spawn workers.
        for i in range(3):
            log_path = c.log_dir / f"{tag}-worker-{i}.out"
            args = [
                str(bin_loop46), "worker",
                "--node-id", str(i),
                "--peers", addrs.peers_csv,
                "--listen", addrs.raft[i],
                "--http", addrs.http[i],
                "--log-public-base", f"https://{addrs.log_addr}",
                "--files-public-base", f"https://{addrs.files_addr}",
                "--data-dir", str(addrs.data_dirs[i]),
                "--public-suffix", public_suffix,
                "--tls-cert", str(tls.cert),
                "--tls-key", str(tls.key),
                "--workers", str(workers_per_node),
                # Match the bash default RAFT_TIMING_FLAGS.
                "--election-timeout-ms", "200",
                "--heartbeat-ms", "50",
            ] + (worker_extra_args or [])
            f = open(log_path, "wb")
            p = subprocess.Popen(args, env=env, stdout=f, stderr=subprocess.STDOUT)
            c.workers.append(p)
            _TRACKED_PROCS.append(p)
        return c

    # ── Context manager ────────────────────────────────────────────────

    def __enter__(self) -> "Cluster":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.shutdown()

    def shutdown(self) -> None:
        for p in (self.files_server, self.log_server, self.schedule_server, self.sse_server):
            if p is not None and p.poll() is None:
                with suppress(ProcessLookupError):
                    p.terminate()
        for p in self.workers:
            if p.poll() is None:
                with suppress(ProcessLookupError):
                    p.terminate()
        deadline = time.monotonic() + 2.0
        for p in self.workers + [
            x
            for x in (self.files_server, self.log_server, self.schedule_server, self.sse_server)
            if x is not None
        ]:
            remaining = max(0.0, deadline - time.monotonic())
            with suppress(subprocess.TimeoutExpired, ProcessLookupError):
                p.wait(timeout=remaining)
            if p.poll() is None:
                with suppress(ProcessLookupError):
                    p.kill()

    # ── Curl context ───────────────────────────────────────────────────

    def curl_ctx(self, *extra_hosts: str) -> CurlContext:
        """A CurlContext that resolves admin + every tenant subdomain + the
        standalones to 127.0.0.1 on the right ports."""
        resolves: list[tuple[str, int]] = [
            (f"files.{self.addrs.public_suffix}", self.addrs.files_port),
            (f"logs.{self.addrs.public_suffix}", self.addrs.log_port),
        ]
        for i in range(3):
            p = self.addrs.http_port(i)
            resolves.append((self.addrs.admin_host, p))
            for host in extra_hosts:
                resolves.append((host, p))
        return CurlContext(cacert=self.tls.cacert, resolves=resolves)

    # ── Leader discovery ───────────────────────────────────────────────

    def discover_leader(self, *, timeout_s: float = 15.0) -> int:
        """Poll each node's /_system/leader; return the leader's index."""
        deadline = time.monotonic() + timeout_s
        ctx = self.curl_ctx()
        while time.monotonic() < deadline:
            for i in range(3):
                p = self.addrs.http_port(i)
                url = f"https://{self.addrs.admin_host}:{p}/_system/leader"
                try:
                    r = curl(
                        ctx,
                        url,
                        headers={"Authorization": f"Bearer {self.root_token}"},
                        timeout=2.0,
                    )
                except (subprocess.TimeoutExpired, RuntimeError):
                    continue
                if r.status == 200:
                    self.leader_idx = i
                    return i
            time.sleep(0.2)
        # Dump worker tails so the operator can see WHY no leader.
        for i in range(3):
            log_path = self.log_dir / f"{self.tag}-worker-{i}.out"
            if log_path.exists():
                sys.stderr.write(f"--- worker {i} log (last 30 lines) ---\n")
                with log_path.open() as f:
                    lines = f.readlines()[-30:]
                sys.stderr.writelines(lines)
        raise RuntimeError(f"no leader elected within {timeout_s}s")

    def leader_port(self) -> int:
        if self.leader_idx is None:
            raise RuntimeError("call discover_leader() first")
        return self.addrs.http_port(self.leader_idx)

    def admin_origin(self) -> str:
        return f"https://{self.addrs.admin_host}:{self.leader_port()}"

    # ── Standalones (files-server, log-server) ─────────────────────────

    def spawn_files_server(
        self,
        *,
        cors_origin: Optional[str] = None,
        leader_url: Optional[str] = None,
        extra_args: Optional[list[str]] = None,
        startup_timeout_s: float = 2.0,
    ) -> None:
        bin_path = BIN_DIR / "files-server-standalone"
        log_path = self.log_dir / f"{self.tag}-files-server.out"
        env = os.environ.copy()
        if leader_url is not None:
            env["LOOP46_LEADER_CACERT"] = str(self.tls.cacert)
            host_port = leader_url.split("://", 1)[1]
            env["LOOP46_LEADER_RESOLVE"] = f"{host_port}:127.0.0.1"
        args = [
            str(bin_path),
            "--data-dir", str(self.addrs.data_dirs[self.leader_idx]),
            "--listen", self.addrs.files_addr,
            "--tls-cert", str(self.tls.cert),
            "--tls-key", str(self.tls.key),
        ]
        if cors_origin:
            args += ["--cors-origin", cors_origin]
        if leader_url:
            args += ["--leader-url", leader_url]
        args += extra_args or []
        f = open(log_path, "wb")
        self.files_server = subprocess.Popen(
            args, env=env, stdout=f, stderr=subprocess.STDOUT
        )
        _TRACKED_PROCS.append(self.files_server)
        self._wait_for_log(log_path, "listening on", startup_timeout_s, "files-server")
        if leader_url:
            self._wait_for_log(log_path, "__replay__ deploy", 15.0, "files-server bootstrap")

    def spawn_log_server(
        self,
        *,
        cors_origin: Optional[str] = None,
        startup_timeout_s: float = 2.0,
    ) -> None:
        bin_path = BIN_DIR / "log-server-standalone"
        log_path = self.log_dir / f"{self.tag}-log-server.out"
        args = [
            str(bin_path),
            "--data-dir", str(self.addrs.data_dirs[self.leader_idx]),
            "--listen", self.addrs.log_addr,
            "--poll-interval-ms", "100",
            "--tls-cert", str(self.tls.cert),
            "--tls-key", str(self.tls.key),
        ]
        if cors_origin:
            args += ["--cors-origin", cors_origin]
        f = open(log_path, "wb")
        self.log_server = subprocess.Popen(args, stdout=f, stderr=subprocess.STDOUT)
        _TRACKED_PROCS.append(self.log_server)
        self._wait_for_log(log_path, "listening on", startup_timeout_s, "log-server")

    def _wait_for_log(
        self,
        log_path: Path,
        needle: str,
        timeout_s: float,
        what: str,
    ) -> None:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            try:
                contents = log_path.read_text(errors="replace")
            except FileNotFoundError:
                contents = ""
            if needle in contents:
                return
            time.sleep(0.1)
        sys.stderr.write(
            f"{what}: didn't see '{needle}' in {log_path} within {timeout_s}s\n"
            f"--- {log_path} ---\n"
        )
        sys.stderr.write(log_path.read_text(errors="replace"))
        raise RuntimeError(f"{what} startup timeout")

    # ── Services-token mint ────────────────────────────────────────────

    def mint_services_token(self) -> None:
        ctx = self.curl_ctx()
        r = curl(
            ctx,
            f"{self.admin_origin()}/_system/services-token",
            headers={"Authorization": f"Bearer {self.root_token}"},
        )
        if r.status != 200:
            raise RuntimeError(
                f"/_system/services-token returned {r.status}: {r.body}"
            )
        parsed = json.loads(r.body)
        self.services_jwt = parsed["token"]
        self.log_base = parsed.get("log_url")
        self.files_base = parsed.get("files_url")

    # ── Assertion helper ───────────────────────────────────────────────


def expect_eq(label: str, expected, actual) -> None:
    if expected != actual:
        sys.stderr.write(f"FAIL {label}: expected '{expected}', got '{actual}'\n")
        sys.exit(1)
    print(f"ok  {label}")


def expect_status(label: str, expected: int, resp: HttpResponse) -> None:
    if resp.status != expected:
        sys.stderr.write(
            f"FAIL {label}: expected status {expected}, got {resp.status}\n"
            f"--- body ---\n{resp.body}\n"
        )
        sys.exit(1)
    print(f"ok  {label}")
